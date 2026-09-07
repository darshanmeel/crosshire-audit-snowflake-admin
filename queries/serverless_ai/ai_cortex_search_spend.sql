-- query_id: ai_cortex_search_spend
-- title: Cortex Search - what each service costs to keep warm, and which one nobody uses
-- domain: serverless_ai   tier: standard
-- rung: account_usage - INFORMATION_SCHEMA.CORTEX_SEARCH_SERVICES lists the services that exist in one database, and the CORTEX_SEARCH_REFRESH_HISTORY function shows refreshes, but neither carries credits. Cost lives on this rung only.
-- reads: snowflake.account_usage.cortex_search_daily_usage_history, snowflake.account_usage.cortex_search_serving_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - the ACCOUNT_USAGE index lists the daily view in the three-hour family and the serving view in the one-hour family; neither view page publishes its own figure. The two therefore settle at different speeds and the last day of the window will not agree between them.
-- params: :period_days (default 30) rolling window in days; :min_credits (default 1) credits a service must have burned in the window before it is judged; :warn_active_share_pct (default 5) share of a service's credits that came from query-driven or indexing work, below which it looks like an index nobody touches; :critical_active_share_pct (default 1) that share which raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: CORTEX_SEARCH_DAILY_USAGE_HISTORY columns USAGE_DATE, DATABASE_NAME, SCHEMA_NAME, SERVICE_NAME, SERVICE_ID, CONSUMPTION_TYPE, CREDITS, MODEL_NAME and TOKENS are documented at docs.snowflake.com/en/sql-reference/account-usage/cortex_search_daily_usage_history, including the CONSUMPTION_TYPE value list SERVING, EMBED_TEXT_TOKENS and BATCH; TOKENS is documented as VARCHAR and is cast, and USAGE_DATE is documented as TIMESTAMP_LTZ rather than DATE and is truncated rather than assumed. CORTEX_SEARCH_SERVING_USAGE_HISTORY columns START_TIME, END_TIME, DATABASE_NAME, SCHEMA_NAME, SERVICE_NAME, SERVICE_ID and CREDITS are documented on its own page, which also states that serving credits are billed on the SIZE OF THE INDEXED DATA. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, cortex_not_used, no_activity
-- read_this: One row = one Cortex Search service over the window. The two columns that matter are TOTAL_CREDITS and ACTIVE_SHARE_PCT. Serving credits are charged on the size of the index, so they accrue whether or not a single query is ever run - that is the standing cost of having the service at all. ACTIVE_SHARE_PCT is the fraction of the service's credits that came from BATCH and embedding work rather than from simply existing, and it is the closest thing these views support to "is anyone using this".
-- healthy: services carrying real serving credits also carry embedding and batch credits, meaning the index is being refreshed with new data and queried against. Cost per service is proportional to the corpus you expect it to hold.
-- investigate_if: ACTIVE_SHARE_PCT falls below :warn_active_share_pct while TOTAL_CREDITS stays above :min_credits - you are paying to keep an index warm that is neither being refreshed nor being asked anything. A false positive is a stable reference corpus that legitimately never changes and is queried through a path these views do not meter, which is the honest limitation described in the caveats. A true positive is a proof-of-concept service that was never deleted.
-- actions: 1) ask the owning team when the service was last queried by their application, since these views cannot tell you - free; 2) drop the services nobody claims, and where a service is wanted but rarely used, reduce the indexed columns or the corpus so the standing serving cost matches the value - config; 3) if several small services serve one audience, consolidate them into one index rather than paying a standing charge per service - config
-- next: ai_cortex_cost_guardrail (if you want the AI share of the whole bill), ai_cortex_analyst_spend (if this search service backs a semantic model), ai_cortex_function_spend (if the same embedding model is also being called directly)
-- caveats: The limitation to state before anything else: NEITHER view exposes a Cortex Search QUERY COUNT. There is no requests column anywhere in this pair, so "serves almost no queries" cannot be measured directly and is inferred from the credit mix instead - a service whose credits are essentially all SERVING is one whose index is being maintained and, as far as billing can see, not worked. That is a proxy and it is labelled as one. USAGE_DATE is a TIMESTAMP_LTZ, so the daily view is truncated to a date here rather than trusted as one. The two views are joined on database, schema, service name and service id, and a service dropped and recreated under the same name gets a new SERVICE_ID and will appear twice. TOKENS is populated only for EMBED_TEXT_TOKENS rows, which is documented and is not a gap.

