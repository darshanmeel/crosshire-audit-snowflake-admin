-- query_id: serverless_credit_exposure
-- title: Serverless credits per day, by service - the spend no warehouse size governs
-- domain: serverless_ai   tier: standard
-- rung: account_usage - METERING_HISTORY is the only rung that carries the SERVICE_TYPE split. INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY sees warehouses only, which is precisely the half of the bill this query is not about.
-- reads: snowflake.account_usage.metering_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 180 minutes for most metrics, up to 6 hours for CREDITS_USED_CLOUD_SERVICES and up to 12 hours for SNOWPIPE_STREAMING. The last day in the window is therefore always understated; read the trend, not today's number.
-- params: :period_days (default 30) rolling window in days; :warn_share_pct (default 15) day-level serverless share of all credits that raises WARN; :critical_share_pct (default 30) share that raises CRITICAL; :min_day_credits (default 1) a day below this many total credits is too small to judge and reports NOT_ASSESSED
-- confidence: confirmed-docs
-- confidence_note: METERING_HISTORY and every column used (SERVICE_TYPE, START_TIME, CREDITS_USED, CREDITS_USED_COMPUTE, CREDITS_USED_CLOUD_SERVICES) are documented at docs.snowflake.com/en/sql-reference/account-usage/metering_history, as is the SERVICE_TYPE value list. Not run against a live account. The two warehouse SERVICE_TYPE values are excluded by name rather than by a flag column, because no flag column exists - if a future release adds a third warehouse-shaped service type it will be counted as serverless here until the exclusion list is updated.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one day x one non-warehouse service type. The two columns that matter are CREDITS_USED (what that service burned that day) and DAY_SERVERLESS_SHARE_PCT (how much of that whole day's bill was serverless). The share is a property of the DAY, so it repeats across every row for that day - that is deliberate: it lets you sort by the biggest serverless service and still see the exposure it sits inside.
-- healthy: serverless is a small, stable minority of the daily bill - under :warn_share_pct - and the service mix is the one you would predict from what you have switched on. AUTO_CLUSTERING, PIPE and MATERIALIZED_VIEW moving in step with data volume is normal.
-- investigate_if: the serverless share crosses :warn_share_pct, or any single service type appears that nobody on the team can name an owner for. A false positive looks like a genuine one-off reclustering or a backfill: check whether the service type is elevated for one or two days only. A true positive is a service type that has quietly become a standing line item.
-- actions: 1) name an owner for every serverless service type in the result, and delete the ones no owner claims - free; 2) attach the underlying object to a schedule or a target lag you actually chose, rather than the default - config; 3) if the exposure is real and wanted, buy the ceiling you cannot get from a resource monitor by budgeting the serverless line separately in the capacity plan - spend
-- next: serverless_not_monitor_guarded (if the serverless share is above the warn band), ai_cortex_cost_guardrail (if AI_SERVICES is the largest serverless line), serverless_task_cost_and_upsizing (if SERVERLESS_TASK is the largest serverless line), serverless_snowpipe_small_files (if PIPE is the largest serverless line)
-- caveats: METERING_HISTORY is hourly and account-wide, and its non-warehouse rows carry no owner. NAME, DATABASE_NAME and SCHEMA_NAME are populated only for some service types, so this query deliberately reports at the service-type grain rather than pretending to an object-level attribution it cannot make. Credits here are METERED credits, not money - only the ORGANIZATION_USAGE rate sheet turns them into currency. Excluding WAREHOUSE_METERING and WAREHOUSE_METERING_READER is what makes this the serverless half of the bill; do not compare the totals here against a warehouse-only report and expect them to add up to the invoice, because cloud-services adjustments happen at the daily level, not here.

WITH metered AS (
  SELECT
    TO_DATE(start_time)                          AS usage_day,
    service_type,
    SUM(credits_used)                            AS credits_used,
    SUM(credits_used_compute)                    AS credits_compute,
    SUM(credits_used_cloud_services)             AS credits_cloud_services,
    SUM(COALESCE(bytes, 0))                      AS bytes_processed,
    SUM(COALESCE(files, 0))                      AS files_processed,
    COUNT(*)                                     AS metered_hours
  FROM snowflake.account_usage.metering_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
day_totals AS (
  SELECT
    usage_day,
    SUM(credits_used)                            AS day_all_credits,
    SUM(CASE WHEN service_type NOT IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER')
             THEN credits_used ELSE 0 END)       AS day_serverless_credits
  FROM metered
  GROUP BY 1
),
scored AS (
  SELECT
    m.usage_day,
    m.service_type,
    ROUND(m.credits_used, 4)                     AS credits_used,
    ROUND(m.credits_compute, 4)                  AS credits_compute,
    ROUND(m.credits_cloud_services, 4)           AS credits_cloud_services,
    m.bytes_processed,
    m.files_processed,
    m.metered_hours,
    ROUND(d.day_serverless_credits, 4)           AS day_serverless_credits,
    ROUND(d.day_all_credits, 4)                  AS day_all_credits,
    CASE WHEN d.day_all_credits > 0
         THEN ROUND(100.0 * d.day_serverless_credits / d.day_all_credits, 2) END
                                                 AS day_serverless_share_pct,
    CASE WHEN d.day_serverless_credits > 0
         THEN ROUND(100.0 * m.credits_used / d.day_serverless_credits, 2) END
                                                 AS share_of_serverless_pct,
    d.day_all_credits                            AS day_all_credits_raw
  FROM metered m
  JOIN day_totals d
    ON d.usage_day = m.usage_day
  WHERE m.service_type NOT IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER')
)
SELECT
  usage_day,
  service_type,
  credits_used,
  credits_compute,
  credits_cloud_services,
  bytes_processed,
  files_processed,
  metered_hours,
  day_serverless_credits,
  day_all_credits,
  day_serverless_share_pct,
  share_of_serverless_pct,
  CASE
    WHEN day_all_credits_raw < :min_day_credits            THEN 'NOT_ASSESSED'
    WHEN day_serverless_share_pct >= :critical_share_pct   THEN 'CRITICAL'
    WHEN day_serverless_share_pct >= :warn_share_pct       THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY day_serverless_share_pct DESC NULLS LAST, credits_used DESC, usage_day DESC;
