-- query_id: perf_spilling_queries
-- title: Queries that spilled to local and remote storage - the working set outgrew the warehouse
-- domain: performance   tier: standard
-- rung: account_usage - climbed here because INFORMATION_SCHEMA.QUERY_HISTORY carries no spill columns at all, so this question cannot be asked on a lower rung
-- reads: snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - the ACCOUNT_USAGE QUERY_HISTORY view is documented at up to 45 minutes latency with 365 days of retention. A statement that spilled ten minutes ago may not be here yet, so an empty result right after an incident means "too early", not "clean".
-- params: :period_days (default 30) trailing window in days, up to 365; :critical_remote_gb (default 1) remote spill in GB at or above which a statement is CRITICAL; :warn_local_gb (default 10) local spill in GB at or above which a statement is WARN even with no remote spill; :top_n (default 200) rows returned, worst first
-- confidence: confirmed-docs
-- confidence_note: BYTES_SPILLED_TO_LOCAL_STORAGE, BYTES_SPILLED_TO_REMOTE_STORAGE, WAREHOUSE_SIZE, PARTITIONS_SCANNED and every other column named here were checked against docs.snowflake.com/en/sql-reference/account-usage/query_history. Not run against a live account. The GB thresholds are a field heuristic, not a documented Snowflake boundary.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one statement that spilled. The two columns that matter are REMOTE_SPILL_GB and WAREHOUSE_SIZE - remote spill means the local SSD was already full and Snowflake fell back to object storage, which is the slowest thing a query can do. LOCAL_SPILL_GB alone is a warning; remote spill is a defect.
-- healthy: no remote spill anywhere in the window, and local spill confined to a handful of known heavy batch statements on the smallest warehouse that can hold them.
-- investigate_if: WARN when a statement spills at least :warn_local_gb locally, CRITICAL when it spills at least :critical_remote_gb remotely. A false positive looks like a one-off backfill or an unbounded ad-hoc join written by hand - check whether the same QUERY_PARAMETERIZED_HASH recurs before you resize anything, because a shape that ran once does not justify a permanently larger warehouse.
-- actions: 1) rewrite the statement to spill less - push the filter below the join, drop the ORDER BY that only feeds a client, replace SELECT star with the columns actually used (free); 2) move the recurring offender onto its own warehouse so the resize is scoped to it instead of the whole account (config); 3) size that warehouse up one step, which doubles both memory and credits per second - the last resort, not the first (spend).
-- next: perf_repeated_query_shapes (if the same QUERY_PARAMETERIZED_HASH appears again and again), perf_operator_stats_probe (if one QUERY_ID needs the operator that actually spilled), perf_table_pruning_gap (if GB_SCANNED is large because the scan is not pruning), perf_queuing_overload (if the same warehouse also queues)
-- covers: Account-wide, one year of retention, every warehouse - what the live rung cannot do. It sees the spill AMOUNT but never the operator that spilled it; for that, take one QUERY_ID from here into perf_operator_stats_probe within its 14-day reach.
-- caveats: Spill bytes are the whole statement, not one operator, so a query with one bad join looks the same as a query that is uniformly too big. WAREHOUSE_SIZE is the size at run time - a warehouse resized since will mislead you. Queries served entirely from the result cache never spill and never appear, which is correct but means the list under-counts a workload with high cache hit rates. There is no compute-credits column on this view - CREDITS_USED_CLOUD_SERVICES is cloud services only - so the cost of a spill is expressed here as elapsed and execution seconds, not credits.

SELECT
  CASE
    WHEN COALESCE(bytes_spilled_to_remote_storage, 0) >= :critical_remote_gb * POWER(1024, 3) THEN 'CRITICAL'
    WHEN COALESCE(bytes_spilled_to_remote_storage, 0) > 0                                     THEN 'WARN'
    WHEN COALESCE(bytes_spilled_to_local_storage, 0)  >= :warn_local_gb * POWER(1024, 3)      THEN 'WARN'
    ELSE 'OK'
  END                                                                         AS status,
  query_id,
  start_time,
  user_name,
  role_name,
  warehouse_name,
  warehouse_size,
  warehouse_type,
  query_type,
  ROUND(COALESCE(bytes_spilled_to_remote_storage, 0) / POWER(1024, 3), 3)     AS remote_spill_gb,
  ROUND(COALESCE(bytes_spilled_to_local_storage, 0)  / POWER(1024, 3), 3)     AS local_spill_gb,
  ROUND(COALESCE(bytes_scanned, 0) / POWER(1024, 3), 3)                       AS gb_scanned,
  ROUND(
    DIV0(
      COALESCE(bytes_spilled_to_local_storage, 0) + COALESCE(bytes_spilled_to_remote_storage, 0),
      NULLIF(bytes_scanned, 0)
    ) * 100, 1)                                                               AS spill_pct_of_scan,
  partitions_scanned,
  partitions_total,
  ROUND(COALESCE(total_elapsed_time, 0) / 1000.0, 1)                          AS elapsed_seconds,
  ROUND(COALESCE(execution_time, 0)     / 1000.0, 1)                          AS execution_seconds,
  ROUND(COALESCE(queued_overload_time, 0) / 1000.0, 1)                        AS queued_overload_seconds,
  rows_produced,
  query_tag,
  query_parameterized_hash,
  LEFT(query_text, 400)                                                       AS query_text_head
FROM snowflake.account_usage.query_history
WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  AND COALESCE(is_client_generated_statement, FALSE) = FALSE
  AND (COALESCE(bytes_spilled_to_local_storage, 0) > 0
       OR COALESCE(bytes_spilled_to_remote_storage, 0) > 0)
ORDER BY
  COALESCE(bytes_spilled_to_remote_storage, 0) DESC,
  COALESCE(bytes_spilled_to_local_storage, 0) DESC,
  COALESCE(total_elapsed_time, 0) DESC
LIMIT :top_n;
