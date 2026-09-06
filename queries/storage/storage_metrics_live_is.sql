-- query_id: storage_metrics_live_is
-- title: What this database's tables occupy right now - active, Time Travel, Fail-safe (live rung)
-- domain: storage   tier: lite
-- rung: information_schema - the live, low-privilege twin of storage_table_breakdown. One database, no admin grant, no ACCOUNT_USAGE lag.
-- reads: information_schema.table_storage_metrics
-- requires: no account-level grant - INFORMATION_SCHEMA returns rows only for objects your own role has privileges on, in the CURRENT database
-- freshness: LIVE view over a LAGGED metric - the view itself is current, but Snowflake's storage accounting behind it settles over 1-2 hours, so a table you loaded five minutes ago will under-report. It will never be 90 minutes behind the way the ACCOUNT_USAGE twin is.
-- params: :min_total_gb (default 1) size floor in GiB - tables smaller than this are noise on a storage bill; :top_n (default 100) how many tables to return worst-first
-- confidence: confirmed-docs
-- confidence_note: Every column named is documented on docs.snowflake.com/en/sql-reference/info-schema/table_storage_metrics. Two differences from the ACCOUNT_USAGE view of the same name are deliberate and doc-checked: this view has NO DELETED column (dropped tables are found by TABLE_DROPPED IS NOT NULL) and NO archive-tier columns. Not run against a live account.
-- empty_if: current_database_only, privilege_scoped
-- read_this: One row = one table in the CURRENT database. The two columns that matter are total_billed_gb (what you are paying for) and retention_overhead_ratio - Time Travel plus Fail-safe divided by live data. A ratio of 1.0 means half your bill for that table is history.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: 1) run this in each database you own before asking anyone for IMPORTED PRIVILEGES - it answers the storage question at zero privilege cost (free); 2) hand the top rows to storage_time_travel_bloat once you do have the admin rung, which scores them account-wide (free); 3) change nothing on this rung - DATA_RETENTION_TIME_IN_DAYS is an account-shaped decision and this view sees one database (config).
-- next: storage_table_breakdown (if you have IMPORTED PRIVILEGES and need every database not just this one), storage_time_travel_bloat (if any retention_overhead_ratio here is above 1)
-- covers: ONE database - whichever is current in the session - and only the tables your role can see. It cannot see other databases, cannot see internal stages, and has no history: there is no yesterday on this rung. What it CAN do that ACCOUNT_USAGE cannot is answer without an account-admin grant and without waiting 90 minutes.
-- caveats: Cloned tables inflate the picture on both rungs: RETAINED_FOR_CLONE_BYTES is billed to whichever table in the clone group happens to own the micro-partitions, so a small table can carry a large clone tail it did not create - CLONE_GROUP_ID is projected so you can group by it before drawing conclusions. Transient and temporary tables have NO Fail-safe at all, so a zero in failsafe_bytes on a transient table is correct, not missing data. Views and external tables do not appear here.

SELECT
    table_catalog                                   AS database_name,
    table_schema                                    AS schema_name,
    table_name,
    is_transient,
    clone_group_id,
    active_bytes,
    time_travel_bytes,
    failsafe_bytes,
    retained_for_clone_bytes,
    active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes
                                                    AS total_billed_bytes,
    ROUND((active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes)
          / POWER(1024, 3), 2)                      AS total_billed_gb,
    ROUND((time_travel_bytes + failsafe_bytes)
          / NULLIF(active_bytes, 0), 2)             AS retention_overhead_ratio,
    ROUND(100 * (time_travel_bytes + failsafe_bytes)
          / NULLIF(active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes, 0), 1)
                                                    AS retention_pct_of_bill,
    table_created,
    table_dropped
FROM information_schema.table_storage_metrics
WHERE table_dropped IS NULL
  AND active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes
      >= :min_total_gb * POWER(1024, 3)
QUALIFY ROW_NUMBER() OVER (
            ORDER BY active_bytes + time_travel_bytes + failsafe_bytes + retained_for_clone_bytes DESC
         ) <= :top_n
ORDER BY total_billed_bytes DESC;
