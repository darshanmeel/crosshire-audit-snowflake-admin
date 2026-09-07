-- query_id: cost_credit_spike_anomaly
-- title: Warehouse-days far outside that warehouse's OWN recent distribution - a spike, not a big number
-- domain: cost   tier: deep
-- rung: account_usage - a baseline needs history, and only ACCOUNT_USAGE has a year of it for every warehouse. The live rung reaches 6 months but cannot see Adaptive Warehouses and is scoped by MONITOR USAGE, so a baseline built there would silently omit warehouses.
-- reads: snowflake.account_usage.warehouse_metering_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 180 minutes. The newest day is partial, so it will look like a DIP rather than a spike; the query keeps it and the day-completeness column tells you which rows to distrust.
-- params: :period_days (default 60) rolling window; it must be comfortably larger than the baseline or the earliest days have nothing to compare against; :baseline_days (default 14) how many of that warehouse's PRECEDING observed days form the baseline; :min_baseline_days (default 7) fewer observed baseline days than this returns NOT_ASSESSED rather than a confident verdict on thin evidence; :min_credits_day (default 1) a day below this many credits is too small to call a spike; :z_warn (default 2) standard deviations above the warehouse's own baseline that raise WARN; :z_critical (default 3) the same z-score that raises CRITICAL; :ratio_warn (default 2) multiple of the warehouse's own baseline mean that raises WARN independently of the z-score; :ratio_critical (default 4) the same multiple that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: START_TIME, WAREHOUSE_NAME, CREDITS_USED, CREDITS_USED_COMPUTE and CREDITS_USED_CLOUD_SERVICES are documented WAREHOUSE_METERING_HISTORY columns. Not run live. The anomaly method - a trailing per-warehouse mean and standard deviation, scored both as a z-score and as a plain ratio - is this library's arithmetic, not a Snowflake verdict; ORGANIZATION_USAGE.ANOMALIES_IN_CURRENCY_DAILY is where Snowflake publishes its own.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one warehouse on one day, scored against ITS OWN preceding days and nothing else. Z_SCORE and RATIO_TO_BASELINE are the two verdicts, deliberately kept separate: the z-score catches a day that is unusual for a steady warehouse, the ratio catches a day that is large on a warehouse too erratic to have a meaningful standard deviation. A day only has to trip one of them.
-- healthy: z-scores clustered inside plus or minus two, and ratios near one. A warehouse with a genuinely bursty schedule will show a stable pattern of high ratios on the same weekday - that is a rhythm, not an anomaly, and it is why the baseline is per-warehouse rather than account-wide.
-- investigate_if: a warehouse-day trips :z_warn or :ratio_warn while carrying real credits, and there is no scheduled reason for it. The costly pattern is a spike that never returns to baseline afterwards - that is not an incident, that is a new steady state someone introduced without telling anyone. False positive: the day a warehouse was resized, the first days after a new workload landed, month-end batches, and the newest partial day. A warehouse with only a few active days in the window has a baseline made of noise, which is what :min_baseline_days is defending against.
-- actions: 1) take the spike day and warehouse into cost_query_attribution_by_user and cost_attribution_fingerprint to see whether one person or one query shape appeared that day (free); 2) if the spike is real and repeatable, put a resource monitor on the warehouse so the next one has a ceiling instead of a post-mortem (config); 3) resize or split the warehouse only once you know the spike is genuine sustained load rather than one bad statement (spend).
-- next: cost_query_attribution_by_user (if a spike day needs a person attached to it), cost_attribution_fingerprint (if the spike is one repeated query shape), cost_resource_monitor_coverage (if the spiking warehouse has no ceiling at all), cost_credits_by_warehouse_day (if you want the plain daily line without the scoring)
-- covers: WAREHOUSE compute only. Serverless spend - tasks, pipes, Cortex, automatic clustering - never appears in this view, so a spike in the account bill that this query cannot see is almost certainly serverless. Days on which a warehouse was not metered at all are absent rather than zero, which is why the baseline counts OBSERVED preceding days rather than calendar days.
-- caveats: The baseline frame counts PRECEDING ROWS, i.e. preceding days on which this warehouse was metered at all - not calendar days. For a warehouse that runs twice a week the baseline therefore stretches back much further than :baseline_days calendar days, which is usually the behaviour you want and occasionally is not. Some clients will not accept a bound parameter as a window-frame offset; if yours rejects it, substitute the number for :baseline_days by hand - nothing else in the query changes. A warehouse whose baseline standard deviation is zero yields no z-score at all and is scored on the ratio alone. The newest day is partial by construction and cannot be trusted in either direction.

