-- query_id: serverless_bulk_load_reliability
-- title: COPY loads that partially fail or get retried, and the rows quietly being dropped
-- domain: serverless_ai   tier: standard
-- rung: account_usage - COPY_HISTORY here is one row per file, account-wide, for a year. The INFORMATION_SCHEMA COPY_HISTORY table function sees only the current database and a short retention, so it cannot answer "which loads are quietly dropping rows" across the estate.
-- reads: snowflake.account_usage.copy_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented as up to 120 minutes in most cases, and documented to stretch to about two days under some conditions. A load that finished an hour ago may not be here yet; do not read an absence as a success.
-- params: :period_days (default 30) rolling window in days; :min_files (default 10) files a target must have loaded before its rates are judged, below which it reports NOT_ASSESSED; :warn_fail_pct (default 1) percentage of files not fully loaded that raises WARN; :critical_fail_pct (default 5) percentage that raises CRITICAL; :warn_dropped_row_pct (default 0.1) percentage of parsed rows that never landed which raises WARN; :critical_dropped_row_pct (default 1) dropped-row percentage that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: COPY_HISTORY columns FILE_NAME, STAGE_LOCATION, LAST_LOAD_TIME, ROW_COUNT, ROW_PARSED, FILE_SIZE, FIRST_ERROR_MESSAGE, FIRST_ERROR_LINE_NUMBER, FIRST_ERROR_COLUMN_NAME, ERROR_COUNT, ERROR_LIMIT, STATUS, TABLE_NAME, TABLE_SCHEMA_NAME, TABLE_CATALOG_NAME, PIPE_NAME, FIRST_COMMIT_TIME and BYTES_BILLED are documented at docs.snowflake.com/en/sql-reference/account-usage/copy_history, as are the four STATUS values Loaded, Load failed, Partially loaded and Load skipped. Those values are documented in mixed case, so every comparison here is made through UPPER. ROW_PARSED is documented as NULL while a load is in progress, which is why the dropped-row arithmetic is guarded. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one target table over the window, split by whether the load came through a pipe or a COPY statement. The two columns that matter are NOT_FULLY_LOADED_PCT and DROPPED_ROW_PCT. The first counts files whose STATUS was anything other than Loaded. The second is the one people miss: ROW_PARSED minus ROW_COUNT is rows Snowflake read out of the file and did not put in the table, and with ON_ERROR set to continue that difference is silent - the load reports success and the data is short.
-- healthy: NOT_FULLY_LOADED_PCT and DROPPED_ROW_PCT are both zero, and ERROR_LIMIT is a number someone chose rather than a default nobody looked at. A load pipeline that is working leaves no partially-loaded files behind.
-- investigate_if: DROPPED_ROW_PCT is above :warn_dropped_row_pct on any table anyone reports from - that is a silent data-quality defect wearing a green status upstream. Also investigate a rising SKIPPED_FILES count, which usually means the same file names are being re-presented. A false positive is a table deliberately loaded with a permissive ON_ERROR because the source is known to be dirty and the rejects are handled elsewhere - confirm that the rejects really are handled. A true positive is a table nobody knew was lossy.
-- actions: 1) take the FIRST_ERROR_MESSAGE and FIRST_ERROR_COLUMN_NAME on the worst table and reproduce it against one file - free; 2) tighten ON_ERROR, or add a rejected-record destination so the dropped rows land somewhere instead of vanishing, and fix the file format that is causing the parse failures - config; 3) where the source genuinely cannot be cleaned, add a reconciliation step that compares parsed against loaded on every run so the gap is measured rather than discovered - config
-- next: serverless_snowpipe_small_files (if the failing loads arrive through a pipe and the files are tiny), serverless_snowpipe_streaming_migration (if the fix is to move this feed to streaming ingestion), serverless_credit_exposure (if the ingestion line is a large share of serverless credits)
-- caveats: ROW_PARSED minus ROW_COUNT is the best available measure of silently dropped rows, but it is not a Snowflake-supplied dropped-row counter and it is NULL for loads still in progress, which are excluded from the arithmetic rather than counted as zero. COPY_HISTORY has one row per file, so a single COPY statement over a thousand files appears as a thousand rows and one badly-formed file among them will barely move a percentage - sort by DROPPED_ROWS as well as by the percentage. BYTES_BILLED is a Snowpipe billing figure and is NULL or zero for loads driven by a COPY statement, so it is reported and never summed across the two lanes. Files whose STATUS is Load skipped are counted separately because a skip is usually deduplication working, not a failure.

