-- query_id: warehouse_low_load_hours
-- title: What share of each warehouse's BILLED hours ran at near-zero load - waste weighted by credits
-- domain: warehouse   tier: standard
-- rung: account_usage - it takes both an account-wide load history and an account-wide credit history to weight low load by what it cost, and only this rung carries either.
-- reads: snowflake.account_usage.warehouse_load_history, snowflake.account_usage.warehouse_metering_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - both views are documented at up to 3 hours, and the metering view's cloud-services column at up to 6. They are on the same clock for the compute columns this query uses, so the join does not skew; the trailing hours are simply incomplete on both sides.
-- params: :period_days (default 30) trailing window in days; :near_zero_load (default 0.10) an hour whose mean running load is below this counts as a low-load hour - 0.10 means that on average a tenth of one statement was executing; :queue_tolerance (default 0.1) a warehouse whose peak overload queue exceeds this is never accused, however quiet its average hour; :warn_pct (default 30) percent of compute credits spent in low-load hours that earns a WARN; :critical_pct (default 60) the same for CRITICAL; :min_billed_hours (default 24) fewer billed hours than this and the window is too thin to judge
-- confidence: confirmed-docs
-- confidence_note: WAREHOUSE_LOAD_HISTORY (START_TIME, WAREHOUSE_NAME, AVG_RUNNING, AVG_QUEUED_LOAD, 5-minute grain) and WAREHOUSE_METERING_HISTORY (START_TIME as the beginning of the hour, WAREHOUSE_NAME, CREDITS_USED_COMPUTE) are both documented on docs.snowflake.com, as are their latencies. Rolling the 5-minute load buckets up to the metering view's hour is this query's own construction, and the mismatch it creates is stated in caveats. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = one warehouse over the window. The pair that matters is pct_credits_in_low_load_hours - the share of what you PAID that went to hours doing almost nothing - and peak_queued_overload, which vetoes the finding if the warehouse ever ran out of room. This is warehouse_oversized_by_load's question asked in credits instead of buckets, and credits is the version you can take to whoever owns the budget.
-- healthy: pct_credits_in_low_load_hours below :warn_pct. A warehouse whose billed hours and whose busy hours are nearly the same set is doing what it was created to do.
-- investigate_if: pct_credits_in_low_load_hours at or above :warn_pct (WARN) or :critical_pct (CRITICAL) with no overload queue. A false positive: an hour billed almost entirely for ONE long statement shows a low mean running load - one statement executing is a load near 1.0 only if it runs the whole hour, and a 20-minute statement in an otherwise empty hour averages to about 0.3 - so a batch warehouse with a few long jobs can look low-load while being perfectly sized. peak_running on the row is the check: if it approaches or exceeds 1.0, real work happened.
-- actions: 1) compare billed_hours with low_load_hours - if they are nearly equal, the warehouse is awake far more than it is used, and that is an auto-suspend question, not a sizing one (free); 2) shorten auto_suspend first, then reconsider the size, in that order - a smaller warehouse that is still awake all day saves less than a correctly-suspending one (config); 3) if the low-load hours are real work that simply does not need this much machine, move it to a smaller warehouse of its own (spend).
-- next: warehouse_idle_credit_leak (if the low-load hours turn out to be hours with no statements at all), warehouse_oversized_by_load (if you want the bucket-level version of the same verdict), warehouse_auto_suspend_thrash (if the plan is to shorten auto_suspend and you need to know what that will cost in resume minimums)
-- covers: Account-wide, every warehouse that was BILLED in the window, with a year of history available. Rows are driven by the metering view, so a warehouse that cost nothing does not appear at all - that is deliberate: there is no waste to weight. It does NOT see: warehouse size, so it cannot tell you which size to move to; nor serverless spend, which no warehouse row carries.
-- caveats: The load view is 5-minute grain and the metering view is hourly, so the load side is averaged up to the hour before the join - an hour that was busy for five minutes and asleep for fifty-five averages to a low-load hour, which is the intended reading but is an average, not a measurement of every minute. Billed hours with no load rows at all are treated as zero load, which is correct for a warehouse that was awake and unused but would be wrong if the load view were simply missing rows for a period - check that first_billed_hour and last_billed_hour span what you expect. AVG_RUNNING is concurrency, not hardware utilization, so this query cannot distinguish a small warehouse working hard from a large one loafing.

WITH load_hourly AS (
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_start,
    AVG(avg_running)               AS mean_running_in_hour,
    MAX(avg_running)               AS peak_running_in_hour,
    MAX(avg_queued_load)           AS peak_queued_in_hour,
    COUNT(*)                       AS load_buckets_in_hour
  FROM snowflake.account_usage.warehouse_load_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
  GROUP BY 1, 2
),
billed_hourly AS (
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_start,
    SUM(credits_used_compute)      AS credits_compute
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
  GROUP BY 1, 2
),
joined AS (
  -- driven by the BILLED side: an hour that cost nothing has no waste to weight
  SELECT
    b.warehouse_name,
    b.hour_start,
    b.credits_compute,
    COALESCE(l.mean_running_in_hour, 0) AS mean_running_in_hour,
    COALESCE(l.peak_running_in_hour, 0) AS peak_running_in_hour,
    COALESCE(l.peak_queued_in_hour, 0)  AS peak_queued_in_hour,
    COALESCE(l.load_buckets_in_hour, 0) AS load_buckets_in_hour
  FROM billed_hourly b
  LEFT JOIN load_hourly l
    ON l.warehouse_name = b.warehouse_name
   AND l.hour_start     = b.hour_start
),
rolled AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                                       AS billed_hours,
    COUNT_IF(mean_running_in_hour < :near_zero_load)                               AS low_load_hours,
    COUNT_IF(load_buckets_in_hour = 0)                                             AS hours_with_no_load_rows,
    ROUND(SUM(credits_compute), 3)                                                 AS credits_compute,
    ROUND(SUM(IFF(mean_running_in_hour < :near_zero_load, credits_compute, 0)), 3) AS credits_in_low_load_hours,
    ROUND(MAX(peak_running_in_hour), 3)                                            AS peak_running,
    ROUND(MAX(peak_queued_in_hour), 3)                                             AS peak_queued_overload,
    MIN(hour_start)                                                                AS first_billed_hour,
    MAX(hour_start)                                                                AS last_billed_hour
  FROM joined
  GROUP BY 1
)
SELECT
  warehouse_name,
  billed_hours,
  low_load_hours,
  hours_with_no_load_rows,
  ROUND(100 * low_load_hours / NULLIF(billed_hours, 0), 1)                     AS pct_low_load_hours,
  credits_compute,
  credits_in_low_load_hours,
  ROUND(100 * credits_in_low_load_hours / NULLIF(credits_compute, 0), 1)       AS pct_credits_in_low_load_hours,
  peak_running,
  peak_queued_overload,
  first_billed_hour,
  last_billed_hour,
  CASE
    WHEN billed_hours < :min_billed_hours
      THEN 'NOT_ASSESSED'
    WHEN peak_queued_overload > :queue_tolerance
      THEN 'OK'
    WHEN 100 * credits_in_low_load_hours / NULLIF(credits_compute, 0) >= :critical_pct
      THEN 'CRITICAL'
    WHEN 100 * credits_in_low_load_hours / NULLIF(credits_compute, 0) >= :warn_pct
      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM rolled
ORDER BY credits_in_low_load_hours DESC, credits_compute DESC;
