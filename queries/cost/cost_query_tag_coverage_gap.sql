-- query_id: cost_query_tag_coverage_gap
-- title: Where chargeback silently fails - warehouses and users running credits with no QUERY_TAG
-- domain: cost   tier: standard
-- rung: account_usage - QUERY_HISTORY holds the tag and the elapsed time, WAREHOUSE_METERING_HISTORY holds the credits those hours actually cost. Neither is reachable live for a whole account.
-- reads: snowflake.account_usage.query_history, snowflake.account_usage.warehouse_metering_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - QUERY_HISTORY up to 45 minutes, WAREHOUSE_METERING_HISTORY up to 180 minutes. The two halves are aligned only at day grain here for exactly that reason.
-- params: :period_days (default 30) rolling window; :untagged_credits_warn (default 10) estimated untagged compute credits on one warehouse-user pair that raises WARN; :untagged_credits_critical (default 100) the same estimate that raises CRITICAL; :min_untagged_pct (default 20) a pair must be at least this untagged by elapsed time before it is banded at all
-- confidence: confirmed-docs
-- confidence_note: QUERY_TAG, USER_NAME, WAREHOUSE_NAME, TOTAL_ELAPSED_TIME, EXECUTION_STATUS and CREDITS_USED_CLOUD_SERVICES are documented QUERY_HISTORY columns; CREDITS_USED_COMPUTE and WAREHOUSE_NAME are documented WAREHOUSE_METERING_HISTORY columns. Not run live. The elapsed-time proration used to turn warehouse credits into a per-user estimate is this library's own arithmetic - Snowflake publishes no such column, and the estimate is labelled EST_ throughout so it is never mistaken for a metered figure.
-- empty_if: no_imported_privileges, account_usage_lag, tagging_not_used, no_activity
-- read_this: One row = one warehouse and one user over the window. UNTAGGED_QUERY_PCT is the coverage fact - what share of their statements set no tag. EST_UNTAGGED_COMPUTE_CREDITS is the consequence: that warehouse's real metered credits, prorated by the share of busy time those untagged statements occupied. The first column is measured, the second is an estimate, and the column names say which is which.
-- healthy: untagged elapsed time is a small tail on every warehouse that carries meaningful credits, and the pairs that are heavily untagged are the ones nobody charges back anyway - a sandbox, an ad-hoc analyst warehouse.
-- investigate_if: EST_UNTAGGED_COMPUTE_CREDITS is at or above :untagged_credits_warn on a warehouse whose spend is supposed to be attributable - that is the exact amount of bill that will land in a chargeback report as unallocated. False positive: a service account whose driver cannot set QUERY_TAG at all will always look bad here and needs a warehouse-level split instead of a tag; and a warehouse running a few very long untagged statements alongside many short tagged ones gets a large elapsed share on a small query count.
-- actions: 1) confirm against cost_chargeback_by_query_tag whether the metered attribution agrees with this estimate before quoting a number to anyone (free); 2) set QUERY_TAG in the connection or session defaults for the user behind the biggest row - one ALTER USER usually clears most of the gap (config); 3) where the client genuinely cannot tag, give that workload its own warehouse so the metering view separates it even without a tag (spend).
-- next: cost_chargeback_by_query_tag (if you want the metered split rather than this prorated estimate), cost_query_attribution_by_user (if the untagged credits need to be handed to a person today), cost_credits_by_warehouse_day (if the warehouse total itself is the surprise)
-- covers: BUSY time only. A warehouse hour with no query in it has no elapsed time to prorate, so idle credits are excluded from the estimate entirely - they are, correctly, nobody's chargeback line and they belong to cost_credits_by_warehouse_day. Serverless spend has no warehouse and no tag and cannot appear here at all.
-- caveats: The credit split is a PRORATION BY ELAPSED TIME, not a measurement. Two statements of equal duration on different warehouse sizes cost different amounts, and concurrency means elapsed time overlaps - so treat EST_UNTAGGED_COMPUTE_CREDITS as an order of magnitude, and use QUERY_ATTRIBUTION_HISTORY when the number has to be defensible. Statements with no warehouse (metadata-only work) are excluded because there is nothing to prorate against. Failed queries still consumed time and are counted; excluding them would understate the gap. An empty tag may arrive as NULL or as an empty string and both are normalised to untagged here.