WITH files AS (
  SELECT
    table_catalog_name,
    table_schema_name,
    table_name,
    CASE WHEN pipe_name IS NULL THEN 'COPY statement' ELSE 'pipe' END        AS load_lane,
    status,
    row_count,
    row_parsed,
    file_size,
    error_count,
    error_limit,
    bytes_billed,
    first_error_message,
    first_error_line_number,
    first_error_column_name,
    last_load_time,
    CASE WHEN row_parsed IS NOT NULL AND row_parsed > row_count
         THEN row_parsed - row_count ELSE 0 END                              AS dropped_rows,
    CASE WHEN row_parsed IS NOT NULL THEN row_parsed ELSE 0 END              AS parsed_rows_known
  FROM snowflake.account_usage.copy_history
  WHERE last_load_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
rolled AS (
  SELECT
    table_catalog_name,
    table_schema_name,
    table_name,
    load_lane,
    COUNT(*)                                                                 AS file_count,
    COUNT(CASE WHEN UPPER(status) = 'LOADED'           THEN 1 END)           AS loaded_files,
    COUNT(CASE WHEN UPPER(status) = 'PARTIALLY LOADED' THEN 1 END)           AS partially_loaded_files,
    COUNT(CASE WHEN UPPER(status) = 'LOAD FAILED'      THEN 1 END)           AS failed_files,
    COUNT(CASE WHEN UPPER(status) = 'LOAD SKIPPED'     THEN 1 END)           AS skipped_files,
    COUNT(CASE WHEN UPPER(status) NOT IN ('LOADED', 'LOAD SKIPPED') THEN 1 END)
                                                                             AS not_fully_loaded_files,
    SUM(row_count)                                                           AS rows_loaded,
    SUM(parsed_rows_known)                                                   AS rows_parsed,
    SUM(dropped_rows)                                                        AS dropped_rows,
    SUM(error_count)                                                         AS error_rows,
    MAX(error_limit)                                                         AS max_error_limit,
    SUM(file_size)                                                           AS total_file_bytes,
    AVG(file_size)                                                           AS avg_file_bytes,
    SUM(bytes_billed)                                                        AS bytes_billed,
    MIN(last_load_time)                                                      AS first_load_at,
    MAX(last_load_time)                                                      AS last_load_at,
    MAX(first_error_message)                                                 AS sample_error_message,
    MAX(first_error_column_name)                                             AS sample_error_column,
    MAX(first_error_line_number)                                             AS sample_error_line
  FROM files
  GROUP BY 1, 2, 3, 4
),
scored AS (
  SELECT
    r.*,
    ROUND(100.0 * r.not_fully_loaded_files / NULLIF(r.file_count, 0), 3)     AS not_fully_loaded_pct,
    ROUND(100.0 * r.skipped_files          / NULLIF(r.file_count, 0), 3)     AS skipped_pct,
    ROUND(100.0 * r.dropped_rows           / NULLIF(r.rows_parsed, 0), 4)    AS dropped_row_pct,
    ROUND(r.avg_file_bytes / POWER(1024, 2), 3)                              AS avg_file_mb
  FROM rolled r
)
SELECT
  table_catalog_name,
  table_schema_name,
  table_name,
  load_lane,
  file_count,
  loaded_files,
  partially_loaded_files,
  failed_files,
  skipped_files,
  not_fully_loaded_files,
  not_fully_loaded_pct,
  skipped_pct,
  rows_loaded,
  rows_parsed,
  dropped_rows,
  dropped_row_pct,
  error_rows,
  max_error_limit,
  total_file_bytes,
  avg_file_mb,
  bytes_billed,
  first_load_at,
  last_load_at,
  sample_error_message,
  sample_error_column,
  sample_error_line,
  CASE
    WHEN file_count < :min_files                                THEN 'NOT_ASSESSED'
    WHEN dropped_row_pct       >= :critical_dropped_row_pct     THEN 'CRITICAL'
    WHEN not_fully_loaded_pct  >= :critical_fail_pct            THEN 'CRITICAL'
    WHEN dropped_row_pct       >= :warn_dropped_row_pct         THEN 'WARN'
    WHEN not_fully_loaded_pct  >= :warn_fail_pct                THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY dropped_row_pct DESC NULLS LAST, not_fully_loaded_pct DESC NULLS LAST, file_count DESC;
