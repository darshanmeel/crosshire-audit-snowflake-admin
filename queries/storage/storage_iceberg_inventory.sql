-- query_id: storage_iceberg_inventory
-- title: Every Iceberg table, its size, and what its optimization jobs cost
-- domain: storage   tier: standard
-- rung: account_usage - ACCOUNT_USAGE has no ICEBERG_TABLES view at all, so the inventory has to be assembled from the IS_ICEBERG flag on TABLES and joined to the compaction bill. The SHOW rung knows more about each table than this one does, but only one database at a time and with no cost side.
-- reads: snowflake.account_usage.tables, snowflake.account_usage.iceberg_storage_optimization_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - TABLES up to 90 minutes, the optimization history up to 2 hours. A table created this morning may be missing from the inventory while its first compaction is already billed, which shows up as a cost row with no table row.
-- params: :period_days (default 30) window over which compaction credits and bytes are summed; :min_gb (default 0) size floor in GiB - raise it to hide the small ones
-- confidence: confirmed-docs
-- confidence_note: IS_ICEBERG, TABLE_ID, BYTES, ROW_COUNT, CLUSTERING_KEY, RETENTION_TIME, AUTO_CLUSTERING_ON and DELETED are documented columns of docs.snowflake.com/en/sql-reference/account-usage/tables; CREDITS_USED, NUM_BYTES_SCANNED, NUM_ROWS_WRITTEN, ICEBERG_TABLE_UUID and TABLE_ID are documented columns of the iceberg_storage_optimization_history view. What is NOT documented anywhere in ACCOUNT_USAGE is the CATALOG a table is managed by: the TABLES view has no catalog, external-volume or base-location column, and there is no ICEBERG_TABLES view. catalog_hint below is therefore a labelled inference, not a fact, and the header says so.
-- empty_if: no_imported_privileges, account_usage_lag, feature_not_enabled
-- read_this: One row = one live Iceberg table. table_gb is what the table holds; compaction_credits is what Snowflake spent maintaining it in the window. The column to read carefully is catalog_hint, which is an INFERENCE: only Snowflake-managed Iceberg tables are compacted by Snowflake, so credits imply Snowflake writes it, and no credits imply either an externally-managed table or a managed one nobody wrote to. It is a hint, not an answer.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: 1) run SHOW ICEBERG TABLES and DESCRIBE ICEBERG TABLE on the rows you care about - that is where CATALOG, EXTERNAL_VOLUME and BASE_LOCATION actually live, and it costs nothing (free); 2) for tables with compaction credits and near-zero rows written, look at the write pattern feeding them: many small commits are what makes compaction expensive, and batching the writer is the fix (config); 3) BYTES on an Iceberg table is not billed as Snowflake storage the way a standard table is - the bytes sit in your own external volume, so the storage conversation for these rows belongs with your cloud provider bill, not this one (spend).
-- next: storage_table_breakdown (if you want the standard tables that DO sit on Snowflake-billed storage), storage_auto_clustering_spend (if an Iceberg table also carries a clustering key and you want the other maintenance line)
-- covers: Tables that ACCOUNT_USAGE.TABLES flags IS_ICEBERG = YES and that have not been dropped, plus whatever the compaction history billed for them in the window. It cannot tell you which catalog integration or external volume backs a table, cannot see snapshot or manifest counts, and does not know whether an externally-managed table is being written to outside Snowflake at all.
-- caveats: ACTIVE_BYTES in TABLE_STORAGE_METRICS is documented as not billed to the Iceberg table itself, and BYTES here is documented as bytes accessible in a scan rather than a storage bill, so neither number is an Iceberg storage cost - the storage cost is in your own object store. A dropped and recreated table gets a new TABLE_ID and appears as a new row with no history. The compaction join is on TABLE_ID; a credits row whose table has since been dropped will not appear at all, because the inventory side filters DELETED IS NULL. RETENTION_TIME on an Iceberg table does not mean what it means on a standard table - Iceberg snapshot expiry is governed by the table format, not by Snowflake Time Travel.

WITH bounds AS (
    SELECT DATEADD('day', -:period_days, CURRENT_TIMESTAMP()) AS window_start
),
optimization AS (
    SELECT
        o.table_id,
        ANY_VALUE(o.iceberg_table_uuid)       AS iceberg_table_uuid,
        SUM(o.credits_used)                   AS compaction_credits,
        SUM(o.num_bytes_scanned)              AS compaction_bytes_scanned,
        SUM(o.num_rows_written)               AS compaction_rows_written,
        COUNT(DISTINCT TO_DATE(o.start_time)) AS compaction_active_days,
        MAX(o.start_time)                     AS last_compaction
    FROM snowflake.account_usage.iceberg_storage_optimization_history o
    CROSS JOIN bounds b
    WHERE o.start_time >= b.window_start
    GROUP BY o.table_id
)
SELECT
    t.table_catalog                                   AS database_name,
    t.table_schema                                    AS schema_name,
    t.table_name,
    t.table_id,
    t.table_type,
    t.table_owner,
    t.row_count,
    ROUND(t.bytes / POWER(1024, 3), 2)                AS table_gb,
    t.clustering_key,
    t.auto_clustering_on,
    t.retention_time                                  AS retention_time_days,
    o.iceberg_table_uuid,
    ROUND(COALESCE(o.compaction_credits, 0), 3)       AS compaction_credits,
    ROUND(COALESCE(o.compaction_bytes_scanned, 0) / POWER(1024, 3), 2) AS compaction_gb_scanned,
    COALESCE(o.compaction_rows_written, 0)            AS compaction_rows_written,
    COALESCE(o.compaction_active_days, 0)             AS compaction_active_days,
    o.last_compaction,
    CASE
        WHEN COALESCE(o.compaction_credits, 0) > 0 THEN 'SNOWFLAKE_WRITES_IT'
        WHEN o.table_id IS NOT NULL                THEN 'SEEN_BUT_NOT_BILLED'
        ELSE 'NO_SNOWFLAKE_COMPACTION_OBSERVED'
    END                                               AS catalog_hint,
    t.created,
    t.last_altered
FROM snowflake.account_usage.tables t
LEFT JOIN optimization o ON o.table_id = t.table_id
WHERE t.is_iceberg = 'YES'
  AND t.deleted IS NULL
  AND COALESCE(t.bytes, 0) >= :min_gb * POWER(1024, 3)
ORDER BY COALESCE(o.compaction_credits, 0) DESC, t.bytes DESC NULLS LAST;
