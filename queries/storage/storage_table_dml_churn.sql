-- query_id: storage_table_dml_churn
-- title: Which tables are rewritten hardest - the churn that turns a small table into a large Time Travel bill
-- domain: storage   tier: deep
-- rung: account_usage - TABLE_DML_HISTORY has no INFORMATION_SCHEMA twin, and query history would only tell you a statement ran, not how many rows it displaced.
-- reads: snowflake.account_usage.table_dml_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 6 hours, the longest of any view in this domain. A pipeline that started churning this morning will not appear until this afternoon, so an empty result is not proof that nothing is rewriting.
-- params: :period_days (default 30) window to sum row movement over - match it to your Time Travel retention so the churn you see is the churn that is still being retained; :warn_rewrite_ratio (default 1.0) rows displaced per row added at which a table is being rewritten rather than appended to; :critical_rewrite_ratio (default 3.0) the ratio at which the table is being rewritten several times over inside the window; :min_displaced_rows (default 1000000) floor on displaced rows so a small table with a dramatic ratio does not outrank a large one with a real bill
-- confidence: confirmed-docs
-- confidence_note: START_TIME, END_TIME, TABLE_ID, TABLE_NAME, SCHEMA_NAME, DATABASE_NAME, ROWS_ADDED, ROWS_REMOVED and ROWS_UPDATED are documented columns of docs.snowflake.com/en/sql-reference/account-usage/table_dml_history, which also documents hourly buckets and that hybrid tables and background maintenance are excluded. Treating ROWS_REMOVED plus ROWS_UPDATED as the version-generating half is this library reasoning about how Time Travel works, not a documented Snowflake metric - it is labelled as such in read_this. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one table over the window. rows_displaced is ROWS_REMOVED plus ROWS_UPDATED - the rows whose previous version had to be kept somewhere, which is the mechanism that fills Time Travel. rewrite_ratio is that number divided by rows_added: near zero means an append-only table, around one means every row you add displaces one, and well above one means the table is being rewritten repeatedly. An append-only table with enormous rows_added is not a churn problem, and this query is built so it does not look like one.
-- healthy: rewrite_ratio below :warn_rewrite_ratio. Loads that append, and updates confined to a recent partition, generate a Time Travel tail proportional to the change and nothing more.
-- investigate_if: WARN at rewrite_ratio >= :warn_rewrite_ratio with at least :min_displaced_rows displaced. CRITICAL at >= :critical_rewrite_ratio - the whole table is effectively being rebuilt inside the retention window, so you are storing several complete copies of it. Two false positives worth naming: a legitimate full-refresh pattern - truncate and reload nightly - produces exactly this signature and the right fix is transient or shorter retention, not stopping the reload; and a one-off backfill inflates the ratio for a window that will never repeat, which active_days will expose because the churn will sit on one or two days rather than spread across the window.
-- actions: 1) look at active_days against the window length before anything else - concentrated churn is a migration, spread churn is a pattern, and telling them apart is free (free); 2) for a genuine full-refresh table, set DATA_RETENTION_TIME_IN_DAYS to the smallest number the recovery story actually needs, or make the table TRANSIENT so no Fail-safe accrues at all (config); 3) for a MERGE that rewrites more than it changes, narrow the ON clause or partition the merge by the load window - the storage bill follows the rows displaced, not the rows you meant to change (config).
-- next: storage_time_travel_bloat (if you want to see what this churn has actually cost in bytes), storage_auto_clustering_spend (if the same tables also pay clustering credits - churn is what makes reclustering expensive), storage_drop_safety_gate (if the conclusion is that the table should not exist)
-- covers: DML performed by users on standard tables. It explicitly does NOT cover hybrid tables, and it does not cover background maintenance such as reclustering or compaction, both of which move bytes without appearing here. It also cannot distinguish a DELETE from an UPDATE beyond the two columns, and it has no query id, so pinning churn to a statement means going to query history separately.
-- caveats: Rows are not bytes. A table of narrow rows and a table of wide rows with identical churn produce very different storage bills, so this query ranks the mechanism, not the money - storage_time_travel_bloat ranks the money. The rewrite ratio is undefined for a table with zero rows added in the window, which is a genuine and common case for a delete-only cleanup job, so those rows are reported with a NULL ratio and scored on displaced rows alone. Hourly buckets mean a burst inside one hour and a steady trickle across it look identical.

WITH bounds AS (
    SELECT DATEADD('day', -:period_days, CURRENT_TIMESTAMP()) AS window_start
),
per_table AS (
    SELECT
        d.database_name,
        d.schema_name,
        d.table_name,
        d.table_id,
        SUM(d.rows_added)                     AS rows_added,
        SUM(d.rows_removed)                   AS rows_removed,
        SUM(d.rows_updated)                   AS rows_updated,
        SUM(d.rows_removed + d.rows_updated)  AS rows_displaced,
        COUNT(*)                              AS dml_hours,
        COUNT(DISTINCT TO_DATE(d.start_time)) AS active_days,
        MIN(d.start_time)                     AS first_dml,
        MAX(d.start_time)                     AS last_dml
    FROM snowflake.account_usage.table_dml_history d
    CROSS JOIN bounds b
    WHERE d.start_time >= b.window_start
    GROUP BY 1, 2, 3, 4
)
SELECT
    database_name,
    schema_name,
    table_name,
    table_id,
    rows_added,
    rows_removed,
    rows_updated,
    rows_displaced,
    ROUND(rows_displaced / NULLIF(rows_added, 0), 2) AS rewrite_ratio,
    dml_hours,
    active_days,
    ROUND(rows_displaced / NULLIF(active_days, 0))   AS displaced_rows_per_active_day,
    first_dml,
    last_dml,
    CASE
        WHEN rows_displaced < :min_displaced_rows                            THEN 'OK'
        WHEN rows_added = 0                                                  THEN 'NOT_ASSESSED'
        WHEN rows_displaced / NULLIF(rows_added, 0) >= :critical_rewrite_ratio THEN 'CRITICAL'
        WHEN rows_displaced / NULLIF(rows_added, 0) >= :warn_rewrite_ratio     THEN 'WARN'
        ELSE 'OK'
    END                                              AS status
FROM per_table
ORDER BY
    CASE status
        WHEN 'CRITICAL' THEN 0
        WHEN 'WARN' THEN 1
        WHEN 'NOT_ASSESSED' THEN 2
        ELSE 3
    END,
    rows_displaced DESC;