WITH daily AS (
  SELECT
    database_name,
    schema_name,
    service_name,
    service_id,
    SUM(credits)                                                                  AS daily_view_credits,
    SUM(CASE WHEN UPPER(consumption_type) = 'SERVING'           THEN credits END) AS serving_credits_daily,
    SUM(CASE WHEN UPPER(consumption_type) = 'BATCH'             THEN credits END) AS batch_credits,
    SUM(CASE WHEN UPPER(consumption_type) = 'EMBED_TEXT_TOKENS' THEN credits END) AS embed_credits,
    SUM(CASE WHEN UPPER(consumption_type) = 'EMBED_TEXT_TOKENS'
             THEN TRY_TO_NUMBER(tokens::VARCHAR) END)                             AS embed_tokens,
    COUNT(DISTINCT TO_DATE(usage_date))                                           AS active_days,
    COUNT(DISTINCT CASE WHEN UPPER(consumption_type) = 'BATCH'
                        THEN TO_DATE(usage_date) END)                             AS days_with_batch,
    MAX(CASE WHEN UPPER(consumption_type) = 'EMBED_TEXT_TOKENS'
             THEN model_name END)                                                 AS embedding_model,
    MIN(TO_DATE(usage_date))                                                      AS first_usage_day,
    MAX(TO_DATE(usage_date))                                                      AS last_usage_day
  FROM snowflake.account_usage.cortex_search_daily_usage_history
  WHERE usage_date >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3, 4
),
serving AS (
  SELECT
    database_name,
    schema_name,
    service_name,
    service_id,
    SUM(credits)          AS serving_credits,
    COUNT(*)              AS serving_windows,
    MIN(start_time)       AS first_served_at,
    MAX(end_time)         AS last_served_at
  FROM snowflake.account_usage.cortex_search_serving_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3, 4
),
combined AS (
  SELECT
    COALESCE(d.database_name, s.database_name)                AS database_name,
    COALESCE(d.schema_name,   s.schema_name)                  AS schema_name,
    COALESCE(d.service_name,  s.service_name)                 AS service_name,
    COALESCE(d.service_id,    s.service_id)                   AS service_id,
    COALESCE(s.serving_credits, d.serving_credits_daily, 0)   AS serving_credits,
    COALESCE(d.batch_credits, 0)                              AS batch_credits,
    COALESCE(d.embed_credits, 0)                              AS embed_credits,
    d.embed_tokens,
    d.embedding_model,
    d.active_days,
    d.days_with_batch,
    d.first_usage_day,
    d.last_usage_day,
    s.serving_windows,
    s.first_served_at,
    s.last_served_at,
    COALESCE(s.serving_credits, d.serving_credits_daily, 0)
      + COALESCE(d.batch_credits, 0)
      + COALESCE(d.embed_credits, 0)                          AS total_credits
  FROM daily d
  FULL OUTER JOIN serving s
    ON  s.database_name = d.database_name
    AND s.schema_name   = d.schema_name
    AND s.service_name  = d.service_name
    AND s.service_id    = d.service_id
),
scored AS (
  SELECT
    c.*,
    CASE WHEN c.total_credits > 0
         THEN ROUND(100.0 * (c.batch_credits + c.embed_credits) / c.total_credits, 2) END
                                                              AS active_share_pct,
    CASE WHEN c.total_credits > 0
         THEN ROUND(100.0 * c.serving_credits / c.total_credits, 2) END
                                                              AS standing_share_pct
  FROM combined c
)
SELECT
  database_name,
  schema_name,
  service_name,
  service_id,
  ROUND(total_credits, 5)     AS total_credits,
  ROUND(serving_credits, 5)   AS serving_credits,
  ROUND(batch_credits, 5)     AS batch_credits,
  ROUND(embed_credits, 5)     AS embed_credits,
  embed_tokens,
  embedding_model,
  active_share_pct,
  standing_share_pct,
  active_days,
  days_with_batch,
  serving_windows,
  first_usage_day,
  last_usage_day,
  first_served_at,
  last_served_at,
  CASE
    WHEN total_credits < :min_credits                     THEN 'NOT_ASSESSED'
    WHEN active_share_pct <= :critical_active_share_pct   THEN 'CRITICAL'
    WHEN active_share_pct <= :warn_active_share_pct       THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY total_credits DESC NULLS LAST, active_share_pct ASC NULLS FIRST;
