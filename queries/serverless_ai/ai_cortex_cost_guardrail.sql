-- query_id: ai_cortex_cost_guardrail
-- title: What share of the daily bill is AI now, and is it trending past the agreed ceiling
-- domain: serverless_ai   tier: standard
-- rung: account_usage - METERING_DAILY_HISTORY is the daily, adjusted view of the bill. It is the right rung for a guardrail because it is the one that already applies the cloud-services adjustment; the hourly METERING_HISTORY does not, and a guardrail built on unadjusted credits argues with the invoice.
-- reads: snowflake.account_usage.metering_daily_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented latency up to 180 minutes. The current day is always partial, so the newest row understates both the AI credits and the total; the trend is the signal, not the last point.
-- params: :period_days (default 60) rolling window in days, kept wide enough that the two halves compared for a trend are each meaningful; :min_day_credits (default 1) total credits a day must carry before its AI share is judged; :warn_ai_share_pct (default 10) AI share of the day's credits that raises WARN; :critical_ai_share_pct (default 25) AI share that raises CRITICAL; :warn_growth_ratio (default 1.5) recent-half average AI credits divided by earlier-half average that raises WARN; :critical_growth_ratio (default 3.0) that ratio which raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: METERING_DAILY_HISTORY and its columns SERVICE_TYPE, USAGE_DATE, CREDITS_USED_COMPUTE, CREDITS_USED_CLOUD_SERVICES, CREDITS_USED, CREDITS_ADJUSTMENT_CLOUD_SERVICES and CREDITS_BILLED are documented at docs.snowflake.com/en/sql-reference/account-usage/metering_daily_history, as is the SERVICE_TYPE value list, which on this view includes AI_SERVICES, CORTEX_CODE_CLI and CORTEX_CODE_SNOWSIGHT alongside the values METERING_HISTORY carries. Not run against a live account. Those three names are the documented AI-shaped service types and are matched by an explicit list here; if Snowflake adds a fourth it will be counted as non-AI until the list is updated, which is a known and stated staleness rather than a silent one.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, cortex_not_used, no_activity
-- read_this: One row = one day for the whole account. The two columns that matter are AI_SHARE_PCT and AI_GROWTH_RATIO. The first is what fraction of that day went to AI service types. The second compares the average daily AI credits in the recent half of the window against the earlier half, and is a property of the WINDOW rather than of the day, so it repeats down the column - that is deliberate, because a share is only alarming in the company of a direction.
-- healthy: AI_SHARE_PCT sits below :warn_ai_share_pct and AI_GROWTH_RATIO hovers near 1.0. AI is a line item somebody agreed to, not a line item that arrived.
-- investigate_if: AI_SHARE_PCT crosses :warn_ai_share_pct, or AI_GROWTH_RATIO crosses :warn_growth_ratio while total account credits stay flat - which means AI is not growing alongside the business, it is displacing the budget. A false positive is a deliberate migration of a workload onto Cortex, where the AI line rises because a warehouse line fell; check NON_AI_CREDITS on the same rows before calling it. Another false positive is a quiet week that shrinks the denominator. A true positive is a steady climb nobody has a decision record for.
-- actions: 1) put this share on the same page as the rest of the bill so it stops being invisible, and name an owner for the AI line - free; 2) create an account-level resource monitor with a NOTIFY threshold, understanding that it will not suspend Cortex, and pin explicit models where a default is being used at scale - config; 3) if the trend is real and the workload is wanted, agree the ceiling explicitly and buy against it, rather than discovering it - spend
-- next: ai_cortex_function_spend (if you need to know which functions and models the AI line is made of), ai_cortex_agent_usage (if agents are the callers), ai_cortex_analyst_spend (if Analyst is the caller), ai_cortex_search_spend (if the standing cost is an always-warm index), serverless_credit_exposure (if you want the whole serverless line this sits inside)
-- caveats: This query answers the SHARE question and deliberately does not answer the WHY question - METERING_DAILY_HISTORY has no object, user or model dimension at all, only a service type per day, so every "which model" follow-up has to go to one of the next queries. CREDITS_BILLED is documented as the total credits billed for the account in the day, which makes it an account-level figure repeated on each service-type row; it is therefore reported as a single MAX per day rather than summed, and the day total used for the share arithmetic is the sum of CREDITS_USED, which is the internally consistent choice. The three AI service types are matched by an explicit list for the reason given in confidence_note. The window halves come from :period_days, so an odd value splits unevenly by up to one day, and the growth ratio is undefined until both halves carry AI credits.

