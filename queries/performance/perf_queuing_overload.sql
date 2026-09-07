-- query_id: perf_queuing_overload
-- title: Where time goes to queue-overload instead of execution, by warehouse and hour
-- domain: performance   tier: standard
-- rung: account_usage - climbed for account-wide reach and 365 days of history; the live twin, perf_query_history_live_is, carries QUEUED_OVERLOAD_TIME too but only for 7 days and only for warehouses the caller can MONITOR
-- reads: snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - up to 45 minutes on this view, 365 days of retention. Fine for "which hour of which day queues"; wrong tool for "is the warehouse queuing right now", which is the live rung.
-- params: :period_days (default 30) trailing window in days, up to 365; :min_queries (default 20) statements an hour-bucket needs before it is judged, so a two-query hour cannot look like a crisis; :warn_queue_pct (default 5) share of total statement time spent queued on overload at which the bucket is WARN; :critical_queue_pct (default 20) the same share at which it is CRITICAL; :top_n (default 200) rows returned, worst first
-- confidence: confirmed-docs
-- confidence_note: QUEUED_OVERLOAD_TIME, QUEUED_PROVISIONING_TIME, QUEUED_REPAIR_TIME, CLUSTER_NUMBER and TOTAL_ELAPSED_TIME were checked against docs.snowflake.com/en/sql-reference/account-usage/query_history. Not run against a live account. The percentage bands are a field heuristic.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one warehouse in one clock hour. The two columns that matter are QUEUE_PCT_OF_TIME and MAX_CLUSTER_NUMBER_SEEN - a high queue share with MAX_CLUSTER_NUMBER_SEEN stuck at 1 means the warehouse never scaled out, which is a configuration answer, not a sizing one.
-- healthy: queue share near zero in every busy hour, and any queuing that does appear is provisioning or repair rather than overload - those are Snowflake starting or replacing compute, not your concurrency.
-- investigate_if: WARN at :warn_queue_pct and CRITICAL at :critical_queue_pct of statement time spent queued on overload. A false positive looks like one enormous statement in an otherwise idle hour holding the warehouse while short queries pile up behind it - check STATEMENTS and MAX_ELAPSED_SECONDS together before you scale anything out.
-- actions: 1) move the batch that collides with the interactive workload into a different hour, which costs nothing and often removes the queue entirely (free); 2) raise MAX_CLUSTER_COUNT on a multi-cluster warehouse, or split the workload onto a second warehouse - queuing is a concurrency problem and scaling OUT is its fix (config); 3) size UP only if the queue survives scale-out because each individual statement is too slow (spend).
-- next: perf_spilling_queries (if the statements holding the warehouse are also spilling), perf_workload_hours (if you need to see which hour is free to move work into), perf_repeated_query_shapes (if one shape dominates the queued hours), perf_runaway_query_guardrail (if a single statement can hold the warehouse forever because no timeout is set)
-- covers: Every warehouse, every hour, one year back - what the 7-day live rung cannot reach. It measures queuing as SEEN BY THE QUERY. Warehouse-side events - resumes, cluster starts - live in WAREHOUSE_EVENTS_HISTORY and are a warehouse-domain question, not this one.
-- caveats: QUEUED_OVERLOAD_TIME is attributed to the hour the statement STARTED, so a query that started at the end of one hour and queued into the next is counted in the first. The three queue columns mean different things and are kept apart here on purpose: overload is your concurrency, provisioning is Snowflake starting compute, repair is Snowflake replacing a failed node. MAX_CLUSTER_NUMBER_SEEN is the highest cluster ordinal a statement ran on, which is evidence that scale-out happened but is not the configured MAX_CLUSTER_COUNT - read the warehouse configuration for that. Client-generated statements are excluded so driver chatter cannot inflate the statement count.

WITH hourly AS (
  SELECT
    DATE_TRUNC('hour', start_time)                            AS hour_bucket,
    warehouse_name,
    warehouse_size,
    COUNT(*)                                                  AS statements,
    COUNT(DISTINCT user_name)                                 AS distinct_users,
    MAX(cluster_number)                                       AS max_cluster_number_seen,
    SUM(COALESCE(total_elapsed_time, 0))                      AS total_elapsed_ms,
    SUM(COALESCE(execution_time, 0))                          AS execution_ms,
    SUM(COALESCE(queued_overload_time, 0))                    AS queued_overload_ms,
    SUM(COALESCE(queued_provisioning_time, 0))                AS queued_provisioning_ms,
    SUM(COALESCE(queued_repair_time, 0))                      AS queued_repair_ms,
    MAX(COALESCE(total_elapsed_time, 0))                      AS max_elapsed_ms,
    COUNT_IF(COALESCE(queued_overload_time, 0) > 0)           AS statements_that_queued
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND COALESCE(is_client_generated_statement, FALSE) = FALSE
  GROUP BY 1, 2, 3
),
scored AS (
  SELECT
    h.*,
    ROUND(DIV0(queued_overload_ms, NULLIF(total_elapsed_ms, 0)) * 100, 2) AS queue_pct_of_time
  FROM hourly h
)
SELECT
  CASE
    WHEN statements < :min_queries                        THEN 'NOT_ASSESSED'
    WHEN queue_pct_of_time >= :critical_queue_pct         THEN 'CRITICAL'
    WHEN queue_pct_of_time >= :warn_queue_pct             THEN 'WARN'
    ELSE 'OK'
  END                                                     AS status,
  hour_bucket,
  warehouse_name,
  warehouse_size,
  statements,
  statements_that_queued,
  distinct_users,
  max_cluster_number_seen,
  queue_pct_of_time,
  ROUND(queued_overload_ms      / 1000.0, 1)              AS queued_overload_seconds,
  ROUND(queued_provisioning_ms  / 1000.0, 1)              AS queued_provisioning_seconds,
  ROUND(queued_repair_ms        / 1000.0, 1)              AS queued_repair_seconds,
  ROUND(execution_ms            / 1000.0, 1)              AS execution_seconds,
  ROUND(total_elapsed_ms        / 1000.0, 1)              AS total_elapsed_seconds,
  ROUND(max_elapsed_ms          / 1000.0, 1)              AS max_elapsed_seconds
FROM scored
ORDER BY
  IFF(statements < :min_queries, 1, 0),
  queue_pct_of_time DESC,
  queued_overload_ms DESC
LIMIT :top_n;
