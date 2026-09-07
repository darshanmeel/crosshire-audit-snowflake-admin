-- query_id: cost_cloud_services_overage
-- title: Days where cloud-services credits broke the 10% daily allowance and became billable
-- domain: cost   tier: standard
-- rung: account_usage - METERING_DAILY_HISTORY is the ONLY view anywhere that carries CREDITS_ADJUSTMENT_CLOUD_SERVICES and CREDITS_BILLED. Every other credits view reports the gross number and cannot answer this question at all.
-- reads: snowflake.account_usage.metering_daily_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 180 minutes. The current day's row is always incomplete, and because the adjustment is computed against the whole day's compute, a partial day systematically LOOKS like an overage. Read complete days only.
-- params: :period_days (default 30) rolling window of usage days; :overage_warn_credits (default 1) billable cloud-services credits on a day that raise WARN; :overage_critical_credits (default 10) the same figure that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: USAGE_DATE, SERVICE_TYPE, CREDITS_USED_COMPUTE, CREDITS_USED_CLOUD_SERVICES, CREDITS_USED, CREDITS_ADJUSTMENT_CLOUD_SERVICES and CREDITS_BILLED are the complete documented column list of this view. The docs state explicitly that CREDITS_BILLED is the sum of compute, cloud services and the adjustment, and that the adjustment is a NEGATIVE number - both facts are relied on here. Not run live; the 10% figure is Snowflake's documented daily allowance, not a tuned threshold.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one usage day for the whole account, summed across every SERVICE_TYPE, because the allowance is applied at account-day grain and nowhere else. BILLABLE_CLOUD_SERVICES_CREDITS is the answer - gross cloud services minus the adjustment Snowflake gave back. If it is zero, the day cost you nothing for cloud services no matter how large the gross number looked.
-- healthy: BILLABLE_CLOUD_SERVICES_CREDITS is zero on almost every day, because cloud services stayed inside the free allowance of 10% of that day's compute credits. A day with heavy compute absorbs a lot of metadata work for free.
-- investigate_if: billable cloud-services credits are at or above :overage_warn_credits on a day - metadata work is now a line on the bill rather than a rounding error. The dangerous shape is a day with LOW compute and normal metadata traffic: the allowance shrinks with compute, so a quiet day can bill cloud services that a busy day would have swallowed. False positive: the most recent day is partial by construction and will often show a spurious overage; and a deliberate metadata-only day (a migration, a mass SHOW sweep) is a real cost but an expected one.
-- actions: 1) take the overage days to cost_cloud_services_by_query_type and find which statement types produced the gross number before changing anything (free); 2) cut the metadata traffic itself - cache SHOW and INFORMATION_SCHEMA results in the tool that polls them, and batch small COPY statements, since per-file and per-statement overhead is where cloud-services credits come from (config); 3) consolidating the workload so heavy compute and heavy metadata land on the same day raises the allowance, but do that only if the scheduling change is otherwise harmless (spend).
-- next: cost_cloud_services_by_query_type (if a day is over the allowance and you need the statement types behind it), cost_credits_by_warehouse_day (if compute is the smaller half of the bill and cloud services are the story), cost_dollarized_usage_by_day (if you need the overage in money rather than credits)
-- covers: ACCOUNT-WIDE and POST-ADJUSTMENT. This is the only place in the library where a cloud-services number is the BILLED one. The per-query CREDITS_USED_CLOUD_SERVICES in QUERY_HISTORY and the per-warehouse column in WAREHOUSE_METERING_HISTORY are both gross and both, summed, exceed what you pay - they explain the overage, they do not measure it.
-- caveats: Rows are summed across SERVICE_TYPE on purpose: the adjustment is an account-day quantity and slicing it by service would invent an allocation Snowflake does not publish. Day boundaries follow the SESSION timezone - run ALTER SESSION SET TIMEZONE = UTC before comparing anything here with ORGANIZATION_USAGE, as the docs require. The 10% allowance is expressed here as a derived column for readability; the authoritative number is the CREDITS_ADJUSTMENT_CLOUD_SERVICES the view reports, and where the two disagree the view is right. A day with zero compute has a zero allowance, so every cloud-services credit that day is billable - correct, but easy to misread as a spike.

WITH daily AS (
  SELECT
    usage_date,
    SUM(COALESCE(credits_used_compute, 0))               AS credits_compute,
    SUM(COALESCE(credits_used_cloud_services, 0))        AS credits_cloud_services_gross,
    SUM(COALESCE(credits_adjustment_cloud_services, 0))  AS credits_adjustment_cloud_services,
    SUM(COALESCE(credits_used, 0))                       AS credits_used_total,
    SUM(COALESCE(credits_billed, 0))                     AS credits_billed,
    COUNT(DISTINCT service_type)                         AS service_types_metered
  FROM snowflake.account_usage.metering_daily_history
  WHERE usage_date >= DATEADD('day', -:period_days, CURRENT_DATE())
  GROUP BY usage_date
),
scored AS (
  SELECT
    daily.*,
    credits_cloud_services_gross + credits_adjustment_cloud_services AS billable_cloud_services_credits,
    0.10 * credits_compute                                          AS allowance_credits,
    100.0 * credits_cloud_services_gross / NULLIF(credits_compute, 0) AS cloud_services_pct_of_compute,
    100.0 * (credits_cloud_services_gross + credits_adjustment_cloud_services)
          / NULLIF(credits_billed, 0)                               AS billable_cloud_services_pct_of_bill
  FROM daily
)
SELECT
  usage_date,
  service_types_metered,
  ROUND(credits_compute, 3)                       AS credits_compute,
  ROUND(credits_cloud_services_gross, 3)          AS credits_cloud_services_gross,
  ROUND(allowance_credits, 3)                     AS allowance_credits_10pct_of_compute,
  ROUND(credits_adjustment_cloud_services, 3)     AS credits_adjustment_cloud_services,
  ROUND(billable_cloud_services_credits, 3)       AS billable_cloud_services_credits,
  ROUND(credits_used_total, 3)                    AS credits_used_gross,
  ROUND(credits_billed, 3)                        AS credits_billed,
  ROUND(cloud_services_pct_of_compute, 1)         AS cloud_services_pct_of_compute,
  ROUND(billable_cloud_services_pct_of_bill, 1)   AS billable_cloud_services_pct_of_bill,
  CASE
    WHEN credits_billed IS NULL                                              THEN 'NOT_ASSESSED'
    WHEN billable_cloud_services_credits >= :overage_critical_credits        THEN 'CRITICAL'
    WHEN billable_cloud_services_credits >= :overage_warn_credits            THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  billable_cloud_services_credits DESC,
  usage_date DESC;
