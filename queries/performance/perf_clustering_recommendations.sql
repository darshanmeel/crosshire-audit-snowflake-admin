-- query_id: perf_clustering_recommendations
-- title: Which badly pruned tables are large and hot enough that a clustering key would pay
-- domain: performance   tier: standard
-- rung: account_usage - both halves of the question live only here: pruning per table in TABLE_QUERY_PRUNING_HISTORY, and table size in TABLE_STORAGE_METRICS
-- reads: snowflake.account_usage.table_query_pruning_history, snowflake.account_usage.table_storage_metrics
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - and by two DIFFERENT amounts, which is the trap in this query. TABLE_QUERY_PRUNING_HISTORY lags up to 4 hours; TABLE_STORAGE_METRICS lags up to 90 minutes and is a current-state view with no history at all. So the pruning side is a window and the size side is a snapshot, and a table that grew this morning is judged on today size against last week pruning.
-- params: :period_days (default 30) trailing window in days for the pruning side, up to 365; :min_queries (default 50) statements a table needs in the window before it is a candidate; :min_active_gb (default 100) active bytes in GB below which clustering is not worth its serverless cost; :max_prune_pct (default 40) partition-pruning percentage at or below which the table is badly enough pruned to be a candidate; :top_n (default 100) rows returned, best candidates first
-- confidence: confirmed-docs
-- confidence_note: The pruning columns were checked against docs.snowflake.com/en/sql-reference/account-usage/table_query_pruning_history and the storage columns against docs.snowflake.com/en/sql-reference/account-usage/table_storage_metrics. Not run against a live account. One naming fact drives the join and is easy to get wrong: TABLE_STORAGE_METRICS spells the database and schema TABLE_CATALOG and TABLE_SCHEMA, while the pruning view spells them DATABASE_NAME and SCHEMA_NAME, so the join must alias rather than rely on matching column names. The GB and percentage thresholds are a field heuristic, not a documented Snowflake boundary.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one candidate table. The three columns that matter are PRUNE_PCT, ACTIVE_GB and EXECUTION_HOURS_ON_TABLE - clustering pays only where all three line up: badly pruned, large enough that partitions matter, and queried often enough that the benefit recurs. A table failing any one of the three is listed but not recommended.
-- healthy: an empty CRITICAL band. No table both large and hot is pruning badly, which means the existing layout already matches the way the account queries it.
-- investigate_if: CRITICAL when a table is at or below :max_prune_pct pruning, at or above :min_active_gb active, and has at least :min_queries statements - that is the candidate set. WARN when it is badly pruned but too small or too cold for clustering to repay its cost. A false positive looks like a table whose bad pruning comes from an unfiltered nightly extract rather than from layout - clustering will not help a query with no predicate. A second: a table already clustered, where the answer is a different key or none, not a first key.
-- actions: 1) confirm what the queries filter on before choosing anything, and check whether an existing clustering key is simply the wrong one, which costs nothing (free); 2) if the filter is low-cardinality and range-like, a clustering key is the mechanism; if it is a high-cardinality point lookup, search optimization is, and the two are not interchangeable (config); 3) automatic clustering bills as a serverless feature with no warehouse and no resource monitor governing it, so enable it on ONE table, measure pruning before and after through perf_table_pruning_gap, and only then widen (spend).
-- next: perf_table_pruning_gap (for the pruning detail per warehouse and shape), perf_row_pruning_gap (to check whether the gap is really at row level, where clustering will not help), perf_repeated_query_shapes (to find the shape that drives the scans and check it has a predicate at all)
-- covers: Tables that appear on BOTH sides - scanned in the window and present in current storage metrics. A table dropped since the window, or one never scanned, cannot appear. Hybrid tables are excluded by the pruning view. This query recommends a CANDIDATE, never a key: nothing in ACCOUNT_USAGE knows which column your predicates use, so choosing the column is still a human step taken from the query text.
-- caveats: The join is by name, because the two views do not share a stable table id in a form safe to join on here, so a table dropped and recreated with the same name inside the window merges into one row. TABLE_STORAGE_METRICS carries one row per table id including clones and dropped tables, so DELETED is filtered to FALSE and active bytes are taken as the maximum per name - a clone group can still inflate the figure. ACTIVE_GB is today size against window pruning, as the freshness field says. EXECUTION_HOURS_ON_TABLE is wall-clock execution time summed over intervals, not credits, so the payoff estimate is directional and this query deliberately prints no dollar figure. Iceberg tables on external volumes report active bytes that are not billed by Snowflake at all.

