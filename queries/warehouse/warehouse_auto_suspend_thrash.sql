-- query_id: warehouse_auto_suspend_thrash
-- title: Warehouses whose suspend/resume cycles cost more in 60-second minimums than the idle they saved
-- domain: warehouse   tier: deep
-- rung: account_usage - WAREHOUSE_EVENTS_HISTORY is the only place a suspend and the resume that follows it are both recorded. Neither SHOW nor INFORMATION_SCHEMA carries warehouse lifecycle events at all, so there is no lower rung to prefer.
-- reads: snowflake.account_usage.warehouse_events_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 3 hours documented, with a year of retention. The lag matters here in one specific way: the last suspend in the window will usually have no resume yet, so the most recent cycle is simply absent rather than counted as infinite.
-- params: :period_days (default 30) trailing window in days; :billing_minimum_seconds (default 60) the documented minimum charge each time a warehouse starts - a parameter, not a constant, so a future change to that rule does not silently invalidate this file; :min_cycles (default 10) fewer suspend-resume cycles than this and there is no pattern to judge; :warn_cycles (default 20) wasteful cycles that earn a WARN; :critical_cycles (default 100) the same for CRITICAL
-- confidence: confirmed-docs
-- confidence_note: WAREHOUSE_EVENTS_HISTORY and its columns TIMESTAMP, WAREHOUSE_NAME, CLUSTER_NUMBER, EVENT_NAME, EVENT_REASON, EVENT_STATE and SIZE are documented at docs.snowflake.com/en/sql-reference/account-usage/warehouse_events_history, as are the exact EVENT_NAME values SUSPEND_WAREHOUSE, RESUME_WAREHOUSE, SUSPEND_CLUSTER and RESUME_CLUSTER, the EVENT_REASON value WAREHOUSE_AUTOSUSPEND, and the EVENT_STATE values STARTED and COMPLETED. The 60-second minimum charge per warehouse start is documented on docs.snowflake.com/en/user-guide/warehouses-overview. The view carries no end timestamp for an event, so pairing each suspend with the next resume is this query's construction. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = one warehouse over the window. The two columns to read together are cycles_shorter_than_minimum (how many times the warehouse suspended and was woken again before the 60-second minimum it would pay on that wake had even elapsed) and net_wasted_seconds (what those cycles cost: for each one, the minimum charged on the resume minus the idle actually avoided). A warehouse can look busy and healthy and still be losing most of its cycles here.
-- healthy: cycles_shorter_than_minimum near zero, and median_idle_seconds comfortably longer than :billing_minimum_seconds - the warehouse sleeps long enough that sleeping was worth it.
-- investigate_if: cycles_shorter_than_minimum at or above :warn_cycles (WARN) or :critical_cycles (CRITICAL) - auto_suspend is set shorter than the natural gap between this warehouse's queries, so it keeps paying to restart. A false positive: a warehouse that a resource monitor suspends and an operator resumes will produce the same event pair with no auto-suspend involved at all - the auto_suspend_cycles column is on the row so you can tell whether the pattern is really the auto-suspend policy or a human and a monitor arguing.
-- actions: 1) compare median_idle_seconds with the warehouse's configured auto_suspend - if the gaps between queries are shorter than the setting, the setting is the bug, and reading it costs nothing (free); 2) raise auto_suspend to a little more than the typical gap so the warehouse rides through it, or lower it dramatically so it genuinely sleeps - the losing position is the middle (config); 3) if the traffic is genuinely a trickle all day, keep one small warehouse awake for it rather than repeatedly starting a large one (spend).
-- next: warehouse_inventory_show (if you need the current auto_suspend value before changing it), warehouse_wake_analysis (if you need to know what is waking it in the first place), warehouse_resume_storm_waste (if the resumes arrive in bursts rather than evenly)
-- covers: Every warehouse and every cluster that generated a lifecycle event, account-wide, up to a year back. It does NOT see: the auto_suspend SETTING, which lives only in SHOW WAREHOUSES; the credits any of this cost, which live in WAREHOUSE_METERING_HISTORY; or what ran between the resume and the next suspend, which is warehouse_wake_analysis's question.
-- caveats: The view has no end timestamp for an event, so an idle gap is reconstructed by pairing a suspend with the NEXT resume on the same warehouse and cluster - a pair straddling the start of the window is dropped, and the last suspend in the window has no partner and is dropped too. Events whose EVENT_STATE is STARTED are excluded so a single lifecycle change is not counted twice; rows where EVENT_STATE is null are kept, since the column is documented as applying only to events that take time to complete. Cluster-level suspends and resumes are included and partitioned by CLUSTER_NUMBER, which means a multi-cluster warehouse contributes one cycle per cluster - correct for billing, but read it alongside warehouse_multicluster_spinup_cost rather than as a single-object figure. net_wasted_seconds is CLUSTER seconds, not credits: multiply by the size rate to price it, and note that a resize inside the window makes that multiplication approximate, which is why sizes_seen is on the row.

