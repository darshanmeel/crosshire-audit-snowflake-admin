-- query_id: warehouse_multicluster_spinup_cost
-- title: Credits spent spinning extra clusters up and down rather than on running queries
-- domain: warehouse   tier: deep
-- rung: account_usage - the cluster spin-up and spin-down events live only in WAREHOUSE_EVENTS_HISTORY, and the credits they have to be measured against live only in WAREHOUSE_METERING_HISTORY. SHOW WAREHOUSES reports started_clusters, which is a single instant and cannot be summed.
-- reads: snowflake.account_usage.warehouse_events_history, snowflake.account_usage.warehouse_metering_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - both views are documented at up to 3 hours. They therefore settle together, which is what makes the ratio of estimated cluster credits to billed compute credits meaningful rather than a comparison of two different moments.
-- params: :period_days (default 30) trailing window in days; :billing_minimum_seconds (default 60) the documented minimum charged each time compute starts; :min_lives (default 5) fewer extra-cluster lifetimes than this and there is no pattern to judge; :warn_pct (default 15) percent of the warehouse's compute credits estimated to sit in extra clusters that earns a WARN; :critical_pct (default 35) the same for CRITICAL; :critical_short_lives (default 50) extra clusters that lived less than the billing minimum, at which point the spin-up policy is the finding regardless of the percentage
-- confidence: confirmed-docs
-- confidence_note: WAREHOUSE_EVENTS_HISTORY documents TIMESTAMP, WAREHOUSE_NAME, CLUSTER_NUMBER, EVENT_NAME, EVENT_REASON, EVENT_STATE, SIZE and CLUSTER_COUNT, and documents SPINUP_CLUSTER and SPINDOWN_CLUSTER as EVENT_NAME values and MULTICLUSTER_SPINUP and MULTICLUSTER_SPINDOWN as EVENT_REASON values. WAREHOUSE_METERING_HISTORY documents START_TIME, WAREHOUSE_NAME and CREDITS_USED_COMPUTE. The size-to-credits-per-hour table and the 60-second start minimum are documented at docs.snowflake.com/en/user-guide/warehouses-overview. What is NOT doc-verified is how the SIZE label is spelled in this particular view, so the size-to-rate mapping falls through to NULL on any label it does not recognise and the count of those rows is reported as lives_with_unpriceable_size rather than being absorbed silently. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity, feature_not_enabled
-- read_this: One row = one warehouse over the window. The two columns that carry the argument are est_extra_cluster_credits (what the additional clusters cost, priced from their measured lifetimes and the documented per-size rate) and est_start_minimum_credits (the part of that which bought nothing at all - the unused remainder of the 60-second minimum on clusters that died young). The first is the price of the concurrency; the second is pure spin-up tax.
-- healthy: est_start_minimum_credits near zero and lives_shorter_than_minimum near zero - extra clusters, when they appear, stay long enough to be worth starting. A pct_of_compute_credits_in_extra_clusters that is high but with long-lived clusters is not waste, it is a busy warehouse.
-- investigate_if: pct_of_compute_credits_in_extra_clusters at or above :warn_pct (WARN) or :critical_pct (CRITICAL), or lives_shorter_than_minimum at or above :critical_short_lives (CRITICAL) - the warehouse is repeatedly buying a cluster it barely uses. False positives come in two shapes: a warehouse with a genuinely bursty arrival pattern will spin up and down often and correctly, and lives_with_unpriceable_size above zero means part of the estimate is simply missing rather than small. Read both columns before quoting the credit figure to anyone.
-- actions: 1) look at when the spin-ups cluster during the day - if they track a known burst, this is scaling doing its job, and the answer is free (free); 2) if they do not, raise the scaling threshold so a brief queue does not buy a cluster, or lower max_cluster_count so it cannot (config); 3) if the concurrency is real and constant, a second permanently-sized warehouse for the competing workload is cheaper than paying the start minimum repeatedly (spend).
-- next: warehouse_multicluster_scaling_misconfig (if the spin-ups look policy-driven rather than demand-driven), warehouse_multicluster_scale_out_need (if you want to know whether the extra clusters were needed at all), warehouse_resume_storm_waste (if the cluster events arrive in bursts)
-- covers: Every extra-cluster lifetime that both began and ended inside the window, account-wide, up to a year back, priced against the same window's billed compute credits. It does NOT see: the scaling policy or the cluster range that produced the behaviour, which live in SHOW WAREHOUSES; nor which statements the extra clusters ran, which is QUERY_HISTORY.CLUSTER_NUMBER's question.
-- caveats: The events view has no end timestamp, so a cluster lifetime is reconstructed by pairing a spin-up with the next spin-down on the same warehouse and CLUSTER_NUMBER - a lifetime straddling either edge of the window is dropped, which makes this an under-count and never an over-count. Cluster numbers are reused after a spin-down, so the pairing depends on the events arriving in order; an out-of-order pair yields no lifetime rather than a wrong one. The credit figures are ESTIMATES built from measured seconds and the documented per-size rate: they are not the bill, they cannot see a resize inside a cluster's life, and they will differ from WAREHOUSE_METERING_HISTORY - which is exactly why the billed compute credits are on the same row as the denominator. Rows whose SIZE label the rate table does not recognise contribute seconds but no credits, and are counted separately so the gap is visible.

