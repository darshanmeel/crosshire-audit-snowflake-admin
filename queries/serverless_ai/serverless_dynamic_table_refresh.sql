-- query_id: serverless_dynamic_table_refresh
-- title: Dynamic tables - the most expensive refreshes, and the ones refreshing on nothing
-- domain: serverless_ai   tier: standard
-- rung: account_usage - the INFORMATION_SCHEMA DYNAMIC_TABLE_REFRESH_HISTORY function exists but is scoped to the current database and a short retention. Ranking refresh cost across the estate needs the account-wide view.
-- reads: snowflake.account_usage.dynamic_table_refresh_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 3 hours. A refresh that is EXECUTING right now will not be here; a refresh that failed two hours ago probably is.
-- params: :period_days (default 30) rolling window in days; :min_refreshes (default 10) refreshes a table needs before its mix is judged, below which it reports NOT_ASSESSED; :min_refresh_seconds (default 60) total refresh seconds in the window below which a table is too cheap to be worth acting on; :warn_no_data_pct (default 40) percentage of refreshes that found nothing to do which raises WARN; :critical_no_data_pct (default 70) that percentage which raises CRITICAL; :warn_fail_pct (default 5) percentage of refreshes ending FAILED or UPSTREAM_FAILED that raises WARN
-- confidence: confirmed-docs
-- confidence_note: DYNAMIC_TABLE_REFRESH_HISTORY columns NAME, SCHEMA_NAME, DATABASE_NAME, STATE, STATE_MESSAGE, QUERY_ID, DATA_TIMESTAMP, REFRESH_START_TIME, REFRESH_END_TIME, COMPLETION_TARGET, QUALIFIED_NAME, STATISTICS, REFRESH_ACTION, REINIT_REASON, REFRESH_TRIGGER and TARGET_LAG_SEC are documented at docs.snowflake.com/en/sql-reference/account-usage/dynamic_table_refresh_history, as are the STATE values EXECUTING, SUCCEEDED, FAILED, CANCELLED and UPSTREAM_FAILED, the REFRESH_ACTION values NO_DATA, REINITIALIZE, FULL, INCREMENTAL and CUSTOM_INCREMENTAL, and the REFRESH_TRIGGER values SCHEDULED, MANUAL and CREATION. The STATISTICS object keys numInsertedRows, numDeletedRows, numCopiedRows, numAddedPartitions, numRemovedPartitions, queuedTimeMs, compilationTimeMs and executionTimeMs are documented on the same page and are read with their exact camel case. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity, feature_not_enabled
-- read_this: One row = one dynamic table over the window. The two columns that matter are TOTAL_REFRESH_SECONDS and NO_DATA_PCT. The first is the closest thing to a cost this view supports - see the caveats, there is no credits column - and the second is the share of refreshes where Snowflake woke up, checked, and found nothing changed. A table with a tight target lag over a source that changes twice a day spends most of its life doing exactly that.
-- healthy: NO_DATA_PCT is low, the refresh mix is mostly INCREMENTAL, and MISSED_TARGET_PCT is near zero - the table keeps its promised lag without re-reading the world. A FULL or REINITIALIZE refresh appearing occasionally after a schema change is normal.
-- investigate_if: NO_DATA_PCT crosses :warn_no_data_pct on a table with real refresh seconds - the target lag is tighter than the data warrants and every empty check is metered. Also investigate a table whose refreshes are mostly FULL or REINITIALIZE, because incremental refresh has stopped working and nobody was told. A false positive is a table that is deliberately near-real-time on a bursty source, where empty checks are the price of low latency and are cheap. A true positive is a nightly-changing source behind a one-minute target lag.
-- actions: 1) compare TARGET_LAG_SECONDS against how often the upstream source actually changes - free; 2) widen the target lag to the freshness the consumers really need, or switch the table to a downstream-driven lag so it refreshes when something asks for it - config; 3) if refreshes are FULL because the query stopped qualifying for incremental refresh, read REINIT_REASON and rewrite the query, which is cheaper than paying for a full rebuild on every lag interval - config
-- next: serverless_credit_exposure (if you need the serverless credit line these refreshes contribute to), serverless_task_cost_and_upsizing (if the same pipeline is also driven by tasks), serverless_not_monitor_guarded (if you want to know what could have capped this spend, and the answer is nothing)
-- caveats: The one hole worth stating first: DYNAMIC_TABLE_REFRESH_HISTORY has NO credits column. Refresh cost here is wall-clock refresh seconds plus the compilation, queue and execution milliseconds inside STATISTICS, which is a proxy for work and not a bill. The credits themselves appear only in aggregate in METERING_HISTORY, with no dynamic-table dimension, which is why serverless_credit_exposure is the next step rather than a join. MISSED_TARGET_PCT compares REFRESH_END_TIME against COMPLETION_TARGET, which is a target derived from TARGET_LAG and not a service-level promise. Rows in the EXECUTING state have no REFRESH_END_TIME and are excluded from the duration arithmetic rather than counted as instant. A dynamic table dropped and recreated with the same qualified name is reported as one table.

