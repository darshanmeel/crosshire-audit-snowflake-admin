-- query_id: serverless_not_monitor_guarded
-- title: Serverless credits no resource monitor could ever have capped
-- domain: serverless_ai   tier: standard
-- rung: account_usage - both halves of the answer live here. RESOURCE_MONITORS is the only view that says whether a monitor is account-level or warehouse-level, and METERING_HISTORY is the only view that splits credits by service type.
-- reads: snowflake.account_usage.metering_history, snowflake.account_usage.resource_monitors
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - METERING_HISTORY up to 180 minutes, RESOURCE_MONITORS up to 120 minutes. A monitor created in the last two hours may not appear, which would make this query overstate the gap. Re-run before acting on a CRITICAL.
-- params: :period_days (default 30) rolling window in days; :warn_credits (default 10) serverless credits in the window for a service type that raises WARN; :critical_credits (default 100) credits that raise CRITICAL when nothing at account level can cap them; :min_credits (default 0.5) service types below this are dropped as noise
-- confidence: confirmed-docs
-- confidence_note: RESOURCE_MONITORS columns NAME, LEVEL, CREDIT_QUOTA, USED_CREDITS, REMAINING_CREDITS, WAREHOUSES, SUSPEND, SUSPEND_IMMEDIATE, NOTIFY and READER_ACCOUNT_DELETED_ON are documented at docs.snowflake.com/en/sql-reference/account-usage/resource_monitors; METERING_HISTORY at the metering_history page. Not run live. CREDIT_QUOTA and USED_CREDITS are documented as VARIANT, so they are cast before arithmetic. The exact string LEVEL carries for an account-level monitor is documented only as "account-level or warehouse-level", so the test is a case-insensitive LIKE on ACCOUNT rather than an equality against a guessed literal.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one serverless service type over the window. The two columns that matter are CREDITS_USED and ACCOUNT_LEVEL_MONITORS. A resource monitor can only ever be attached to warehouses or to the whole account - the RESOURCE_MONITORS view has exactly one attachment column, WAREHOUSES - so a serverless service type is by construction outside every warehouse-level monitor on the account. ACCOUNT_LEVEL_MONITORS is therefore the whole question: zero means this credit line has no ceiling of any kind.
-- healthy: at least one account-level resource monitor exists with a quota someone chose, and the serverless credits it has to absorb are small enough that they do not eat the account quota before the warehouses do.
-- investigate_if: ACCOUNT_LEVEL_MONITORS is zero and any service type is above :warn_credits - that spend has no ceiling at all. A false positive is a monitor created inside the view's two-hour latency window, or a monitor that exists but has a quota so large it is decorative. A true positive is an account with warehouse monitors only, which reads as governed and is not.
-- actions: 1) list the serverless service types that carry real credits and confirm each has a named owner - free; 2) create an ACCOUNT-level resource monitor with a quota and a NOTIFY threshold, since that is the only monitor that sees serverless credits at all - config; 3) where a service type cannot be capped and cannot be turned off, move its budget into the capacity plan explicitly rather than discovering it on the invoice - spend
-- next: serverless_credit_exposure (if you need the day-by-day shape of the same credits), serverless_orphaned_services (if SNOWPARK_CONTAINER_SERVICES is on the list), serverless_task_cost_and_upsizing (if SERVERLESS_TASK is on the list)
-- caveats: An account-level resource monitor suspends WAREHOUSES when its quota is hit - it does not and cannot suspend a pipe, a task, a dynamic table or a Cortex call. So even ACCOUNT_LEVEL_MONITORS greater than zero is a notification mechanism for serverless spend, not a brake, and this query grades it as the best available rather than as a control. USED_CREDITS and REMAINING_CREDITS are reported for the current monthly billing cycle, which is a different window from :period_days; they are shown as context and never mixed into the same arithmetic as the metered credits. Reader-account monitors are excluded by READER_ACCOUNT_DELETED_ON.

WITH monitors AS (
  SELECT
    COUNT(*)                                                                AS monitor_count,
    COUNT(CASE WHEN UPPER(level) LIKE '%ACCOUNT%' THEN 1 END)               AS account_level_monitors,
    COUNT(CASE WHEN UPPER(level) NOT LIKE '%ACCOUNT%' THEN 1 END)           AS warehouse_level_monitors,
    SUM(TRY_TO_DOUBLE(credit_quota::VARCHAR))                               AS total_credit_quota,
    SUM(TRY_TO_DOUBLE(used_credits::VARCHAR))                               AS total_used_credits_this_cycle
  FROM snowflake.account_usage.resource_monitors
  WHERE reader_account_deleted_on IS NULL
),
serverless AS (
  SELECT
    service_type,
    SUM(credits_used)                            AS credits_used,
    SUM(credits_used_compute)                    AS credits_compute,
    SUM(credits_used_cloud_services)             AS credits_cloud_services,
    MIN(start_time)                              AS first_metered_at,
    MAX(end_time)                                AS last_metered_at,
    COUNT(*)                                     AS metered_hours
  FROM snowflake.account_usage.metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND service_type NOT IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER')
  GROUP BY 1
),
scored AS (
  SELECT
    s.service_type,
    ROUND(s.credits_used, 4)                     AS credits_used,
    ROUND(s.credits_compute, 4)                  AS credits_compute,
    ROUND(s.credits_cloud_services, 4)           AS credits_cloud_services,
    s.metered_hours,
    s.first_metered_at,
    s.last_metered_at,
    m.monitor_count,
    m.account_level_monitors,
    m.warehouse_level_monitors,
    ROUND(m.total_credit_quota, 2)               AS total_credit_quota,
    ROUND(m.total_used_credits_this_cycle, 2)    AS total_used_credits_this_cycle,
    'resource monitors attach to warehouses or to the account only - never to a serverless service'
                                                 AS why_ungoverned
  FROM serverless s
  CROSS JOIN monitors m
  WHERE s.credits_used >= :min_credits
)
SELECT
  service_type,
  credits_used,
  credits_compute,
  credits_cloud_services,
  metered_hours,
  first_metered_at,
  last_metered_at,
  monitor_count,
  account_level_monitors,
  warehouse_level_monitors,
  total_credit_quota,
  total_used_credits_this_cycle,
  why_ungoverned,
  CASE
    WHEN account_level_monitors = 0 AND credits_used >= :critical_credits THEN 'CRITICAL'
    WHEN account_level_monitors = 0 AND credits_used >= :warn_credits     THEN 'WARN'
    WHEN credits_used >= :critical_credits                                THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY credits_used DESC;
