-- query_id: perf_operator_stats_probe
-- title: For ONE query id, which operator burned the time and which one spilled
-- domain: performance   tier: deep
-- rung: information_schema - GET_QUERY_OPERATOR_STATS is a built-in table function rather than a view, but it stands on the same rung: live, no IMPORTED PRIVILEGES, scoped to what the caller can already see
-- reads: get_query_operator_stats()
-- requires: OPERATE or MONITOR on the warehouse the probed query ran on. No ACCOUNTADMIN and no IMPORTED PRIVILEGES.
-- freshness: LIVE - the plan is read from the query profile the instant you ask, with no ACCOUNT_USAGE lag at all. The limit is reach, not freshness: the function looks back roughly 14 days per query, so a statement you found in a 30-day ACCOUNT_USAGE window may already be out of range.
-- params: :probe_query_id (default PASTE_A_QUERY_ID_HERE) the single query id to open up - take it from the SAMPLE_QUERY_ID or QUERY_ID column of a finding you already have; :slow_operator_pct (default 25) share of the total query time one operator must take to be called the hot operator
-- confidence: confirmed-docs
-- confidence_note: The signature, the call form and every output column - QUERY_ID, STEP_ID, OPERATOR_ID, PARENT_OPERATORS, OPERATOR_TYPE, OPERATOR_STATISTICS, EXECUTION_TIME_BREAKDOWN, OPERATOR_ATTRIBUTES - were checked against docs.snowflake.com/en/sql-reference/functions/get_query_operator_stats, as were the OBJECT sub-keys read here: input_rows, output_rows, io.bytes_scanned, pruning.partitions_scanned, pruning.partitions_total, spilling.bytes_spilled_local_storage, spilling.bytes_spilled_remote_storage, and overall_percentage on the time breakdown. Not run against a live account. Sub-keys are read with GET rather than the colon path operator so that a client which binds a leading colon cannot mangle them.
-- empty_if: privilege_scoped, retention_window, no_activity
-- read_this: One row = one operator in the plan of ONE statement. The two columns that matter are OVERALL_PCT and REMOTE_SPILL_GB - the first says where the time went, the second says which operator ran out of memory. An operator with a large INPUT_ROWS and a small OUTPUT_ROWS is a filter that ran too late; the reverse is a join that fanned out.
-- healthy: time concentrated in the operator you would expect - the scan on a scan-heavy query, the join on a join-heavy one - with no spilling anywhere and a scan whose partitions scanned are a small fraction of partitions total.
-- investigate_if: any operator at or above :slow_operator_pct of overall time that you did not expect, any non-zero remote spill on any operator, or a TableScan whose PARTITIONS_SCANNED is close to PARTITIONS_TOTAL. A false positive looks like a query that is simply small - on a statement that ran for two seconds, one operator taking 40 percent of the time means nothing. Probe statements that are already known to be expensive.
-- actions: 1) rewrite around the operator the plan blames - push the filter below the join, remove the ORDER BY that only feeds a client, replace the correlated subquery the plan turned into a loop (free); 2) if the hot operator is a TableScan reading nearly every partition, the fix is layout and belongs to the pruning queries, not to the warehouse (config); 3) if and only if the spill is spread across several operators rather than concentrated in one, the working set genuinely exceeds the warehouse and a size increase is the answer (spend).
-- next: perf_spilling_queries (to check whether this statement is one of many with the same problem), perf_table_pruning_gap (if the hot operator is a scan that is not pruning), perf_repeated_query_shapes (to size the shape this statement belongs to), perf_query_insights (to compare your reading of the plan with the vendor verdict on the same statement)
-- covers: ONE statement, in full plan detail that no view in ACCOUNT_USAGE carries at any lag. That is the trade: everything else in this domain is account-wide and shallow, and this is single-statement and deep. It is a PROBE, pointed at a query id another query already found - never a sweep.
-- caveats: The function reaches back roughly 14 days per query, far short of the year ACCOUNT_USAGE keeps, so a statement found in a 30-day ACCOUNT_USAGE window may be beyond reach here - that is a coverage gap, not an empty plan. It returns nothing for a query id the calling role cannot see, and nothing for a statement served entirely from the result cache, because such a statement has no plan. OVERALL_PCT is the documented overall_percentage sub-key and is a share of the query, so the column sums to about 100 across operators and small rounding drift is expected. The spilling, pruning and io sub-objects are absent on operator types that do not have them, which is why every extraction is wrapped in COALESCE and yields zero rather than null. PARENT_OPERATORS is an ARRAY and is null on the final operator by documentation.

