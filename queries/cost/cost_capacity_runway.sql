-- query_id: cost_capacity_runway
-- title: How fast prepaid capacity is draining, and the date it runs out at the current burn
-- domain: cost   tier: deep
-- rung: organization_usage - a balance is a contract fact, and no ACCOUNT_USAGE view has ever seen one. This is the only rung that can answer when the money runs out rather than how many credits were used.
-- reads: snowflake.organization_usage.remaining_balance_daily, snowflake.organization_usage.usage_in_currency_daily
-- requires: the ORGANIZATION_BILLING_VIEWER database role on the SNOWFLAKE database, queried from the organization account. REMAINING_BALANCE_DAILY is additionally visible only to the PRIMARY funding organization when several organizations share a capacity contract - a secondary org gets an empty result, not an error.
-- freshness: LAGGED - up to 72 hours on both views. A runway measured today is a runway as of roughly three days ago, which matters most in exactly the situation where the number is small.
-- params: :period_days (default 90) window of balance observations used to measure the drawdown trend; :burn_window_days (default 30) the more recent window whose average daily spend is used as the forward burn rate; :runway_warn_days (default 90) projected days of remaining prepaid balance that raise WARN; :runway_critical_days (default 30) the same projection that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: ORGANIZATION_NAME, CONTRACT_NUMBER, DATE, CURRENCY, FREE_USAGE_BALANCE, CAPACITY_BALANCE, ON_DEMAND_CONSUMPTION_BALANCE, ROLLOVER_BALANCE and MARKETPLACE_CAPACITY_DRAWDOWN_BALANCE are the complete documented column list of REMAINING_BALANCE_DAILY; USAGE_DATE, USAGE_IN_CURRENCY, CURRENCY and IS_ADJUSTMENT are documented on USAGE_IN_CURRENCY_DAILY. The docs state that ON_DEMAND_CONSUMPTION_BALANCE is negative, which is why it is reported rather than added. Not run live: the linear projection is this library's arithmetic and Snowflake publishes no runway column.
-- empty_if: org_scope_required, account_usage_lag, no_activity
-- read_this: One row = one contract in one currency, as of its most recent balance observation. PREPAID_REMAINING is what is left to spend; RUNWAY_DAYS is that divided by the faster of two independently measured burn rates - the average daily spend from the usage view, and the observed drawdown of the balance itself. Two estimates rather than one because a contract can drain for reasons that never appear as usage.
-- healthy: runway comfortably beyond :runway_warn_days, the two burn estimates roughly agreeing, and ON_DEMAND_CONSUMPTION_BALANCE at zero - nothing has spilled past the prepaid balance into on-demand pricing yet.
-- investigate_if: runway is at or under :runway_warn_days, or ON_DEMAND_CONSUMPTION_BALANCE is non-zero at all - the second one is not a forecast, it means you are ALREADY paying on-demand rates for some consumption. Also investigate the two burn estimates disagreeing badly: the balance falling faster than usage explains means something is drawing on the contract that the usage view does not show. False positive: a contract that has just been topped up shows a huge drawdown in the window followed by a large balance, which makes the balance-derived burn rate meaningless for a few days.
-- actions: 1) reconcile the two burn estimates and confirm the exhaustion date with whoever owns the contract before anyone is alarmed by it - a three-day-lagged projection is a planning input, not an alert (free); 2) if the runway is short, put resource monitors on the largest uncapped warehouses so the burn cannot accelerate while the contract is being discussed - cost_resource_monitor_coverage says which ones have no ceiling (config); 3) renegotiating or topping up capacity is the only real remedy once the burn rate itself is legitimate (spend).
-- next: cost_dollarized_usage_by_day (if you need which service type is draining the balance), cost_resource_monitor_coverage (if the burn has no ceiling anywhere), cost_effective_rate_sheet (if the burn is rising because the rate moved rather than because usage did)
-- covers: CONTRACT-WIDE, across every account on it. That is the point - runway is a contract property and cannot be computed per account. What it cannot do is attribute: no warehouse, user or query appears here, and the drawdown says nothing about which account caused it. Cross to cost_dollarized_usage_by_day for the per-account split.
-- caveats: The projection is LINEAR - it assumes the next 30 days look like the last :burn_window_days, which is exactly the assumption that fails when a new workload is being onboarded. Treat PROJECTED_EXHAUSTION_DATE as a horizon, never as a date to plan around. The balance-derived burn is (earliest observed balance minus latest) divided by the days between them, so a mid-window top-up makes it negative or absurd; it is reported alongside rather than blended, so you can see when that happened. Adjustment rows are excluded from the usage-derived burn because a rebate is not consumption. Free usage, capacity and rollover are added into one prepaid figure here; if your contract treats them differently, read the three columns separately. Marketplace drawdown is reported but not added, since it draws on capacity through a separate mechanism.

