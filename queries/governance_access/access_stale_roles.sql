-- query_id: access_stale_roles
-- title: Roles that hold privileges but are held by nobody - access that exists for no one
-- domain: governance_access   tier: standard
-- rung: account_usage - the only rung that can enumerate EVERY role in the account and every user assignment in one pass. SHOW GRANTS answers one role at a time, so a stale-role sweep on the SHOW rung is hundreds of statements.
-- reads: snowflake.account_usage.roles, snowflake.account_usage.grants_to_roles, snowflake.account_usage.grants_to_users, snowflake.account_usage.login_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - ROLES, GRANTS_TO_ROLES, GRANTS_TO_USERS and LOGIN_HISTORY each carry a documented latency of up to 2 hours. A role created or a user assigned this morning can still read as stale; re-check anything created inside that window before revoking.
-- params: :period_days (default 90) how far back a successful login counts as someone still using this role; :min_grants (default 1) a role holding fewer privileges than this is not judged, so freshly-created empty roles do not flood the result
-- confidence: confirmed-docs
-- confidence_note: ROLES, GRANTS_TO_ROLES, GRANTS_TO_USERS and LOGIN_HISTORY are documented ACCOUNT_USAGE views and every column used appears in their documented column lists. Two things could not be doc-verified and are handled defensively: LOGIN_HISTORY.IS_SUCCESS is documented as a VARCHAR with no enumerated value list, so it is compared case-insensitively against YES; and the exact form a DATABASE_ROLE takes in GRANTS_TO_ROLES.GRANTEE_NAME (bare name vs database-qualified) is version-dependent, so the role key is matched both ways and the join may need narrowing on your version.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window
-- read_this: One row = one live role. The two columns that matter are grants_held (how much access this role carries) and users_holding_directly (how many people hold it). A role with the first and not the second is a standing privilege set attached to nobody - the thing an attacker looks for and an auditor cannot explain.
-- healthy: every role with grants is either held directly by at least one user who has logged in inside :period_days, or is a functional parent role that other roles inherit from (roles_holding_this_role greater than zero).
-- investigate_if: CRITICAL when a role holds privileges and nobody at all reaches it - no user, no parent role. WARN when the only people holding it have not logged in inside :period_days, which is an offboarding leftover as often as it is a seasonal role. False positive: a break-glass role deliberately held by nobody until an incident, and a role used only by a service that authenticates without writing a LOGIN_HISTORY row inside the window you chose.
-- actions: 1) list the CRITICAL roles and ask an owner to claim each one - a role nobody claims is the answer (free); 2) revoke the role assignment from users who have not logged in, before touching the role itself, so the change is reversible (config); 3) drop the role only after a full :period_days observation window with its grants already revoked - dropping a role destroys its grant history on the SHOW rung (config).
-- next: access_who_can_read_object_au (if a CRITICAL role holds a grant on an object you care about and you need the closure), access_share_exposure (if a stale role also owns a share), gov_object_tag_coverage (if you cannot attribute a role to a team and need the tagging that would have)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE. It sees every role and every live assignment, which no lower rung can do in one pass. It does NOT see whether a role is actually USED - only whether the people holding it logged in at all; a user can log in daily and never once activate this role.
-- caveats: Holding is not using: a user who logs in and never activates the role still counts as a holder here. LOGIN_HISTORY retains 365 days, so a :period_days larger than that silently truncates. roles_holding_this_role is a ONE-HOP count, not a transitive closure - a role reachable only through a chain still shows one. Database, instance and application roles are included and keyed with their database prefix where one exists, but their grantee form in GRANTS_TO_ROLES is version-dependent, so the key is matched both qualified and bare. A role held only by a share or by another account is invisible in GRANTS_TO_USERS and will read as CRITICAL.

