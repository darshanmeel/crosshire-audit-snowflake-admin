-- query_id: cost_effective_rate_sheet
-- title: What this account actually pays per credit and per TB - the contracted rate, not a list price
-- domain: cost   tier: standard
-- rung: organization_usage - the ONLY rung in Snowflake that knows a currency. Every ACCOUNT_USAGE view in this library counts credits and bytes; nothing below this rung can turn either into money.
-- reads: snowflake.organization_usage.rate_sheet_daily
-- requires: the ORGANIZATION_BILLING_VIEWER database role on the SNOWFLAKE database, queried from the organization account (or an ORGADMIN-enabled account). ACCOUNTADMIN on an ordinary account is NOT enough and this is the usual reason the query returns nothing.
-- freshness: LAGGED - up to 24 hours. Slower than every ACCOUNT_USAGE view here, which matters when a contract change has just landed: the credits move first and the rate follows a day later.
-- params: :period_days (default 30) rolling window of rate-sheet days to inspect for movement; :rate_change_warn_pct (default 1) percentage move in the effective rate across the window that raises WARN; :rate_change_critical_pct (default 5) the same move that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: DATE, ORGANIZATION_NAME, CONTRACT_NUMBER, ACCOUNT_NAME, ACCOUNT_LOCATOR, REGION, SERVICE_LEVEL, USAGE_TYPE, CURRENCY, EFFECTIVE_RATE, SERVICE_TYPE, RATING_TYPE, BILLING_TYPE and IS_ADJUSTMENT are the complete documented column list. The docs define EFFECTIVE_RATE as the rate after contract discounts, and RATING_TYPE as compute, storage or other - both are relied on here. Not run live; which exact USAGE_TYPE strings a given contract emits is contract-specific and is therefore never matched against a hard-coded list.
-- empty_if: org_scope_required, account_usage_lag, no_activity
-- read_this: One row = one priced thing - a USAGE_TYPE on one account in one region under one contract - and EFFECTIVE_RATE_LATEST is the number you multiply your credits by. RATING_TYPE beside it tells you what the rate is PER: compute rates are per credit, storage rates are per TB, and multiplying the wrong one is the single most common way a spend model comes out wrong by an order of magnitude.
-- healthy: one rate per usage type, flat across the window, in one currency. A rate sheet that does not move is a rate sheet you can build a forecast on.
-- investigate_if: the effective rate moved by :rate_change_warn_pct or more inside the window - every credit forecast built before that day is now wrong, and nothing in ACCOUNT_USAGE will ever tell you. Also investigate more than one CURRENCY appearing across your accounts, or a usage type present in one region and absent in another: both quietly break any spend model that sums across accounts. False positive: a contract genuinely renegotiated mid-window shows a real, expected step - the point of the flag is that you should KNOW about it, not that it is wrong.
-- actions: 1) record the current rate per usage type somewhere your own reporting reads, so a silent change is detectable next month (free); 2) if the rate moved and nobody on the team knew, get the contract change confirmed before republishing any chargeback numbers built on the old one (free); 3) where several accounts in the org carry different rates for the same usage type, route new workloads to the cheaper region only when latency and residency allow it (config).
-- next: cost_dollarized_usage_by_day (if you want the money already multiplied out rather than the rate), cost_capacity_runway (if you need to know how long the prepaid balance survives at this rate), cost_credits_by_warehouse_day (if you now want to price a specific warehouse in this currency)
-- covers: ORG-WIDE. Every account under the contract appears here, which is exactly why it is the rung that can compare two accounts. It carries no usage at all - it is a price list, and the quantities live in ACCOUNT_USAGE or, already multiplied, in cost_dollarized_usage_by_day. Adjustment rows are excluded here by default because a rebate line is not a rate.
-- caveats: EFFECTIVE_RATE is documented as NUMBER with two decimal places, so a very small per-unit rate can round in the view itself - never re-derive a rate by dividing money by credits and expect it to match to the penny. The DATE column is literally named DATE; it is not a Snowflake reserved word but some clients still object, in which case quote it. The window-start rate used for the movement check is the earliest rate OBSERVED in the window, not the rate on the first calendar day, so a usage type that only started being priced recently will report a short observation count and stay NOT_ASSESSED. BILLING_TYPE distinguishes consumption from rebates, support credits and deployment fees; they are all kept in separate rows here rather than blended, because only the consumption rows are the price of a credit.

WITH rates AS (
  SELECT
    r.date              AS rate_date,
    r.organization_name,
    r.contract_number,
    r.account_name,
    r.account_locator,
    r.region,
    r.service_level,
    r.usage_type,
    r.service_type,
    r.rating_type,
    r.billing_type,
    r.currency,
    r.effective_rate
  FROM snowflake.organization_usage.rate_sheet_daily r
  WHERE r.date >= DATEADD('day', -:period_days, CURRENT_DATE())
    AND COALESCE(r.is_adjustment, FALSE) = FALSE
),
agg AS (
  SELECT
    organization_name,
    contract_number,
    account_name,
    account_locator,
    region,
    service_level,
    usage_type,
    service_type,
    rating_type,
    billing_type,
    currency,
    COUNT(*)                              AS rate_days_observed,
    MIN(rate_date)                        AS first_rate_date,
    MAX(rate_date)                        AS latest_rate_date,
    MIN_BY(effective_rate, rate_date)     AS effective_rate_window_start,
    MAX_BY(effective_rate, rate_date)     AS effective_rate_latest,
    MIN(effective_rate)                   AS effective_rate_min,
    MAX(effective_rate)                   AS effective_rate_max,
    COUNT(DISTINCT effective_rate)        AS distinct_rates_seen
  FROM rates
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
),
scored AS (
  SELECT
    agg.*,
    100.0 * (effective_rate_latest - effective_rate_window_start)
          / NULLIF(effective_rate_window_start, 0) AS rate_change_pct,
    CASE rating_type
      WHEN 'compute' THEN 'per credit'
      WHEN 'storage' THEN 'per TB per month'
      ELSE 'per unit - see RATING_TYPE'
    END AS rate_unit
  FROM agg
)
SELECT
  account_name,
  account_locator,
  region,
  contract_number,
  service_level,
  usage_type,
  service_type,
  rating_type,
  billing_type,
  rate_unit,
  currency,
  effective_rate_latest,
  effective_rate_window_start,
  effective_rate_min,
  effective_rate_max,
  distinct_rates_seen,
  ROUND(rate_change_pct, 3) AS rate_change_pct,
  rate_days_observed,
  first_rate_date,
  latest_rate_date,
  CASE
    WHEN rate_days_observed < 2                                        THEN 'NOT_ASSESSED'
    WHEN effective_rate_window_start IS NULL                           THEN 'NOT_ASSESSED'
    WHEN effective_rate_window_start = 0                               THEN 'NOT_ASSESSED'
    WHEN ABS(rate_change_pct) >= :rate_change_critical_pct             THEN 'CRITICAL'
    WHEN ABS(rate_change_pct) >= :rate_change_warn_pct                 THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  account_name,
  rating_type,
  usage_type;
