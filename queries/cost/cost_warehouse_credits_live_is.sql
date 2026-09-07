-- query_id: cost_warehouse_credits_live_is
-- title: Credits by warehouse and day TODAY - the live, no-lag rung of the same bill line
-- domain: cost   tier: lite
-- rung: information_schema - the live rung. It answers the credits question without the ACCOUNT_USAGE lag and without IMPORTED PRIVILEGES, at the price of a shorter horizon and one missing column.
-- reads: information_schema.warehouse_metering_history
-- requires: MONITOR USAGE on the account, or ACCOUNTADMIN. Notably NOT IMPORTED PRIVILEGES on the SNOWFLAKE database - that is the whole reason this rung exists.
-- freshness: LIVE - the table function reads current metering, so the hour that just closed is already here. This is the rung to stand on when someone asks what a warehouse is costing right now.
-- params: :period_days (default 7) rolling window in days; the function only reaches back 6 months so keep this well inside that; :min_credits_day (default 1) a warehouse-day below this many compute credits returns NOT_ASSESSED; :cloud_services_warn_pct (default 10) cloud-services credits as a share of compute credits that raises WARN - 10% is the documented daily allowance; :cloud_services_critical_pct (default 25) the same share that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: The argument names (DATE_RANGE_START, DATE_RANGE_END, WAREHOUSE_NAME) and the six output columns (START_TIME, END_TIME, WAREHOUSE_NAME, CREDITS_USED, CREDITS_USED_COMPUTE, CREDITS_USED_CLOUD_SERVICES) are the documented signature of the INFORMATION_SCHEMA table function. Not run live. Verified by reading the docs, NOT by execution: that the docs mark this function superseded by the ACCOUNT_USAGE view and that it omits Adaptive Warehouse usage.
-- empty_if: privilege_scoped, retention_window, no_activity
-- read_this: One row = one warehouse on one day, as the account sees it right now. CREDITS_USED_TOTAL is the live bill line; CLOUD_SERVICES_PCT_OF_COMPUTE is the one band this rung can score, because the 10% daily cloud-services allowance is a ratio against compute and both halves are here.
-- healthy: cloud services stay under :cloud_services_warn_pct of compute, and the newest day's credits look like the days before it. Because this rung has no lag, an unfamiliar number here is a real change, not a reporting artefact.
-- investigate_if: cloud services are at or above :cloud_services_warn_pct of compute - metadata and SHOW traffic is starting to cost real money. False positive: a day with almost no compute (a maintenance window, or a warehouse used only for metadata work) makes the ratio explode on a tiny absolute number, which is why :min_credits_day gates the band at all.
-- actions: 1) confirm the same warehouse-day against cost_credits_by_warehouse_day once the lag clears - if the two disagree by more than rounding, trust neither number until you know why (free); 2) if cloud services drive the ratio, find the statement types behind it and cache or batch them (config); 3) resize or re-schedule the warehouse only after the attributed-vs-idle split from the ACCOUNT_USAGE twin says the compute half is the problem (spend).
-- next: cost_credits_by_warehouse_day (if you need the idle-vs-work split or more than 6 months of history), cost_cloud_services_by_query_type (if cloud services are the half that is growing), cost_cloud_services_overage (if you need the billed rather than the gross cloud-services number)
-- covers: LIVE and CURRENT-ACCOUNT, 6 months back, and NO attribution column - INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY has no CREDITS_ATTRIBUTED_COMPUTE_QUERIES, so this rung can restate the bill but cannot tell idle from work. It also cannot see Adaptive Warehouse usage at all. Climb to cost_credits_by_warehouse_day for both. This rung is cheaper in privilege, not in truth: it still needs MONITOR USAGE, so it is low-privilege relative to ACCOUNT_USAGE, not zero-privilege.
-- caveats: DATE_RANGE_START must be a constant expression; DATEADD over CURRENT_DATE() is the documented idiom, but a client that binds :period_days as a late parameter may reject it - substitute the number by hand if so. The function is scoped to the account, not to the current database, despite living in INFORMATION_SCHEMA. Docs mark it superseded by the ACCOUNT_USAGE view: treat it as the live cross-check, not as the system of record. As on the ACCOUNT_USAGE view, CREDITS_USED here ignores the daily cloud-services adjustment and so overstates what is billed.

WITH daily AS (
  SELECT
    DATE_TRUNC('day', m.start_time)::DATE  AS usage_date,
    m.warehouse_name,
    COUNT(*)                               AS metered_hours,
    SUM(m.credits_used_compute)            AS credits_compute,
    SUM(m.credits_used_cloud_services)     AS credits_cloud_services,
    SUM(m.credits_used)                    AS credits_used_total
  FROM TABLE(
         information_schema.warehouse_metering_history(
           DATE_RANGE_START => DATEADD('day', -:period_days, CURRENT_DATE())
         )
       ) m
  GROUP BY 1, 2
),
scored AS (
  SELECT
    daily.*,
    100.0 * credits_cloud_services / NULLIF(credits_compute, 0) AS cloud_services_pct_of_compute,
    100.0 * credits_used_total
          / NULLIF(SUM(credits_used_total) OVER (PARTITION BY usage_date), 0) AS pct_of_day
  FROM daily
)
SELECT
  usage_date,
  warehouse_name,
  metered_hours,
  ROUND(credits_compute, 3)               AS credits_compute,
  ROUND(credits_cloud_services, 3)        AS credits_cloud_services,
  ROUND(credits_used_total, 3)            AS credits_used_total,
  ROUND(cloud_services_pct_of_compute, 1) AS cloud_services_pct_of_compute,
  ROUND(pct_of_day, 1)                    AS pct_of_day,
  CASE
    WHEN credits_compute < :min_credits_day                                THEN 'NOT_ASSESSED'
    WHEN cloud_services_pct_of_compute >= :cloud_services_critical_pct     THEN 'CRITICAL'
    WHEN cloud_services_pct_of_compute >= :cloud_services_warn_pct         THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  credits_used_total DESC,
  usage_date DESC;
