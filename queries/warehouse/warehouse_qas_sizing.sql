-- query_id: warehouse_qas_sizing
-- title: Which queries Query Acceleration would help, how much time it could remove, and at what scale factor
-- domain: warehouse   tier: deep
-- rung: account_usage - Snowflake computes the eligibility itself and publishes it in QUERY_ACCELERATION_ELIGIBLE. Nothing on a live rung answers "would this have been faster with acceleration", because the answer is a counterfactual only the service can produce.
-- reads: snowflake.account_usage.query_acceleration_eligible, snowflake.account_usage.query_acceleration_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - both views are documented at up to 3 hours, so they settle together and the comparison of eligibility against spend is a like-for-like one.
-- params: :period_days (default 30) trailing window in days; :min_eligible_seconds (default 1) ignore statements with less eligible time than this - a fraction of a second of offloadable work is not a case for anything; :min_statements (default 10) fewer eligible statements on a warehouse than this and there is no pattern to size against; :warn_eligible_seconds (default 600) total offloadable seconds on a warehouse with acceleration switched off that earns a WARN; :critical_eligible_seconds (default 3600) the same for CRITICAL
-- confidence: confirmed-docs
-- confidence_note: QUERY_ACCELERATION_ELIGIBLE documents QUERY_ID, QUERY_TEXT, START_TIME, END_TIME, WAREHOUSE_NAME, WAREHOUSE_SIZE, ELIGIBLE_QUERY_ACCELERATION_TIME - explicitly in SECONDS - and UPPER_LIMIT_SCALE_FACTOR. QUERY_ACCELERATION_HISTORY documents START_TIME, END_TIME, CREDITS_USED, WAREHOUSE_ID and WAREHOUSE_NAME, and carries no QUERY_ID, which is why spend can only be compared at warehouse level. Both latencies are documented at 3 hours. Not run against a live account. Note that eligibility rows are published whether or not the service is enabled, which is what makes the never-enabled case findable at all.
-- empty_if: no_imported_privileges, account_usage_lag, feature_not_enabled, no_activity, edition_gated
-- read_this: One row = one warehouse. The two columns that make the decision are eligible_seconds - how much execution time Snowflake itself says acceleration could have taken off this warehouse's statements - and p90_useful_scale_factor, which is the size to configure: the scale factor above which, for nine statements in ten, more acceleration would buy nothing. qas_credits_used on the same row says whether the service is already switched on, so the row reads as a whole sentence: this much time is offloadable, this is the factor that would cover it, this is what you are paying today.
-- healthy: eligible_seconds small relative to the warehouse's total runtime, or eligible_seconds large WITH qas_credits_used above zero - the service is on and doing the work this view says is there.
-- investigate_if: eligible_seconds at or above :warn_eligible_seconds (WARN) or :critical_eligible_seconds (CRITICAL) while qas_credits_used is zero - Snowflake has been telling you for a month that these statements could shed that much time and nothing is switched on. The inverse also warns: a warehouse with QAS credits and no eligible statements in the window is paying for a service its current workload no longer uses. The main false positive is a one-off - a single enormous backfill can carry a whole warehouse over the threshold, which is why median_eligible_seconds and worst_single_eligible_seconds are both on the row.
-- actions: 1) read pct_of_runtime_offloadable before anything else - if acceleration would remove a tenth of the runtime, the answer is probably no, and finding that out is free (free); 2) enable the service on the warehouse with a scale factor at p90_useful_scale_factor rather than at the maximum, and switch it off where credits are being spent with nothing eligible (config); 3) if the offloadable share is large and constant, compare enabling acceleration against simply running the workload on a larger warehouse - both are spend, and this row only prices one of them (spend).
-- next: warehouse_oversized_by_load (if acceleration would only be masking a warehouse that is the wrong size for its work), warehouse_multicluster_scale_out_need (if the time being lost is queueing rather than scanning - acceleration does nothing for a queue), warehouse_adaptive_candidacy (if the eligible work is concentrated in occasional spikes)
-- covers: Every warehouse with either eligible statements or acceleration spend in the window - the join is a full outer one precisely so that a warehouse paying for acceleration it no longer needs is not invisible. It does NOT see: per-query acceleration SPEND, because the history view has no query id; use QUERY_ATTRIBUTION_HISTORY.CREDITS_USED_QUERY_ACCELERATION for that. It also does not see whether the warehouse is on an edition that offers the service.
-- caveats: ELIGIBLE_QUERY_ACCELERATION_TIME is Snowflake's own estimate of what COULD be offloaded, not a measurement of what would be - treat every second here as an upper bound. The scale-factor percentile is taken across statements, so a warehouse running two unrelated workloads produces a p90 that suits neither; if the eligible statements split into obvious groups, size for the group that matters rather than for the blend. Warehouse-level spend cannot be attributed to the eligible statements, so a warehouse can show both QAS credits and eligible seconds simply because acceleration is on and some statements still exceed what it covers - that is not a defect. Statements below :min_eligible_seconds are excluded before any aggregation, so the counts here are of statements worth acting on, not of every row the view holds.

