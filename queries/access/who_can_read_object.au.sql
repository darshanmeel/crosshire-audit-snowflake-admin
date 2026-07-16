-- query_id: who_can_read_object
-- title: Who can read this object — transitive access + history (ACCOUNT_USAGE)
-- domain: access   tier: ★ starter
-- rung: AU  (ACCOUNT_USAGE)  — the fallback, and the only rung with history
-- reads: snowflake.account_usage.grants_to_roles, snowflake.account_usage.grants_to_users
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED — the ACCOUNT_USAGE grants views carry a documented latency (up to a few hours). Wrong tool for "did the grant I just changed take?"; right tool for "who USED to have access" (DELETED_ON).
-- params: edit the seed predicate (name / table_catalog / table_schema) below
-- confidence: unverified-live
-- confidence_note: column labels (name, table_catalog, table_schema, granted_on, deleted_on) and the exact DATABASE_ROLE grantee value / qualification drift across Snowflake versions and are NOT verified live for this release — confirm on your account. Database-role names may come back DB.ROLE-qualified, so the role-to-role join may need to match on that form.
-- read_this: One row = a principal that can reach the object. user_name = the human/service user; role = the role in the chain that lands on them; hop = edges from the object. A principal appearing at all = can read the table.
-- covers: FULL transitive closure, resolved to USERS. Use this rung only when you can reach ACCOUNT_USAGE and can tolerate the lag — or when you need HISTORY (drop the deleted_on IS NULL filters to see who once had access). Otherwise prefer the WORKAROUND proc, which is live and needs only SHOW.
-- caveats: Admin-gated + lagged. To go historical, replace `deleted_on IS NULL` with a point-in-time predicate on deleted_on / a snapshot timestamp.
-- next: who_can_read_object.proc.sql (live, no admin), who_can_read_object.is.sql (live, one hop)

WITH RECURSIVE reach AS (
  -- seed: roles granted directly on the object
  SELECT grantee_name AS role, 1 AS hop
  FROM snowflake.account_usage.grants_to_roles
  WHERE name          = 'ORDERS'        -- <object>
    AND table_catalog = 'CROSSHIRE'     -- <database>  (pin db + type so a same-named
    AND table_schema  = 'SILVER'        -- <schema>     object elsewhere can't over-match)
    AND granted_on    = 'TABLE'
    AND deleted_on IS NULL
  UNION ALL
  -- climb: account roles AND database roles that hold a role we already have
  SELECT g.grantee_name, r.hop + 1
  FROM snowflake.account_usage.grants_to_roles g
  JOIN reach r ON g.name = r.role
  WHERE g.granted_on IN ('ROLE', 'DATABASE_ROLE')
    AND g.deleted_on IS NULL
)
-- resolve the reachable roles down to the actual humans + service users
SELECT DISTINCT u.grantee_name AS user_name, r.role, r.hop
FROM reach r
JOIN snowflake.account_usage.grants_to_users u
  ON u.role = r.role
 AND u.deleted_on IS NULL
ORDER BY r.hop, user_name;