WITH daily AS (
  SELECT
    DATE_TRUNC('day', start_time)::DATE AS usage_date,
    warehouse_name,
    COUNT(*)                            AS metered_hours,
    SUM(COALESCE(credits_used, 0))      AS credits_used_total,
    SUM(COALESCE(credits_used_compute, 0))        AS credits_compute,
    SUM(COALESCE(credits_used_cloud_services, 0)) AS credits_cloud_services
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
baselined AS (
  SELECT
    daily.*,
    AVG(credits_used_total) OVER (
      PARTITION BY warehouse_name ORDER BY usage_date
      ROWS BETWEEN :baseline_days PRECEDING AND 1 PRECEDING)          AS baseline_mean_credits,
    STDDEV_SAMP(credits_used_total) OVER (
      PARTITION BY warehouse_name ORDER BY usage_date
      ROWS BETWEEN :baseline_days PRECEDING AND 1 PRECEDING)          AS baseline_stddev_credits,
    COUNT(credits_used_total) OVER (
      PARTITION BY warehouse_name ORDER BY usage_date
      ROWS BETWEEN :baseline_days PRECEDING AND 1 PRECEDING)          AS baseline_days_observed,
    MAX(usage_date) OVER ()                                           AS newest_day_in_window
  FROM daily
),
scored AS (
  SELECT
    baselined.*,
    (credits_used_total - baseline_mean_credits)
      / NULLIF(baseline_stddev_credits, 0)            AS z_score,
    credits_used_total / NULLIF(baseline_mean_credits, 0) AS ratio_to_baseline,
    credits_used_total - baseline_mean_credits        AS excess_credits_vs_baseline
  FROM baselined
)
SELECT
  usage_date,
  warehouse_name,
  metered_hours,
  IFF(usage_date = newest_day_in_window, FALSE, TRUE) AS day_is_complete,
  ROUND(credits_used_total, 3)          AS credits_used_total,
  ROUND(credits_compute, 3)             AS credits_compute,
  ROUND(credits_cloud_services, 3)      AS credits_cloud_services,
  baseline_days_observed,
  ROUND(baseline_mean_credits, 3)       AS baseline_mean_credits,
  ROUND(baseline_stddev_credits, 3)     AS baseline_stddev_credits,
  ROUND(z_score, 2)                     AS z_score,
  ROUND(ratio_to_baseline, 2)           AS ratio_to_baseline,
  ROUND(excess_credits_vs_baseline, 3)  AS excess_credits_vs_baseline,
  CASE
    WHEN baseline_days_observed < :min_baseline_days                   THEN 'NOT_ASSESSED'
    WHEN credits_used_total < :min_credits_day                         THEN 'NOT_ASSESSED'
    WHEN COALESCE(z_score, 0) >= :z_critical                           THEN 'CRITICAL'
    WHEN COALESCE(ratio_to_baseline, 0) >= :ratio_critical             THEN 'CRITICAL'
    WHEN COALESCE(z_score, 0) >= :z_warn                               THEN 'WARN'
    WHEN COALESCE(ratio_to_baseline, 0) >= :ratio_warn                 THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  excess_credits_vs_baseline DESC NULLS LAST,
  usage_date DESC;
