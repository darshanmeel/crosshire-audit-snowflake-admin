-- query_id: access_who_can_read_object_au
-- title: Who can read this object - transitive access + history (ACCOUNT_USAGE)
-- domain: governance_access   tier: standard
-- rung: account_usage - the fallback rung, and the only rung that answers HISTORICALLY
-- reads: snowflake.account_usage.grants_to_roles, snowflake.account_usage.grants_to_users
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - the ACCOUNT_USAGE grants views carry a documented ~2h latency. Wrong tool for "did the grant I just changed take?"; right tool for "who USED to have access" (drop the deleted_on filters).
-- params: :object_name (default ORDERS) the unqualified object name; :object_database (default CROSSHIRE) the database holding it; :object_schema (default SILVER) the schema holding it
-- confidence: confirmed-docs
-- confidence_note: GRANTS_TO_ROLES and GRANTS_TO_USERS are documented ACCOUNT_USAGE views (docs.snowflake.com/en/sql-reference/account-usage). Not run against a live account: the exact DATABASE_ROLE grantee form (bare vs DB.ROLE-qualified) is version-dependent, so the role-to-role join may need to match the qualified form on your version.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = a USER (human or service) that can reach the object, via the role that lands on them. The GRANTS_TO_USERS join is what turns "reachable roles" into people - a role-only result stops one hop short.
-- healthy: the reachable-user set matches the access list you would have written by hand - and every hop > 1 is a role you meant to nest.
-- investigate_if: a user appears that no one can name an owner for, or hop is larger than your role design allows (a deep chain means a role was nested into a role that was nested into a role - access nobody reviewed).
-- actions: 1) confirm each unexpected principal with the object owner (free); 2) revoke the USAGE edge that carries the surprise, not the object grant - the object grant is usually correct and the nesting is the defect (config); 3) if the chain is legitimate but unreviewable, split the object role so the graph is one hop deep (config).
-- next: access_who_can_read_object_proc (if you need the answer LIVE, or cannot reach ACCOUNT_USAGE)
-- covers: FULL transitive closure, RESOLVED TO USERS. Use this rung only when you can reach ACCOUNT_USAGE and can tolerate the lag - or when you need HISTORY. Otherwise prefer the procedure rung (live, needs only SHOW). INFORMATION_SCHEMA is NOT a rung for this question: OBJECT_PRIVILEGES answers what privileges exist on an object (one hop), not who can read it transitively, and it has no role-hierarchy view to walk.
-- caveats: Two privilege details make this a READ audit rather than a grant dump: the seed keeps only read-conferring grants (privilege IN ('SELECT','OWNERSHIP')), and the climb follows only the USAGE edge on a role - owning a role is not holding it. Ships TWO forms of the same question in one file (documented exception to the one-SELECT rule): a PRIMARY that seeds on the object and climbs, and an ALTERNATE that builds the role graph once (object-independent) for auditing many objects.

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
    AND name          = :object_name             -- e.g. 'ORDERS'
    AND table_catalog = :object_database         -- e.g. 'CROSSHIRE'
    AND table_schema  = :object_schema           -- e.g. 'SILVER'
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
    AND name          = :object_name     -- e.g. 'ORDERS'
    AND table_catalog = :object_database -- e.g. 'CROSSHIRE'
    AND table_schema  = :object_schema   -- e.g. 'SILVER'
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
