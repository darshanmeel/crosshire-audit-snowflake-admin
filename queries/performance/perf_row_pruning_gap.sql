-- query_id: perf_row_pruning_gap
-- title: Good partition pruning, bad row pruning - the gap a partition ratio hides
-- domain: performance   tier: deep
-- rung: account_usage - TABLE_PRUNING_HISTORY is the newer row-level pruning view and exists only on this rung; no live rung reports rows pruned at all
-- reads: snowflake.account_usage.table_pruning_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - the documented latency on TABLE_PRUNING_HISTORY is up to 6 hours, the longest of the three query-side views this domain uses, with 1 year of retention. Do not read it against a QUERY_HISTORY result from the same hour and expect the two to line up.
-- params: :period_days (default 30) trailing window in days, up to 365; :min_scans (default 50) scans a table needs in the window before it is judged; :min_partition_prune_pct (default 50) the partition-pruning percentage above which a table is considered to be pruning WELL at partition level, which is what makes a bad row ratio interesting; :warn_row_prune_pct (default 50) row-pruning percentage below which the table is WARN; :critical_row_prune_pct (default 20) the percentage below which it is CRITICAL; :top_n (default 200) rows returned, worst first
-- confidence: confirmed-docs
-- confidence_note: START_TIME, END_TIME, NUM_SCANS, PARTITIONS_SCANNED, PARTITIONS_PRUNED, ROWS_SCANNED and ROWS_PRUNED were checked against docs.snowflake.com/en/sql-reference/account-usage/table_pruning_history. Not run against a live account. Two shape facts matter and are easy to get wrong: this view uses START_TIME, not INTERVAL_START_TIME as its partition-level sibling does, and it carries NO WAREHOUSE_NAME, no query hash and no execution-time column - so it cannot be sliced by workload the way perf_table_pruning_gap can.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one table across the window. The two columns that matter are ROW_PRUNE_PCT and PARTITION_PRUNE_PCT read TOGETHER - a table pruning 90 percent of its partitions and 5 percent of its rows is opening the right micro-partitions and then reading nearly everything inside them, which is the failure a partition ratio alone hides.
-- healthy: row pruning that tracks partition pruning. Where partitions prune well and rows prune well, the layout matches the predicate at both levels and there is nothing to do.
-- investigate_if: WARN below :warn_row_prune_pct and CRITICAL below :critical_row_prune_pct of rows pruned, once a table has at least :min_scans scans. The rows flagged PRUNE_GAP are the ones where partition pruning is already above :min_partition_prune_pct - those are the real finding. A false positive looks like a table whose queries legitimately need most rows of the partitions they open - an aggregation over a date range, for instance - where the row ratio is low because the work is genuinely wide, not because the layout is wrong.
-- actions: 1) look at the predicate that is doing the row filtering and check whether it is on a high-cardinality column that clustering can never help - equality on an id, a LIKE, a JSON path - which costs nothing to establish (free); 2) if it is a point lookup on high cardinality, search optimization is the mechanism designed for exactly this gap, and a clustering key is not (config); 3) both automatic clustering and search optimization bill as serverless features, so measure first and enable on one table (spend).
-- next: perf_table_pruning_gap (to see the partition-level story with the warehouse and shape attribution this view lacks), perf_clustering_recommendations (if the table is also large and hot), perf_bytes_scanned_divergence (if the scan volume here does not match what the statements report), perf_operator_stats_probe (to see the scan operator on one query id and its pruning object)
-- covers: Row-level pruning for every table scanned in the window, which no other rung and no other view reports. It does NOT cover hybrid tables, it retains only the 1,000 longest-running table scans per query, and it has no warehouse, user or query attribution at all - so it tells you WHICH table has the gap and never WHO caused it. Pair it with perf_table_pruning_gap for that half.
-- caveats: The two ratios have different denominators and are not directly comparable as numbers - partition pruning is out of partitions considered, row pruning is out of rows scanned plus rows pruned - so PRUNE_GAP is a flag on the combination, not an arithmetic difference. The view aggregates into hourly buckets on the hour mark, so a scan straddling an hour boundary contributes to both. Because there is no execution-time column here, impact is ranked by ROWS_SCANNED, which is a volume proxy and not a cost. A table that appears here with good ratios has still not been proven cheap: it may simply be small.

WITH per_table AS (
  SELECT
    database_name,
    schema_name,
    table_name,
    SUM(COALESCE(num_scans, 0))          AS scans,
    SUM(COALESCE(partitions_scanned, 0)) AS partitions_scanned,
    SUM(COALESCE(partitions_pruned, 0))  AS partitions_pruned,
    SUM(COALESCE(rows_scanned, 0))       AS rows_scanned,
    SUM(COALESCE(rows_pruned, 0))        AS rows_pruned,
    MIN(start_time)                      AS first_hour,
    MAX(end_time)                        AS last_hour
  FROM snowflake.account_usage.table_pruning_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
),
scored AS (
  SELECT
    p.*,
    ROUND(DIV0(partitions_pruned,
               NULLIF(partitions_scanned + partitions_pruned, 0)) * 100, 2) AS partition_prune_pct,
    ROUND(DIV0(rows_pruned,
               NULLIF(rows_scanned + rows_pruned, 0)) * 100, 2)             AS row_prune_pct
  FROM per_table p
)
SELECT
  CASE
    WHEN scans < :min_scans                     THEN 'NOT_ASSESSED'
    WHEN row_prune_pct < :critical_row_prune_pct THEN 'CRITICAL'
    WHEN row_prune_pct < :warn_row_prune_pct     THEN 'WARN'
    ELSE 'OK'
  END                                           AS status,
  IFF(partition_prune_pct >= :min_partition_prune_pct
      AND row_prune_pct   <  :warn_row_prune_pct,
      TRUE, FALSE)                              AS prune_gap,
  database_name,
  schema_name,
  table_name,
  scans,
  partition_prune_pct,
  row_prune_pct,
  partitions_scanned,
  partitions_pruned,
  rows_scanned,
  rows_pruned,
  rows_scanned + rows_pruned                    AS rows_considered,
  ROUND(DIV0(rows_scanned, NULLIF(scans, 0)))   AS avg_rows_scanned_per_scan,
  first_hour,
  last_hour
FROM scored
ORDER BY
  IFF(scans < :min_scans, 1, 0),
  IFF(partition_prune_pct >= :min_partition_prune_pct
      AND row_prune_pct   <  :warn_row_prune_pct, 0, 1),
  row_prune_pct ASC,
  rows_scanned DESC
LIMIT :top_n;
