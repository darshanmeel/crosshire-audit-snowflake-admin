-- query_id: storage_account_trend
-- title: Account storage day by day - is the bill growing on data or on retention?
-- domain: storage   tier: lite
-- rung: account_usage - the only rung with a day-by-day storage series. TABLE_STORAGE_METRICS on either rung is a snapshot and has no yesterday.
-- reads: snowflake.account_usage.storage_usage
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 120 minutes, and each row is an AVERAGE over its day, so today's row is partial until the day closes. Read the last row as provisional and compare closed days with closed days.
-- params: :period_days (default 90) how far back to trend - 90 days is long enough that a retention change made a month ago has visibly drained
-- confidence: confirmed-docs
-- confidence_note: USAGE_DATE, STORAGE_BYTES, STAGE_BYTES, FAILSAFE_BYTES and HYBRID_TABLE_STORAGE_BYTES are documented columns of docs.snowflake.com/en/sql-reference/account-usage/storage_usage, which is documented as account-wide daily averages retained one year. The ARCHIVE_STORAGE_* columns on the same view are not selected here so the query does not depend on cool or cold tiering being in use. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window
-- read_this: One row = one day, whole account. The two columns to read together are total_gb and failsafe_pct: a rising total with a flat Fail-safe share means you are storing more DATA, a rising total with a rising Fail-safe share means you are storing more HISTORY of the same data - and only the second one is fixable by touching retention. delta_gb is the day-on-day move; gb_change_vs_window_start is the whole trend in one number.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: 1) before blaming growth on anyone, check whether stage_pct is the line that moved - internal stage bytes grow silently and belong to nobody, and finding that costs nothing (free); 2) if failsafe_pct is the line that moved, the cause is churn, not volume - go to storage_time_travel_bloat and fix the specific tables (config); 3) if total_gb is genuinely growing on active data, that is a lifecycle conversation, not a tuning one - archive or drop with a gate, never a blind DROP (config).
-- next: storage_stage_leak (if stage_pct is the share that is climbing), storage_time_travel_bloat (if failsafe_pct is the share that is climbing), storage_table_breakdown (if total_gb is climbing and you need to know which tables)
-- covers: The whole account, including internal stages and hybrid tables, as a daily series. It cannot tell you WHICH database or table moved - it has no object columns at all. That is the trade: this rung has the time axis, TABLE_STORAGE_METRICS has the object axis, and no single view has both.
-- caveats: Every figure is a daily AVERAGE, so a large table that existed for six hours shows up as a quarter of its size and a spike that started and ended inside one day is invisible. STORAGE_BYTES is documented as including Time Travel data but NOT Fail-safe, which is the separate FAILSAFE_BYTES column - so total_gb here adds them rather than assuming one contains the other. Fail-safe lags its cause by the Time Travel window plus seven days, so a Fail-safe rise you see today was caused by churn one to nine days ago, not today. The percentage columns are shares of that day's total and will move when any component moves, including down.

WITH daily AS (
    SELECT
        usage_date,
        storage_bytes,
        stage_bytes,
        failsafe_bytes,
        hybrid_table_storage_bytes,
        storage_bytes + stage_bytes + failsafe_bytes + hybrid_table_storage_bytes AS total_bytes
    FROM snowflake.account_usage.storage_usage
    WHERE usage_date >= DATEADD('day', -:period_days, CURRENT_DATE())
)
SELECT
    usage_date,
    ROUND(total_bytes / POWER(1024, 3), 2)                          AS total_gb,
    ROUND(storage_bytes / POWER(1024, 3), 2)                        AS table_storage_gb,
    ROUND(stage_bytes / POWER(1024, 3), 2)                          AS stage_gb,
    ROUND(failsafe_bytes / POWER(1024, 3), 2)                       AS failsafe_gb,
    ROUND(hybrid_table_storage_bytes / POWER(1024, 3), 2)           AS hybrid_table_gb,
    ROUND(100 * failsafe_bytes / NULLIF(total_bytes, 0), 1)         AS failsafe_pct,
    ROUND(100 * stage_bytes / NULLIF(total_bytes, 0), 1)            AS stage_pct,
    ROUND((total_bytes - LAG(total_bytes) OVER (ORDER BY usage_date)) / POWER(1024, 3), 2)
                                                                    AS delta_gb,
    ROUND(AVG(total_bytes) OVER (ORDER BY usage_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
          / POWER(1024, 3), 2)                                      AS total_gb_7d_avg,
    ROUND((total_bytes - FIRST_VALUE(total_bytes) OVER (ORDER BY usage_date)) / POWER(1024, 3), 2)
                                                                    AS gb_change_vs_window_start,
    ROUND((failsafe_bytes - FIRST_VALUE(failsafe_bytes) OVER (ORDER BY usage_date)) / POWER(1024, 3), 2)
                                                                    AS failsafe_gb_change_vs_window_start,
    ROUND((stage_bytes - FIRST_VALUE(stage_bytes) OVER (ORDER BY usage_date)) / POWER(1024, 3), 2)
                                                                    AS stage_gb_change_vs_window_start
FROM daily
ORDER BY usage_date;
