-- query_id: storage_time_travel_bloat
-- title: Tables carrying more Time Travel and Fail-safe than live data
-- domain: storage   tier: standard
-- rung: account_usage - the only rung that can score every table in the account in one pass. The live twin storage_metrics_live_is answers the same question for one database.
-- reads: snowflake.account_usage.table_storage_metrics
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 90 minutes. A retention change you made this morning will not show here yet, and it would not show anyway: shortening DATA_RETENTION_TIME_IN_DAYS releases Time Travel bytes gradually as versions age out, so re-run this a week later, not an hour later.
-- params: :min_active_gb (default 1) size floor in GiB of LIVE data - a 10 MB table with a 10x overhead ratio is arithmetic, not a bill; :warn_overhead_ratio (default 1.0) retention bytes per byte of live data at which this becomes worth a conversation; :critical_overhead_ratio (default 3.0) the ratio at which retention is most of what you are paying for
-- confidence: confirmed-docs
-- confidence_note: ACTIVE_BYTES, TIME_TRAVEL_BYTES, FAILSAFE_BYTES, RETAINED_FOR_CLONE_BYTES, IS_TRANSIENT and DELETED are all documented columns of docs.snowflake.com/en/sql-reference/account-usage/table_storage_metrics. The thresholds are labelled field heuristics exposed as params, not measurements from anyone's account. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag
-- read_this: One row = one live table whose retention tail is large enough to matter. The two columns that decide everything are retention_overhead_ratio - Time Travel plus Fail-safe divided by live bytes - and failsafe_gb, because Fail-safe is the half you CANNOT do anything about after the fact. Sorted worst-first by wasted bytes, not by ratio, so a big table with a modest ratio outranks a tiny one with a huge one.
-- healthy: retention_overhead_ratio below :warn_overhead_ratio on every table above the size floor. A ratio near your retention days divided by your rewrite interval is normal for a table that is genuinely rewritten daily.
-- investigate_if: WARN at ratio >= :warn_overhead_ratio - more than half that table's storage line is history. CRITICAL at >= :critical_overhead_ratio - you are paying three times over for data nobody has restored. The classic false positive is a table that was bulk-reloaded once this week: one full rewrite inside the retention window legitimately doubles the footprint and it will drain on its own, so check table_dml_history before cutting retention - that is what storage_table_dml_churn is for.
-- actions: 1) ask the owner of the top rows when they last restored from Time Travel on that table - the honest answer is usually never, and that answer is free (free); 2) lower DATA_RETENTION_TIME_IN_DAYS on the named tables, not on the account - a per-table ALTER is reversible and blast-radius-free, an account default is neither (config); 3) for a genuinely churny staging table, recreate it TRANSIENT - transient tables have no Fail-safe at all, which removes the component you cannot otherwise touch, at the price of no Fail-safe recovery (config).
-- next: storage_table_dml_churn (if you need to know whether the tail is one bulk reload or continuous rewriting), storage_drop_safety_gate (if the fix under discussion is dropping the table rather than shortening its retention), storage_table_breakdown (if you want the same tables without the scoring)
-- covers: Live tables only. Dropped-but-still-billed tables are excluded on purpose - their Fail-safe cannot be shortened, so scoring them would produce findings with no action. storage_table_breakdown shows those.
-- caveats: RETAINED_FOR_CLONE_BYTES is reported but deliberately kept OUT of the ratio: it is billed to whichever member of a clone group owns the micro-partitions, so folding it into the numerator blames a table for a clone somebody else made. Transient and temporary tables have no Fail-safe period, so their whole tail is Time Travel and the CRITICAL band is harder for them to reach - is_transient is projected so you can read the row correctly. Fail-safe is a fixed seven days on permanent tables and cannot be configured, disabled or purged: no action in this query shortens it, they only stop new bytes entering it. A table with zero active bytes is NOT_ASSESSED rather than infinitely bad, because the ratio is undefined.

WITH scored AS (
    SELECT
        table_catalog                               AS database_name,
        table_schema                                AS schema_name,
        table_name,
        id                                          AS table_id,
        is_transient,
        active_bytes,
        time_travel_bytes,
        failsafe_bytes,
        retained_for_clone_bytes,
        time_travel_bytes + failsafe_bytes          AS retention_bytes,
        ROUND(active_bytes / POWER(1024, 3), 2)                     AS active_gb,
        ROUND(time_travel_bytes / POWER(1024, 3), 2)                AS time_travel_gb,
        ROUND(failsafe_bytes / POWER(1024, 3), 2)                   AS failsafe_gb,
        ROUND(retained_for_clone_bytes / POWER(1024, 3), 2)         AS retained_for_clone_gb,
        ROUND((time_travel_bytes + failsafe_bytes) / NULLIF(active_bytes, 0), 2)
                                                    AS retention_overhead_ratio,
        table_created
    FROM snowflake.account_usage.table_storage_metrics
    WHERE deleted = FALSE
      AND active_bytes >= :min_active_gb * POWER(1024, 3)
)
SELECT
    database_name,
    schema_name,
    table_name,
    table_id,
    is_transient,
    active_gb,
    time_travel_gb,
    failsafe_gb,
    retained_for_clone_gb,
    retention_overhead_ratio,
    ROUND(retention_bytes / POWER(1024, 3), 2)      AS retention_gb,
    ROUND(100 * retention_bytes / NULLIF(active_bytes + retention_bytes, 0), 1)
                                                    AS retention_pct_of_table,
    table_created,
    CASE
        WHEN retention_overhead_ratio IS NULL                       THEN 'NOT_ASSESSED'
        WHEN retention_overhead_ratio >= :critical_overhead_ratio   THEN 'CRITICAL'
        WHEN retention_overhead_ratio >= :warn_overhead_ratio       THEN 'WARN'
        ELSE 'OK'
    END                                             AS status
FROM scored
ORDER BY
    CASE status
        WHEN 'CRITICAL' THEN 0
        WHEN 'WARN' THEN 1
        WHEN 'NOT_ASSESSED' THEN 2
        ELSE 3
    END,
    retention_bytes DESC;