WITH balances AS (
  SELECT
    b.date                                           AS balance_date,
    b.organization_name,
    b.contract_number,
    b.currency,
    COALESCE(b.free_usage_balance, 0)                AS free_usage_balance,
    COALESCE(b.capacity_balance, 0)                  AS capacity_balance,
    COALESCE(b.rollover_balance, 0)                  AS rollover_balance,
    COALESCE(b.on_demand_consumption_balance, 0)     AS on_demand_consumption_balance,
    COALESCE(b.marketplace_capacity_drawdown_balance, 0) AS marketplace_drawdown_balance,
    COALESCE(b.free_usage_balance, 0)
      + COALESCE(b.capacity_balance, 0)
      + COALESCE(b.rollover_balance, 0)              AS prepaid_remaining
  FROM snowflake.organization_usage.remaining_balance_daily b
  WHERE b.date >= DATEADD('day', -:period_days, CURRENT_DATE())
),
balance_trend AS (
  SELECT
    organization_name,
    contract_number,
    currency,
    COUNT(*)                                    AS balance_days_observed,
    MIN(balance_date)                           AS first_balance_date,
    MAX(balance_date)                           AS latest_balance_date,
    MIN_BY(prepaid_remaining, balance_date)     AS prepaid_at_window_start,
    MAX_BY(prepaid_remaining, balance_date)     AS prepaid_remaining,
    MAX_BY(free_usage_balance, balance_date)    AS free_usage_balance,
    MAX_BY(capacity_balance, balance_date)      AS capacity_balance,
    MAX_BY(rollover_balance, balance_date)      AS rollover_balance,
    MAX_BY(on_demand_consumption_balance, balance_date) AS on_demand_consumption_balance,
    MAX_BY(marketplace_drawdown_balance, balance_date)  AS marketplace_drawdown_balance,
    DATEDIFF('day', MIN(balance_date), MAX(balance_date)) AS balance_span_days
  FROM balances
  GROUP BY 1, 2, 3
),
spend_burn AS (
  SELECT
    contract_number,
    currency,
    COUNT(DISTINCT usage_date)                                          AS spend_days_observed,
    SUM(COALESCE(usage_in_currency, 0))                                 AS spend_in_window,
    SUM(COALESCE(usage_in_currency, 0)) / NULLIF(COUNT(DISTINCT usage_date), 0) AS avg_daily_spend
  FROM snowflake.organization_usage.usage_in_currency_daily
  WHERE usage_date >= DATEADD('day', -:burn_window_days, CURRENT_DATE())
    AND COALESCE(is_adjustment, FALSE) = FALSE
  GROUP BY 1, 2
),
combined AS (
  SELECT
    t.organization_name,
    t.contract_number,
    t.currency,
    t.latest_balance_date,
    t.first_balance_date,
    t.balance_days_observed,
    t.balance_span_days,
    t.prepaid_remaining,
    t.prepaid_at_window_start,
    t.free_usage_balance,
    t.capacity_balance,
    t.rollover_balance,
    t.on_demand_consumption_balance,
    t.marketplace_drawdown_balance,
    s.spend_days_observed,
    s.spend_in_window,
    s.avg_daily_spend                                     AS burn_from_usage_per_day,
    (t.prepaid_at_window_start - t.prepaid_remaining)
      / NULLIF(t.balance_span_days, 0)                    AS burn_from_balance_per_day
  FROM balance_trend t
  LEFT JOIN spend_burn s
    ON s.contract_number = t.contract_number
   AND s.currency = t.currency
),
projected AS (
  SELECT
    combined.*,
    GREATEST(
      COALESCE(burn_from_usage_per_day, 0),
      COALESCE(burn_from_balance_per_day, 0)
    )                                                     AS burn_used_per_day,
    prepaid_remaining
      / NULLIF(GREATEST(
          COALESCE(burn_from_usage_per_day, 0),
          COALESCE(burn_from_balance_per_day, 0)
        ), 0)                                             AS runway_days
  FROM combined
)
SELECT
  organization_name,
  contract_number,
  currency,
  latest_balance_date,
  balance_days_observed,
  ROUND(prepaid_remaining, 2)              AS prepaid_remaining,
  ROUND(capacity_balance, 2)               AS capacity_balance,
  ROUND(rollover_balance, 2)               AS rollover_balance,
  ROUND(free_usage_balance, 2)             AS free_usage_balance,
  ROUND(on_demand_consumption_balance, 2)  AS on_demand_consumption_balance,
  ROUND(marketplace_drawdown_balance, 2)   AS marketplace_drawdown_balance,
  spend_days_observed,
  ROUND(spend_in_window, 2)                AS spend_in_burn_window,
  ROUND(burn_from_usage_per_day, 2)        AS burn_from_usage_per_day,
  ROUND(burn_from_balance_per_day, 2)      AS burn_from_balance_per_day,
  ROUND(burn_used_per_day, 2)              AS burn_used_per_day,
  ROUND(runway_days, 1)                    AS runway_days,
  DATEADD('day', FLOOR(runway_days)::INT, latest_balance_date) AS projected_exhaustion_date,
  CASE
    WHEN prepaid_remaining IS NULL                     THEN 'NOT_ASSESSED'
    WHEN burn_used_per_day <= 0                        THEN 'NOT_ASSESSED'
    WHEN runway_days IS NULL                           THEN 'NOT_ASSESSED'
    WHEN runway_days <= :runway_critical_days          THEN 'CRITICAL'
    WHEN runway_days <= :runway_warn_days              THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM projected
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  runway_days ASC NULLS LAST;