WITH daily AS (
  SELECT
    usage_date,
    SUM(credits_used)                                  AS day_credits,
    SUM(credits_used_compute)                          AS day_credits_compute,
    SUM(credits_used_cloud_services)                   AS day_credits_cloud_services,
    SUM(credits_adjustment_cloud_services)             AS day_cloud_services_adjustment,
    MAX(credits_billed)                                AS day_credits_billed,
    SUM(CASE WHEN service_type IN ('AI_SERVICES', 'CORTEX_CODE_CLI', 'CORTEX_CODE_SNOWSIGHT')
             THEN credits_used ELSE 0 END)             AS ai_credits,
    SUM(CASE WHEN service_type = 'AI_SERVICES'          THEN credits_used ELSE 0 END)
                                                       AS ai_services_credits,
    SUM(CASE WHEN service_type IN ('CORTEX_CODE_CLI', 'CORTEX_CODE_SNOWSIGHT')
             THEN credits_used ELSE 0 END)             AS cortex_code_credits,
    SUM(CASE WHEN service_type IN ('WAREHOUSE_METERING', 'WAREHOUSE_METERING_READER')
             THEN credits_used ELSE 0 END)             AS warehouse_credits,
    COUNT(DISTINCT service_type)                       AS distinct_service_types
  FROM snowflake.account_usage.metering_daily_history
  WHERE usage_date >= DATEADD('day', -:period_days, CURRENT_DATE())
  GROUP BY 1
),
halves AS (
  SELECT
    AVG(CASE WHEN usage_date >= DATEADD('day', -(:period_days / 2), CURRENT_DATE())
             THEN ai_credits END)                      AS recent_avg_ai_credits,
    AVG(CASE WHEN usage_date <  DATEADD('day', -(:period_days / 2), CURRENT_DATE())
             THEN ai_credits END)                      AS earlier_avg_ai_credits,
    AVG(CASE WHEN usage_date >= DATEADD('day', -(:period_days / 2), CURRENT_DATE())
             THEN day_credits END)                     AS recent_avg_day_credits,
    AVG(CASE WHEN usage_date <  DATEADD('day', -(:period_days / 2), CURRENT_DATE())
             THEN day_credits END)                     AS earlier_avg_day_credits
  FROM daily
),
scored AS (
  SELECT
    d.usage_date,
    ROUND(d.day_credits, 4)                                                     AS day_credits,
    ROUND(d.ai_credits, 4)                                                      AS ai_credits,
    ROUND(d.ai_services_credits, 4)                                             AS ai_services_credits,
    ROUND(d.cortex_code_credits, 4)                                             AS cortex_code_credits,
    ROUND(d.day_credits - d.ai_credits, 4)                                      AS non_ai_credits,
    ROUND(d.warehouse_credits, 4)                                               AS warehouse_credits,
    ROUND(d.day_credits_compute, 4)                                             AS day_credits_compute,
    ROUND(d.day_credits_cloud_services, 4)                                      AS day_credits_cloud_services,
    ROUND(d.day_cloud_services_adjustment, 4)                                   AS day_cloud_services_adjustment,
    ROUND(d.day_credits_billed, 4)                                              AS day_credits_billed,
    d.distinct_service_types,
    CASE WHEN d.day_credits > 0
         THEN ROUND(100.0 * d.ai_credits / d.day_credits, 2) END                AS ai_share_pct,
    ROUND(h.recent_avg_ai_credits, 4)                                           AS recent_avg_ai_credits,
    ROUND(h.earlier_avg_ai_credits, 4)                                          AS earlier_avg_ai_credits,
    ROUND(h.recent_avg_day_credits, 4)                                          AS recent_avg_day_credits,
    ROUND(h.earlier_avg_day_credits, 4)                                         AS earlier_avg_day_credits,
    CASE WHEN h.earlier_avg_ai_credits > 0
         THEN ROUND(h.recent_avg_ai_credits / h.earlier_avg_ai_credits, 3) END  AS ai_growth_ratio,
    CASE WHEN h.earlier_avg_day_credits > 0
         THEN ROUND(h.recent_avg_day_credits / h.earlier_avg_day_credits, 3) END
                                                                                AS account_growth_ratio,
    d.day_credits                                                               AS day_credits_raw
  FROM daily d
  CROSS JOIN halves h
)
SELECT
  usage_date,
  day_credits,
  ai_credits,
  ai_share_pct,
  ai_services_credits,
  cortex_code_credits,
  non_ai_credits,
  warehouse_credits,
  ai_growth_ratio,
  account_growth_ratio,
  recent_avg_ai_credits,
  earlier_avg_ai_credits,
  recent_avg_day_credits,
  earlier_avg_day_credits,
  day_credits_compute,
  day_credits_cloud_services,
  day_cloud_services_adjustment,
  day_credits_billed,
  distinct_service_types,
  CASE
    WHEN day_credits_raw < :min_day_credits                       THEN 'NOT_ASSESSED'
    WHEN ai_share_pct    >= :critical_ai_share_pct                THEN 'CRITICAL'
    WHEN ai_growth_ratio >= :critical_growth_ratio                THEN 'CRITICAL'
    WHEN ai_share_pct    >= :warn_ai_share_pct                    THEN 'WARN'
    WHEN ai_growth_ratio >= :warn_growth_ratio                    THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY usage_date DESC;
