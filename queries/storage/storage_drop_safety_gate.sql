-- query_id: storage_drop_safety_gate
-- title: Before you drop it - what depends on it, who read it last, and how many bytes go into Fail-safe
-- domain: storage   tier: deep
-- rung: account_usage - all three halves of the gate are here and nowhere else. The dependency graph, the read history and the storage tail have no INFORMATION_SCHEMA equivalent that spans the account, and a SHOW cannot tell you who read anything.
-- reads: snowflake.account_usage.object_dependencies, snowflake.account_usage.table_storage_metrics, snowflake.account_usage.access_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default); ACCESS_HISTORY additionally needs Enterprise Edition or higher
-- freshness: LAGGED - and the slowest side governs the verdict: dependencies up to 3 hours, access history up to 3 hours, storage metrics up to 90 minutes. A view created in the last three hours may not yet appear as a dependent, which is the one lag in this library that can turn a safe-looking answer into a broken pipeline. Wait out the lag before acting on an OK.
-- params: :period_days (default 90) how far back to look for reads - this is the definition of unused, so set it to the longest legitimate gap between uses, including quarterly and year-end reporting; :min_active_gb (default 1) size floor in GiB, since a gate is only worth running on tables large enough to be worth dropping
-- confidence: confirmed-docs
-- confidence_note: OBJECT_DEPENDENCIES columns including DEPENDENCY_TYPE with its documented BY_ID, BY_NAME and BY_NAME_AND_ID values; TABLE_STORAGE_METRICS columns ACTIVE_BYTES, TIME_TRAVEL_BYTES, FAILSAFE_BYTES, IS_TRANSIENT and DELETED; and ACCESS_HISTORY columns QUERY_ID, QUERY_START_TIME, USER_NAME and BASE_OBJECTS_ACCESSED with its documented objectDomain and objectName keys, are all documented on docs.snowflake.com. The objectName key is documented as fully qualified, which is what makes the string join to the storage view possible. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, edition_gated, retention_window
-- read_this: One row = one live table above the size floor, with the three facts a drop decision needs. status is the VERDICT ON DROPPING, not on the table: CRITICAL means something still references it and dropping it breaks that object; WARN means nothing references it but a human or a tool read it inside the window; OK means the gate found neither and the drop looks safe. bytes_entering_failsafe is the second number to read - it is what you keep paying for after the drop, and on a permanent table you cannot shorten or cancel it.
-- healthy: status OK with dependent_objects zero and read_queries zero across a :period_days window that genuinely covers the table's usage cycle. That is a table you can drop.
-- investigate_if: CRITICAL on any row with dependent_objects above zero - and read dependency_types before arguing, because a BY_NAME dependency is a name-resolved reference that may already be dangling while a BY_ID one is a hard link. WARN on any row still being read. The false positives run in both directions and both matter: OBJECT_DEPENDENCIES does not see a reference built by string concatenation inside a stored procedure or issued by an external tool, so an OK is evidence of safety and not proof of it; and ACCESS_HISTORY is Enterprise-only, so on a Standard account every row comes back NOT_ASSESSED rather than falsely clean.
-- actions: 1) ask the owners of the referencing objects before touching anything - the gate names them, and a two-minute conversation is cheaper than a broken dashboard (free); 2) rename the table instead of dropping it and wait one full usage cycle - a rename breaks the same things a drop would but is instantly reversible, and Fail-safe never starts (config); 3) if you do drop it, drop it as TRANSIENT-equivalent work first where possible, because a permanent table entering Fail-safe bills for seven days after the drop with no way to stop it (spend).
-- next: storage_time_travel_bloat (if the honest fix is shortening retention rather than dropping), storage_table_breakdown (if you want to see what the table costs today), storage_table_dml_churn (if the table is still being written to by something you have not identified)
-- covers: Live standard tables above the floor. It does not gate views, materialized views, stages or external tables. On the dependency side it sees Snowflake's own recorded dependencies for views, materialized views and tasks; on the read side it sees queries Snowflake attributed to a base object, which includes reads that arrived through a view.
-- caveats: BASE_OBJECTS_ACCESSED is used rather than DIRECT_OBJECTS_ACCESSED on purpose, so a table read only through a view still counts as read - the opposite choice would produce confident, wrong OK verdicts. The join between access history and storage metrics is by fully-qualified NAME, so a table dropped and recreated under the same name inherits its predecessor's read history, and a table renamed inside the window loses its own. Oversized access-history records are documented as progressively truncated with sentinel values, so an extremely wide query may under-report the objects it touched. OBJECT_DEPENDENCIES is a current-state view with no time axis: it tells you what references the table now, never what used to. Fail-safe is seven days on permanent tables and cannot be shortened, disabled or purged, so bytes_entering_failsafe is a cost you accept at the moment of the drop.

