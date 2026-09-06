-- query_id: storage_search_optimization_benefit
-- title: What Search Optimization credits bought - the partitions it pruned that nothing else would have
-- domain: storage   tier: deep
-- rung: account_usage - the only rung that carries both the credits and Snowflake's own measurement of the benefit. The SHOW rung knows a table has the feature on; it has no idea whether it is earning anything.
-- reads: snowflake.account_usage.search_optimization_benefits, snowflake.account_usage.search_optimization_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default); Search Optimization itself needs Enterprise Edition or higher
-- freshness: LAGGED - and unevenly: the billing view lags up to 180 minutes, the benefits view up to 6 hours. Comparing the last few hours of one against the last few hours of the other will show credits with no benefit purely because the benefit rows have not landed yet.
-- params: :period_days (default 30) window over which credits and measured benefit are both summed; :warn_credits (default 5) credits in the window below which the question is not worth asking; :critical_credits (default 25) credits at which a table that prunes nothing extra is a real line item; :min_extra_prune_pct (default 5) percentage of the partitions left after natural pruning that search optimization must remove to be earning its keep
-- confidence: confirmed-docs
-- confidence_note: SEARCH_OPTIMIZATION_BENEFITS columns NUM_SCANS, PARTITIONS_SCANNED, PARTITIONS_PRUNED_DEFAULT and PARTITIONS_PRUNED_ADDITIONAL, and SEARCH_OPTIMIZATION_HISTORY columns CREDITS_USED and TABLE_NAME, are documented on docs.snowflake.com. One documented landmine drives the join: TABLE_NAME in the billing view is a system-generated alias of the form SEARCH OPTIMIZATION ON TABLE_ID followed by the id, and its TABLE_ID column is documented as the identifier of the search optimization SERVICE rather than of the table - so this query joins on the numeric id parsed out of that alias and falls back to TABLE_ID. Not run against a live account, so the join has not been observed to line up.
-- empty_if: no_imported_privileges, account_usage_lag, edition_gated, feature_not_enabled, no_activity
-- read_this: One row = one table that spent search optimization credits in the window. The verdict column is extra_prune_pct: of the partitions still standing after Snowflake pruned naturally, what share did search optimization remove? That is the marginal benefit, and it is the only number that credits can be weighed against. partitions_pruned_default is what you would have got for free anyway - it is not what you are paying for.
-- healthy: extra_prune_pct at or above :min_extra_prune_pct with a credits_per_million_partitions_pruned figure you would pay again. A table doing point lookups on a high-cardinality column is exactly what this feature is for and will show a large extra_prune_pct.
-- investigate_if: WARN when credits_used >= :warn_credits and extra_prune_pct is under :min_extra_prune_pct. CRITICAL when credits_used >= :critical_credits and search optimization pruned NOTHING extra despite the benefits view having seen scans - you are maintaining a second access path that no query uses. The false positive to respect above all others: the benefits view is SAMPLED, documented as retaining the 1,000 longest-running table scans per query, so an absent benefit row is not evidence of absent benefit. That is why zero benefit rows returns NOT_ASSESSED and never CRITICAL.
-- actions: 1) run DESCRIBE SEARCH OPTIMIZATION ON TABLE for the worst rows and check whether the optimized columns are the ones the queries actually filter on - the usual finding is a whole-table ADD SEARCH OPTIMIZATION where two columns were meant (free); 2) narrow the property to specific columns and predicate types with ALTER TABLE ... ADD SEARCH OPTIMIZATION ON EQUALITY, which shrinks both the build cost and the maintenance cost (config); 3) DROP SEARCH OPTIMIZATION on tables that measured nothing, then re-run this query a fortnight later to confirm no query regressed (config).
-- next: storage_search_optimization_active (if you need the live list of which tables have it on and which columns), storage_clustering_benefit_review (if the same table also pays for clustering - two access paths on one table is a decision that should be deliberate), storage_auto_clustering_spend (if the answer is that the workload wants ranges rather than lookups)
-- covers: Tables that BILLED search optimization credits in the window. A table with the property on that cost nothing in the window does not appear - and that is correct, because nothing was spent to evaluate. The SHOW-rung query beside this one is the inventory; this one is the verdict.
-- caveats: The sampling in the benefits view is the dominant caveat and it cuts one way only: it can hide benefit, never invent it, so a high extra_prune_pct is trustworthy and a zero is merely unproven. Credits from the history view include the build as well as the maintenance, so a table optimized for the first time inside the window will look expensive for a reason that will not repeat - check whether first_billed sits near the window start before judging. The join between the two views is by parsed id and has not been verified live; if it silently misses, a table shows credits with NULL benefit columns and is reported NOT_ASSESSED rather than condemned. Credits are credits, not currency.

