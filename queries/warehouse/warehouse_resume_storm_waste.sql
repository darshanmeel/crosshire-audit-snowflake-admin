-- query_id: warehouse_resume_storm_waste
-- title: Warehouses whose resumes arrive in bursts - a storm of restarts, not a workload
-- domain: warehouse   tier: deep
-- rung: account_usage - resume events exist nowhere else. SHOW WAREHOUSES reports a resumed_on timestamp, which is the LAST resume and cannot show a burst, so there is no lower rung that answers this.
-- reads: snowflake.account_usage.warehouse_events_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 3 hours documented, a year retained. A storm in the last three hours is exactly the case this view will not show you yet, which is worth saying out loud when someone reports that the bill spiked this morning.
-- params: :period_days (default 30) trailing window in days; :storm_window_minutes (default 5) the bucket width a burst is counted in - must divide 60, because buckets are aligned to the hour; :storm_resumes (default 3) resumes inside one bucket that make it a storm bucket; :billing_minimum_seconds (default 60) the documented minimum charged each time a warehouse starts; :min_resumes (default 10) fewer resumes than this in the window and there is no pattern to judge; :warn_storm_buckets (default 5) storm buckets that earn a WARN; :critical_storm_buckets (default 20) the same for CRITICAL
-- confidence: confirmed-docs
-- confidence_note: WAREHOUSE_EVENTS_HISTORY and the columns TIMESTAMP, WAREHOUSE_NAME, CLUSTER_NUMBER, EVENT_NAME, EVENT_REASON, EVENT_STATE, USER_NAME and SIZE are documented, as are the EVENT_NAME values RESUME_WAREHOUSE and RESUME_CLUSTER and the EVENT_REASON values WAREHOUSE_AUTORESUME and WAREHOUSE_RESUME. The 60-second minimum charge per start is documented on docs.snowflake.com/en/user-guide/warehouses-overview. Bucketing to an hour-aligned window is done with MINUTE() and MOD() rather than TIME_SLICE so that the bucket width can be a bind parameter on every driver. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = one warehouse over the window. The two columns that make the case are storm_buckets (how many :storm_window_minutes-wide slices contained :storm_resumes or more restarts) and floor_billed_seconds (the pure restart tax - every resume buys at least :billing_minimum_seconds of billing whether or not any work needed it). A storm is not the same finding as thrash: thrash is a warehouse suspending too eagerly between quiet stretches, a storm is many wake-ups arriving together, which usually means many clients, not one policy.
-- healthy: storm_buckets at or near zero, and median_seconds_between_resumes comfortably longer than :billing_minimum_seconds. Resumes spread evenly through the day are a workload, not a storm.
-- investigate_if: storm_buckets at or above :warn_storm_buckets (WARN) or :critical_storm_buckets (CRITICAL). A false positive worth naming: a multi-cluster warehouse legitimately spinning several clusters up at once will produce several RESUME_CLUSTER events in the same second, and that is scaling working, not a storm - the resumes_at_cluster_level column separates the two, and if it dominates, read warehouse_multicluster_spinup_cost instead.
-- actions: 1) count distinct wakers before touching config - the same burst from one scheduler is a scheduling fix, and from twenty dashboards it is a caching fix (free); 2) stagger whatever fires together, or let the warehouse stay up across the burst by lengthening auto_suspend so the burst costs one start instead of many (config); 3) if the burst is genuinely simultaneous demand, that is a concurrency question and belongs to multi-cluster sizing, not to auto-suspend (spend).
-- next: warehouse_wake_analysis (if you need to name the user or client behind the burst), warehouse_auto_suspend_thrash (if the resumes turn out to be evenly spaced and the real problem is a too-short auto_suspend), warehouse_multicluster_spinup_cost (if most of the resumes are cluster-level)
-- covers: Every resume event on every warehouse, account-wide, up to a year back, with the cluster-level ones separated out. It does NOT see: what each resume then did - warehouse_wake_analysis joins QUERY_HISTORY for that; nor the credits, which are in WAREHOUSE_METERING_HISTORY; nor the auto_suspend setting that shaped the pattern, which is in SHOW WAREHOUSES.
-- caveats: Buckets are aligned to the hour, so a burst that straddles a bucket boundary is split across two buckets and can fall under the :storm_resumes threshold on both sides - this query therefore UNDER-reports storms rather than inventing them, which is the right direction for an accusation. Events with EVENT_STATE STARTED are excluded so one lifecycle change is not counted twice. Cluster-level resumes are counted and reported separately, because a multi-cluster warehouse scaling out is not a storm. floor_billed_seconds is a floor, not a bill: it is what the minimum charge alone comes to, priced in cluster seconds and ignoring the size, so multiply by the size rate to turn it into credits.