WITH statements AS (
  SELECT
    DATE_TRUNC('day', start_time)::DATE AS usage_date,
    warehouse_name,
    user_name,
    COALESCE(NULLIF(TRIM(query_tag), ''), '') AS query_tag_norm,
    COALESCE(total_elapsed_time, 0)           AS elapsed_ms,
    COALESCE(credits_used_cloud_services, 0)  AS cloud_services_credits
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
),
pair AS (
  SELECT
    warehouse_name,
    user_name,
    COUNT(*)                                                      AS statements,
    COUNT_IF(query_tag_norm = '')                                 AS untagged_statements,
    SUM(elapsed_ms)                                               AS elapsed_ms_total,
    SUM(IFF(query_tag_norm = '', elapsed_ms, 0))                  AS untagged_elapsed_ms,
    SUM(cloud_services_credits)                                   AS cloud_services_credits,
    SUM(IFF(query_tag_norm = '', cloud_services_credits, 0))      AS untagged_cloud_services_credits
  FROM statements
  GROUP BY warehouse_name, user_name
),
warehouse_busy AS (
  SELECT
    warehouse_name,
    SUM(elapsed_ms_total)     AS warehouse_elapsed_ms
  FROM pair
  GROUP BY warehouse_name
),
warehouse_credits AS (
  SELECT
    warehouse_name,
    SUM(credits_used_compute) AS warehouse_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY warehouse_name
),
estimated AS (
  SELECT
    p.warehouse_name,
    p.user_name,
    p.statements,
    p.untagged_statements,
    p.elapsed_ms_total,
    p.untagged_elapsed_ms,
    p.cloud_services_credits,
    p.untagged_cloud_services_credits,
    wc.warehouse_compute_credits,
    100.0 * p.untagged_statements / NULLIF(p.statements, 0)           AS untagged_query_pct,
    100.0 * p.untagged_elapsed_ms / NULLIF(p.elapsed_ms_total, 0)     AS untagged_elapsed_pct,
    wc.warehouse_compute_credits
      * (p.untagged_elapsed_ms / NULLIF(wb.warehouse_elapsed_ms, 0))  AS est_untagged_compute_credits,
    wc.warehouse_compute_credits
      * (p.elapsed_ms_total / NULLIF(wb.warehouse_elapsed_ms, 0))     AS est_pair_compute_credits
  FROM pair p
  JOIN warehouse_busy wb    ON wb.warehouse_name = p.warehouse_name
  LEFT JOIN warehouse_credits wc ON wc.warehouse_name = p.warehouse_name
)
SELECT
  warehouse_name,
  user_name,
  statements,
  untagged_statements,
  ROUND(untagged_query_pct, 1)                  AS untagged_query_pct,
  ROUND(untagged_elapsed_pct, 1)                AS untagged_elapsed_pct,
  ROUND(elapsed_ms_total / 1000.0, 1)           AS elapsed_seconds_total,
  ROUND(est_pair_compute_credits, 3)            AS est_pair_compute_credits,
  ROUND(est_untagged_compute_credits, 3)        AS est_untagged_compute_credits,
  ROUND(untagged_cloud_services_credits, 4)     AS untagged_cloud_services_credits_gross,
  ROUND(warehouse_compute_credits, 3)           AS warehouse_compute_credits_window,
  CASE
    WHEN warehouse_compute_credits IS NULL                                THEN 'NOT_ASSESSED'
    WHEN untagged_statements = 0                                          THEN 'OK'
    WHEN untagged_elapsed_pct < :min_untagged_pct                         THEN 'OK'
    WHEN est_untagged_compute_credits >= :untagged_credits_critical       THEN 'CRITICAL'
    WHEN est_untagged_compute_credits >= :untagged_credits_warn           THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM estimated
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  est_untagged_compute_credits DESC NULLS LAST;
