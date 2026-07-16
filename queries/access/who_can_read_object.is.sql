-- query_id: who_can_read_object
-- title: Direct grants on this object (INFORMATION_SCHEMA)
-- domain: access   tier: ★ starter
-- rung: IS
-- reads: <database>.information_schema.object_privileges
-- requires: a role with USAGE on the database; the view returns only grants your current role is allowed to see
-- freshness: LIVE — current metadata, no ACCOUNT_USAGE lag
-- params: set <database> in the FROM clause; edit the WHERE for your object
-- confidence: unverified-live
-- confidence_note: OBJECT_PRIVILEGES column names (grantee, grantor, privilege_type, object_catalog/schema/name/type, is_grantable) are per the SQL-standard view; confirm on your Snowflake version.
-- read_this: One row = a role granted a privilege DIRECTLY on the object. role = the grantee; privilege_type = SELECT / OWNERSHIP / etc. This is ONE HOP only.
-- covers: DIRECT grants on the object, live. INFORMATION_SCHEMA has NO role-hierarchy view, so it CANNOT resolve who reaches the object through role inheritance. This is the "one-hop lie" — the roles here are the START of the access paths, not the whole of them. For the transitive answer drop to the WORKAROUND proc (live) or the AU CTE (history, admin-gated).
-- caveats: OBJECT_PRIVILEGES is PER-DATABASE — you query <db>.information_schema, not a global view. Privileges inherited via role hierarchy or object ownership never appear as rows here. Privilege-scoped: a role sees only the grants it is entitled to see.
-- next: who_can_read_object.proc.sql (full graph, live), who_can_read_object.au.sql (full graph + history, admin-gated)

SELECT grantee                                                       AS role,
       privilege_type,
       object_type,
       object_catalog || '.' || object_schema || '.' || object_name  AS object,
       grantor,
       is_grantable
FROM crosshire.information_schema.object_privileges   -- <database>.information_schema
WHERE object_name   = 'ORDERS'                        -- <object>
  AND object_schema = 'SILVER'                        -- <schema>
  AND object_type   = 'TABLE'
ORDER BY privilege_type, role;
