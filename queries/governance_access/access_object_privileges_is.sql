-- query_id: access_object_privileges_is
-- title: What privileges exist on this object, as a joinable view (INFORMATION_SCHEMA, live)
-- domain: governance_access   tier: lite
-- rung: information_schema - the lowest rung there is: live, no IMPORTED PRIVILEGES, and unlike SHOW it is a VIEW, so you can join it, filter it and union it.
-- reads: information_schema.object_privileges
-- requires: nothing beyond the caller own grants - OBJECT_PRIVILEGES shows only objects the current session role has access privileges on. Run it with :object_database as the session database.
-- freshness: LIVE - reflects the grant state at this second, with none of the ACCOUNT_USAGE lag.
-- params: :object_database (default CROSSHIRE) database holding the object, and the database whose INFORMATION_SCHEMA is read; :object_schema (default SILVER) schema holding it; :object_name (default ORDERS) unqualified object name
-- confidence: confirmed-docs
-- confidence_note: Every column named is from the documented INFORMATION_SCHEMA.OBJECT_PRIVILEGES column list (docs.snowflake.com/en/sql-reference/info-schema/object_privileges), which also documents the role-scoping limitation quoted in caveats. Not run against a live account. IS_GRANTABLE is documented as a VARCHAR; the YES/NO literals are the observed convention across INFORMATION_SCHEMA and are compared case-insensitively here rather than assumed.
-- empty_if: current_database_only, privilege_scoped
-- read_this: One row = one privilege granted to one grantee on this object. The two columns that matter are grantee_role and privilege_type; read confers_read alongside them, because most rows on a busy object are write or admin privileges that this audit is not about.
-- healthy: the read-conferring rows name only roles you can attribute to an owner, and is_grantable is NO on every row except the owner.
-- investigate_if: WARN when a read-conferring privilege is grantable by a non-owner - that role can re-grant your table onward. CRITICAL when grantee_kind is USER. NOT_ASSESSED marks a privilege this query does not judge (a write or admin privilege); it is context, not a finding. False positive: an empty result usually means the object is invisible to your role, NOT that the object has no grants - see caveats.
-- actions: 1) run it a second time under a different role and compare - a differing answer is the scoping caveat, not a change (free); 2) revoke privileges granted directly to a USER and re-issue through a role (config); 3) remove the grant option from non-owner grantees (config).
-- next: access_grants_on_object_show (if you want the SHOW form, which also returns granted_by_role_type), access_who_can_read_object_proc (if a role appears here and you need to know who holds it), access_who_can_read_object_au (if you need the account-wide or historical answer)
-- covers: ONE HOP, LIVE, CALLER-SCOPED, ONE DATABASE. This rung answers WHAT PRIVILEGES EXIST on an object. It does not answer WHO CAN READ IT: INFORMATION_SCHEMA carries no role-hierarchy view, so a role that reaches the object through three nested roles is invisible here. That gap is the whole reason the procedure and ACCOUNT_USAGE rungs exist.
-- caveats: The docs are explicit that the view only displays objects for which the current session role has been granted access privileges - so an empty result is a statement about YOUR role, not about the object, and two auditors can legitimately get two different answers. INFORMATION_SCHEMA is per-database: this reads the INFORMATION_SCHEMA of whichever database is in session context, so set it to :object_database first or fully qualify the FROM clause. Object grants alone do not confer readability - a grantee still needs USAGE on the database and the schema, which this view reports as separate rows on separate objects.

SELECT
  op.object_catalog                                  AS object_database,
  op.object_schema                                   AS object_schema,
  op.object_name                                     AS object_name,
  op.object_type                                     AS object_type,
  op.grantee                                         AS grantee_role,
  op.granted_to                                      AS grantee_kind,
  op.privilege_type                                  AS privilege_type,
  IFF(UPPER(op.privilege_type) IN ('SELECT', 'OWNERSHIP', 'REFERENCES'), TRUE, FALSE) AS confers_read,
  op.is_grantable                                    AS is_grantable,
  op.grantor                                         AS granted_by,
  op.created                                         AS granted_at,
  CASE
    WHEN UPPER(op.granted_to) = 'USER'                                        THEN 'CRITICAL'
    WHEN UPPER(op.privilege_type) NOT IN ('SELECT', 'OWNERSHIP', 'REFERENCES') THEN 'NOT_ASSESSED'
    WHEN UPPER(op.is_grantable) = 'YES'
         AND UPPER(op.privilege_type) <> 'OWNERSHIP'                          THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM information_schema.object_privileges op
WHERE op.object_name    = :object_name
  AND op.object_schema  = :object_schema
  AND op.object_catalog = :object_database
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  op.privilege_type,
  grantee_role;