WITH cluster_events AS (
  SELECT
    e.warehouse_name,
    COALESCE(e.cluster_number, 1) AS cluster_number,
    e.timestamp                   AS event_ts,
    e.size                        AS warehouse_size,
    CASE
      WHEN e.event_name = 'SPINUP_CLUSTER'   OR e.event_reason = 'MULTICLUSTER_SPINUP'   THEN 'UP'
      WHEN e.event_name = 'SPINDOWN_CLUSTER' OR e.event_reason = 'MULTICLUSTER_SPINDOWN' THEN 'DOWN'
    END AS direction
  FROM snowflake.account_usage.warehouse_events_history e
  WHERE e.timestamp >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND e.warehouse_name IS NOT NULL
    AND (e.event_name IN ('SPINUP_CLUSTER', 'SPINDOWN_CLUSTER')
         OR e.event_reason IN ('MULTICLUSTER_SPINUP', 'MULTICLUSTER_SPINDOWN'))
    AND (e.event_state = 'COMPLETED' OR e.event_state IS NULL)
),
paired AS (
  SELECT
    warehouse_name,
    cluster_number,
    event_ts,
    direction,
    warehouse_size,
    LEAD(direction) OVER (PARTITION BY warehouse_name, cluster_number ORDER BY event_ts) AS next_direction,
    LEAD(event_ts)  OVER (PARTITION BY warehouse_name, cluster_number ORDER BY event_ts) AS next_ts
  FROM cluster_events
  WHERE direction IS NOT NULL
),
lives AS (
  -- one row per extra cluster that both started and stopped inside the window
  SELECT
    warehouse_name,
    cluster_number,
    warehouse_size,
    event_ts                              AS spun_up_at,
    DATEDIFF('second', event_ts, next_ts) AS alive_seconds
  FROM paired
  WHERE direction = 'UP'
    AND next_direction = 'DOWN'
    AND next_ts IS NOT NULL
),
rated AS (
  SELECT
    warehouse_name,
    cluster_number,
    warehouse_size,
    spun_up_at,
    alive_seconds,
    -- documented credits per hour PER CLUSTER; an unrecognised label yields NULL, never a guess
    CASE UPPER(REPLACE(REPLACE(warehouse_size, '-', ''), ' ', ''))
      WHEN 'XSMALL'  THEN 1
      WHEN 'SMALL'   THEN 2
      WHEN 'MEDIUM'  THEN 4
      WHEN 'LARGE'   THEN 8
      WHEN 'XLARGE'  THEN 16
      WHEN '2XLARGE' THEN 32
      WHEN '3XLARGE' THEN 64
      WHEN '4XLARGE' THEN 128
      WHEN '5XLARGE' THEN 256
      WHEN '6XLARGE' THEN 512
      ELSE NULL
    END AS credits_per_hour_per_cluster
  FROM lives
),
spin AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                AS extra_cluster_lives,
    COUNT_IF(alive_seconds < :billing_minimum_seconds)       AS lives_shorter_than_minimum,
    COUNT_IF(credits_per_hour_per_cluster IS NULL)           AS lives_with_unpriceable_size,
    ROUND(MEDIAN(alive_seconds), 0)                          AS median_alive_seconds,
    MIN(alive_seconds)                                       AS shortest_alive_seconds,
    SUM(alive_seconds)                                       AS total_extra_cluster_seconds,
    ROUND(
      SUM(GREATEST(alive_seconds, :billing_minimum_seconds) * credits_per_hour_per_cluster) / 3600.0,
      3
    ) AS est_extra_cluster_credits,
    ROUND(
      SUM(GREATEST(:billing_minimum_seconds - alive_seconds, 0) * credits_per_hour_per_cluster) / 3600.0,
      3
    ) AS est_start_minimum_credits,
    LISTAGG(DISTINCT warehouse_size, ' | ')                  AS sizes_seen,
    MAX(spun_up_at)                                          AS last_spin_up
  FROM rated
  GROUP BY 1
),
metered AS (
  SELECT
    warehouse_name,
    ROUND(SUM(credits_used_compute), 3) AS billed_compute_credits
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
  GROUP BY 1
)
SELECT
  s.warehouse_name,
  s.extra_cluster_lives,
  s.lives_shorter_than_minimum,
  s.lives_with_unpriceable_size,
  s.shortest_alive_seconds,
  s.median_alive_seconds,
  s.total_extra_cluster_seconds,
  ROUND(s.total_extra_cluster_seconds / 3600.0, 2) AS total_extra_cluster_hours,
  s.est_extra_cluster_credits,
  s.est_start_minimum_credits,
  m.billed_compute_credits,
  ROUND(100 * s.est_extra_cluster_credits / NULLIF(m.billed_compute_credits, 0), 1)
    AS pct_of_compute_credits_in_extra_clusters,
  s.sizes_seen,
  s.last_spin_up,
  CASE
    WHEN s.extra_cluster_lives < :min_lives
      OR s.lives_with_unpriceable_size = s.extra_cluster_lives
      THEN 'NOT_ASSESSED'
    WHEN s.lives_shorter_than_minimum >= :critical_short_lives
      THEN 'CRITICAL'
    WHEN 100 * s.est_extra_cluster_credits / NULLIF(m.billed_compute_credits, 0) >= :critical_pct
      THEN 'CRITICAL'
    WHEN 100 * s.est_extra_cluster_credits / NULLIF(m.billed_compute_credits, 0) >= :warn_pct
      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM spin s
LEFT JOIN metered m
  ON m.warehouse_name = s.warehouse_name
ORDER BY s.est_extra_cluster_credits DESC NULLS LAST, s.extra_cluster_lives DESC;
