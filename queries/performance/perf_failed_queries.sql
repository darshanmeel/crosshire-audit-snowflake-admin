-- query_id: perf_failed_queries
-- title: What is failing, with which error, how often, and what it burns before it fails
-- domain: performance   tier: lite
-- rung: account_usage - climbed for account-wide reach and a year of history; the same question for the last 7 days, without any grant, is perf_query_history_live_is
-- reads: snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - up to 45 minutes on this view, 365 days of retention. A failure from the last half hour may simply not be here yet.
-- params: :period_days (default 30) trailing window in days, up to 365; :warn_failures (default 10) occurrences of one error signature at which it becomes WARN; :critical_failures (default 100) occurrences at which it becomes CRITICAL; :top_n (default 200) rows returned, worst first
-- confidence: confirmed-docs
-- confidence_note: EXECUTION_STATUS, ERROR_CODE, ERROR_MESSAGE, QUERY_RETRY_TIME, QUERY_RETRY_CAUSE, FAULT_HANDLING_TIME and CREDITS_USED_CLOUD_SERVICES were checked against docs.snowflake.com/en/sql-reference/account-usage/query_history, where the documented EXECUTION_STATUS values are success, fail and incident. Not run against a live account. The occurrence thresholds are a field heuristic.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one error signature, meaning one ERROR_CODE on one warehouse from one statement type. The two columns that matter are FAILURES and BURNED_EXECUTION_SECONDS - a cheap error that fires ten thousand times is a bug in a client retry loop, while one expensive failure at the end of a two-hour job is a data problem.
-- healthy: a short tail of hand-typed syntax and permission errors from interactive users, no signature repeating on a schedule, and almost no execution time burned before the failure.
-- investigate_if: WARN at :warn_failures and CRITICAL at :critical_failures occurrences of one signature. A false positive looks like a deliberate probe - a health check that expects to fail, or a migration script whose first statement always errors on an already-existing object. Confirm by looking at DISTINCT_USERS and FIRST_SEEN together, because a single automated caller failing on a fixed cadence is a very different problem from twenty humans hitting the same wall.
-- actions: 1) fix the caller - a retry loop with no backoff, a stale credential, a dropped object still referenced by a saved query - which costs nothing (free); 2) if a statement fails after burning real execution time, add a bound so it fails fast instead: STATEMENT_TIMEOUT_IN_SECONDS on the warehouse, or a LIMIT on the exploratory query (config); 3) nothing here justifies more compute - a failing query does not get less likely on a bigger warehouse (spend).
-- next: perf_runaway_query_guardrail (if failures burn a lot of execution time before dying), perf_query_history_live_is (if you need to reproduce a failure right now), perf_spilling_queries (if the errors are memory or resource exhaustion), perf_workload_hours (if the failures cluster in one hour of the day)
-- covers: Account-wide failures for a year. It does NOT see statements the client never submitted, statements rejected before compilation reached the account, or the application-side retry that succeeded afterwards - so a signature here can be entirely invisible to the people who own the pipeline.
-- caveats: There is no per-query compute-credits column on this view. CREDITS_USED_CLOUD_SERVICES is cloud services only, so the honest measure of what a failure cost is the execution seconds it burned first, which is what BURNED_EXECUTION_SECONDS reports; per-query compute credits live in QUERY_ATTRIBUTION_HISTORY and are a cost-domain question. ERROR_MESSAGE is sampled with ANY_VALUE, so the sample may not be representative of the whole group, and it can contain object names from your own account - treat the output as internal. INCIDENT is grouped alongside FAIL because both mean the statement did not deliver a result. EXECUTION_STATUS is compared case-insensitively.

WITH failures AS (
  SELECT
    COALESCE(error_code, -1)                      AS error_code_key,
    warehouse_name,
    query_type,
    UPPER(execution_status)                       AS execution_status_norm,
    user_name,
    query_id,
    start_time,
    error_message,
    COALESCE(execution_time, 0)                   AS execution_ms,
    COALESCE(total_elapsed_time, 0)               AS elapsed_ms,
    COALESCE(query_retry_time, 0)                 AS retry_ms,
    COALESCE(fault_handling_time, 0)              AS fault_ms,
    COALESCE(credits_used_cloud_services, 0)      AS cloud_services_credits
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND UPPER(execution_status) IN ('FAIL', 'INCIDENT')
    AND COALESCE(is_client_generated_statement, FALSE) = FALSE
),
rolled AS (
  SELECT
    error_code_key,
    warehouse_name,
    query_type,
    execution_status_norm,
    COUNT(*)                              AS failures,
    COUNT(DISTINCT user_name)             AS distinct_users,
    MIN(start_time)                       AS first_seen,
    MAX(start_time)                       AS last_seen,
    SUM(execution_ms)                     AS burned_execution_ms,
    SUM(elapsed_ms)                       AS burned_elapsed_ms,
    SUM(retry_ms)                         AS retry_ms,
    SUM(fault_ms)                         AS fault_handling_ms,
    SUM(cloud_services_credits)           AS cloud_services_credits,
    ANY_VALUE(error_message)              AS sample_error_message,
    ANY_VALUE(query_id)                   AS sample_query_id
  FROM failures
  GROUP BY 1, 2, 3, 4
)
SELECT
  CASE
    WHEN failures >= :critical_failures THEN 'CRITICAL'
    WHEN failures >= :warn_failures     THEN 'WARN'
    ELSE 'OK'
  END                                            AS status,
  error_code_key                                 AS error_code,
  execution_status_norm                          AS execution_status,
  warehouse_name,
  query_type,
  failures,
  distinct_users,
  first_seen,
  last_seen,
  ROUND(burned_execution_ms / 1000.0, 1)         AS burned_execution_seconds,
  ROUND(burned_elapsed_ms   / 1000.0, 1)         AS burned_elapsed_seconds,
  ROUND(DIV0(burned_execution_ms, failures) / 1000.0, 1) AS avg_burned_execution_seconds,
  ROUND(retry_ms            / 1000.0, 1)         AS query_retry_seconds,
  ROUND(fault_handling_ms   / 1000.0, 1)         AS fault_handling_seconds,
  ROUND(cloud_services_credits, 4)               AS cloud_services_credits,
  sample_query_id,
  LEFT(sample_error_message, 300)                AS sample_error_message
FROM rolled
ORDER BY failures DESC, burned_execution_ms DESC
LIMIT :top_n;