WITH resumes AS (
  SELECT
    e.warehouse_name,
    COALESCE(e.cluster_number, 1) AS cluster_number,
    e.timestamp                 AS event_ts,
    e.event_name,
    e.event_reason,
    e.user_name,
    e.size                      AS warehouse_size,
    -- hour-aligned bucket of :storm_window_minutes; MOD() keeps the width bindable
    DATEADD(
      'minute',
      -MOD(MINUTE(e.timestamp), :storm_window_minutes),
      DATE_TRUNC('minute', e.timestamp)
    ) AS bucket_start
  FROM snowflake.account_usage.warehouse_events_history e
  WHERE e.timestamp >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND e.warehouse_name IS NOT NULL
    AND e.event_name IN ('RESUME_WAREHOUSE', 'RESUME_CLUSTER')
    AND (e.event_state = 'COMPLETED' OR e.event_state IS NULL)
),
bucketed AS (
  SELECT
    warehouse_name,
    bucket_start,
    COUNT(*)                                     AS resumes_in_bucket,
    COUNT(DISTINCT user_name)                    AS distinct_users_in_bucket
  FROM resumes
  GROUP BY 1, 2
),
gaps AS (
  SELECT
    warehouse_name,
    DATEDIFF(
      'second',
      LAG(event_ts) OVER (PARTITION BY warehouse_name ORDER BY event_ts),
      event_ts
    ) AS seconds_since_previous_resume
  FROM resumes
),
gap_stats AS (
  SELECT
    warehouse_name,
    ROUND(MEDIAN(seconds_since_previous_resume), 0)                  AS median_seconds_between_resumes,
    MIN(seconds_since_previous_resume)                               AS shortest_seconds_between_resumes,
    COUNT_IF(seconds_since_previous_resume < :billing_minimum_seconds) AS resumes_inside_previous_minimum
  FROM gaps
  WHERE seconds_since_previous_resume IS NOT NULL
  GROUP BY 1
),
totals AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                     AS resumes,
    COUNT_IF(event_name = 'RESUME_CLUSTER')                      AS resumes_at_cluster_level,
    COUNT_IF(event_reason = 'WAREHOUSE_AUTORESUME')              AS auto_resumes,
    COUNT(DISTINCT user_name)                                    AS distinct_wakers,
    LISTAGG(DISTINCT warehouse_size, ' | ')                      AS sizes_seen,
    MAX(event_ts)                                                AS last_resume
  FROM resumes
  GROUP BY 1
),
storms AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                                    AS buckets_with_a_resume,
    COUNT_IF(resumes_in_bucket >= :storm_resumes)                               AS storm_buckets,
    MAX(resumes_in_bucket)                                                      AS max_resumes_in_one_bucket,
    SUM(IFF(resumes_in_bucket >= :storm_resumes, resumes_in_bucket, 0))         AS resumes_inside_storms,
    MAX(IFF(resumes_in_bucket >= :storm_resumes, distinct_users_in_bucket, 0))  AS most_users_in_a_storm_bucket
  FROM bucketed
  GROUP BY 1
)
SELECT
  t.warehouse_name,
  t.resumes,
  t.resumes_at_cluster_level,
  t.auto_resumes,
  t.distinct_wakers,
  s.buckets_with_a_resume,
  s.storm_buckets,
  s.max_resumes_in_one_bucket,
  s.resumes_inside_storms,
  s.most_users_in_a_storm_bucket,
  ROUND(100 * s.resumes_inside_storms / NULLIF(t.resumes, 0), 1) AS pct_resumes_inside_storms,
  g.shortest_seconds_between_resumes,
  g.median_seconds_between_resumes,
  g.resumes_inside_previous_minimum,
  t.resumes * :billing_minimum_seconds                          AS floor_billed_seconds,
  ROUND(t.resumes * :billing_minimum_seconds / 3600.0, 2)       AS floor_billed_cluster_hours,
  t.sizes_seen,
  t.last_resume,
  CASE
    WHEN t.resumes < :min_resumes                     THEN 'NOT_ASSESSED'
    WHEN s.storm_buckets >= :critical_storm_buckets   THEN 'CRITICAL'
    WHEN s.storm_buckets >= :warn_storm_buckets       THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM totals t
JOIN storms s        ON s.warehouse_name = t.warehouse_name
LEFT JOIN gap_stats g ON g.warehouse_name = t.warehouse_name
ORDER BY s.storm_buckets DESC, t.resumes DESC;