WITH bounds AS (
    SELECT DATEADD('day', -:period_days, CURRENT_TIMESTAMP()) AS window_start
),
spend AS (
    SELECT
        COALESCE(TRY_TO_NUMBER(REGEXP_SUBSTR(h.table_name, '[0-9]+$')), h.table_id) AS table_id,
        ANY_VALUE(h.database_name)            AS spend_database_name,
        ANY_VALUE(h.schema_name)              AS spend_schema_name,
        SUM(h.credits_used)                   AS credits_used,
        MIN(h.start_time)                     AS first_billed,
        MAX(h.start_time)                     AS last_billed,
        COUNT(DISTINCT TO_DATE(h.start_time)) AS billed_days
    FROM snowflake.account_usage.search_optimization_history h
    CROSS JOIN bounds b
    WHERE h.start_time >= b.window_start
    GROUP BY 1
),
benefit AS (
    SELECT
        e.table_id,
        ANY_VALUE(e.database_name)          AS database_name,
        ANY_VALUE(e.schema_name)            AS schema_name,
        ANY_VALUE(e.table_name)             AS table_name,
        SUM(e.num_scans)                    AS num_scans,
        SUM(e.partitions_scanned)           AS partitions_scanned,
        SUM(e.partitions_pruned_default)    AS partitions_pruned_default,
        SUM(e.partitions_pruned_additional) AS partitions_pruned_additional
    FROM snowflake.account_usage.search_optimization_benefits e
    CROSS JOIN bounds b
    WHERE e.start_time >= b.window_start
    GROUP BY e.table_id
)
SELECT
    COALESCE(n.database_name, s.spend_database_name) AS database_name,
    COALESCE(n.schema_name,   s.spend_schema_name)   AS schema_name,
    n.table_name,
    s.table_id,
    ROUND(s.credits_used, 3)                         AS credits_used,
    s.billed_days,
    s.first_billed,
    s.last_billed,
    n.num_scans,
    n.partitions_scanned,
    n.partitions_pruned_default,
    n.partitions_pruned_additional,
    ROUND(100 * n.partitions_pruned_additional
          / NULLIF(n.partitions_scanned + n.partitions_pruned_additional, 0), 2) AS extra_prune_pct,
    ROUND(100 * n.partitions_pruned_default
          / NULLIF(n.partitions_scanned + n.partitions_pruned_default
                   + n.partitions_pruned_additional, 0), 2)                      AS natural_prune_pct,
    ROUND(1000000 * s.credits_used
          / NULLIF(n.partitions_pruned_additional, 0), 3) AS credits_per_million_partitions_pruned,
    CASE
        WHEN n.table_id IS NULL OR n.num_scans IS NULL              THEN 'NOT_ASSESSED'
        WHEN s.credits_used >= :critical_credits
             AND COALESCE(n.partitions_pruned_additional, 0) = 0    THEN 'CRITICAL'
        WHEN s.credits_used >= :warn_credits
             AND 100 * n.partitions_pruned_additional
                 / NULLIF(n.partitions_scanned + n.partitions_pruned_additional, 0)
                 < :min_extra_prune_pct                             THEN 'WARN'
        ELSE 'OK'
    END                                              AS status
FROM spend s
LEFT JOIN benefit n ON n.table_id = s.table_id
ORDER BY
    CASE status
        WHEN 'CRITICAL' THEN 0
        WHEN 'WARN' THEN 1
        WHEN 'NOT_ASSESSED' THEN 2
        ELSE 3
    END,
    s.credits_used DESC;