WITH pruning AS (
  SELECT
    database_name,
    schema_name,
    table_name,
    SUM(COALESCE(num_queries, 0))                    AS queries,
    COUNT(DISTINCT warehouse_name)                   AS distinct_warehouses,
    COUNT(DISTINCT query_parameterized_hash)         AS distinct_shapes,
    SUM(COALESCE(partitions_scanned, 0))             AS partitions_scanned,
    SUM(COALESCE(partitions_pruned, 0))              AS partitions_pruned,
    SUM(COALESCE(aggregate_query_execution_time, 0)) AS execution_ms,
    MAX(interval_end_time)                           AS last_interval
  FROM snowflake.account_usage.table_query_pruning_history
  WHERE interval_start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
),
storage AS (
  SELECT
    table_catalog                        AS database_name,
    table_schema                         AS schema_name,
    table_name                           AS table_name,
    MAX(COALESCE(active_bytes, 0))       AS active_bytes,
    MAX(COALESCE(time_travel_bytes, 0))  AS time_travel_bytes,
    MAX(COALESCE(failsafe_bytes, 0))     AS failsafe_bytes,
    MAX(is_transient)                    AS is_transient,
    COUNT(*)                             AS storage_rows_for_name
  FROM snowflake.account_usage.table_storage_metrics
  WHERE COALESCE(deleted, FALSE) = FALSE
  GROUP BY 1, 2, 3
),
joined AS (
  SELECT
    p.database_name,
    p.schema_name,
    p.table_name,
    p.queries,
    p.distinct_shapes,
    p.distinct_warehouses,
    p.partitions_scanned,
    p.partitions_pruned,
    p.execution_ms,
    p.last_interval,
    s.active_bytes,
    s.time_travel_bytes,
    s.failsafe_bytes,
    s.is_transient,
    s.storage_rows_for_name,
    ROUND(DIV0(p.partitions_pruned,
               NULLIF(p.partitions_scanned + p.partitions_pruned, 0)) * 100, 2) AS prune_pct,
    ROUND(COALESCE(s.active_bytes, 0) / POWER(1024, 3), 2)                      AS active_gb
  FROM pruning p
  JOIN storage s
    ON  s.database_name = p.database_name
    AND s.schema_name   = p.schema_name
    AND s.table_name    = p.table_name
)
SELECT
  CASE
    WHEN queries < :min_queries                                                        THEN 'NOT_ASSESSED'
    WHEN prune_pct <= :max_prune_pct AND active_gb >= :min_active_gb                   THEN 'CRITICAL'
    WHEN prune_pct <= :max_prune_pct                                                   THEN 'WARN'
    ELSE 'OK'
  END                                                     AS status,
  database_name,
  schema_name,
  table_name,
  prune_pct,
  active_gb,
  queries,
  distinct_shapes,
  distinct_warehouses,
  ROUND(execution_ms / 3600000.0, 3)                      AS execution_hours_on_table,
  partitions_scanned,
  partitions_pruned,
  partitions_scanned + partitions_pruned                  AS partitions_considered,
  ROUND(COALESCE(time_travel_bytes, 0) / POWER(1024, 3), 2) AS time_travel_gb,
  ROUND(COALESCE(failsafe_bytes, 0)    / POWER(1024, 3), 2) AS failsafe_gb,
  is_transient,
  storage_rows_for_name                                   AS storage_rows_matching_this_name,
  last_interval
FROM joined
ORDER BY
  IFF(queries < :min_queries, 1, 0),
  IFF(prune_pct <= :max_prune_pct AND active_gb >= :min_active_gb, 0, 1),
  execution_ms DESC,
  active_gb DESC
LIMIT :top_n;
