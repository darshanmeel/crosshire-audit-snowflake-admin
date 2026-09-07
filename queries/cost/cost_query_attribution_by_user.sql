-- query_id: cost_query_attribution_by_user
-- title: Attributed compute credits by user and warehouse - a cost line you can hand to a person
-- domain: cost   tier: standard
-- rung: account_usage - QUERY_ATTRIBUTION_HISTORY exists on no other rung. INFORMATION_SCHEMA has no per-query credit column at all, so there is no live twin of this question.
-- reads: snowflake.account_usage.query_attribution_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, or the USAGE_VIEWER / GOVERNANCE_VIEWER database role on SNOWFLAKE which the docs name specifically for this view
-- freshness: LAGGED - up to 8 hours, the longest lag of any view in this domain. A query run this morning may simply not be here yet, so never read a same-day total as final.
-- params: :period_days (default 30) rolling window; :min_credits (default 1) a user-warehouse pair below this many attributed credits returns NOT_ASSESSED; :concentration_warn_pct (default 15) share of the window's attributed credits held by one pair that raises WARN; :concentration_critical_pct (default 30) the same share that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: USER_NAME, WAREHOUSE_NAME, QUERY_ID, START_TIME, CREDITS_ATTRIBUTED_COMPUTE and CREDITS_USED_QUERY_ACCELERATION are all on the documented QUERY_ATTRIBUTION_HISTORY column list. Not run live. Doc-verified and load-bearing: this view has NO ROLE_NAME column, so a role-level chargeback needs a join to QUERY_HISTORY on QUERY_ID.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one user on one warehouse over the whole window. CREDITS_ATTRIBUTED_TOTAL is what that person's queries actually consumed; PCT_OF_WINDOW is their share of everything attributed. Those two are the chargeback line - the count and the averages beside them only tell you whether it is one heavy query or ten thousand small ones.
-- healthy: attributed credits spread across users in a shape you can explain - a service account carrying the pipeline load, analysts carrying much less. No single pair above :concentration_warn_pct unless you know exactly which pipeline it is.
-- investigate_if: one user-warehouse pair holds at or above :concentration_warn_pct of all attributed credits, or MAX_CREDITS_SINGLE_QUERY is a large fraction of that pair's own total - one statement carrying a month of cost. False positive: the orchestration service account is SUPPOSED to dominate; concentration is only a defect when nobody expected it there.
-- actions: 1) name an owner for every pair above the warn band before changing anything - attribution without an owner is trivia (free); 2) push the heavy users onto a tagged, separately-monitored warehouse so the cost lands on a budget rather than a shared pool (config); 3) resize or split only after cost_attribution_fingerprint says the cost is one repeated shape rather than genuine volume (spend).
-- next: cost_chargeback_by_query_tag (if you need a team or a pipeline rather than a person), cost_attribution_fingerprint (if one user's cost is really one repeated query shape), cost_credits_by_warehouse_day (if the attributed total is far below what the warehouse actually billed)
-- covers: EXECUTION credits only. Warehouse idle time is documented as excluded here, so the sum of this view is always LESS than WAREHOUSE_METERING_HISTORY for the same window - the gap is idle, and cost_credits_by_warehouse_day is where you read it. Adaptive Warehouse jobs are not tracked in this view at all. Serverless spend (tasks, pipes, Cortex) never appears here because no warehouse ran it.
-- caveats: Queries shorter than roughly 100ms are excluded upstream, so a workload of very many tiny statements under-reports. For concurrent queries the credits are a weighted-average apportionment, not a measurement of one query in isolation - two runs of the same statement on a busy and an idle warehouse will not agree. Rows for statements inside a stored procedure carry their own credits; if you want the cost rolled up to the calling statement, group on ROOT_QUERY_ID instead of USER_NAME. Query-acceleration credits are reported separately by Snowflake and are summed here into a distinct column rather than folded into compute.

WITH attributed AS (
  SELECT
    user_name,
    warehouse_name,
    query_id,
    root_query_id,
    start_time,
    COALESCE(credits_attributed_compute, 0)      AS credits_compute,
    COALESCE(credits_used_query_acceleration, 0) AS credits_acceleration
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
by_user AS (
  SELECT
    user_name,
    warehouse_name,
    COUNT(*)                                        AS attributed_queries,
    COUNT(DISTINCT root_query_id)                   AS distinct_root_statements,
    SUM(credits_compute)                            AS credits_attributed_compute,
    SUM(credits_acceleration)                       AS credits_query_acceleration,
    SUM(credits_compute + credits_acceleration)     AS credits_attributed_total,
    MAX(credits_compute + credits_acceleration)     AS max_credits_single_query,
    MAX_BY(query_id, credits_compute + credits_acceleration) AS most_expensive_query_id,
    MIN(start_time)                                 AS first_seen,
    MAX(start_time)                                 AS last_seen
  FROM attributed
  GROUP BY user_name, warehouse_name
),
scored AS (
  SELECT
    by_user.*,
    credits_attributed_total / NULLIF(attributed_queries, 0)  AS avg_credits_per_query,
    100.0 * credits_attributed_total
          / NULLIF(SUM(credits_attributed_total) OVER (), 0)  AS pct_of_window,
    100.0 * max_credits_single_query
          / NULLIF(credits_attributed_total, 0)               AS single_query_pct_of_pair
  FROM by_user
)
SELECT
  user_name,
  warehouse_name,
  attributed_queries,
  distinct_root_statements,
  ROUND(credits_attributed_compute, 3)     AS credits_attributed_compute,
  ROUND(credits_query_acceleration, 3)     AS credits_query_acceleration,
  ROUND(credits_attributed_total, 3)       AS credits_attributed_total,
  ROUND(pct_of_window, 1)                  AS pct_of_window,
  ROUND(avg_credits_per_query, 5)          AS avg_credits_per_query,
  ROUND(max_credits_single_query, 3)       AS max_credits_single_query,
  ROUND(single_query_pct_of_pair, 1)       AS single_query_pct_of_pair,
  most_expensive_query_id,
  first_seen,
  last_seen,
  CASE
    WHEN credits_attributed_total < :min_credits            THEN 'NOT_ASSESSED'
    WHEN pct_of_window >= :concentration_critical_pct       THEN 'CRITICAL'
    WHEN pct_of_window >= :concentration_warn_pct           THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  credits_attributed_total DESC;
