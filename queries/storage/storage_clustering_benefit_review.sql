-- query_id: storage_clustering_benefit_review
-- title: Did clustering credits actually buy pruning? Early half vs late half of the window
-- domain: storage   tier: deep
-- rung: account_usage - both halves of the question live here. The pruning view has no INFORMATION_SCHEMA twin at all, so there is no lower rung to fall back to.
-- reads: snowflake.account_usage.automatic_clustering_history, snowflake.account_usage.table_query_pruning_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - and the two sides lag DIFFERENTLY: clustering history up to 180 minutes, pruning history up to 4 hours. The most recent few hours are therefore incomplete on one side before the other, which is a reason to keep :period_days large and ignore the tail.
-- params: :period_days (default 60) total window - it is split in half and the two halves are compared, so this must span at least two normal load cycles; :warn_credits (default 5) clustering credits in the window below which no verdict is worth rendering; :critical_credits (default 25) credits at which a table earning nothing is a real line item; :min_prune_pct (default 60) partition-pruning percentage a clustered table is expected to reach; :min_improvement_pp (default 5) percentage POINTS of pruning improvement between the two halves that would count as clustering still doing work
-- confidence: confirmed-docs
-- confidence_note: AUTOMATIC_CLUSTERING_HISTORY columns and TABLE_QUERY_PRUNING_HISTORY columns are both documented on docs.snowflake.com. Two doc facts this query depends on: the pruning view time column is INTERVAL_START_TIME and not START_TIME, and its PARTITIONS_SCANNED and PARTITIONS_PRUNED are disjoint, so partitions considered = scanned + pruned. The join is on TABLE_ID, which both views document as the internal identifier for the table. Not run against a live account, so the TABLE_ID join has not been observed to line up in practice.
-- empty_if: no_imported_privileges, account_usage_lag, feature_not_enabled, no_activity
-- read_this: One row = one table that spent clustering credits in the window. The verdict is in three columns read together: credits_used says what you paid, late_prune_pct says how well the table prunes NOW, and prune_improvement_pp says whether that number moved while you were paying. Credits with a flat, low prune percentage is the shape that means the key is wrong.
-- healthy: late_prune_pct at or above :min_prune_pct - the clustered table is being read with a filter the key actually supports - or a positive prune_improvement_pp, meaning clustering is still converging on a table that was recently keyed or recently reloaded.
-- investigate_if: WARN when credits_used >= :warn_credits and either the table prunes below :min_prune_pct or the improvement between halves is under :min_improvement_pp. CRITICAL when credits_used >= :critical_credits and BOTH are true - money spent, nothing pruned, nothing improving. Also CRITICAL when a table burns clustering credits with zero query rows in the window at all: you are maintaining an ordering nobody reads. Two false positives: the 4-hour lag on the pruning view can empty the late half of a short window, which is why the query reports queries_late and marks a missing half NOT_ASSESSED rather than guessing; and a table whose queries genuinely carry no selective predicate will never prune well no matter what the key is - the fix there is the query, not the clustering.
-- actions: 1) look at the actual WHERE clauses on the table before touching the key - QUERY_HASH is aggregated in the pruning view and reading it costs nothing (free); 2) if the filter column and the clustering key disagree, ALTER TABLE ... CLUSTER BY the column the queries filter on, and expect one expensive backfill before it settles (config); 3) if nothing filters selectively, drop the clustering key entirely with ALTER TABLE ... DROP CLUSTERING KEY - a table read with full scans loses nothing and stops paying (config).
-- next: storage_auto_clustering_spend (if you want the credits ranked without the verdict), storage_search_optimization_benefit (if the queries are point lookups - search optimization is the feature for equality predicates and clustering the one for ranges), storage_table_dml_churn (if the table is being rewritten so hard that no key could keep up)
-- covers: Tables that spent Automatic Clustering credits in the window, joined to whatever the pruning view saw of them. It does not cover manual RECLUSTER, does not cover Iceberg compaction, and cannot see a clustered table that spent no credits in the window - a perfectly clustered stable table correctly disappears from this list.
-- caveats: The early-half versus late-half comparison assumes the workload was comparable across both halves; a reporting cycle that only runs at month end fails that assumption and the improvement figure becomes noise rather than signal. Pruning percentage is computed over partitions the view attributes to this table across ALL queries, so one badly written full scan drags the average down for everyone. Credits are credits, not currency - the ORGANIZATION_USAGE rung is the only one that knows your rate. A table dropped and recreated gets a distinct TABLE_ID, so it will not silently merge with its predecessor, but it will also not inherit its history.

