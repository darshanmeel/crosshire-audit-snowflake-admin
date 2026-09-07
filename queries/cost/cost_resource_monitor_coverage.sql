-- query_id: cost_resource_monitor_coverage
-- title: Which warehouses burn credits with no ceiling - resource-monitor coverage, weighted by spend
-- domain: cost   tier: standard
-- rung: account_usage - SHOW RESOURCE MONITORS is live and would answer the inventory half, but it cannot be joined to a month of metered credits, and coverage without spend is a list rather than a finding. The credits are what turn this into a ranking.
-- reads: snowflake.account_usage.resource_monitors, snowflake.account_usage.warehouse_metering_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database. Note that RESOURCE_MONITORS is documented to show only objects the CURRENT ROLE can access, so a role short of ACCOUNTADMIN can produce a result that understates coverage rather than erroring.
-- freshness: LAGGED - RESOURCE_MONITORS up to 120 minutes, WAREHOUSE_METERING_HISTORY up to 180 minutes. A monitor created in the last hour may not be here yet, which would show as an uncovered warehouse that is in fact covered.
-- params: :period_days (default 30) rolling window of metered credits used to weight the coverage gap; :min_credits (default 1) a warehouse below this many credits in the window returns NOT_ASSESSED; :warn_credits (default 10) credits burned by a warehouse with no ceiling of its own that raise WARN; :critical_credits (default 100) credits burned by a warehouse with no ceiling at all that raise CRITICAL
-- confidence: confirmed-docs
-- confidence_note: NAME, CREATED, CREDIT_QUOTA, USED_CREDITS, REMAINING_CREDITS, OWNER, WAREHOUSES, NOTIFY, SUSPEND, SUSPEND_IMMEDIATE and LEVEL are the documented columns of ACCOUNT_USAGE.RESOURCE_MONITORS, and CREDIT_QUOTA and USED_CREDITS are documented as VARIANT and are cast here before any arithmetic. Not run live, and one shape is honestly unverified: the WAREHOUSES column is documented as a VARCHAR list of assigned warehouses, but its exact delimiting and quoting is not specified, so the match below is a split-and-trim rather than a foreign key. A warehouse whose name contains the delimiter would be matched wrongly, and that is stated in the caveats rather than hidden.
-- empty_if: no_imported_privileges, account_usage_lag, privilege_scoped, no_activity
-- read_this: One row = one warehouse that actually burned credits in the window. CREDITS_USED_WINDOW is what it spent; MONITORS_ATTACHED and ACCOUNT_MONITOR_COUNT together say whether anything could have stopped it. The third column that matters is HAS_SUSPENDING_MONITOR: a monitor with only a NOTIFY action is an email, not a ceiling, and a warehouse covered solely by one is uncapped in every sense that matters.
-- healthy: every warehouse carrying real spend is either named by a monitor with a suspend action, or sits under an account-level monitor with a quota someone chose deliberately. A small sandbox warehouse with no monitor is fine; the largest warehouse on the account having none is not.
-- investigate_if: a warehouse burned :warn_credits or more with no monitor naming it, or is covered only by notify-only monitors - the spend has no ceiling and the first anyone will know is the invoice. The worst case, and the CRITICAL band here, is a heavy warehouse with neither a warehouse-level nor an account-level monitor anywhere. False positive: a deliberately uncapped production warehouse whose suspension would cause an outage is a considered decision, not a defect - but it should be a written one, and the notify-only pattern is often exactly that decision, made properly.
-- actions: 1) list the uncapped warehouses against who owns them and decide, per warehouse, whether a ceiling is acceptable - suspending production is sometimes worse than overspending (free); 2) attach a monitor with a realistic quota and a NOTIFY threshold below the SUSPEND threshold, so the warning arrives before the ceiling does; an account-level monitor is the backstop, never the plan (config); 3) remember that no resource monitor governs serverless spend at all, so a fully monitored warehouse estate still leaves tasks, pipes and Cortex uncapped (config).
-- next: cost_credits_by_warehouse_day (if you need the daily shape of what an uncapped warehouse actually burned), cost_credit_spike_anomaly (if an uncapped warehouse also spikes), cost_capacity_runway (if the uncapped burn is what is draining the contract)
-- covers: WAREHOUSE spend only, and only warehouses that were metered in the window - a warehouse that exists but ran nothing does not appear, by design, because it has nothing to cap. Serverless credits are structurally outside this query and outside resource monitors themselves: no monitor can cap a task, a pipe, a dynamic table or a Cortex call, which is why an account can be fully monitored and still surprised.
-- caveats: The monitor-to-warehouse match is a STRING match on the documented WAREHOUSES list, split on commas and trimmed, then compared case-insensitively. It is not a join on an id, because Snowflake does not publish one in this view - a warehouse whose name contains a comma, or a list format that differs from the assumed one, will mismatch. Treat an unexpected zero-monitor result as a prompt to check SHOW RESOURCE MONITORS live before believing it. CREDIT_QUOTA and USED_CREDITS are VARIANT and are cast; where several monitors cover one warehouse the SMALLEST quota is reported, since that is the one that will bite first. The view has no deleted-on column, so a dropped monitor may linger. Quota consumption resets on the monitor's own frequency, which this view does not expose, so USED_CREDITS is a point in an unknown cycle and is reported for context rather than banded.

