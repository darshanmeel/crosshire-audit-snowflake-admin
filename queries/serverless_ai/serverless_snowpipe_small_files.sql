-- query_id: serverless_snowpipe_small_files
-- title: Pipes paying per-file overhead on tiny files - credits per GB far above the batched rate
-- domain: serverless_ai   tier: standard
-- rung: account_usage - PIPE_USAGE_HISTORY has the credits, COPY_HISTORY has the file sizes. INFORMATION_SCHEMA has a PIPE_USAGE_HISTORY function too, but it is scoped to the current database and to a short retention, so it cannot rank pipes account-wide.
-- reads: snowflake.account_usage.pipe_usage_history, snowflake.account_usage.copy_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - PIPE_USAGE_HISTORY up to 180 minutes, COPY_HISTORY up to 120 minutes in most cases and documented to stretch to about two days under some conditions. Treat the last day of the window as incomplete on both sides.
-- params: :period_days (default 30) rolling window in days; :min_gb (default 1) gigabytes a pipe must have loaded in the window before its credits-per-GB is judged, below which it reports NOT_ASSESSED; :small_file_mb (default 10) average file size under which the per-file overhead starts to dominate; :warn_credits_per_gb (default 0.2) credits per gigabyte that raises WARN; :critical_credits_per_gb (default 1.0) credits per gigabyte that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: PIPE_USAGE_HISTORY columns PIPE_ID, PIPE_NAME, START_TIME, END_TIME, CREDITS_USED, BYTES_INSERTED, FILES_INSERTED and BYTES_BILLED are documented at docs.snowflake.com/en/sql-reference/account-usage/pipe_usage_history; FILES_INSERTED is documented as VARIANT and BYTES_INSERTED as FLOAT, so both are cast before arithmetic. COPY_HISTORY columns FILE_SIZE, PIPE_NAME, PIPE_CATALOG_NAME, PIPE_SCHEMA_NAME, LAST_LOAD_TIME, STATUS and ROW_COUNT are documented on its own page. Not run against a live account. The one shape that could NOT be doc-verified is whether PIPE_USAGE_HISTORY.PIPE_NAME is fully qualified: the join here assumes it is, and the query is written so that a failed join leaves the COPY-derived columns NULL and still reports the pipe-side credits-per-GB, rather than dropping the pipe.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity, serverless_only
-- read_this: One row = one pipe over the window. The two columns that matter are CREDITS_PER_GB and AVG_FILE_MB. Snowpipe bills a per-file overhead on top of the data it moves, so the same gigabyte delivered as thousands of small files costs a multiple of the same gigabyte delivered as a few large ones. CREDITS_PER_GB is the symptom; AVG_FILE_MB is the cause, and the two together tell you whether batching upstream would pay.
-- healthy: CREDITS_PER_GB is low and stable across pipes doing similar work, and AVG_FILE_MB is comfortably above :small_file_mb. A pipe whose cost per gigabyte matches its peers is loading files of a sensible size.
-- investigate_if: CREDITS_PER_GB crosses :warn_credits_per_gb while AVG_FILE_MB sits under :small_file_mb - that pair is the small-file signature. A false positive is a genuinely low-volume pipe where a handful of files makes the ratio meaningless, which is what :min_gb guards, or a pipe deliberately kept at low latency where small files are the point and the overhead is the price of freshness. A true positive is a high-volume pipe whose producer writes a file per event.
-- actions: 1) look at the producer writing into the stage and count files per hour against bytes per hour - free; 2) batch on the producer side or add a staging step so files land in the size range the pipe was designed for, and consider Snowpipe Streaming where the latency requirement is the reason the files are small - config; 3) where neither is possible, accept the overhead knowingly and budget the pipe as a premium-latency line - spend
-- next: serverless_bulk_load_reliability (if the same pipes also show partial loads or dropped rows), serverless_snowpipe_streaming_migration (if the answer to small files is to move the pipe to streaming), serverless_credit_exposure (if PIPE is a large share of serverless credits)
-- caveats: PIPE_USAGE_HISTORY is an hourly rollup with no table dimension, so a pipe feeding several tables is reported as one line. COPY_HISTORY is one row per FILE and its PIPE_NAME is NULL for loads driven by a COPY statement rather than a pipe, so those rows are excluded here and belong to serverless_bulk_load_reliability instead. AVG_FILE_MB is computed from COPY_HISTORY file sizes, which are the size on the stage BEFORE loading, not the bytes billed. BYTES_BILLED and BYTES_INSERTED are different numbers by design and are both reported rather than reconciled. Credits here are metered credits, not currency.

