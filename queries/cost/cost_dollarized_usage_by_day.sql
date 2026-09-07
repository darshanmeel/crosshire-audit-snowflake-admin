-- query_id: cost_dollarized_usage_by_day
-- title: What each day's usage actually cost in currency - already multiplied out by Snowflake
-- domain: cost   tier: standard
-- rung: organization_usage - the money is here and nowhere else. This view is the one place you do not have to multiply credits by a rate yourself, which also makes it the arbiter when your own multiplication and Snowflake's disagree.
-- reads: snowflake.organization_usage.usage_in_currency_daily
-- requires: the ORGANIZATION_BILLING_VIEWER database role on the SNOWFLAKE database, queried from the organization account (or an ORGADMIN-enabled account)
-- freshness: LAGGED - up to 72 hours, the longest lag anywhere in this library. The last few days are structurally incomplete, which is why :ignore_recent_days exists rather than being left to the reader to remember.
-- params: :period_days (default 60) rolling window of usage days; :ignore_recent_days (default 3) days newer than this are returned but scored NOT_ASSESSED, because the 72-hour lag makes them partial; :day_spike_warn_ratio (default 1.5) a day's spend as a multiple of the window's median day that raises WARN; :day_spike_critical_ratio (default 2.5) the same multiple that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: ORGANIZATION_NAME, CONTRACT_NUMBER, ACCOUNT_NAME, ACCOUNT_LOCATOR, REGION, SERVICE_LEVEL, USAGE_DATE, USAGE_TYPE, USAGE, CURRENCY, USAGE_IN_CURRENCY, BALANCE_SOURCE, BILLING_TYPE, RATING_TYPE, SERVICE_TYPE and IS_ADJUSTMENT are the complete documented column list. The docs state that the unit of USAGE depends on RATING_TYPE, which is why usage units are never summed across rating types here. Not run live.
-- empty_if: org_scope_required, account_usage_lag, no_activity
-- read_this: One row = one account, one day, one SERVICE_TYPE, in one currency. SPEND_IN_CURRENCY is the money for that line; DAY_SPEND_IN_CURRENCY beside it is the whole day for that account, and it is repeated on every row of the day on purpose - a service line only means something against the day it sits in. The status is a verdict on the DAY, not on the line.
-- healthy: day totals cluster around the window median with a weekly rhythm you recognise, and the service-type mix is stable. A slowly rising floor is a more important finding than any single spike and shows up here as the median itself moving between runs.
-- investigate_if: a day's spend is at or above :day_spike_warn_ratio times the median day - then read down its rows to see which SERVICE_TYPE moved. A new service type appearing with real money attached is worth as much attention as a big number on a familiar one, because it means a feature was switched on that nobody costed. False positive: the newest days are partial by construction and are deliberately NOT_ASSESSED; a genuine month-end or quarter-end batch will spike every cycle and is a rhythm rather than an anomaly.
-- actions: 1) identify the service type behind the spike day, then cross to the ACCOUNT_USAGE query for that service to find the object - money here, objects there (free); 2) if the mover is warehouse metering, act on the warehouse; if it is a serverless service type, remember no resource monitor governs it and the fix has to be in the feature's own configuration (config); 3) only consider a contract or region change once the same shape has held for several windows (spend).
-- next: cost_effective_rate_sheet (if a service line's money does not match the credits you counted), cost_capacity_runway (if spend is rising and you need to know when the balance runs out), cost_credits_by_warehouse_day (if warehouse metering is the mover and you need the object behind it), cost_data_transfer_egress (if a data-transfer line is the mover)
-- covers: ORG-WIDE and ALREADY PRICED. Because it is org-wide, one account's spike is visible next to its siblings - something no ACCOUNT_USAGE view can do. What it cannot do is name an object: there is no warehouse, table or query in this view, only service types. Pair it with the ACCOUNT_USAGE domain queries for that.
-- caveats: Currency is part of the grouping and is never summed across - adding EUR to USD produces a number that means nothing, and this query will show them as separate rows rather than quietly adding them. USAGE units are likewise not summed across RATING_TYPE, because credits and terabytes share a column. Adjustment rows are separated into their own column rather than netted into spend, so a rebate does not silently make a day look cheap. The median that the spike ratio is measured against is computed over the same window the query returns, including its partial newest days - widen :period_days if the window is short enough for that to matter. Day boundaries and the 72-hour lag mean this view and ACCOUNT_USAGE will not agree on the newest days even when both are correct.

WITH usage AS (
  SELECT
    usage_date,
    account_name,
    account_locator,
    region,
    currency,
    service_type,
    rating_type,
    balance_source,
    COALESCE(is_adjustment, FALSE)    AS is_adjustment,
    COALESCE(usage, 0)                AS usage_units,
    COALESCE(usage_in_currency, 0)    AS amount_in_currency
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE usage_date >= DATEADD('day', -:period_days, CURRENT_DATE())
),
by_line AS (
  SELECT
    usage_date,
    account_name,
    account_locator,
    region,
    currency,
    service_type,
    rating_type,
    COUNT(DISTINCT balance_source)                     AS balance_sources,
    SUM(IFF(is_adjustment, 0, usage_units))            AS usage_units,
    SUM(IFF(is_adjustment, 0, amount_in_currency))     AS spend_in_currency,
    SUM(IFF(is_adjustment, amount_in_currency, 0))     AS adjustment_in_currency
  FROM usage
  GROUP BY 1, 2, 3, 4, 5, 6, 7
),
day_totals AS (
  SELECT
    usage_date,
    account_name,
    currency,
    SUM(spend_in_currency) AS day_spend_in_currency
  FROM by_line
  GROUP BY 1, 2, 3
),
day_baseline AS (
  SELECT
    account_name,
    currency,
    MEDIAN(day_spend_in_currency) AS median_day_spend_in_currency
  FROM day_totals
  GROUP BY 1, 2
)
SELECT
  l.usage_date,
  l.account_name,
  l.account_locator,
  l.region,
  l.currency,
  l.service_type,
  l.rating_type,
  l.balance_sources,
  ROUND(l.usage_units, 3)                     AS usage_units,
  ROUND(l.spend_in_currency, 2)               AS spend_in_currency,
  ROUND(l.adjustment_in_currency, 2)          AS adjustment_in_currency,
  ROUND(d.day_spend_in_currency, 2)           AS day_spend_in_currency,
  ROUND(b.median_day_spend_in_currency, 2)    AS median_day_spend_in_currency,
  ROUND(100.0 * l.spend_in_currency / NULLIF(d.day_spend_in_currency, 0), 1) AS pct_of_day_spend,
  ROUND(d.day_spend_in_currency / NULLIF(b.median_day_spend_in_currency, 0), 2) AS day_spend_ratio_to_median,
  CASE
    WHEN l.usage_date > DATEADD('day', -:ignore_recent_days, CURRENT_DATE())          THEN 'NOT_ASSESSED'
    WHEN COALESCE(b.median_day_spend_in_currency, 0) = 0                              THEN 'NOT_ASSESSED'
    WHEN d.day_spend_in_currency
         >= :day_spike_critical_ratio * b.median_day_spend_in_currency                THEN 'CRITICAL'
    WHEN d.day_spend_in_currency
         >= :day_spike_warn_ratio * b.median_day_spend_in_currency                    THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM by_line l
JOIN day_totals d
  ON d.usage_date = l.usage_date
 AND d.account_name = l.account_name
 AND d.currency = l.currency
JOIN day_baseline b
  ON b.account_name = l.account_name
 AND b.currency = l.currency
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  l.usage_date DESC,
  l.spend_in_currency DESC;