WITH eligible AS (
  SELECT
    warehouse_name,
    warehouse_size,
    query_id,
    eligible_query_acceleration_time,
    upper_limit_scale_factor,
    DATEDIFF('second', start_time, end_time) AS elapsed_seconds
  FROM snowflake.account_usage.query_acceleration_eligible
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND eligible_query_acceleration_time >= :min_eligible_seconds
),
by_warehouse AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                AS eligible_statements,
    LISTAGG(DISTINCT warehouse_size, ' | ')                  AS sizes_seen,
    ROUND(SUM(eligible_query_acceleration_time), 0)          AS eligible_seconds,
    ROUND(SUM(elapsed_seconds), 0)                           AS elapsed_seconds,
    ROUND(MEDIAN(eligible_query_acceleration_time), 1)       AS median_eligible_seconds,
    ROUND(MAX(eligible_query_acceleration_time), 1)          AS worst_single_eligible_seconds,
    ROUND(MEDIAN(upper_limit_scale_factor), 0)               AS median_useful_scale_factor,
    ROUND(
      PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY upper_limit_scale_factor), 0
    )                                                        AS p90_useful_scale_factor,
    MAX(upper_limit_scale_factor)                            AS max_useful_scale_factor
  FROM eligible
  GROUP BY 1
),
spend AS (
  SELECT
    warehouse_name,
    ROUND(SUM(credits_used), 3) AS qas_credits_used,
    MAX(end_time)               AS last_qas_billing_window
  FROM snowflake.account_usage.query_acceleration_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
  GROUP BY 1
)
SELECT
  COALESCE(e.warehouse_name, s.warehouse_name)                             AS warehouse_name,
  COALESCE(e.eligible_statements, 0)                                       AS eligible_statements,
  COALESCE(e.eligible_seconds, 0)                                          AS eligible_seconds,
  e.elapsed_seconds,
  ROUND(100 * e.eligible_seconds / NULLIF(e.elapsed_seconds, 0), 1)        AS pct_of_runtime_offloadable,
  e.median_eligible_seconds,
  e.worst_single_eligible_seconds,
  e.median_useful_scale_factor,
  e.p90_useful_scale_factor,
  e.max_useful_scale_factor,
  e.sizes_seen,
  COALESCE(s.qas_credits_used, 0)                                          AS qas_credits_used,
  s.last_qas_billing_window,
  CASE
    WHEN e.warehouse_name IS NULL AND COALESCE(s.qas_credits_used, 0) > 0
      THEN 'WARN'
    WHEN COALESCE(e.eligible_statements, 0) < :min_statements
      THEN 'NOT_ASSESSED'
    WHEN COALESCE(s.qas_credits_used, 0) = 0
     AND e.eligible_seconds >= :critical_eligible_seconds
      THEN 'CRITICAL'
    WHEN COALESCE(s.qas_credits_used, 0) = 0
     AND e.eligible_seconds >= :warn_eligible_seconds
      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM by_warehouse e
FULL OUTER JOIN spend s
  ON s.warehouse_name = e.warehouse_name
ORDER BY COALESCE(e.eligible_seconds, 0) DESC, COALESCE(s.qas_credits_used, 0) DESC;
