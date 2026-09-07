-- query_id: serverless_snowpipe_streaming_migration
-- title: Snowpipe Streaming file migration - cost per table and whether the lane is keeping up
-- domain: serverless_ai   tier: deep
-- rung: account_usage - neither view has an INFORMATION_SCHEMA twin. Snowpipe Streaming migration is a background serverless lane and ACCOUNT_USAGE is the only place it is reported at all.
-- reads: snowflake.account_usage.snowpipe_streaming_file_migration_history, snowflake.account_usage.snowpipe_streaming_client_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - and unusually so. SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY carries a documented latency of up to 12 HOURS, while SNOWPIPE_STREAMING_CLIENT_HISTORY carries up to 120 minutes. The two sides of this query therefore see different amounts of the recent past, which makes the most recent day look like a backlog when it is only lag. Judge the middle of the window, never its edge.
-- params: :period_days (default 30) rolling window in days; :min_gb (default 1) gigabytes migrated on a day before its credits-per-GB is judged; :warn_credits_per_gb (default 0.5) migration credits per gigabyte that raises WARN; :critical_credits_per_gb (default 2.0) credits per gigabyte that raises CRITICAL; :backlog_ratio (default 0.5) migrated bytes divided by client-ingested bytes for the day, below which the migration lane is treated as falling behind; :lag_exclusion_hours (default 24) how much of the most recent history to mark NOT_ASSESSED because the 12-hour migration latency has not settled
-- confidence: confirmed-docs
-- confidence_note: SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY columns START_TIME, END_TIME, CREDITS_USED, NUM_BYTES_MIGRATED, NUM_ROWS_MIGRATED, TABLE_ID, TABLE_NAME, SCHEMA_NAME and DATABASE_NAME, and SNOWPIPE_STREAMING_CLIENT_HISTORY columns CLIENT_NAME, SNOWFLAKE_PROVIDED_ID, EVENT_TIMESTAMP, EVENT_TYPE and BLOB_SIZE_BYTES, are documented on their account-usage pages. Not run against a live account. The EVENT_TYPE value list is NOT documented, so this query groups by it and never filters on a guessed literal. There is no documented key joining a client to a table, so the client side is attached at the DAY level only and is labelled as account-wide context, not as an attribution.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity, feature_not_enabled
-- read_this: One row = one day x one target table whose streamed rows were migrated into normal table files. The two columns that matter are CREDITS_PER_GB_MIGRATED and DAY_MIGRATION_COVERAGE. The first is what this background lane costs to move a gigabyte for that table; the second is that whole day's migrated bytes divided by the bytes the streaming clients pushed in on the same day, and is the only backlog signal these two views can support - it is a property of the DAY, not of the table, and it repeats across the day's rows for that reason.
-- healthy: CREDITS_PER_GB_MIGRATED is stable across days for a given table, and DAY_MIGRATION_COVERAGE hovers around 1.0 once the 12-hour latency has settled - what came in got written out.
-- investigate_if: DAY_MIGRATION_COVERAGE sits below :backlog_ratio for several consecutive settled days, which means rows are arriving faster than the lane rewrites them, or CREDITS_PER_GB_MIGRATED climbs for one table while its row count does not. A false positive is the edge of the window, where the 12-hour migration lag guarantees an apparent shortfall - that is why :lag_exclusion_hours marks the newest rows NOT_ASSESSED. Another false positive is compression: client blob bytes and migrated bytes are measured at different points and will never match exactly.
-- actions: 1) compare NUM_ROWS_MIGRATED per day against what the producers believe they sent, and settle whether this is a lag or a real backlog - free; 2) reduce the number of channels per table or raise the batch size on the client so the lane has fewer, larger units to rewrite - config; 3) if throughput is genuinely the constraint, plan the migration credits as a standing line rather than treating each spike as an incident - spend
-- next: serverless_snowpipe_small_files (if the same tables are also fed by a classic pipe writing tiny files), serverless_credit_exposure (if SNOWPIPE_STREAMING is a visible line in the serverless mix), serverless_bulk_load_reliability (if you need the per-file load outcomes the streaming views do not carry)
-- caveats: The single largest hole is stated in the read_this and repeated here: there is NO documented join key between SNOWPIPE_STREAMING_CLIENT_HISTORY and SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY. The client view has no table, database or channel column, so per-channel backlog - the question as it is usually asked - cannot be answered from these two views at any confidence. What is answerable is per-table migration cost and a day-level coverage ratio, and that is what this query returns; SNOWPIPE_STREAMING_CHANNEL_HISTORY would be the view to add if per-channel is required, and it is out of scope here. BLOB_SIZE_BYTES is the size of the blobs a client wrote, which is not the same measurement as bytes migrated, so DAY_MIGRATION_COVERAGE is a ratio of two related but differently-measured quantities and should be read as a trend, not as a percentage of truth.

