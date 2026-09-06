-- query_id: storage_auto_clustering_spend
-- title: What Automatic Clustering costs per table, and how much churn it is reclustering
-- domain: storage   tier: standard
-- rung: account_usage - the INFORMATION_SCHEMA table function of the same name exists but is scoped to one database and a short retention, so it cannot rank an account's clustering spend.
-- reads: snowflake.account_usage.automatic_clustering_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 180 minutes. Clustering is serverless and bills continuously, so the last three hours of a spike will be missing; do not use this to watch a change you made minutes ago.
-- params: :period_days (default 30) window to sum credits over; :warn_credits (default 10) credits in the window at which a single table's clustering is worth reviewing; :critical_credits (default 50) credits at which it is a line item somebody should own
-- confidence: confirmed-docs
-- confidence_note: START_TIME, END_TIME, CREDITS_USED, NUM_BYTES_RECLUSTERED, NUM_ROWS_RECLUSTERED, DATABASE_NAME, SCHEMA_NAME, TABLE_NAME, TABLE_ID and VERSION are documented columns of docs.snowflake.com/en/sql-reference/account-usage/automatic_clustering_history. The column is NUM_BYTES_RECLUSTERED, not BYTES_RECLUSTERED - a plausible-looking wrong name that fails at compile time. VERSION is documented as CLASSIC or OPTIMA. Credit thresholds are labelled field heuristics. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, feature_not_enabled, no_activity
-- read_this: One row = one table over the whole window. Read credits_used against gb_reclustered together: credits alone say what it costs, and credits_per_tb_reclustered says whether that cost is proportionate. A table with high credits and low bytes reclustered is the bad shape - it means clustering is being re-triggered constantly on small changes rather than doing bulk work efficiently.
-- healthy: credits_used below :warn_credits, or above it with a credits_per_tb_reclustered in line with the rest of the account. Clustering that costs real money on a table that is genuinely large and genuinely queried with a selective filter is clustering doing its job.
-- investigate_if: WARN at credits_used >= :warn_credits. CRITICAL at >= :critical_credits, and worse when active_days is close to the whole window - continuous reclustering means the write pattern is fighting the clustering key. The false positive that matters: a table that was just clustered for the FIRST time, or whose key was just changed, pays a large one-off backfill and then settles. Check first_seen against the window start before concluding anything - a table whose activity begins on day one of the window may simply have been enabled that day.
-- actions: 1) confirm the clustering key still matches the filter the queries actually use - a key chosen for last year's dashboard is the most common cause of expensive reclustering, and reading the key is free (free); 2) if writes land in random key order, batch the loads so each one covers a narrow key range - clustering cost is driven by how much a write scatters the key, not by how much you write (config); 3) SUSPEND RECLUSTER on the table and measure what pruning actually loses over a week - the only honest way to find out whether the credits were buying anything (config).
-- next: storage_clustering_benefit_review (if you need to know whether the credits bought any pruning at all), storage_table_dml_churn (if the write pattern is the suspect), storage_search_optimization_benefit (if the queries are point lookups rather than range scans - then this may be the wrong feature entirely)
-- covers: Automatic Clustering only. It does NOT cover manual RECLUSTER statements, which bill as ordinary warehouse compute and appear in query history instead, and it does not cover Iceberg table compaction, which is a separate view and a separate bill.
-- caveats: CREDITS_USED is credits, not money - multiply by your contracted rate, which only the ORGANIZATION_USAGE rung knows. A table dropped and recreated with the same name aggregates as one table here unless you group by TABLE_ID, which this query projects for exactly that reason. NUM_ROWS_RECLUSTERED and NUM_BYTES_RECLUSTERED count work done, not rows in the table, so a small table can show enormous reclustered volume if it is rewritten constantly. The VERSION column distinguishes Clustering Classic from Optima Clustering and their cost profiles differ, so comparing a CLASSIC table against an OPTIMA one on credits alone is not a fair comparison - the column is projected so you can see which you are looking at.

WITH runs AS (
    SELECT
        database_name,
        schema_name,
        table_name,
        table_id,
        version,
        start_time,
        credits_used,
        num_bytes_reclustered,
        num_rows_reclustered
    FROM snowflake.account_usage.automatic_clustering_history
    WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
per_table AS (
    SELECT
        database_name,
        schema_name,
        table_name,
        table_id,
        LISTAGG(DISTINCT version, ' + ')                    AS clustering_version,
        SUM(credits_used)                                   AS credits_used,
        SUM(num_bytes_reclustered)                          AS bytes_reclustered,
        SUM(num_rows_reclustered)                           AS rows_reclustered,
        COUNT(*)                                            AS billing_intervals,
        COUNT(DISTINCT TO_DATE(start_time))                 AS active_days,
        MIN(start_time)                                     AS first_seen,
        MAX(start_time)                                     AS last_seen
    FROM runs
    GROUP BY 1, 2, 3, 4
)
SELECT
    database_name,
    schema_name,
    table_name,
    table_id,
    clustering_version,
    ROUND(credits_used, 3)                                  AS credits_used,
    ROUND(bytes_reclustered / POWER(1024, 3), 2)            AS gb_reclustered,
    rows_reclustered,
    active_days,
    billing_intervals,
    ROUND(credits_used / NULLIF(bytes_reclustered / POWER(1024, 4), 0), 2)
                                                            AS credits_per_tb_reclustered,
    ROUND(credits_used / NULLIF(active_days, 0), 3)         AS credits_per_active_day,
    first_seen,
    last_seen,
    CASE
        WHEN credits_used >= :critical_credits THEN 'CRITICAL'
        WHEN credits_used >= :warn_credits     THEN 'WARN'
        ELSE 'OK'
    END                                                     AS status
FROM per_table
ORDER BY credits_used DESC;
