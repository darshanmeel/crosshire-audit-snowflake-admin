-- query_id: perf_table_pruning_gap
-- title: Which tables are scanned with the worst partition pruning - full scans dressed as filtered queries
-- domain: performance   tier: standard
-- rung: account_usage - TABLE_QUERY_PRUNING_HISTORY is an ACCOUNT_USAGE-only view. QUERY_HISTORY carries PARTITIONS_SCANNED and PARTITIONS_TOTAL per statement, but only this view attributes pruning to the TABLE, which is where the fix lands.
-- reads: snowflake.account_usage.table_query_pruning_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - the documented latency on TABLE_QUERY_PRUNING_HISTORY is up to 4 hours, with 1 year of retention. Longer than the QUERY_HISTORY lag, so a pruning answer and a query answer taken at the same moment do not cover the same minutes.
-- params: :period_days (default 30) trailing window in days, up to 365; :min_queries (default 50) statements a table needs in the window before it is judged; :warn_prune_pct (default 50) partition-pruning percentage below which a table is WARN; :critical_prune_pct (default 10) the percentage below which it is CRITICAL; :top_n (default 200) rows returned, worst first
-- confidence: confirmed-docs
-- confidence_note: INTERVAL_START_TIME, PARTITIONS_SCANNED, PARTITIONS_PRUNED, ROWS_SCANNED, ROWS_MATCHED, NUM_QUERIES and AGGREGATE_QUERY_EXECUTION_TIME were checked against docs.snowflake.com/en/sql-reference/account-usage/table_query_pruning_history. Not run against a live account. Note the time column is INTERVAL_START_TIME, not START_TIME - that is the single most common mistake against this view. The percentage bands are a field heuristic, not a documented Snowflake boundary.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one table across the window. The two columns that matter are PRUNE_PCT and EXECUTION_HOURS_ON_TABLE - a badly pruned table nobody queries is not a problem, and the second column is what separates the two. PARTITIONS_SCANNED plus PARTITIONS_PRUNED is the number of partitions the optimizer CONSIDERED, so the percentage is out of that, not out of the table.
-- healthy: high prune percentages on the tables that carry the execution hours, and low percentages confined to small dimension tables where a full scan is cheap and correct.
-- investigate_if: WARN below :warn_prune_pct and CRITICAL below :critical_prune_pct partition pruning, once a table has at least :min_queries statements against it. A false positive looks like a table that is genuinely read end to end every time - a small lookup, a nightly full extract - where no pruning is possible and none is needed. A second false positive: a table whose queries filter on a column the clustering cannot help, where the honest fix is search optimization or a rewrite, not a clustering key.
-- actions: 1) look at what the queries actually filter on and add the predicate that is missing, or push the existing one below the join, which costs nothing (free); 2) if the filter is right and pruning is still bad, the table is laid out against the query - a clustering key or search optimization is the config answer, and both are chosen from measurement, not from a hunch (config); 3) automatic clustering and search optimization are serverless features with their own credit line, so they are the spend rung, not the free one (spend).
-- next: perf_clustering_recommendations (if a badly pruned table is also large and hot enough to pay for clustering), perf_row_pruning_gap (if partition pruning looks fine but the queries still read too much), perf_bytes_scanned_divergence (if the scan numbers here disagree with what QUERY_HISTORY reports), perf_spilling_queries (if the same tables show up behind spilling statements)
-- covers: Every table scanned in the window, attributed per table and per warehouse, for up to a year. It does NOT cover hybrid tables, which the view excludes by documentation, and it retains only the 1,000 longest-running table scans per query, so the very cheapest scans can be missing. It carries no QUERY_ID - only QUERY_HASH and QUERY_PARAMETERIZED_HASH - so a drill-down to a single statement goes through QUERY_HISTORY on the hash.
-- caveats: The denominator is partitions CONSIDERED, that is scanned plus pruned, so a table whose queries were already narrowed by a join can look well pruned while still reading too much. ROWS_MATCHED can overstate, because the docs state complex WHERE conditions may not filter rows during the table scan itself. AGGREGATE_QUERY_EXECUTION_TIME is summed over intervals and is wall-clock execution time, not credits, so EXECUTION_HOURS_ON_TABLE ranks impact without pricing it. Warehouse names are counted rather than grouped, so one row is one table across all warehouses that touched it - group by WAREHOUSE_NAME as well if you need to know which workload is responsible.

WITH per_table AS (
  SELECT
    database_name,
    schema_name,
    table_name,
    SUM(COALESCE(num_queries, 0))                        AS queries,
    COUNT(DISTINCT warehouse_name)                       AS distinct_warehouses,
    COUNT(DISTINCT query_parameterized_hash)             AS distinct_shapes,
    SUM(COALESCE(partitions_scanned, 0))                 AS partitions_scanned,
    SUM(COALESCE(partitions_pruned, 0))                  AS partitions_pruned,
    SUM(COALESCE(rows_scanned, 0))                       AS rows_scanned,
    SUM(COALESCE(rows_pruned, 0))                        AS rows_pruned,
    SUM(COALESCE(rows_matched, 0))                       AS rows_matched,
    SUM(COALESCE(aggregate_query_execution_time, 0))     AS execution_ms,
    SUM(COALESCE(aggregate_query_elapsed_time, 0))       AS elapsed_ms,
    SUM(COALESCE(aggregate_query_compilation_time, 0))   AS compilation_ms,
    MIN(interval_start_time)                             AS first_interval,
    MAX(interval_end_time)                               AS last_interval
  FROM snowflake.account_usage.table_query_pruning_history
  WHERE interval_start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
),
scored AS (
  SELECT
    p.*,
    ROUND(DIV0(partitions_pruned,
               NULLIF(partitions_scanned + partitions_pruned, 0)) * 100, 2) AS prune_pct,
    ROUND(DIV0(rows_matched, NULLIF(rows_scanned, 0)) * 100, 2)             AS rows_matched_pct_of_scanned
  FROM per_table p
)
SELECT
  CASE
    WHEN queries < :min_queries                THEN 'NOT_ASSESSED'
    WHEN prune_pct < :critical_prune_pct       THEN 'CRITICAL'
    WHEN prune_pct < :warn_prune_pct           THEN 'WARN'
    ELSE 'OK'
  END                                          AS status,
  database_name,
  schema_name,
  table_name,
  queries,
  distinct_shapes,
  distinct_warehouses,
  prune_pct,
  rows_matched_pct_of_scanned,
  partitions_scanned,
  partitions_pruned,
  partitions_scanned + partitions_pruned       AS partitions_considered,
  rows_scanned,
  rows_pruned,
  rows_matched,
  ROUND(execution_ms   / 3600000.0, 3)         AS execution_hours_on_table,
  ROUND(elapsed_ms     / 3600000.0, 3)         AS elapsed_hours_on_table,
  ROUND(compilation_ms / 3600000.0, 3)         AS compilation_hours_on_table,
  first_interval,
  last_interval
FROM scored
ORDER BY
  IFF(queries < :min_queries, 1, 0),
  prune_pct ASC,
  execution_ms DESC
LIMIT :top_n;