WITH bounds AS (
    SELECT
        DATEADD('day', -:period_days, CURRENT_TIMESTAMP())       AS window_start,
        DATEADD('hour', -:period_days * 12, CURRENT_TIMESTAMP()) AS midpoint
),
clustering AS (
    SELECT
        h.table_id,
        ANY_VALUE(h.database_name)            AS database_name,
        ANY_VALUE(h.schema_name)              AS schema_name,
        ANY_VALUE(h.table_name)               AS table_name,
        LISTAGG(DISTINCT h.version, ' + ')    AS clustering_version,
        SUM(h.credits_used)                   AS credits_used,
        SUM(h.num_bytes_reclustered)          AS bytes_reclustered,
        COUNT(DISTINCT TO_DATE(h.start_time)) AS clustering_active_days
    FROM snowflake.account_usage.automatic_clustering_history h
    CROSS JOIN bounds b
    WHERE h.start_time >= b.window_start
    GROUP BY h.table_id
),
pruning AS (
    SELECT
        p.table_id,
        SUM(p.num_queries)                                                     AS queries_total,
        SUM(IFF(p.interval_start_time <  b.midpoint, p.num_queries, 0))        AS queries_early,
        SUM(IFF(p.interval_start_time >= b.midpoint, p.num_queries, 0))        AS queries_late,
        SUM(IFF(p.interval_start_time <  b.midpoint, p.partitions_scanned, 0)) AS scanned_early,
        SUM(IFF(p.interval_start_time <  b.midpoint, p.partitions_pruned,  0)) AS pruned_early,
        SUM(IFF(p.interval_start_time >= b.midpoint, p.partitions_scanned, 0)) AS scanned_late,
        SUM(IFF(p.interval_start_time >= b.midpoint, p.partitions_pruned,  0)) AS pruned_late
    FROM snowflake.account_usage.table_query_pruning_history p
    CROSS JOIN bounds b
    WHERE p.interval_start_time >= b.window_start
    GROUP BY p.table_id
),
joined AS (
    SELECT
        c.database_name,
        c.schema_name,
        c.table_name,
        c.table_id,
        c.clustering_version,
        c.credits_used,
        c.bytes_reclustered,
        c.clustering_active_days,
        COALESCE(p.queries_total, 0) AS queries_total,
        COALESCE(p.queries_early, 0) AS queries_early,
        COALESCE(p.queries_late,  0) AS queries_late,
        ROUND(100 * p.pruned_early / NULLIF(p.scanned_early + p.pruned_early, 0), 1) AS early_prune_pct,
        ROUND(100 * p.pruned_late  / NULLIF(p.scanned_late  + p.pruned_late,  0), 1) AS late_prune_pct
    FROM clustering c
    LEFT JOIN pruning p ON p.table_id = c.table_id
)
SELECT
    database_name,
    schema_name,
    table_name,
    table_id,
    clustering_version,
    ROUND(credits_used, 3)                            AS credits_used,
    ROUND(bytes_reclustered / POWER(1024, 3), 2)      AS gb_reclustered,
    clustering_active_days,
    queries_total,
    queries_early,
    queries_late,
    early_prune_pct,
    late_prune_pct,
    ROUND(late_prune_pct - early_prune_pct, 1)        AS prune_improvement_pp,
    ROUND(credits_used / NULLIF(queries_total, 0), 4) AS credits_per_query_served,
    CASE
        WHEN queries_total = 0 AND credits_used >= :critical_credits         THEN 'CRITICAL'
        WHEN queries_total = 0 AND credits_used >= :warn_credits             THEN 'WARN'
        WHEN queries_total = 0                                               THEN 'OK'
        WHEN early_prune_pct IS NULL OR late_prune_pct IS NULL               THEN 'NOT_ASSESSED'
        WHEN credits_used >= :critical_credits
             AND late_prune_pct < :min_prune_pct
             AND late_prune_pct - early_prune_pct < :min_improvement_pp      THEN 'CRITICAL'
        WHEN credits_used >= :warn_credits
             AND (late_prune_pct < :min_prune_pct
                  OR late_prune_pct - early_prune_pct < :min_improvement_pp) THEN 'WARN'
        ELSE 'OK'
    END                                               AS status
FROM joined
ORDER BY
    CASE status
        WHEN 'CRITICAL' THEN 0
        WHEN 'WARN' THEN 1
        WHEN 'NOT_ASSESSED' THEN 2
        ELSE 3
    END,
    credits_used DESC;
