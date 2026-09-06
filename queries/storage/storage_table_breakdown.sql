-- query_id: storage_table_breakdown
-- title: Account-wide table storage, split active vs Time Travel vs Fail-safe vs retained-for-clone
-- domain: storage   tier: lite
-- rung: account_usage - the inventory every other storage query joins back to. INFORMATION_SCHEMA can only answer this one database at a time, so account-wide needs this rung.
-- reads: snowflake.account_usage.table_storage_metrics
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 90 minutes. This is a snapshot view, not a time series: there is exactly one current row per table, so you cannot ask it what storage looked like last Tuesday. For the day-by-day shape use storage_account_trend.
-- params: :min_total_gb (default 1) size floor in GiB - below this a table cannot move a storage bill; :top_n (default 200) how many tables to return, largest first
-- confidence: confirmed-docs
-- confidence_note: Every column named is documented on docs.snowflake.com/en/sql-reference/account-usage/table_storage_metrics, including DELETED (BOOLEAN), IS_TRANSIENT (VARCHAR YES/NO) and RETAINED_FOR_CLONE_BYTES. The archive-tier columns are deliberately NOT selected: the docs gate them behind behavior-change bundle BCR-2127, so naming them would break this query on an account that has not enabled it. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag
-- read_this: One row = one table version. total_billed_gb is the whole storage line for that table; the four component columns say WHY it is that size. A row with lifecycle = DROPPED_STILL_BILLED is a table nobody can query and everybody is paying for - that is the cheapest money in the account to stop spending.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: 1) sort by retained_for_clone_bytes and confirm each large clone group is a clone somebody still wants - abandoned dev clones are the most common surprise here (free); 2) for DROPPED_STILL_BILLED rows, nothing to do but wait out Fail-safe - it cannot be shortened or purged, which is exactly why the drop decision deserves a gate (free); 3) reduce DATA_RETENTION_TIME_IN_DAYS on the specific tables storage_time_travel_bloat scores, not account-wide (config).
-- next: storage_time_travel_bloat (if any table's Time Travel plus Fail-safe rivals its active bytes), storage_account_trend (if you need the day-by-day trend this snapshot cannot show), storage_drop_safety_gate (if you are about to delete one of these tables)
-- covers: Every table in the account, including tables in databases you would never think to look in - that is the whole reason to climb to this rung. It does NOT cover internal stages (storage_stage_leak), and BYTES here is not the same number as ACCOUNT_USAGE.TABLES.BYTES, which excludes Time Travel and Fail-safe entirely.
-- caveats: A recreated table leaves several rows with the same TABLE_NAME - successive versions distinguished by ID - so summing by name double-counts; this query returns one row per ID and projects ID so you can see it. RETAINED_FOR_CLONE_BYTES is billed to whichever member of a clone group owns the micro-partitions, which is often not the table a human would blame; group by CLONE_GROUP_ID before acting. Transient and temporary tables have no Fail-safe period, so failsafe_bytes = 0 on them is correct. The DELETED flag is documented as unreliable for data written before August 2018.

SELECT
    table_catalog                                   AS database_name,
    table_schema                                    AS schema_name,
    table_name,
    id                                              AS table_id,
    clone_group_id,
    is_transient,
    CASE
        WHEN deleted THEN 'DROPPED_STILL_BILLED'
        ELSE 'LIVE'
    END                                             AS lifecycle,
    active_bytes,
    time_travel_bytes,
    failsafe_bytes,
    retained_for_clone_bytes,
    active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes
                                                    AS total_billed_bytes,
    ROUND((active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes)
          / POWER(1024, 3), 2)                      AS total_billed_gb,
    ROUND(100 * active_bytes
          / NULLIF(active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes, 0), 1)
                                                    AS active_pct_of_bill,
    ROUND(100 * (time_travel_bytes + failsafe_bytes)
          / NULLIF(active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes, 0), 1)
                                                    AS retention_pct_of_bill,
    ROUND(100 * retained_for_clone_bytes
          / NULLIF(active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes, 0), 1)
                                                    AS clone_pct_of_bill,
    table_created,
    table_dropped,
    table_entered_failsafe
FROM snowflake.account_usage.table_storage_metrics
WHERE active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes
      >= :min_total_gb * POWER(1024, 3)
QUALIFY ROW_NUMBER() OVER (
            ORDER BY active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes DESC
         ) <= :top_n
ORDER BY total_billed_bytes DESC;
