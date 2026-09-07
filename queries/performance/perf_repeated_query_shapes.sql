-- query_id: perf_repeated_query_shapes
-- title: Which query shapes repeat most, and what they cost in aggregate
-- domain: performance   tier: deep
-- rung: account_usage - AGGREGATE_QUERY_HISTORY exists only here, and it is the only view that has already done the per-shape rollup for you
-- reads: snowflake.account_usage.aggregate_query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - the documented latency on AGGREGATE_QUERY_HISTORY is up to 180 minutes, three times the lag on QUERY_HISTORY. Retention is not stated on the view page, so do not assume the full year that QUERY_HISTORY gives you.
-- params: :period_days (default 30) trailing window in days; :min_calls (default 100) calls a shape needs before it is judged, so a one-off heavy statement is not called a pattern; :warn_total_hours (default 1) aggregate elapsed hours across all calls at which a shape becomes WARN; :critical_total_hours (default 10) the same at which it becomes CRITICAL; :top_n (default 200) rows returned, worst first
-- confidence: confirmed-docs
-- confidence_note: Every column and every OBJECT sub-key used here was checked against docs.snowflake.com/en/sql-reference/account-usage/aggregate_query_history, which documents the sub-keys sum, avg, stddev, min, median, p90, p99 and max on the metric columns. Not run against a live account. Three columns carry no sum sub-key - PERCENTAGE_SCANNED_FROM_CACHE, QUERY_LOAD_PERCENT and QUERY_ACCELERATION_UPPER_LIMIT_SCALE_FACTOR - and none of them is read here. The view carries NO compute-credits column and no QUERY_ID, so the cost of a shape is stated in time, never in credits.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one query SHAPE, identified by QUERY_PARAMETERIZED_HASH, rolled up across the whole window. The two columns that matter are CALLS and APPROX_TOTAL_ELAPSED_HOURS - together they say where one fix pays many times. A shape at the top with a small MEDIAN_ELAPSED_SECONDS is a frequency problem; one with a large median is a single slow statement that happens to recur.
-- healthy: the top shapes by aggregate time are the ones you would have named yourself - the nightly load, the dashboard refresh - and no shape carries a P99 far above its median.
-- investigate_if: WARN at :warn_total_hours and CRITICAL at :critical_total_hours of aggregate elapsed time, provided the shape ran at least :min_calls times. A false positive looks like a genuinely long-running batch shape that runs once a night and is meant to take an hour - read CALLS before you read hours. A P99 many times the median is the more interesting signal: the same SQL is sometimes fast and sometimes not, which is usually queuing or cache, not the SQL.
-- actions: 1) fix the shape once - add the missing predicate, materialise the repeated subquery, stop the dashboard polling every thirty seconds - and every call inherits the fix (free); 2) if the shape is already minimal but runs constantly, cache its result in a table or a dynamic table so the calls stop reaching the warehouse (config); 3) size the warehouse only after the shape itself has been ruled out (spend).
-- next: perf_spilling_queries (if MAX_REMOTE_SPILL_GB on a shape is non-zero and you need the individual statements), perf_query_insights (if you want the vendor verdict on the same shapes), perf_table_pruning_gap (if the shape scans far more than it returns), perf_operator_stats_probe (if you can find one QUERY_ID of this shape and need its plan)
-- covers: Every repeated shape the account ran in the window, already grouped - which is exactly what QUERY_HISTORY makes you compute yourself. What it does NOT carry: QUERY_ID, EXECUTION_STATUS, QUERY_HASH and any compute-credit column. So you cannot go from a row here to a single statement inside this view; take the QUERY_PARAMETERIZED_HASH into QUERY_HISTORY, which carries the same column, to find individual query ids.
-- caveats: APPROX_TOTAL_ELAPSED_HOURS is calls multiplied by the mean elapsed time per call and summed over the one-minute intervals - it is an approximation by construction, and it is wall-clock time, not credits. Statements that run concurrently on the same warehouse each contribute their full elapsed time, so the total can exceed the wall-clock length of the window. The OBJECT columns are read with GET rather than the colon path operator, so a client that binds a leading colon cannot mangle them. MEDIAN and P99 are taken as the maximum of the per-interval values, not a true median across the window - a percentile of percentiles is directional, not exact. Shapes with a null QUERY_PARAMETERIZED_HASH are excluded because they cannot be grouped.

