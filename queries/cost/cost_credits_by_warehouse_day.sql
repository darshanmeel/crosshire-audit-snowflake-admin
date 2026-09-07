-- query_id: cost_credits_by_warehouse_day
-- title: Credits by warehouse and day, split compute vs cloud services - the line the bill is made of
-- domain: cost   tier: lite
-- rung: account_usage - the only rung with a full year of every warehouse, and the only one carrying CREDITS_ATTRIBUTED_COMPUTE_QUERIES
-- reads: snowflake.account_usage.warehouse_metering_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 180 minutes on this view, and up to 6 hours on CREDITS_USED_CLOUD_SERVICES specifically. Today's row is therefore always partial: read the last complete day, not the last row.
-- params: :period_days (default 30) rolling window of metered hours to summarise; :min_credits_day (default 1) a warehouse-day below this many compute credits is too small to band and returns NOT_ASSESSED; :unattributed_warn_pct (default 30) share of compute credits not attributable to any query that raises WARN; :unattributed_critical_pct (default 60) the same share that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: Every column named - START_TIME, WAREHOUSE_NAME, CREDITS_USED, CREDITS_USED_COMPUTE, CREDITS_USED_CLOUD_SERVICES, CREDITS_ATTRIBUTED_COMPUTE_QUERIES - is on the documented WAREHOUSE_METERING_HISTORY column list. Not run against a live account: the thresholds are field heuristics, not measured bands, and the unattributed share is an inference from two documented columns rather than a column Snowflake publishes.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one warehouse on one day. CREDITS_USED_TOTAL is the bill line; CREDITS_NOT_ATTRIBUTED_TO_QUERIES is the same day's compute credits that no query claimed - idle, resume overhead and provisioning. Those two columns together are the whole point: the first says what you paid, the second says how much of it did no work.
-- healthy: most warehouse-days sit under :unattributed_warn_pct unattributed, and cloud services stay well under 10% of compute (the daily allowance). A batch warehouse that wakes, works and suspends should be near zero unattributed.
-- investigate_if: unattributed share is at or above :unattributed_warn_pct on a warehouse that carries real credits - you are paying for a warehouse that is awake and not working. False positive: a warehouse running only sub-100ms statements, or an Adaptive Warehouse (CREDITS_ATTRIBUTED_COMPUTE_QUERIES is documented NULL there and the row is deliberately NOT_ASSESSED rather than scored as fully unattributed).
-- actions: 1) read the same warehouse in cost_query_attribution_by_user to see whether the credits belong to a person or to nobody (free); 2) shorten AUTO_SUSPEND on the warehouses whose unattributed share is high - idle is a config defect not a capacity one (config); 3) only if the attributed share is what is large should you consider resizing or splitting the warehouse (spend).
-- next: cost_query_attribution_by_user (if a warehouse-day is large and you need the person behind it), cost_credit_spike_anomaly (if a day looks unusual rather than merely big), cost_warehouse_credits_live_is (if you need today's number and cannot wait out the lag), cost_resource_monitor_coverage (if the biggest warehouse has no ceiling)
-- covers: ACCOUNT-WIDE and historical - every warehouse the account has, for a year. The live twin cost_warehouse_credits_live_is sees the same credits without the lag but has NO attributed-credits column and only 6 months, so it can restate the bill but cannot separate idle from work. Neither rung dollarizes: that is cost_effective_rate_sheet on the organization rung.
-- caveats: CREDITS_USED here does NOT account for the daily cloud-services adjustment, so summing it OVERSTATES the billed number - METERING_DAILY_HISTORY is the only view with the post-adjustment figure (cost_cloud_services_overage). Day boundaries follow the SESSION timezone; run ALTER SESSION SET TIMEZONE = UTC before reconciling with anything in ORGANIZATION_USAGE. CREDITS_ATTRIBUTED_COMPUTE_QUERIES excludes warehouse idle time by design and is NULL for Adaptive Warehouses, so the unattributed column is a residual, not a metered quantity. Queries shorter than roughly 100ms are excluded from attribution upstream, which inflates the residual slightly on very chatty warehouses.

WITH hourly AS (
  SELECT
    DATE_TRUNC('day', start_time)::DATE AS usage_date,
    warehouse_name,
    credits_used_compute,
    credits_used_cloud_services,
    credits_used,
    credits_attributed_compute_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
daily AS (
  SELECT
    usage_date,
    warehouse_name,
    COUNT(*)                                AS metered_hours,
    SUM(credits_used_compute)               AS credits_compute,
    SUM(credits_used_cloud_services)        AS credits_cloud_services,
    SUM(credits_used)                       AS credits_used_total,
    SUM(credits_attributed_compute_queries) AS credits_attributed_to_queries
  FROM hourly
  GROUP BY usage_date, warehouse_name
),
scored AS (
  SELECT
    usage_date,
    warehouse_name,
    metered_hours,
    credits_compute,
    credits_cloud_services,
    credits_used_total,
    credits_attributed_to_queries,
    credits_compute - credits_attributed_to_queries AS credits_not_attributed_to_queries,
    100.0 * (credits_compute - credits_attributed_to_queries)
          / NULLIF(credits_compute, 0)              AS unattributed_pct,
    100.0 * credits_cloud_services
          / NULLIF(credits_compute, 0)              AS cloud_services_pct_of_compute,
    100.0 * credits_used_total
          / NULLIF(SUM(credits_used_total) OVER (PARTITION BY usage_date), 0) AS pct_of_day
  FROM daily
)
SELECT
  usage_date,
  warehouse_name,
  metered_hours,
  ROUND(credits_compute, 3)                    AS credits_compute,
  ROUND(credits_cloud_services, 3)             AS credits_cloud_services,
  ROUND(credits_used_total, 3)                 AS credits_used_total,
  ROUND(credits_attributed_to_queries, 3)      AS credits_attributed_to_queries,
  ROUND(credits_not_attributed_to_queries, 3)  AS credits_not_attributed_to_queries,
  ROUND(unattributed_pct, 1)                   AS unattributed_pct,
  ROUND(cloud_services_pct_of_compute, 1)      AS cloud_services_pct_of_compute,
  ROUND(pct_of_day, 1)                         AS pct_of_day,
  CASE
    WHEN credits_compute < :min_credits_day               THEN 'NOT_ASSESSED'
    WHEN credits_attributed_to_queries IS NULL            THEN 'NOT_ASSESSED'
    WHEN unattributed_pct >= :unattributed_critical_pct   THEN 'CRITICAL'
    WHEN unattributed_pct >= :unattributed_warn_pct       THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  credits_used_total DESC,
  usage_date DESC;
