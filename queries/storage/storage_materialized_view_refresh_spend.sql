-- query_id: storage_materialized_view_refresh_spend
-- title: What materialized views cost to keep refreshed, against how often anyone queries them
-- domain: storage   tier: standard
-- rung: account_usage - the INFORMATION_SCHEMA table function of the same name exists but covers one database and a short retention, and there is no read-side companion for it at all, so the cost-versus-benefit question only closes on this rung.
-- reads: snowflake.account_usage.materialized_view_refresh_history, snowflake.account_usage.access_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default); materialized views and ACCESS_HISTORY both need Enterprise Edition or higher
-- freshness: LAGGED - both views up to 180 minutes. Refresh is serverless and continuous, so the most recent hours are always short on the cost side; keep :period_days long enough that the missing tail cannot change the verdict.
-- params: :period_days (default 30) window over which refresh credits and reads are both counted; :warn_credits (default 5) refresh credits in the window below which the view is too cheap to argue about; :critical_credits (default 25) credits at which an unread materialized view is a real line item; :max_credits_per_query (default 0.05) refresh credits per query served above which the view is costing more to maintain than it can plausibly be saving
-- confidence: confirmed-docs
-- confidence_note: START_TIME, CREDITS_USED, TABLE_ID, TABLE_NAME, SCHEMA_NAME and DATABASE_NAME are documented columns of docs.snowflake.com/en/sql-reference/account-usage/materialized_view_refresh_history, and the read side uses the documented ACCESS_HISTORY arrays and their objectName key. One documented landmine is handled explicitly: CREDITS_USED on the refresh view is documented as VARCHAR, not a number, so it is cast with TRY_TO_DOUBLE before any arithmetic - summing it raw either fails or silently concatenates. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, edition_gated, feature_not_enabled, no_activity
-- read_this: One row = one materialized view. refresh_credits is what Snowflake spent keeping it current; query_count is how many queries named it in the window. The number that decides is credits_per_query - the maintenance cost of each query the view served. A materialized view exists to make reads cheaper, so a high cost per read means it is doing the opposite of its job.
-- healthy: credits_per_query below :max_credits_per_query, or refresh_credits below :warn_credits. A view refreshed cheaply and read constantly is the case this feature was built for.
-- investigate_if: WARN when refresh_credits >= :warn_credits and credits_per_query >= :max_credits_per_query. CRITICAL when refresh_credits >= :critical_credits and NOTHING queried it in the window - continuous maintenance for an audience of nobody. The false positive that matters most is the optimizer rewrite: Snowflake can silently answer a query against the BASE TABLE by using a materialized view, and that rewrite does not necessarily name the view in access history, so a view can be earning its keep while appearing unread. Treat a zero query_count as a question for the owner, never as a licence to drop.
-- actions: 1) ask what the view exists for and whether the base table now prunes well enough on its own - clustering the base table often removes the need for the view entirely, and asking costs nothing (free); 2) where reads are periodic rather than continuous, replace the materialized view with a scheduled task writing a plain table, which pays only when it runs instead of continuously (config); 3) drop the ones nobody can justify, and re-run the perf domain a fortnight later to confirm no query regressed - a drop is cheap to reverse if you kept the definition (config).
-- next: storage_drop_safety_gate (if the decision is to drop the view and you need to know what references it), storage_table_dml_churn (if the base table churn is what makes the refresh expensive), storage_clustering_benefit_review (if clustering the base table would remove the need for the view)
-- covers: Materialized views that BILLED refresh credits in the window, joined to whatever access history recorded of them. A view that was never refreshed in the window does not appear, and neither do dynamic tables, which are a different feature with a different view and belong to the serverless domain.
-- caveats: The optimizer-rewrite blind spot is the reason this query has an owner conversation as its first action rather than a drop. The read side concatenates the direct and base object arrays before matching on fully-qualified name, so a materialized view read only through another view still counts as read; queries are counted distinct by query id so a view appearing in both arrays is not double-counted. CREDITS_USED is documented as VARCHAR and is cast; if a future release changes its type the cast still holds. Credits are credits, not currency - the ORGANIZATION_USAGE rung is the only one that knows your rate. Access history is Enterprise-only, so on an account without it every row returns NOT_ASSESSED rather than a falsely confident zero.

WITH refreshes AS (
    SELECT
        r.database_name,
        r.schema_name,
        r.table_name,
        r.table_id,
        SUM(TRY_TO_DOUBLE(r.credits_used))    AS refresh_credits,
        COUNT(*)                              AS refresh_intervals,
        COUNT(DISTINCT TO_DATE(r.start_time)) AS active_days,
        MIN(r.start_time)                     AS first_refresh,
        MAX(r.start_time)                     AS last_refresh
    FROM snowflake.account_usage.materialized_view_refresh_history r
    WHERE r.start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    GROUP BY 1, 2, 3, 4
),
mv_reads AS (
    SELECT
        UPPER(f.value:objectName::string)       AS full_name,
        COUNT(DISTINCT a.query_id)              AS query_count,
        COUNT(DISTINCT a.user_name)             AS distinct_readers,
        MAX(a.query_start_time)                 AS last_queried_at
    FROM snowflake.account_usage.access_history a,
         LATERAL FLATTEN(input => ARRAY_CAT(a.direct_objects_accessed, a.base_objects_accessed)) f
    WHERE a.query_start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    GROUP BY 1
),
access_probe AS (
    SELECT COUNT(*) AS rows_seen FROM mv_reads
)
SELECT
    v.database_name,
    v.schema_name,
    v.table_name                                        AS materialized_view,
    v.table_id,
    ROUND(v.refresh_credits, 3)                         AS refresh_credits,
    v.refresh_intervals,
    v.active_days,
    COALESCE(q.query_count, 0)                          AS query_count,
    COALESCE(q.distinct_readers, 0)                     AS distinct_readers,
    q.last_queried_at,
    DATEDIFF('day', q.last_queried_at, CURRENT_TIMESTAMP()) AS days_since_last_query,
    ROUND(v.refresh_credits / NULLIF(q.query_count, 0), 4)  AS credits_per_query,
    ROUND(v.refresh_credits / NULLIF(v.active_days, 0), 3)  AS credits_per_active_day,
    v.first_refresh,
    v.last_refresh,
    CASE
        WHEN p.rows_seen = 0                                     THEN 'NOT_ASSESSED'
        WHEN v.refresh_credits >= :critical_credits
             AND COALESCE(q.query_count, 0) = 0                  THEN 'CRITICAL'
        WHEN v.refresh_credits >= :warn_credits
             AND COALESCE(v.refresh_credits / NULLIF(q.query_count, 0), 1e9)
                 >= :max_credits_per_query                       THEN 'WARN'
        ELSE 'OK'
    END                                                 AS status
FROM refreshes v
CROSS JOIN access_probe p
LEFT JOIN mv_reads q
       ON q.full_name = UPPER(v.database_name || '.' || v.schema_name || '.' || v.table_name)
ORDER BY
    CASE status
        WHEN 'CRITICAL' THEN 0
        WHEN 'WARN' THEN 1
        WHEN 'NOT_ASSESSED' THEN 2
        ELSE 3
    END,
    v.refresh_credits DESC;