WITH shapes AS (
  SELECT
    query_parameterized_hash,
    ANY_VALUE(query_type)                                          AS query_type,
    ANY_VALUE(warehouse_name)                                      AS sample_warehouse_name,
    ANY_VALUE(warehouse_size)                                      AS sample_warehouse_size,
    ANY_VALUE(database_name)                                       AS sample_database_name,
    ANY_VALUE(schema_name)                                         AS sample_schema_name,
    ANY_VALUE(user_name)                                           AS sample_user_name,
    COUNT(DISTINCT warehouse_name)                                 AS distinct_warehouses,
    COUNT(DISTINCT user_name)                                      AS distinct_users,
    MIN(interval_start_time)                                       AS first_interval,
    MAX(interval_end_time)                                         AS last_interval,
    SUM(calls)                                                     AS calls,
    SUM(calls * GET(total_elapsed_time, 'avg')::float)             AS approx_total_elapsed_ms,
    MAX(GET(total_elapsed_time, 'median')::float)                  AS median_elapsed_ms,
    MAX(GET(total_elapsed_time, 'p99')::float)                     AS p99_elapsed_ms,
    MAX(GET(total_elapsed_time, 'max')::float)                     AS max_elapsed_ms,
    MAX(GET(bytes_scanned, 'median')::float)                       AS median_bytes_scanned,
    MAX(GET(bytes_spilled_to_remote_storage, 'max')::float)        AS max_remote_spill_bytes,
    SUM(GET(queued_overload_time, 'sum')::float)                   AS queued_overload_ms,
    SUM(GET(credits_used_cloud_services, 'sum')::float)            AS cloud_services_credits,
    ANY_VALUE(query_text)                                          AS sample_query_text
  FROM snowflake.account_usage.aggregate_query_history
  WHERE interval_start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND query_parameterized_hash IS NOT NULL
    AND COALESCE(is_client_generated_statement, FALSE) = FALSE
  GROUP BY 1
)
SELECT
  CASE
    WHEN calls < :min_calls                                                THEN 'NOT_ASSESSED'
    WHEN approx_total_elapsed_ms >= :critical_total_hours * 3600000        THEN 'CRITICAL'
    WHEN approx_total_elapsed_ms >= :warn_total_hours * 3600000            THEN 'WARN'
    ELSE 'OK'
  END                                                             AS status,
  query_parameterized_hash,
  query_type,
  calls,
  ROUND(approx_total_elapsed_ms / 3600000.0, 3)                   AS approx_total_elapsed_hours,
  ROUND(median_elapsed_ms / 1000.0, 3)                            AS median_elapsed_seconds,
  ROUND(p99_elapsed_ms    / 1000.0, 3)                            AS p99_elapsed_seconds,
  ROUND(max_elapsed_ms    / 1000.0, 3)                            AS max_elapsed_seconds,
  ROUND(DIV0(p99_elapsed_ms, NULLIF(median_elapsed_ms, 0)), 2)    AS p99_over_median,
  ROUND(median_bytes_scanned  / POWER(1024, 3), 3)                AS median_gb_scanned,
  ROUND(max_remote_spill_bytes / POWER(1024, 3), 3)               AS max_remote_spill_gb,
  ROUND(queued_overload_ms / 1000.0, 1)                           AS queued_overload_seconds,
  ROUND(cloud_services_credits, 4)                                AS cloud_services_credits,
  distinct_warehouses,
  distinct_users,
  sample_warehouse_name,
  sample_warehouse_size,
  sample_database_name,
  sample_schema_name,
  sample_user_name,
  first_interval,
  last_interval,
  LEFT(sample_query_text, 400)                                    AS query_text_head
FROM shapes
ORDER BY
  IFF(calls < :min_calls, 1, 0),
  approx_total_elapsed_ms DESC,
  calls DESC
LIMIT :top_n;
