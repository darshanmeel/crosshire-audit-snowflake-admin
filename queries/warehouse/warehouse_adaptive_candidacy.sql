-- query_id: warehouse_adaptive_candidacy
-- title: Warehouses whose load is spiky enough that one fixed size is the wrong answer
-- domain: warehouse   tier: deep
-- rung: account_usage - the case rests on three views that exist only here: hourly credits, per-statement attributed credits, and the 5-minute load history. No live rung carries any of them account-wide.
-- reads: snowflake.account_usage.warehouse_metering_history, snowflake.account_usage.query_attribution_history, snowflake.account_usage.warehouse_load_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - and unevenly, which matters here: the metering and load views are documented at up to 3 hours, QUERY_ATTRIBUTION_HISTORY at up to 8. The attribution columns on a row are therefore the stalest thing on it, so a warehouse whose statements all ran in the last few hours can show credits with no attributed statements at all. That is why attributed_statements being absent forces NOT_ASSESSED rather than a verdict.
-- params: :period_days (default 30) trailing window in days; :warn_variability (default 1.0) coefficient of variation of hourly credits that earns a WARN - 1.0 means the hour-to-hour swing is as large as the average hour itself; :critical_variability (default 1.5) the same for CRITICAL; :idle_share_pct (default 30) percent of compute credits not attributable to query execution above which the spikiness is expensive rather than merely present; :min_billed_hours (default 72) fewer billed hours than this and the shape is not yet a shape
-- confidence: confirmed-docs
-- confidence_note: WAREHOUSE_METERING_HISTORY (START_TIME as the beginning of the hour, WAREHOUSE_NAME, CREDITS_USED_COMPUTE, CREDITS_ATTRIBUTED_COMPUTE_QUERIES), WAREHOUSE_LOAD_HISTORY (START_TIME, WAREHOUSE_NAME, AVG_RUNNING, AVG_QUEUED_LOAD) and QUERY_ATTRIBUTION_HISTORY (START_TIME, WAREHOUSE_NAME, CREDITS_ATTRIBUTED_COMPUTE) are all documented on docs.snowflake.com, as are their latencies and the note that attributed credits exclude idle time. The three shape measures - coefficient of variation, peak-to-median credits and peak-to-mean load - are this query's own construction from those documented columns, and the thresholds on them are labelled field heuristics exposed as params. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = one warehouse over the window. The two columns that make the case are credit_variability - how far this warehouse's hourly spend swings around its own average - and pct_credits_not_on_queries, which says whether that swing is expensive. A high swing with low idle is a warehouse that is busy in bursts and asleep between them, which a fixed size already handles well. A high swing WITH high idle is the candidate: it is sized for its peak and paying for that size while it waits.
-- healthy: credit_variability below :warn_variability, or a high variability with pct_credits_not_on_queries below :idle_share_pct - the warehouse is bursty but it stands down between bursts, which is what auto-suspend is for.
-- investigate_if: credit_variability at or above :warn_variability (WARN), or at or above :critical_variability together with pct_credits_not_on_queries at or above :idle_share_pct (CRITICAL). Read CRITICAL here as "strongest candidate", not "broken" - nothing on this row is a defect, it is a shape that a single fixed size fits badly. Two false positives to expect: a warehouse used for one big job a week has enormous variability and needs nothing but a schedule, and a warehouse with a very small credit total will show wild ratios on trivial absolute numbers, which is what :min_billed_hours and the credits_compute column are for.
-- actions: 1) plot the hourly credits before believing the statistic - a shape you can see is worth more than a coefficient, and it costs nothing (free); 2) if the peak is one predictable window, split the workload by schedule rather than by machine, or set auto_suspend so the quiet hours stop being billed at peak size (config); 3) only where the peak is unpredictable AND the idle share is real does a size that adapts to the load beat a fixed one - that is the case this query exists to find, and it is a spend decision, so bring both the variability and the credits to it (spend).
-- next: warehouse_oversized_by_load (if the spikiness turns out to be persistent over-sizing with an occasional peak), warehouse_idle_credit_leak (if the variability is idle rather than workload), warehouse_low_load_hours (if you want the credits in the quiet hours named directly)
-- covers: Every warehouse billed in the window, with its credit shape, its load shape and its per-statement attribution side by side. It does NOT see: the warehouse's size, so it cannot say which size to adapt from; nor the queries themselves; nor anything about warehouses that cost nothing, which are excluded because there is no spend to reshape.
-- caveats: Hourly credits are the unit of the variability measure, so a workload that spikes for ten minutes inside an otherwise quiet hour is flattened into that hour and understates the spikiness - the load columns, at 5-minute grain, are on the row as the finer-grained cross-check. The coefficient of variation is undefined for a warehouse whose average hourly credits are zero and is returned as NULL rather than as a large number. Attributed statements come from a view documented as complete only from mid-August 2024 and lagging up to 8 hours, so a window that reaches back before that, or forward into the last few hours, has a thin attribution side - the attributed_statements count is on the row so that thinness is visible rather than assumed away. Load buckets are counted only where something ran, so mean_running is an average over ACTIVE time and is not comparable to a duty cycle.