WITH monitors AS (
  SELECT
    m.name                            AS monitor_name,
    m.level                           AS monitor_level,
    TO_NUMBER(m.credit_quota)         AS credit_quota,
    TO_NUMBER(m.used_credits)         AS used_credits,
    m.remaining_credits,
    m.notify,
    m.suspend,
    m.suspend_immediate,
    m.warehouses
  FROM snowflake.account_usage.resource_monitors m
),
account_monitors AS (
  SELECT
    COUNT(*)                                                   AS account_monitor_count,
    MIN(credit_quota)                                          AS account_smallest_quota,
    COUNT_IF(suspend IS NOT NULL OR suspend_immediate IS NOT NULL) AS account_suspending_monitors
  FROM monitors
  WHERE UPPER(COALESCE(monitor_level, '')) = 'ACCOUNT'
),
monitor_warehouse AS (
  SELECT
    mo.monitor_name,
    mo.credit_quota,
    mo.used_credits,
    mo.suspend,
    mo.suspend_immediate,
    UPPER(TRIM(f.value)) AS warehouse_key
  FROM monitors mo,
       LATERAL SPLIT_TO_TABLE(COALESCE(mo.warehouses, ''), ',') f
  WHERE TRIM(f.value) <> ''
),
warehouse_spend AS (
  SELECT
    warehouse_name,
    SUM(COALESCE(credits_used, 0))         AS credits_used_window,
    SUM(COALESCE(credits_used_compute, 0)) AS credits_compute_window,
    COUNT(*)                               AS metered_hours,
    MAX(start_time)                        AS last_metered_at
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY warehouse_name
),
joined AS (
  SELECT
    w.warehouse_name,
    w.credits_used_window,
    w.credits_compute_window,
    w.metered_hours,
    w.last_metered_at,
    a.account_monitor_count,
    a.account_smallest_quota,
    a.account_suspending_monitors,
    COUNT(mw.monitor_name)                                        AS warehouse_monitor_count,
    COUNT_IF(mw.suspend IS NOT NULL OR mw.suspend_immediate IS NOT NULL) AS suspending_monitor_count,
    MIN(mw.credit_quota)                                          AS smallest_quota_credits,
    MAX(mw.used_credits)                                          AS largest_quota_used_credits,
    LISTAGG(DISTINCT mw.monitor_name, ' | ')
      WITHIN GROUP (ORDER BY mw.monitor_name)                     AS monitors_attached,
    100.0 * w.credits_used_window
          / NULLIF(SUM(w.credits_used_window) OVER (), 0)         AS pct_of_warehouse_credits
  FROM warehouse_spend w
  CROSS JOIN account_monitors a
  LEFT JOIN monitor_warehouse mw
    ON mw.warehouse_key = UPPER(w.warehouse_name)
  GROUP BY
    w.warehouse_name, w.credits_used_window, w.credits_compute_window,
    w.metered_hours, w.last_metered_at,
    a.account_monitor_count, a.account_smallest_quota, a.account_suspending_monitors
)
SELECT
  warehouse_name,
  ROUND(credits_used_window, 3)     AS credits_used_window,
  ROUND(credits_compute_window, 3)  AS credits_compute_window,
  ROUND(pct_of_warehouse_credits, 1) AS pct_of_warehouse_credits,
  metered_hours,
  last_metered_at,
  warehouse_monitor_count,
  suspending_monitor_count,
  IFF(suspending_monitor_count > 0 OR account_suspending_monitors > 0, TRUE, FALSE) AS has_suspending_monitor,
  monitors_attached,
  smallest_quota_credits,
  largest_quota_used_credits,
  account_monitor_count,
  account_smallest_quota,
  CASE
    WHEN credits_used_window < :min_credits                                        THEN 'NOT_ASSESSED'
    WHEN warehouse_monitor_count = 0
     AND account_monitor_count = 0
     AND credits_used_window >= :critical_credits                                  THEN 'CRITICAL'
    WHEN warehouse_monitor_count = 0
     AND account_monitor_count = 0                                                 THEN 'WARN'
    WHEN suspending_monitor_count = 0
     AND account_suspending_monitors = 0
     AND credits_used_window >= :warn_credits                                      THEN 'WARN'
    WHEN warehouse_monitor_count = 0
     AND credits_used_window >= :warn_credits                                      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM joined
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  credits_used_window DESC;
