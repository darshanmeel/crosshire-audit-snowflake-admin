-- query_id: warehouse_idle_credit_leak
-- title: Credits burned by warehouses in hours when nothing ran - compute paid for nothing
-- domain: warehouse   tier: lite
-- rung: account_usage - the only rung that carries billed credits per warehouse per hour. INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY is the live twin but reaches back days, not a month, so a monthly waste number has to climb.
-- reads: snowflake.account_usage.warehouse_metering_history, snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - WAREHOUSE_METERING_HISTORY is documented at up to 3 hours (its CREDITS_USED_CLOUD_SERVICES column up to 6), QUERY_HISTORY at up to 45 minutes. The two views therefore settle at different times, so the most recent hours can show credits with no queries purely because the query rows have not landed yet. Exclude the trailing hours before believing a fresh spike.
-- params: :period_days (default 30) trailing window in days; :min_idle_credits (default 1) suppress warehouses whose non-query credits are below this - noise, not a finding; :warn_pct (default 25) percent of compute credits not attributable to queries that earns a WARN; :critical_pct (default 50) the same threshold for CRITICAL; :min_billed_hours (default 24) below this many billed hours the window is too thin to judge
-- confidence: confirmed-docs
-- confidence_note: Every column is documented. WAREHOUSE_METERING_HISTORY carries START_TIME, WAREHOUSE_NAME, CREDITS_USED, CREDITS_USED_COMPUTE, CREDITS_USED_CLOUD_SERVICES and CREDITS_ATTRIBUTED_COMPUTE_QUERIES, whose own documentation states it "includes only the credit usage for query execution and doesn't include warehouse idle time usage" - that sentence is what makes CREDITS_USED_COMPUTE minus CREDITS_ATTRIBUTED_COMPUTE_QUERIES a documented idle figure rather than an inference. QUERY_HISTORY carries WAREHOUSE_NAME, WAREHOUSE_SIZE and START_TIME. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = one warehouse over the window. Two columns matter and they answer the same question two ways: credits_non_query is Snowflake's own arithmetic (compute credits minus the credits it attributed to query execution) and is the tighter number; credits_in_silent_hours is the blunt cross-check - credits billed in clock hours during which QUERY_HISTORY recorded no statement at all. When those two disagree wildly, trust credits_non_query and suspect the hour-bucketing described in caveats.
-- healthy: pct_non_query in the low tens for an interactive warehouse - a short idle tail after each burst of work is what auto-suspend is supposed to leave behind. A batch warehouse that wakes, works and suspends should sit lower still. silent_hours near zero.
-- investigate_if: pct_non_query at or above :warn_pct with credits_non_query above :min_idle_credits (WARN), or at or above :critical_pct (CRITICAL) - most of what this object cost was not query execution. A false positive looks like this: a warehouse whose work is one long-running statement started in the previous hour, so the hour it ran through has credits and no query START_TIME - that inflates silent_hours but NOT credits_non_query, which is why both columns are on the row.
-- actions: 1) read the warehouse's current auto_suspend value and ask whether anything justifies it - the answer is free and is usually the whole fix (free); 2) lower auto_suspend, or set it at all where it is null or zero - a warehouse that suspends in a minute instead of an hour stops buying the idle (config); 3) only if the idle survives a correct auto_suspend, split the workload onto a second, smaller warehouse so the long tail is not paid at the big size (spend).
-- next: warehouse_wake_analysis (if the credits sit in hours nobody queried and you need to know what keeps waking it), warehouse_auto_suspend_thrash (if lowering auto_suspend is the plan - check first that it will not just buy resume minimums instead), warehouse_inventory_show (if you do not yet know this warehouse's auto_suspend and cluster settings)
-- covers: Account-wide, every warehouse, up to a year of history. It does NOT see: what the idle time was for, which is WAREHOUSE_EVENTS_HISTORY; whether the warehouse was merely lightly loaded rather than truly idle, which is WAREHOUSE_LOAD_HISTORY; or serverless spend, which no warehouse row can carry.
-- caveats: Queries are bucketed by START_TIME, so a statement that starts at 09:59 and runs to 11:30 makes hours 10 and 11 look query-free in the silent_hours column. That is exactly why credits_non_query, which needs no bucketing, is the primary signal and silent_hours is the cross-check. Statements with a NULL WAREHOUSE_SIZE are excluded because they never ran on warehouse compute. CREDITS_ATTRIBUTED_COMPUTE_QUERIES can be NULL on older rows and is coalesced to zero, which biases credits_non_query UPWARD on those rows - check last_billed_hour and the age of the window before acting on a warehouse whose activity is all old. Cloud-services credits are reported but deliberately kept out of the idle arithmetic: they are not warehouse compute.

WITH metered AS (
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time)                       AS hour_start,
    SUM(credits_used)                                    AS credits_total,
    SUM(credits_used_compute)                            AS credits_compute,
    SUM(credits_used_cloud_services)                     AS credits_cloud_services,
    SUM(COALESCE(credits_attributed_compute_queries, 0)) AS credits_queries
  FROM snowflake.account_usage.warehouse_metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
  GROUP BY 1, 2
),
ran AS (
  -- statements that actually used warehouse compute; a NULL WAREHOUSE_SIZE means it did not
  SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_start,
    COUNT(*)                       AS statements
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND warehouse_size IS NOT NULL
  GROUP BY 1, 2
),
hourly AS (
  SELECT
    m.warehouse_name,
    m.hour_start,
    m.credits_total,
    m.credits_compute,
    m.credits_cloud_services,
    m.credits_queries,
    GREATEST(m.credits_compute - m.credits_queries, 0) AS credits_non_query,
    COALESCE(r.statements, 0)                          AS statements
  FROM metered m
  LEFT JOIN ran r
    ON r.warehouse_name = m.warehouse_name
   AND r.hour_start     = m.hour_start
),
rolled AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                                  AS billed_hours,
    COUNT_IF(statements = 0)                                                  AS silent_hours,
    SUM(statements)                                                           AS statements,
    ROUND(SUM(credits_total), 3)                                              AS credits_total,
    ROUND(SUM(credits_compute), 3)                                            AS credits_compute,
    ROUND(SUM(credits_cloud_services), 3)                                     AS credits_cloud_services,
    ROUND(SUM(credits_non_query), 3)                                          AS credits_non_query,
    ROUND(SUM(IFF(statements = 0, credits_compute, 0)), 3)                    AS credits_in_silent_hours,
    MIN(hour_start)                                                           AS first_billed_hour,
    MAX(hour_start)                                                           AS last_billed_hour
  FROM hourly
  GROUP BY 1
)
SELECT
  warehouse_name,
  billed_hours,
  silent_hours,
  statements,
  credits_total,
  credits_compute,
  credits_cloud_services,
  credits_non_query,
  credits_in_silent_hours,
  ROUND(100 * credits_non_query       / NULLIF(credits_compute, 0), 1) AS pct_non_query,
  ROUND(100 * credits_in_silent_hours / NULLIF(credits_compute, 0), 1) AS pct_in_silent_hours,
  first_billed_hour,
  last_billed_hour,
  CASE
    WHEN billed_hours < :min_billed_hours
      THEN 'NOT_ASSESSED'
    WHEN credits_non_query >= :min_idle_credits
     AND 100 * credits_non_query / NULLIF(credits_compute, 0) >= :critical_pct
      THEN 'CRITICAL'
    WHEN credits_non_query >= :min_idle_credits
     AND 100 * credits_non_query / NULLIF(credits_compute, 0) >= :warn_pct
      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM rolled
ORDER BY credits_non_query DESC, credits_compute DESC;