SELECT
  CASE
    WHEN COALESCE(GET(GET(operator_statistics, 'spilling'), 'bytes_spilled_remote_storage')::float, 0) > 0
      THEN 'CRITICAL'
    WHEN COALESCE(GET(GET(operator_statistics, 'spilling'), 'bytes_spilled_local_storage')::float, 0) > 0
      THEN 'WARN'
    WHEN COALESCE(GET(execution_time_breakdown, 'overall_percentage')::float, 0) >= :slow_operator_pct
      THEN 'WARN'
    ELSE 'OK'
  END                                                                                        AS status,
  query_id,
  step_id,
  operator_id,
  parent_operators,
  operator_type,
  ROUND(COALESCE(GET(execution_time_breakdown, 'overall_percentage')::float, 0), 2)          AS overall_pct,
  ROUND(COALESCE(GET(execution_time_breakdown, 'processing')::float, 0), 2)                  AS processing_pct,
  ROUND(COALESCE(GET(execution_time_breakdown, 'initialization')::float, 0), 2)              AS initialization_pct,
  ROUND(COALESCE(GET(execution_time_breakdown, 'synchronization')::float, 0), 2)             AS synchronization_pct,
  ROUND(COALESCE(GET(execution_time_breakdown, 'local_disk_io')::float, 0), 2)               AS local_disk_io_pct,
  ROUND(COALESCE(GET(execution_time_breakdown, 'remote_disk_io')::float, 0), 2)              AS remote_disk_io_pct,
  ROUND(COALESCE(GET(execution_time_breakdown, 'network_communication')::float, 0), 2)       AS network_communication_pct,
  COALESCE(GET(operator_statistics, 'input_rows')::float, 0)                                 AS input_rows,
  COALESCE(GET(operator_statistics, 'output_rows')::float, 0)                                AS output_rows,
  ROUND(DIV0(COALESCE(GET(operator_statistics, 'output_rows')::float, 0),
             NULLIF(COALESCE(GET(operator_statistics, 'input_rows')::float, 0), 0)), 4)      AS output_over_input,
  ROUND(COALESCE(GET(GET(operator_statistics, 'io'), 'bytes_scanned')::float, 0)
        / POWER(1024, 3), 4)                                                                 AS gb_scanned,
  COALESCE(GET(GET(operator_statistics, 'pruning'), 'partitions_scanned')::float, 0)         AS partitions_scanned,
  COALESCE(GET(GET(operator_statistics, 'pruning'), 'partitions_total')::float, 0)           AS partitions_total,
  ROUND(DIV0(COALESCE(GET(GET(operator_statistics, 'pruning'), 'partitions_scanned')::float, 0),
             NULLIF(COALESCE(GET(GET(operator_statistics, 'pruning'), 'partitions_total')::float, 0), 0)) * 100, 2)
                                                                                             AS partitions_scanned_pct,
  ROUND(COALESCE(GET(GET(operator_statistics, 'spilling'), 'bytes_spilled_local_storage')::float, 0)
        / POWER(1024, 3), 4)                                                                 AS local_spill_gb,
  ROUND(COALESCE(GET(GET(operator_statistics, 'spilling'), 'bytes_spilled_remote_storage')::float, 0)
        / POWER(1024, 3), 4)                                                                 AS remote_spill_gb,
  IFF(COALESCE(GET(execution_time_breakdown, 'overall_percentage')::float, 0) >= :slow_operator_pct,
      TRUE, FALSE)                                                                           AS is_hot_operator,
  operator_statistics,
  operator_attributes
FROM TABLE(GET_QUERY_OPERATOR_STATS(:probe_query_id))
ORDER BY overall_pct DESC, remote_spill_gb DESC, step_id, operator_id;