WITH candidates AS (
    SELECT
        m.table_catalog AS database_name,
        m.table_schema  AS schema_name,
        m.table_name,
        m.id            AS table_id,
        m.is_transient,
        m.active_bytes,
        m.time_travel_bytes,
        m.failsafe_bytes,
        m.retained_for_clone_bytes,
        m.table_created
    FROM snowflake.account_usage.table_storage_metrics m
    WHERE m.deleted = FALSE
      AND m.active_bytes >= :min_active_gb * POWER(1024, 3)
),
dependents AS (
    SELECT
        UPPER(d.referenced_database)    AS database_name,
        UPPER(d.referenced_schema)      AS schema_name,
        UPPER(d.referenced_object_name) AS table_name,
        COUNT(*)                                                        AS dependent_objects,
        COUNT_IF(UPPER(d.dependency_type) IN ('BY_ID', 'BY_NAME_AND_ID')) AS hard_dependencies,
        LISTAGG(DISTINCT UPPER(d.referencing_object_domain), ' + ')     AS dependent_domains,
        LISTAGG(DISTINCT UPPER(d.dependency_type), ' + ')               AS dependency_types,
        LISTAGG(DISTINCT d.referencing_database || '.' || d.referencing_schema
                || '.' || d.referencing_object_name, ' | ')             AS dependent_objects_list
    FROM snowflake.account_usage.object_dependencies d
    WHERE UPPER(d.referenced_object_domain) = 'TABLE'
    GROUP BY 1, 2, 3
),
read_activity AS (
    SELECT
        UPPER(f.value:objectName::string)             AS full_name,
        COUNT(DISTINCT a.query_id)                    AS read_queries,
        COUNT(DISTINCT a.user_name)                   AS distinct_readers,
        MAX(a.query_start_time)                       AS last_read_at,
        MAX_BY(a.user_name, a.query_start_time)       AS last_read_by
    FROM snowflake.account_usage.access_history a,
         LATERAL FLATTEN(input => a.base_objects_accessed) f
    WHERE a.query_start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
      AND UPPER(f.value:objectDomain::string) = 'TABLE'
    GROUP BY 1
),
access_probe AS (
    SELECT COUNT(*) AS rows_seen FROM read_activity
)
SELECT
    c.database_name,
    c.schema_name,
    c.table_name,
    c.table_id,
    c.is_transient,
    COALESCE(d.dependent_objects, 0)                  AS dependent_objects,
    COALESCE(d.hard_dependencies, 0)                  AS hard_dependencies,
    d.dependent_domains,
    d.dependency_types,
    d.dependent_objects_list,
    COALESCE(r.read_queries, 0)                       AS read_queries,
    COALESCE(r.distinct_readers, 0)                   AS distinct_readers,
    r.last_read_at,
    r.last_read_by,
    DATEDIFF('day', r.last_read_at, CURRENT_TIMESTAMP()) AS days_since_last_read,
    ROUND(c.active_bytes / POWER(1024, 3), 2)         AS active_gb,
    ROUND(c.time_travel_bytes / POWER(1024, 3), 2)    AS time_travel_gb,
    ROUND(c.failsafe_bytes / POWER(1024, 3), 2)       AS failsafe_gb_today,
    ROUND(c.retained_for_clone_bytes / POWER(1024, 3), 2) AS retained_for_clone_gb,
    ROUND(IFF(UPPER(c.is_transient) = 'YES', 0, c.active_bytes + c.time_travel_bytes)
          / POWER(1024, 3), 2)                        AS bytes_entering_failsafe_gb,
    c.table_created,
    CASE
        WHEN p.rows_seen = 0                          THEN 'NOT_ASSESSED'
        WHEN COALESCE(d.dependent_objects, 0) > 0     THEN 'CRITICAL'
        WHEN COALESCE(r.read_queries, 0) > 0          THEN 'WARN'
        ELSE 'OK'
    END                                               AS status
FROM candidates c
CROSS JOIN access_probe p
LEFT JOIN dependents d
       ON d.database_name = UPPER(c.database_name)
      AND d.schema_name   = UPPER(c.schema_name)
      AND d.table_name    = UPPER(c.table_name)
LEFT JOIN read_activity r
       ON r.full_name = UPPER(c.database_name || '.' || c.schema_name || '.' || c.table_name)
ORDER BY
    CASE status
        WHEN 'CRITICAL' THEN 0
        WHEN 'WARN' THEN 1
        WHEN 'NOT_ASSESSED' THEN 2
        ELSE 3
    END,
    c.active_bytes DESC;