WITH lifecycle AS (
  SELECT
    e.warehouse_name,
    COALESCE(e.cluster_number, 1) AS cluster_number,
    e.timestamp                 AS event_ts,
    e.event_reason,
    e.size                      AS warehouse_size,
    CASE
      WHEN e.event_name IN ('SUSPEND_WAREHOUSE', 'SUSPEND_CLUSTER') THEN 'SUSPEND'
      WHEN e.event_name IN ('RESUME_WAREHOUSE',  'RESUME_CLUSTER')  THEN 'RESUME'
    END AS phase
  FROM snowflake.account_usage.warehouse_events_history e
  WHERE e.timestamp >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND e.warehouse_name IS NOT NULL
    AND e.event_name IN ('SUSPEND_WAREHOUSE', 'SUSPEND_CLUSTER', 'RESUME_WAREHOUSE', 'RESUME_CLUSTER')
    -- a lifecycle change that reports both STARTED and COMPLETED must be counted once
    AND (e.event_state = 'COMPLETED' OR e.event_state IS NULL)
),
paired AS (
  SELECT
    warehouse_name,
    cluster_number,
    event_ts,
    phase,
    event_reason,
    warehouse_size,
    LEAD(phase)    OVER (PARTITION BY warehouse_name, cluster_number ORDER BY event_ts) AS next_phase,
    LEAD(event_ts) OVER (PARTITION BY warehouse_name, cluster_number ORDER BY event_ts) AS next_ts
  FROM lifecycle
),
idle_gaps AS (
  -- one row per completed sleep: suspended here, woken there
  SELECT
    warehouse_name,
    cluster_number,
    warehouse_size,
    event_reason,
    event_ts                              AS suspended_at,
    DATEDIFF('second', event_ts, next_ts) AS idle_seconds
  FROM paired
  WHERE phase = 'SUSPEND'
    AND next_phase = 'RESUME'
    AND next_ts IS NOT NULL
),
rolled AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                  AS suspend_resume_cycles,
    COUNT_IF(event_reason = 'WAREHOUSE_AUTOSUSPEND')          AS auto_suspend_cycles,
    COUNT_IF(idle_seconds < :billing_minimum_seconds)         AS cycles_shorter_than_minimum,
    ROUND(MEDIAN(idle_seconds), 0)                            AS median_idle_seconds,
    MIN(idle_seconds)                                         AS shortest_idle_seconds,
    ROUND(AVG(idle_seconds), 0)                               AS mean_idle_seconds,
    SUM(GREATEST(:billing_minimum_seconds - idle_seconds, 0)) AS net_wasted_seconds,
    LISTAGG(DISTINCT warehouse_size, ' | ')                   AS sizes_seen,
    COUNT(DISTINCT cluster_number)                            AS clusters_seen,
    MAX(suspended_at)                                         AS last_suspend
  FROM idle_gaps
  GROUP BY 1
)
SELECT
  warehouse_name,
  suspend_resume_cycles,
  auto_suspend_cycles,
  cycles_shorter_than_minimum,
  ROUND(100 * cycles_shorter_than_minimum / NULLIF(suspend_resume_cycles, 0), 1) AS pct_cycles_wasteful,
  shortest_idle_seconds,
  median_idle_seconds,
  mean_idle_seconds,
  net_wasted_seconds,
  ROUND(net_wasted_seconds / 3600.0, 2) AS net_wasted_cluster_hours,
  clusters_seen,
  sizes_seen,
  last_suspend,
  CASE
    WHEN suspend_resume_cycles < :min_cycles           THEN 'NOT_ASSESSED'
    WHEN cycles_shorter_than_minimum >= :critical_cycles THEN 'CRITICAL'
    WHEN cycles_shorter_than_minimum >= :warn_cycles     THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM rolled
ORDER BY net_wasted_seconds DESC, cycles_shorter_than_minimum DESC;
