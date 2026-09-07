-- query_id: perf_workload_hours
-- title: The shape of the workload - by hour of day, statement class and warehouse
-- domain: performance   tier: lite
-- rung: account_usage - climbed because the shape of a workload is only meaningful over weeks, and the live rung reaches 7 days
-- reads: snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - up to 45 minutes on this view, 365 days of retention. Irrelevant here: a profile built from weeks of history does not move because the last half hour is missing.
-- params: :period_days (default 30) trailing window in days, up to 365; :top_n (default 500) rows returned
-- confidence: confirmed-docs
-- confidence_note: QUERY_TYPE, START_TIME, TOTAL_ELAPSED_TIME, BYTES_SCANNED and the spill and queue columns were checked against docs.snowflake.com/en/sql-reference/account-usage/query_history. Not run against a live account. STATEMENT_CLASS is this library's own grouping of QUERY_TYPE values, not a Snowflake concept - the raw QUERY_TYPE is kept beside it so you can regroup.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one hour of the day, for one warehouse and one statement class, summed across every day in the window. The two columns that matter are STATEMENTS and TOTAL_ELAPSED_HOURS - the first says when people are here, the second says when the machine is busy, and they are frequently not the same hour.
-- healthy: n/a - inventory. This is the reference profile other queries are read against, not a finding.
-- investigate_if: n/a - inventory. Nothing here is a defect on its own. Use it to choose a window: the hour with the fewest statements and the least elapsed time is where a maintenance job, a clustering run or a backfill belongs.
-- actions: 1) move batch work into the quietest hour this profile shows, which costs nothing and is usually the single cheapest performance change available (free); 2) set warehouse auto-suspend against the real gaps in this profile rather than against a guess (config); 3) if two classes of work genuinely overlap every hour, split them onto separate warehouses so one cannot queue behind the other (spend).
-- next: perf_queuing_overload (if a busy hour here is also a queuing hour), perf_spilling_queries (if the heavy hours are heavy because statements spill), perf_repeated_query_shapes (if you want to know WHICH statement fills the busy hour), perf_failed_queries (if failures cluster in one hour)
-- covers: Every warehouse and every statement type the account ran, for up to a year - the census the 7-day live rung cannot give. Serverless work that runs without a warehouse (tasks, pipes, Cortex) appears here only when it also lands a statement in QUERY_HISTORY, so this is not a complete picture of account activity.
-- caveats: HOUR_OF_DAY is taken from START_TIME, which is rendered in the account timezone, so a workload spread across regions will look smeared - the profile is about the account, not about a user. A statement is counted in the hour it STARTED, so a three-hour job is one row in one hour, not three. Client-generated statements are excluded, which is what you want for a human workload profile and wrong if you are auditing a driver. STATEMENT_CLASS lumps QUERY_TYPE values that Snowflake does not group, and its buckets are prefix matches, so an unfamiliar QUERY_TYPE lands in OTHER rather than being dropped.

WITH classified AS (
  SELECT
    HOUR(start_time)                             AS hour_of_day,
    warehouse_name,
    query_type,
    CASE
      WHEN query_type IN ('SELECT', 'DESCRIBE', 'SHOW')                       THEN 'READ'
      WHEN query_type IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE', 'TRUNCATE_TABLE',
                          'COPY', 'UNLOAD', 'MULTI_STATEMENT')                THEN 'WRITE'
      WHEN query_type LIKE 'CREATE%' OR query_type LIKE 'ALTER%'
        OR query_type LIKE 'DROP%'   OR query_type LIKE 'RENAME%'             THEN 'DDL'
      WHEN query_type IN ('GRANT', 'REVOKE', 'USE', 'SET', 'UNSET', 'COMMIT',
                          'BEGIN_TRANSACTION', 'ROLLBACK', 'GET_FILES',
                          'PUT_FILES', 'LIST_FILES')                          THEN 'SESSION_OR_METADATA'
      ELSE 'OTHER'
    END                                          AS statement_class,
    user_name,
    COALESCE(total_elapsed_time, 0)              AS elapsed_ms,
    COALESCE(execution_time, 0)                  AS execution_ms,
    COALESCE(queued_overload_time, 0)            AS queued_overload_ms,
    COALESCE(bytes_scanned, 0)                   AS bytes_scanned,
    COALESCE(bytes_spilled_to_remote_storage, 0) AS remote_spill_bytes,
    IFF(UPPER(execution_status) IN ('FAIL', 'INCIDENT'), 1, 0) AS is_failure
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND COALESCE(is_client_generated_statement, FALSE) = FALSE
)
SELECT
  hour_of_day,
  warehouse_name,
  statement_class,
  query_type,
  COUNT(*)                                                        AS statements,
  COUNT(DISTINCT user_name)                                       AS distinct_users,
  SUM(is_failure)                                                 AS failures,
  ROUND(SUM(elapsed_ms)   / 3600000.0, 2)                         AS total_elapsed_hours,
  ROUND(SUM(execution_ms) / 3600000.0, 2)                         AS total_execution_hours,
  ROUND(SUM(queued_overload_ms) / 3600000.0, 2)                   AS total_queued_overload_hours,
  ROUND(DIV0(SUM(elapsed_ms), COUNT(*)) / 1000.0, 2)              AS avg_elapsed_seconds,
  ROUND(MEDIAN(elapsed_ms) / 1000.0, 2)                           AS median_elapsed_seconds,
  ROUND(SUM(bytes_scanned)     / POWER(1024, 4), 3)               AS tb_scanned,
  ROUND(SUM(remote_spill_bytes) / POWER(1024, 3), 3)              AS remote_spill_gb
FROM classified
GROUP BY 1, 2, 3, 4
ORDER BY hour_of_day, total_elapsed_hours DESC
LIMIT :top_n;