WITH refreshes AS (
  SELECT
    database_name,
    schema_name,
    name                                                                  AS table_name,
    qualified_name,
    state,
    refresh_action,
    refresh_trigger,
    reinit_reason,
    target_lag_sec,
    refresh_start_time,
    refresh_end_time,
    completion_target,
    data_timestamp,
    state_message,
    DATEDIFF('millisecond', refresh_start_time, refresh_end_time)         AS wall_ms,
    statistics:"executionTimeMs"::NUMBER                                  AS execution_ms,
    statistics:"compilationTimeMs"::NUMBER                                AS compilation_ms,
    statistics:"queuedTimeMs"::NUMBER                                     AS queued_ms,
    statistics:"numInsertedRows"::NUMBER                                  AS inserted_rows,
    statistics:"numDeletedRows"::NUMBER                                   AS deleted_rows,
    statistics:"numCopiedRows"::NUMBER                                    AS copied_rows,
    statistics:"numAddedPartitions"::NUMBER                               AS added_partitions,
    statistics:"numRemovedPartitions"::NUMBER                             AS removed_partitions
  FROM snowflake.account_usage.dynamic_table_refresh_history
  WHERE refresh_start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
rolled AS (
  SELECT
    database_name,
    schema_name,
    table_name,
    MAX(qualified_name)                                                       AS qualified_name,
    MAX(target_lag_sec)                                                       AS target_lag_seconds,
    COUNT(*)                                                                  AS refresh_count,
    COUNT(CASE WHEN UPPER(state) = 'SUCCEEDED'  THEN 1 END)                   AS succeeded_refreshes,
    COUNT(CASE WHEN UPPER(state) IN ('FAILED', 'UPSTREAM_FAILED') THEN 1 END) AS failed_refreshes,
    COUNT(CASE WHEN UPPER(state) = 'CANCELLED'  THEN 1 END)                   AS cancelled_refreshes,
    COUNT(CASE WHEN UPPER(state) = 'EXECUTING'  THEN 1 END)                   AS in_flight_refreshes,
    COUNT(CASE WHEN UPPER(refresh_action) = 'NO_DATA'             THEN 1 END) AS no_data_refreshes,
    COUNT(CASE WHEN UPPER(refresh_action) = 'INCREMENTAL'         THEN 1 END) AS incremental_refreshes,
    COUNT(CASE WHEN UPPER(refresh_action) = 'CUSTOM_INCREMENTAL'  THEN 1 END) AS custom_incremental_refreshes,
    COUNT(CASE WHEN UPPER(refresh_action) = 'FULL'                THEN 1 END) AS full_refreshes,
    COUNT(CASE WHEN UPPER(refresh_action) = 'REINITIALIZE'        THEN 1 END) AS reinitialize_refreshes,
    COUNT(CASE WHEN UPPER(refresh_trigger) = 'MANUAL'             THEN 1 END) AS manual_refreshes,
    COUNT(CASE WHEN refresh_end_time > completion_target          THEN 1 END) AS missed_target_refreshes,
    COUNT(CASE WHEN COALESCE(inserted_rows, 0) + COALESCE(deleted_rows, 0) = 0
               THEN 1 END)                                                    AS zero_change_refreshes,
    SUM(wall_ms)         / 1000.0                                             AS total_refresh_seconds,
    AVG(wall_ms)         / 1000.0                                             AS avg_refresh_seconds,
    MAX(wall_ms)         / 1000.0                                             AS max_refresh_seconds,
    SUM(execution_ms)    / 1000.0                                             AS total_execution_seconds,
    SUM(compilation_ms)  / 1000.0                                             AS total_compilation_seconds,
    SUM(queued_ms)       / 1000.0                                             AS total_queued_seconds,
    SUM(COALESCE(inserted_rows, 0))                                           AS inserted_rows,
    SUM(COALESCE(deleted_rows, 0))                                            AS deleted_rows,
    SUM(COALESCE(copied_rows, 0))                                             AS copied_rows,
    SUM(COALESCE(added_partitions, 0))                                        AS added_partitions,
    MAX(reinit_reason)                                                        AS sample_reinit_reason,
    MAX(state_message)                                                        AS sample_state_message,
    MIN(refresh_start_time)                                                   AS first_refresh_at,
    MAX(refresh_start_time)                                                   AS last_refresh_at
  FROM refreshes
  GROUP BY 1, 2, 3
),
scored AS (
  SELECT
    r.*,
    ROUND(100.0 * r.no_data_refreshes       / NULLIF(r.refresh_count, 0), 2) AS no_data_pct,
    ROUND(100.0 * r.zero_change_refreshes   / NULLIF(r.refresh_count, 0), 2) AS zero_change_pct,
    ROUND(100.0 * r.failed_refreshes        / NULLIF(r.refresh_count, 0), 2) AS failed_pct,
    ROUND(100.0 * r.missed_target_refreshes / NULLIF(r.refresh_count, 0), 2) AS missed_target_pct,
    ROUND(100.0 * (r.full_refreshes + r.reinitialize_refreshes)
                                            / NULLIF(r.refresh_count, 0), 2) AS full_rebuild_pct,
    CASE WHEN r.refresh_count > 0
         THEN ROUND(r.total_refresh_seconds / r.refresh_count, 2) END        AS seconds_per_refresh
  FROM rolled r
)
SELECT
  database_name,
  schema_name,
  table_name,
  qualified_name,
  target_lag_seconds,
  refresh_count,
  ROUND(total_refresh_seconds, 1)     AS total_refresh_seconds,
  ROUND(avg_refresh_seconds, 2)       AS avg_refresh_seconds,
  ROUND(max_refresh_seconds, 2)       AS max_refresh_seconds,
  ROUND(total_execution_seconds, 1)   AS total_execution_seconds,
  ROUND(total_compilation_seconds, 1) AS total_compilation_seconds,
  ROUND(total_queued_seconds, 1)      AS total_queued_seconds,
  no_data_refreshes,
  no_data_pct,
  zero_change_refreshes,
  zero_change_pct,
  incremental_refreshes,
  custom_incremental_refreshes,
  full_refreshes,
  reinitialize_refreshes,
  full_rebuild_pct,
  manual_refreshes,
  succeeded_refreshes,
  failed_refreshes,
  failed_pct,
  cancelled_refreshes,
  in_flight_refreshes,
  missed_target_refreshes,
  missed_target_pct,
  inserted_rows,
  deleted_rows,
  copied_rows,
  added_partitions,
  seconds_per_refresh,
  sample_reinit_reason,
  sample_state_message,
  first_refresh_at,
  last_refresh_at,
  CASE
    WHEN refresh_count < :min_refreshes                                         THEN 'NOT_ASSESSED'
    WHEN total_refresh_seconds < :min_refresh_seconds                           THEN 'NOT_ASSESSED'
    WHEN no_data_pct >= :critical_no_data_pct                                   THEN 'CRITICAL'
    WHEN failed_pct  >= :warn_fail_pct                                          THEN 'CRITICAL'
    WHEN no_data_pct >= :warn_no_data_pct                                       THEN 'WARN'
    WHEN full_rebuild_pct >= :warn_no_data_pct                                  THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY total_refresh_seconds DESC NULLS LAST, no_data_pct DESC NULLS LAST;