WITH migration AS (
  SELECT
    TO_DATE(start_time)                     AS usage_day,
    database_name,
    schema_name,
    table_name,
    SUM(credits_used)                       AS credits_used,
    SUM(num_bytes_migrated)                 AS bytes_migrated,
    SUM(num_rows_migrated)                  AS rows_migrated,
    COUNT(*)                                AS migration_windows,
    MIN(start_time)                         AS first_migration_at,
    MAX(end_time)                           AS last_migration_at
  FROM snowflake.account_usage.snowpipe_streaming_file_migration_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3, 4
),
day_migration AS (
  SELECT
    usage_day,
    SUM(bytes_migrated)                     AS day_bytes_migrated,
    SUM(credits_used)                       AS day_credits_used,
    COUNT(DISTINCT database_name || '.' || schema_name || '.' || table_name)
                                            AS day_tables_migrated
  FROM migration
  GROUP BY 1
),
day_clients AS (
  SELECT
    TO_DATE(event_timestamp)                AS usage_day,
    SUM(blob_size_bytes)                    AS day_client_bytes,
    COUNT(DISTINCT client_name)             AS day_distinct_clients,
    COUNT(DISTINCT event_type)              AS day_distinct_event_types,
    COUNT(*)                                AS day_client_events
  FROM snowflake.account_usage.snowpipe_streaming_client_history
  WHERE event_timestamp >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1
),
scored AS (
  SELECT
    m.usage_day,
    m.database_name,
    m.schema_name,
    m.table_name,
    ROUND(m.credits_used, 5)                                              AS credits_used,
    m.bytes_migrated,
    m.rows_migrated,
    m.migration_windows,
    m.first_migration_at,
    m.last_migration_at,
    ROUND(m.bytes_migrated / POWER(1024, 3), 5)                           AS gb_migrated,
    CASE WHEN m.bytes_migrated > 0
         THEN ROUND(m.credits_used / (m.bytes_migrated / POWER(1024, 3)), 5) END
                                                                          AS credits_per_gb_migrated,
    CASE WHEN m.rows_migrated > 0
         THEN ROUND(m.bytes_migrated / m.rows_migrated, 2) END            AS avg_bytes_per_row,
    ROUND(d.day_bytes_migrated / POWER(1024, 3), 5)                       AS day_gb_migrated,
    ROUND(c.day_client_bytes   / POWER(1024, 3), 5)                       AS day_gb_client_blobs,
    c.day_distinct_clients,
    c.day_distinct_event_types,
    c.day_client_events,
    d.day_tables_migrated,
    CASE WHEN c.day_client_bytes > 0
         THEN ROUND(d.day_bytes_migrated / c.day_client_bytes, 3) END     AS day_migration_coverage,
    DATEDIFF('hour', m.last_migration_at, CURRENT_TIMESTAMP())            AS hours_since_last_migration
  FROM migration m
  JOIN day_migration d
    ON d.usage_day = m.usage_day
  LEFT JOIN day_clients c
    ON c.usage_day = m.usage_day
)
SELECT
  usage_day,
  database_name,
  schema_name,
  table_name,
  credits_used,
  gb_migrated,
  rows_migrated,
  credits_per_gb_migrated,
  avg_bytes_per_row,
  migration_windows,
  day_gb_migrated,
  day_gb_client_blobs,
  day_migration_coverage,
  day_distinct_clients,
  day_distinct_event_types,
  day_client_events,
  day_tables_migrated,
  first_migration_at,
  last_migration_at,
  hours_since_last_migration,
  CASE
    WHEN hours_since_last_migration < :lag_exclusion_hours                            THEN 'NOT_ASSESSED'
    WHEN gb_migrated < :min_gb AND day_migration_coverage IS NULL                     THEN 'NOT_ASSESSED'
    WHEN day_migration_coverage < :backlog_ratio                                      THEN 'CRITICAL'
    WHEN gb_migrated >= :min_gb AND credits_per_gb_migrated >= :critical_credits_per_gb THEN 'CRITICAL'
    WHEN gb_migrated >= :min_gb AND credits_per_gb_migrated >= :warn_credits_per_gb   THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY usage_day DESC, credits_per_gb_migrated DESC NULLS LAST, credits_used DESC;
