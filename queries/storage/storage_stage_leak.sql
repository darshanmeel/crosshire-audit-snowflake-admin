-- query_id: storage_stage_leak
-- title: Internal-stage bytes nobody owns - the storage line with no table attached
-- domain: storage   tier: standard
-- rung: account_usage - there is no other rung for this. STAGE_STORAGE_USAGE_HISTORY is the only view that bills internal-stage bytes; INFORMATION_SCHEMA.STAGES lists stages but not what they hold.
-- reads: snowflake.account_usage.stage_storage_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 120 minutes, and each row is the AVERAGE stage bytes for its day, so a file staged and consumed inside one day barely registers. That is why this query reads the FLOOR of the series rather than its peak.
-- params: :period_days (default 90) how far back to read the series - long enough that a genuine load cycle would have drained at least once; :warn_floor_gb (default 50) persistent stage bytes at which the leak is worth chasing; :critical_floor_gb (default 250) persistent stage bytes that are certainly nobody's intention
-- confidence: confirmed-docs
-- confidence_note: USAGE_DATE and AVERAGE_STAGE_BYTES are the only two columns this view has, per docs.snowflake.com/en/sql-reference/account-usage/stage_storage_usage_history, which also documents that the figure is account-wide across named, table and user stages with NO per-stage breakdown. The floor-of-the-series method and its thresholds are a labelled field heuristic, not a Snowflake-documented measure. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: ONE row, the whole account. The number that matters is never_drained_gb - the LOWEST daily average in the window. Anything a load actually consumed would have brought the series down to near that floor at some point, so whatever the floor is, is what has been sitting there the entire time and paying rent. peak_gb minus never_drained_gb is the part that is genuinely working traffic.
-- healthy: never_drained_gb below :warn_floor_gb, and growth_gb near zero or negative - the stage area breathes with the load and does not accumulate.
-- investigate_if: WARN at never_drained_gb >= :warn_floor_gb. CRITICAL at >= :critical_floor_gb, or at WARN plus a clearly positive growth_gb - a floor that is rising is a leak that is still leaking. Two false positives to know: a stage deliberately used as an archive or a landing zone with a retention policy is SUPPOSED to hold a constant volume; and a load pipeline that keeps files for replay is a decision, not an accident. Both look identical from this rung, which is why the action is to go LIST the stages, not to purge them.
-- actions: 1) run SHOW STAGES IN ACCOUNT and LIST on the named stages to find WHICH stage holds the floor - this view cannot tell you and nothing else will (free); 2) set PURGE = TRUE on the COPY INTO statements that load from those stages so files are removed as they are consumed - this is the fix that stops the leak recurring (config); 3) if files must be kept for replay, move them to an external stage on your own object storage where lifecycle rules can age them out and Snowflake stops billing them (spend).
-- next: storage_account_trend (if you want to see the stage share against total account storage day by day), storage_table_breakdown (if the storage growth turned out not to be stages after all)
-- covers: The whole account's internal stages - named, table and user stages together - as one number per day. It cannot name a stage, a database, a schema or an owner, because the view carries no such column. This is a detection query whose only honest output is a size and a direction; attribution happens off this rung with SHOW STAGES and LIST.
-- caveats: The daily AVERAGE hides intraday peaks entirely: a pipeline that stages a terabyte at 02:00 and consumes it by 03:00 contributes roughly a twenty-fourth of a terabyte to its day. The floor method therefore under-reports transient traffic on purpose and reports only what persists. User stages are included in the total, so one person's forgotten PUT is indistinguishable from a pipeline's backlog. There is no history before the view's 365-day retention, so a :period_days above 365 silently truncates. A very short window makes the floor meaningless - two days of data cannot show you what never drained.

WITH windowed AS (
    SELECT
        usage_date,
        average_stage_bytes
    FROM snowflake.account_usage.stage_storage_usage_history
    WHERE usage_date >= DATEADD('day', -:period_days, CURRENT_DATE())
),
agg AS (
    SELECT
        COUNT(*)                                            AS days_observed,
        MIN(usage_date)                                     AS window_start,
        MAX(usage_date)                                     AS window_end,
        MIN(average_stage_bytes)                            AS floor_bytes,
        MAX(average_stage_bytes)                            AS peak_bytes,
        AVG(average_stage_bytes)                            AS mean_bytes,
        MIN_BY(average_stage_bytes, usage_date)             AS first_bytes,
        MAX_BY(average_stage_bytes, usage_date)             AS last_bytes
    FROM windowed
)
SELECT
    window_start,
    window_end,
    days_observed,
    ROUND(floor_bytes / POWER(1024, 3), 2)                  AS never_drained_gb,
    ROUND(peak_bytes / POWER(1024, 3), 2)                   AS peak_gb,
    ROUND(mean_bytes / POWER(1024, 3), 2)                   AS mean_gb,
    ROUND(last_bytes / POWER(1024, 3), 2)                   AS latest_gb,
    ROUND((peak_bytes - floor_bytes) / POWER(1024, 3), 2)   AS working_traffic_gb,
    ROUND((last_bytes - first_bytes) / POWER(1024, 3), 2)   AS growth_gb,
    ROUND(100 * floor_bytes / NULLIF(peak_bytes, 0), 1)     AS floor_pct_of_peak,
    CASE
        WHEN days_observed < 2
            THEN 'NOT_ASSESSED'
        WHEN floor_bytes >= :critical_floor_gb * POWER(1024, 3)
            THEN 'CRITICAL'
        WHEN floor_bytes >= :warn_floor_gb * POWER(1024, 3)
             AND last_bytes > first_bytes
            THEN 'CRITICAL'
        WHEN floor_bytes >= :warn_floor_gb * POWER(1024, 3)
            THEN 'WARN'
        ELSE 'OK'
    END                                                     AS status
FROM agg;
