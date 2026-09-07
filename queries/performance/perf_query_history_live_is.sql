-- query_id: perf_query_history_live_is
-- title: What the account ran in the last few hours - the live, low-privilege rung
-- domain: performance   tier: lite
-- rung: information_schema - the live rung, and the only one that can answer "what is happening right now"
-- reads: information_schema.query_history
-- requires: MONITOR or OPERATE on the warehouses whose statements you want to see, or MONITOR EXECUTION on the account. No IMPORTED PRIVILEGES and no ACCOUNTADMIN.
-- freshness: LIVE - a row appears as soon as the statement finishes. This is the rung to stand on when ACCOUNT_USAGE has not caught up yet, because the ACCOUNT_USAGE QUERY_HISTORY view lags up to 45 minutes, or when you cannot reach ACCOUNT_USAGE at all.
-- params: :hours_back (default 6) how far back to look in hours - the table function only reaches 7 days; :row_limit (default 1000) rows the table function returns, from 1 to 10000; :slow_seconds (default 300) elapsed seconds above which a statement counts as slow; :queue_seconds (default 30) queued-overload seconds above which a statement waited on a full warehouse
-- confidence: confirmed-docs
-- confidence_note: Arguments and every output column were checked against docs.snowflake.com/en/sql-reference/functions/query_history. Not run against a live account. Note what this function does NOT return, and which the ACCOUNT_USAGE twin does: BYTES_SPILLED_TO_LOCAL_STORAGE, BYTES_SPILLED_TO_REMOTE_STORAGE, PARTITIONS_SCANNED, PARTITIONS_TOTAL and QUERY_LOAD_PERCENT are absent here, so spill and pruning cannot be asked at this rung.
-- empty_if: privilege_scoped, retention_window, no_activity
-- read_this: One row = one statement that FINISHED inside the window. The two columns that matter are STATUS and ELAPSED_SECONDS; QUEUED_OVERLOAD_SECONDS is the third, because it separates "the query is slow" from "the warehouse was full".
-- healthy: nearly every row OK, queued-overload seconds at or near zero, and the failures that do appear are ones a human can name - a cancelled ad-hoc query, a permission error from a new user.
-- investigate_if: WARN on statements past :slow_seconds elapsed or :queue_seconds queued, CRITICAL on any FAIL or INCIDENT. A false positive looks like a deliberately long batch load, or a client-generated statement - this query excludes client-generated statements by default so the list is human and application work only.
-- actions: 1) read the STATUS and ERROR_MESSAGE columns and re-run the failing statement yourself, which costs nothing (free); 2) if QUEUED_OVERLOAD_SECONDS dominates, raise MAX_CLUSTER_COUNT rather than warehouse size - queuing is a concurrency problem, not a size one (config); 3) only if elapsed time dominates with no queuing and no spill does a larger warehouse become the answer (spend).
-- next: perf_spilling_queries (if the slow statements here look memory-bound and you can reach ACCOUNT_USAGE), perf_queuing_overload (if QUEUED_OVERLOAD_SECONDS is the biggest column), perf_failed_queries (if the CRITICAL rows are the story), perf_operator_stats_probe (if one QUERY_ID needs a plan-level answer)
-- covers: The last 7 days at most, scoped to warehouses the calling role can MONITOR, and capped at :row_limit rows - it is a live window, not an account-wide census. It cannot see spill or pruning at all. Climb to perf_spilling_queries and perf_table_pruning_gap for those, and accept the ACCOUNT_USAGE lag as the price.
-- caveats: RESULT_LIMIT caps the result BEFORE any filtering here, so a busy account can hide its worst statement behind the cap - raise :row_limit or narrow :hours_back rather than trusting a full page. The function cannot be called from a stored procedure or a UDF. Times are milliseconds in the source and are divided here. INCLUDE_CLIENT_GENERATED_STATEMENT is left at its default FALSE, so driver and UI chatter is excluded - set it TRUE if you are auditing a client library. EXECUTION_STATUS is compared case-insensitively because the documented values are lower-case while the account renders them upper-case.

SELECT
  CASE
    WHEN UPPER(execution_status) IN ('FAIL', 'INCIDENT')                  THEN 'CRITICAL'
    WHEN COALESCE(queued_overload_time, 0) > :queue_seconds * 1000        THEN 'WARN'
    WHEN COALESCE(total_elapsed_time, 0)   > :slow_seconds * 1000         THEN 'WARN'
    ELSE 'OK'
  END                                                       AS status,
  query_id,
  start_time,
  end_time,
  user_name,
  role_name,
  warehouse_name,
  warehouse_size,
  query_type,
  execution_status,
  error_code,
  error_message,
  ROUND(COALESCE(total_elapsed_time, 0)       / 1000.0, 1)  AS elapsed_seconds,
  ROUND(COALESCE(compilation_time, 0)         / 1000.0, 1)  AS compilation_seconds,
  ROUND(COALESCE(execution_time, 0)           / 1000.0, 1)  AS execution_seconds,
  ROUND(COALESCE(queued_overload_time, 0)     / 1000.0, 1)  AS queued_overload_seconds,
  ROUND(COALESCE(queued_provisioning_time, 0) / 1000.0, 1)  AS queued_provisioning_seconds,
  ROUND(COALESCE(transaction_blocked_time, 0) / 1000.0, 1)  AS transaction_blocked_seconds,
  ROUND(COALESCE(bytes_scanned, 0) / POWER(1024, 3), 3)     AS gb_scanned,
  rows_produced,
  query_tag,
  query_parameterized_hash,
  LEFT(query_text, 400)                                     AS query_text_head
FROM TABLE(
       INFORMATION_SCHEMA.QUERY_HISTORY(
         END_TIME_RANGE_START => DATEADD('hour', -:hours_back, CURRENT_TIMESTAMP()),
         END_TIME_RANGE_END   => CURRENT_TIMESTAMP(),
         RESULT_LIMIT         => :row_limit
       )
     )
ORDER BY
  IFF(UPPER(execution_status) IN ('FAIL', 'INCIDENT'), 0, 1),
  COALESCE(queued_overload_time, 0) DESC,
  COALESCE(total_elapsed_time, 0) DESC;
