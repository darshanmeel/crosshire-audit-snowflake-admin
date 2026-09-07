-- query_id: access_share_exposure
-- title: What leaves this account through shares and listings, and to whom
-- domain: governance_access   tier: standard
-- rung: account_usage - SHOW SHARES exists and is live, but only ACCOUNT_USAGE joins the share to the OBJECTS granted into it in one statement, and only it retains the grant timestamps that say when the exposure changed.
-- reads: snowflake.account_usage.shares, snowflake.account_usage.grants_to_shares
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - both views carry a documented latency of up to 3 hours, the longest on this ladder rung. An object added to a share this morning may not appear yet, so this query cannot be used to confirm a just-made change; use SHOW GRANTS TO SHARE for that.
-- params: :period_days (default 30) grants added inside this window are counted as a RECENT change to the exposure, so a share that has been stable for a year reads differently from one that grew last week; :min_objects (default 1) a share exposing fewer objects than this is reported but not judged
-- confidence: confirmed-docs
-- confidence_note: SHARES and GRANTS_TO_SHARES are documented ACCOUNT_USAGE views and every column used is in their documented column lists, including TARGET_ACCOUNTS, LISTING_GLOBAL_NAME and SECURE_OBJECTS_ONLY on SHARES and OBJECT_DATABASE / OBJECT_SCHEMA / GRANTED_ON on GRANTS_TO_SHARES. Not run against a live account. The docs describe TARGET_ACCOUNTS as an OUTBOUND list and say it is empty when there are none, but do not say whether empty means NULL or an empty string, so both are treated as empty here.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = one share this account owns. The two columns that matter are target_accounts (who outside this account can attach it) and objects_exposed (how much they get). A share with objects and no targets is loaded but not aimed; a share with targets and no objects is aimed but empty. The dangerous row has both.
-- healthy: every share with a non-empty target_accounts is one a named person asked for, secure_objects_only is TRUE on it, and objects_added_in_window is zero because the exposure has not changed since it was approved.
-- investigate_if: CRITICAL when a share is aimed at consumer accounts and secure_objects_only is FALSE - non-secure views and tables in a share expose their definition and can leak rows the provider did not intend. WARN when a share is aimed at anyone at all, or is attached to a listing, since that is exposure that needs an owner. NOT_ASSESSED marks a share below :min_objects, usually a stub. False positive: a deliberate public listing, and an inbound share from a provider, which appears in SHARES with no targets of its own.
-- actions: 1) print the share-to-target map and have the data owner confirm each consumer account, before changing anything (free); 2) set SECURE_OBJECTS_ONLY on any outbound share and replace non-secure views with secure ones (config); 3) revoke the objects rather than dropping the share, so the consumer sees an empty share instead of a broken attach, then drop it after the consumer confirms (config).
-- next: access_who_can_read_object_au (if an exposed object turns out to be one whose internal reader list you also need), gov_masking_policy_coverage (if an exposed object holds columns that should be masked before they leave), access_stale_roles (if the share owner role has no holder)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE, OUTBOUND. It sees which objects are granted into which share and which consumer accounts the share is aimed at. It does NOT see what the consumer actually read - that is the consumer side of the boundary and no view on this account carries it. It also does not see reader-account activity or listing request history.
-- caveats: SHARES contains inbound shares too - a share this account CONSUMES has no target accounts and no grants of its own, so it lands in the NOT_ASSESSED or OK band rather than being excluded, and the owner column is the way to tell them apart. TARGET_ACCOUNTS is a comma-separated string, not an array, so it is reported verbatim rather than counted. A listing can distribute a share to accounts that never appear in TARGET_ACCOUNTS; LISTING_GLOBAL_NAME being non-null is the signal that the real audience is the listing audience. Objects granted through a database role attached to the share appear as the grant on the database role, not as one row per table.

WITH share_grants AS (
  SELECT
    g.share_name                                                                   AS share_name,
    COUNT(*)                                                                       AS privileges_granted,
    COUNT(DISTINCT COALESCE(g.object_database, '') || '.'
               || COALESCE(g.object_schema, '')   || '.'
               || g.object_name)                                                   AS objects_exposed,
    COUNT(DISTINCT COALESCE(g.object_database, ''))                                AS databases_touched,
    ARRAY_AGG(DISTINCT g.granted_on)                                               AS object_kinds,
    ARRAY_AGG(DISTINCT g.privilege)                                                AS privileges,
    MIN(g.created_on)                                                              AS first_grant_on,
    MAX(g.modified_on)                                                             AS last_change_on,
    COUNT(DISTINCT IFF(g.created_on >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP()),
                       g.object_name, NULL))                                       AS objects_added_in_window
  FROM snowflake.account_usage.grants_to_shares g
  WHERE g.deleted_on IS NULL
  GROUP BY 1
)
SELECT
  s.name                                              AS share_name,
  s.owner                                             AS share_owner,
  s.database_name                                     AS share_database,
  s.target_accounts                                   AS target_accounts,
  s.listing_global_name                               AS listing_global_name,
  s.secure_objects_only                               AS secure_objects_only,
  s.created_on                                        AS share_created_on,
  COALESCE(sg.objects_exposed, 0)                     AS objects_exposed,
  COALESCE(sg.privileges_granted, 0)                  AS privileges_granted,
  COALESCE(sg.databases_touched, 0)                   AS databases_touched,
  sg.object_kinds                                     AS object_kinds,
  sg.privileges                                       AS privileges,
  sg.first_grant_on                                   AS first_grant_on,
  sg.last_change_on                                   AS last_change_on,
  COALESCE(sg.objects_added_in_window, 0)             AS objects_added_in_window,
  IFF(NULLIF(TRIM(COALESCE(s.target_accounts, '')), '') IS NOT NULL, TRUE, FALSE) AS is_aimed_outbound,
  CASE
    WHEN COALESCE(sg.objects_exposed, 0) < :min_objects                    THEN 'NOT_ASSESSED'
    WHEN NULLIF(TRIM(COALESCE(s.target_accounts, '')), '') IS NOT NULL
     AND COALESCE(s.secure_objects_only, FALSE) = FALSE                    THEN 'CRITICAL'
    WHEN NULLIF(TRIM(COALESCE(s.target_accounts, '')), '') IS NOT NULL
      OR s.listing_global_name IS NOT NULL                                 THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM snowflake.account_usage.shares s
LEFT JOIN share_grants sg
  ON sg.share_name = s.name
WHERE s.deleted_on IS NULL
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  objects_exposed DESC,
  share_name;