WITH hourly_credits AS (
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time)                       AS hour_start,
    SUM(credits_used_compute)                            AS credits_compute,
    SUM(COALESCE(credits_attributed_compute_queries, 0)) AS credits_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
  GROUP BY 1, 2
),
credit_shape AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                     AS billed_hours,
    ROUND(SUM(credits_compute), 3)                               AS credits_compute,
    ROUND(AVG(credits_compute), 4)                               AS mean_hourly_credits,
    ROUND(MEDIAN(credits_compute), 4)                            AS median_hourly_credits,
    ROUND(MAX(credits_compute), 4)                               AS peak_hourly_credits,
    ROUND(STDDEV(credits_compute), 4)                            AS stddev_hourly_credits,
    ROUND(STDDEV(credits_compute) / NULLIF(AVG(credits_compute), 0), 2)    AS credit_variability,
    ROUND(MAX(credits_compute)    / NULLIF(MEDIAN(credits_compute), 0), 2) AS peak_to_median_credits,
    ROUND(
      100 * SUM(GREATEST(credits_compute - credits_queries, 0))
          / NULLIF(SUM(credits_compute), 0), 1
    ) AS pct_credits_not_on_queries
  FROM hourly_credits
  GROUP BY 1
),
load_shape AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                  AS active_load_buckets,
    ROUND(AVG(avg_running), 3)                                AS mean_running,
    ROUND(MAX(avg_running), 3)                                AS peak_running,
    ROUND(MAX(avg_running) / NULLIF(AVG(avg_running), 0), 2)  AS peak_to_mean_load,
    ROUND(MAX(avg_queued_load), 3)                            AS peak_queued_overload
  FROM snowflake.account_usage.warehouse_load_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND avg_running > 0
  GROUP BY 1
),
query_shape AS (
  SELECT
    warehouse_name,
    COUNT(*)                                        AS attributed_statements,
    ROUND(SUM(credits_attributed_compute), 3)       AS credits_attributed,
    ROUND(MEDIAN(credits_attributed_compute), 6)    AS median_statement_credits,
    ROUND(MAX(credits_attributed_compute), 6)       AS max_statement_credits
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
  GROUP BY 1
)
SELECT
  c.warehouse_name,
  c.billed_hours,
  c.credits_compute,
  c.mean_hourly_credits,
  c.median_hourly_credits,
  c.peak_hourly_credits,
  c.stddev_hourly_credits,
  c.credit_variability,
  c.peak_to_median_credits,
  c.pct_credits_not_on_queries,
  l.active_load_buckets,
  l.mean_running,
  l.peak_running,
  l.peak_to_mean_load,
  l.peak_queued_overload,
  q.attributed_statements,
  q.credits_attributed,
  q.median_statement_credits,
  q.max_statement_credits,
  CASE
    WHEN c.billed_hours < :min_billed_hours OR q.attributed_statements IS NULL
      THEN 'NOT_ASSESSED'
    WHEN c.credit_variability >= :critical_variability
     AND c.pct_credits_not_on_queries >= :idle_share_pct
      THEN 'CRITICAL'
    WHEN c.credit_variability >= :warn_variability
      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM credit_shape c
LEFT JOIN load_shape l
  ON l.warehouse_name = c.warehouse_name
LEFT JOIN query_shape q
  ON q.warehouse_name = c.warehouse_name
ORDER BY c.credit_variability DESC NULLS LAST, c.credits_compute DESC;