WITH pipe_usage AS (
  SELECT
    pipe_name,
    SUM(credits_used)                                     AS credits_used,
    SUM(TO_DOUBLE(bytes_inserted))                        AS bytes_inserted,
    SUM(TRY_TO_NUMBER(files_inserted::VARCHAR))           AS files_inserted,
    SUM(bytes_billed)                                     AS bytes_billed,
    COUNT(*)                                              AS metered_hours,
    MIN(start_time)                                       AS first_metered_at,
    MAX(end_time)                                         AS last_metered_at
  FROM snowflake.account_usage.pipe_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1
),
copy_files AS (
  SELECT
    pipe_catalog_name || '.' || pipe_schema_name || '.' || pipe_name AS qualified_pipe_name,
    COUNT(*)                                              AS copy_file_count,
    AVG(file_size)                                        AS avg_file_bytes,
    MEDIAN(file_size)                                     AS median_file_bytes,
    MIN(file_size)                                        AS min_file_bytes,
    MAX(file_size)                                        AS max_file_bytes,
    SUM(row_count)                                        AS rows_loaded,
    COUNT(DISTINCT table_catalog_name || '.' || table_schema_name || '.' || table_name)
                                                          AS target_tables
  FROM snowflake.account_usage.copy_history
  WHERE last_load_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND pipe_name IS NOT NULL
  GROUP BY 1
),
scored AS (
  SELECT
    p.pipe_name,
    ROUND(p.credits_used, 4)                                          AS credits_used,
    p.bytes_inserted,
    p.files_inserted,
    p.bytes_billed,
    p.metered_hours,
    p.first_metered_at,
    p.last_metered_at,
    ROUND(p.bytes_inserted / POWER(1024, 3), 4)                       AS gb_inserted,
    CASE WHEN p.bytes_inserted > 0
         THEN ROUND(p.credits_used / (p.bytes_inserted / POWER(1024, 3)), 5) END
                                                                      AS credits_per_gb,
    CASE WHEN p.files_inserted > 0
         THEN ROUND(p.bytes_inserted / p.files_inserted / POWER(1024, 2), 3) END
                                                                      AS avg_file_mb,
    CASE WHEN p.files_inserted > 0
         THEN ROUND(p.credits_used / p.files_inserted, 8) END         AS credits_per_file,
    c.copy_file_count,
    ROUND(c.avg_file_bytes    / POWER(1024, 2), 3)                    AS copy_avg_file_mb,
    ROUND(c.median_file_bytes / POWER(1024, 2), 3)                    AS copy_median_file_mb,
    ROUND(c.min_file_bytes    / POWER(1024, 2), 3)                    AS copy_min_file_mb,
    ROUND(c.max_file_bytes    / POWER(1024, 2), 3)                    AS copy_max_file_mb,
    c.rows_loaded,
    c.target_tables
  FROM pipe_usage p
  LEFT JOIN copy_files c
    ON UPPER(c.qualified_pipe_name) = UPPER(p.pipe_name)
)
SELECT
  pipe_name,
  credits_used,
  gb_inserted,
  files_inserted,
  credits_per_gb,
  avg_file_mb,
  credits_per_file,
  bytes_billed,
  metered_hours,
  copy_file_count,
  copy_avg_file_mb,
  copy_median_file_mb,
  copy_min_file_mb,
  copy_max_file_mb,
  rows_loaded,
  target_tables,
  first_metered_at,
  last_metered_at,
  CASE
    WHEN gb_inserted < :min_gb                                                     THEN 'NOT_ASSESSED'
    WHEN credits_per_gb >= :critical_credits_per_gb                                THEN 'CRITICAL'
    WHEN credits_per_gb >= :warn_credits_per_gb
         AND COALESCE(avg_file_mb, copy_avg_file_mb) < :small_file_mb              THEN 'CRITICAL'
    WHEN credits_per_gb >= :warn_credits_per_gb                                    THEN 'WARN'
    WHEN COALESCE(avg_file_mb, copy_avg_file_mb) < :small_file_mb                  THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY credits_per_gb DESC NULLS LAST, credits_used DESC;
