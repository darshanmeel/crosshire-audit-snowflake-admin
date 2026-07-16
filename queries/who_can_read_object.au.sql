-- query_id: who_can_read_object
-- title: Who can read this object — transitive access + history (ACCOUNT_USAGE)
-- domain: access   tier: ★ starter
-- rung: AU  (ACCOUNT_USAGE)  — the fallback, and the only rung with history
-- reads: snowflake.account_usage.grants_to_roles, snowflake.account_usage.grants_to_users
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED — the ACCOUNT_USAGE grants views carry a documented latency (up to a few hours). Wrong tool for "did the grant I just changed take?"; right tool for "who USED to have access" (drop the deleted_on filters).
-- params: edit the object predicate (name / table_catalog / table_schema)
-- confidence: unverified-live
-- confidence_note: column labels (name, table_catalog, table_schema, granted_on, granted_to, deleted_on) and the exact DATABASE_ROLE value / qualification drift across Snowflake versions and are NOT verified live for this release. Database-role names may come back DB.ROLE-qualified, so the role-to-role join may need to match on that form.
-- read_this: One row = a USER (human or service) that can reach the object, via the role that lands on them. The GRANTS_TO_USERS join is essential — a role-only result stops one hop short of the people.
-- covers: FULL transitive closure, RESOLVED TO USERS. Use this rung only when you can reach ACCOUNT_USAGE and can tolerate the lag — or when you need HISTORY. Otherwise prefer the WORKAROUND proc (live, needs only SHOW). Note: INFORMATION_SCHEMA is NOT a rung here — OBJECT_PRIVILEGES answers a different question (what privileges exist on an object, one hop), not who can read it transitively.
-- next: who_can_read_object.proc.sql (live, no admin)

-- =====================================================================
-- PRIMARY — seed on the object, climb roles, then RESOLVE TO USERS.
-- The final GRANTS_TO_USERS join is what turns "reachable roles" into
-- the actual people; without it the answer stops one hop short.
-- =====================================================================
WITH RECURSIVE reach AS (
  -- seed: roles that can READ the object directly
  SELECT grantee_name AS role, 1 AS hop
  FROM snowflake.account_usage.grants_to_roles
  WHERE granted_on = 'TABLE'
    AND name          = 'ORDERS'                 -- <object>
    AND table_catalog = 'CROSSHIRE'              -- <database>
    AND table_schema  = 'SILVER'                 -- <schema>
    AND privilege IN ('SELECT', 'OWNERSHIP')     -- read-conferring only
    AND deleted_on IS NULL
  UNION ALL
  -- climb: who HOLDS a role we reached — USAGE is the hierarchy edge
  SELECT g.grantee_name, r.hop + 1
  FROM snowflake.account_usage.grants_to_roles g
  JOIN reach r ON g.name = r.role
  WHERE g.granted_on IN ('ROLE', 'DATABASE_ROLE')
    AND g.privilege = 'USAGE'                    -- owning a role != holding it
    AND g.deleted_on IS NULL
)
-- resolve every reachable role down to the users who hold it
SELECT DISTINCT u.grantee_name AS user_name, r.role, r.hop
FROM reach r
JOIN snowflake.account_usage.grants_to_users u
  ON u.role = r.role
 AND u.deleted_on IS NULL
ORDER BY r.hop, user_name;

-- =====================================================================
-- ALTERNATE — build the role graph ONCE (object-independent), then put
-- the OBJECT FILTER in the final stage. Prefer this when auditing many
-- objects: only `object_roles` changes; `role_ancestors` is reused.
-- =====================================================================
WITH RECURSIVE role_ancestors AS (
  -- generic: (role, ancestor) where ancestor HOLDS role via USAGE — NO object filter
  SELECT name AS role, grantee_name AS ancestor
  FROM snowflake.account_usage.grants_to_roles
  WHERE granted_on IN ('ROLE', 'DATABASE_ROLE')
    AND privilege = 'USAGE'                      -- the hierarchy edge (not OWNERSHIP)
    AND deleted_on IS NULL
  UNION ALL
  SELECT ra.role, g.grantee_name
  FROM role_ancestors ra
  JOIN snowflake.account_usage.grants_to_roles g
    ON g.name = ra.ancestor
   AND g.granted_on IN ('ROLE', 'DATABASE_ROLE')
   AND g.privilege = 'USAGE'
   AND g.deleted_on IS NULL
),
object_roles AS (
  -- the OBJECT FILTER lives here — the only part that changes per object
  SELECT grantee_name AS role
  FROM snowflake.account_usage.grants_to_roles
  WHERE granted_on    = 'TABLE'
    AND privilege IN ('SELECT', 'OWNERSHIP')     -- read-conferring only
    AND deleted_on IS NULL
    AND name          = 'ORDERS'        -- <object>
    AND table_catalog = 'CROSSHIRE'     -- <database>
    AND table_schema  = 'SILVER'        -- <schema>
),
reachable_roles AS (
  -- the object's direct roles, plus every role that transitively reaches them
  SELECT role FROM object_roles
  UNION
  SELECT ra.ancestor
  FROM role_ancestors ra
  JOIN object_roles o ON ra.role = o.role
)
-- resolve to users in the final SELECT (includes users granted an object role directly)
SELECT DISTINCT u.grantee_name AS user_name, rr.role
FROM reachable_roles rr
JOIN snowflake.account_usage.grants_to_users u
  ON u.role = rr.role
 AND u.deleted_on IS NULL
ORDER BY user_name;