WITH live_roles AS (
  SELECT
    r.name                                                                           AS role_name,
    r.role_type                                                                      AS role_type,
    r.role_database_name                                                             AS role_database,
    r.owner                                                                          AS role_owner,
    r.created_on                                                                     AS role_created_on,
    IFF(r.role_database_name IS NULL, r.name, r.role_database_name || '.' || r.name) AS role_key
  FROM snowflake.account_usage.roles r
  WHERE r.deleted_on IS NULL
),
grants_held AS (
  -- how much access each role CARRIES (privileges granted TO the role)
  SELECT
    g.grantee_name                    AS grantee_key,
    COUNT(*)                          AS grants_held,
    COUNT(DISTINCT g.granted_on)      AS object_kinds_reached,
    MAX(g.created_on)                 AS last_grant_added_on
  FROM snowflake.account_usage.grants_to_roles g
  WHERE g.deleted_on IS NULL
    AND UPPER(g.granted_to) IN ('ROLE', 'ACCOUNT ROLE', 'DATABASE_ROLE', 'INSTANCE_ROLE', 'APPLICATION_ROLE')
  GROUP BY 1
),
held_by_roles AS (
  -- who HOLDS the role - USAGE on a role is the hierarchy edge, ownership is not
  SELECT
    g.name                            AS role_key,
    COUNT(DISTINCT g.grantee_name)    AS roles_holding_this_role
  FROM snowflake.account_usage.grants_to_roles g
  WHERE g.deleted_on IS NULL
    AND UPPER(g.granted_on) IN ('ROLE', 'DATABASE_ROLE')
    AND UPPER(g.privilege) = 'USAGE'
  GROUP BY 1
),
held_by_users AS (
  SELECT
    u.role                            AS role_key,
    COUNT(DISTINCT u.grantee_name)    AS users_holding_directly,
    MIN(u.created_on)                 AS first_assigned_on
  FROM snowflake.account_usage.grants_to_users u
  WHERE u.deleted_on IS NULL
  GROUP BY 1
),
recent_logins AS (
  SELECT DISTINCT l.user_name
  FROM snowflake.account_usage.login_history l
  WHERE l.event_timestamp >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND UPPER(l.is_success) = 'YES'
),
active_holders AS (
  SELECT
    u.role                            AS role_key,
    COUNT(DISTINCT u.grantee_name)    AS users_who_logged_in
  FROM snowflake.account_usage.grants_to_users u
  JOIN recent_logins rl
    ON rl.user_name = u.grantee_name
  WHERE u.deleted_on IS NULL
  GROUP BY 1
)
SELECT
  lr.role_key                                    AS role_name,
  lr.role_type                                   AS role_type,
  lr.role_database                               AS role_database,
  lr.role_owner                                  AS role_owner,
  lr.role_created_on                             AS role_created_on,
  COALESCE(ghq.grants_held, 0) + COALESCE(ghb.grants_held, 0)                    AS grants_held,
  GREATEST(COALESCE(ghq.object_kinds_reached, 0),
           COALESCE(ghb.object_kinds_reached, 0))                                AS object_kinds_reached,
  GREATEST(COALESCE(ghq.last_grant_added_on, TO_TIMESTAMP_LTZ(0)),
           COALESCE(ghb.last_grant_added_on, TO_TIMESTAMP_LTZ(0)))               AS last_grant_added_on,
  COALESCE(hu.users_holding_directly, 0)                                         AS users_holding_directly,
  COALESCE(ah.users_who_logged_in, 0)                                            AS users_who_logged_in,
  COALESCE(hrq.roles_holding_this_role, 0)
    + COALESCE(hrb.roles_holding_this_role, 0)                                   AS roles_holding_this_role,
  hu.first_assigned_on                                                           AS first_assigned_on,
  CASE
    WHEN COALESCE(ghq.grants_held, 0) + COALESCE(ghb.grants_held, 0)
         < :min_grants                                                     THEN 'NOT_ASSESSED'
    WHEN COALESCE(hu.users_holding_directly, 0) = 0
     AND COALESCE(hrq.roles_holding_this_role, 0)
       + COALESCE(hrb.roles_holding_this_role, 0) = 0                      THEN 'CRITICAL'
    WHEN COALESCE(ah.users_who_logged_in, 0) = 0
     AND COALESCE(hrq.roles_holding_this_role, 0)
       + COALESCE(hrb.roles_holding_this_role, 0) = 0                      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM live_roles lr
-- Two joins per side, never an OR: a database role can appear in GRANTS_TO_ROLES either
-- database-qualified or bare depending on version, and a single OR join would match both and
-- double the row. Each join here matches at most one aggregated row, so the counts add instead.
LEFT JOIN grants_held    ghq ON ghq.grantee_key = lr.role_key
LEFT JOIN grants_held    ghb ON ghb.grantee_key = lr.role_name AND lr.role_key <> lr.role_name
LEFT JOIN held_by_roles  hrq ON hrq.role_key    = lr.role_key
LEFT JOIN held_by_roles  hrb ON hrb.role_key    = lr.role_name AND lr.role_key <> lr.role_name
LEFT JOIN held_by_users  hu  ON hu.role_key     = lr.role_name
LEFT JOIN active_holders ah  ON ah.role_key     = lr.role_name
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  grants_held DESC,
  role_name;
