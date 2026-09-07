-- query_id: ai_cortex_analyst_spend
-- title: Cortex Analyst cost per day, and how few people it is really for
-- domain: serverless_ai   tier: standard
-- rung: account_usage - CORTEX_ANALYST_USAGE_HISTORY has no INFORMATION_SCHEMA twin and no SHOW equivalent. This question exists on one rung only.
-- reads: snowflake.account_usage.cortex_analyst_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - the ACCOUNT_USAGE index lists this view in the one-hour family; the view page itself does not publish a latency figure. Today is always understated.
-- params: :period_days (default 30) rolling window in days; :min_day_credits (default 0.1) credits a day must carry before its concentration is judged; :warn_user_share_pct (default 50) share of a day's Analyst credits held by one user that raises WARN; :critical_user_share_pct (default 80) that share which raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: CORTEX_ANALYST_USAGE_HISTORY and all five of its columns - START_TIME, END_TIME, REQUEST_COUNT, CREDITS and USERNAME - are documented at docs.snowflake.com/en/sql-reference/account-usage/cortex_analyst_usage_history. The credits column is named CREDITS on this view, not CREDITS_USED as on most of the serverless views, and that difference is real and is honoured here. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, cortex_not_used, no_activity
-- read_this: One row = one day x one user. The two columns that matter are CREDITS and CREDITS_PER_REQUEST. The first is what that person cost that day; the second is how expensive each of their questions was, which is the number that separates "a lot of cheap questions" from "a handful of very expensive ones". DAY_TOP_USER_SHARE_PCT is a property of the DAY and repeats across its rows, so you can sort by cost and still see whether the day was one person or a department.
-- healthy: cost per request is stable, the user list looks like the audience you rolled Analyst out to, and no single day is dominated by one person unless that person is the pilot.
-- investigate_if: DAY_TOP_USER_SHARE_PCT crosses :warn_user_share_pct on days that carry real credits - a tool bought for a team that one person is using is either a rollout that stalled or an automated caller wearing a human name. Also investigate a CREDITS_PER_REQUEST that climbs without the request count changing. A false positive is a deliberate pilot with a single named user. A true positive is a service account issuing Analyst requests in a loop.
-- actions: 1) confirm each top USERNAME is a person and not an integration running on someone's credentials - free; 2) if the audience is one team, scope the semantic model and the role that can reach Analyst to that team, so the spend is attributable and bounded - config; 3) if usage is real and growing, agree a per-team ceiling before the trend sets the budget for you - spend
-- next: ai_cortex_cost_guardrail (if you want the share of the whole bill AI now represents), ai_cortex_agent_usage (if the same users are also driving agents), ai_cortex_search_spend (if the semantic model is backed by a search service)
-- caveats: The view carries no semantic-model name, no request id and no model name, so a question that costs ten times its peers cannot be traced to the model or the semantic view that made it expensive - USERNAME is the only dimension there is. Rows are time windows over a set of messages rather than one row per message, so REQUEST_COUNT is the only call counter and dividing credits by it gives an average across the window, not a per-request cost. A user who is a service account is indistinguishable from a human here; that judgement has to be made outside this query.

WITH usage AS (
  SELECT
    TO_DATE(start_time)                    AS usage_day,
    username,
    SUM(credits)                           AS credits,
    SUM(request_count)                     AS request_count,
    COUNT(*)                               AS metered_windows,
    MIN(start_time)                        AS first_request_window,
    MAX(end_time)                          AS last_request_window
  FROM snowflake.account_usage.cortex_analyst_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
day_totals AS (
  SELECT
    usage_day,
    SUM(credits)                           AS day_credits,
    SUM(request_count)                     AS day_requests,
    COUNT(DISTINCT username)               AS day_distinct_users,
    MAX(credits)                           AS day_top_user_credits
  FROM usage
  GROUP BY 1
),
scored AS (
  SELECT
    u.usage_day,
    u.username,
    ROUND(u.credits, 5)                                                     AS credits,
    u.request_count,
    u.metered_windows,
    u.first_request_window,
    u.last_request_window,
    CASE WHEN u.request_count > 0
         THEN ROUND(u.credits / u.request_count, 6) END                     AS credits_per_request,
    ROUND(d.day_credits, 5)                                                 AS day_credits,
    d.day_requests,
    d.day_distinct_users,
    CASE WHEN d.day_credits > 0
         THEN ROUND(100.0 * u.credits / d.day_credits, 2) END               AS user_share_of_day_pct,
    CASE WHEN d.day_credits > 0
         THEN ROUND(100.0 * d.day_top_user_credits / d.day_credits, 2) END  AS day_top_user_share_pct,
    d.day_credits                                                           AS day_credits_raw
  FROM usage u
  JOIN day_totals d
    ON d.usage_day = u.usage_day
)
SELECT
  usage_day,
  username,
  credits,
  request_count,
  credits_per_request,
  user_share_of_day_pct,
  day_credits,
  day_requests,
  day_distinct_users,
  day_top_user_share_pct,
  metered_windows,
  first_request_window,
  last_request_window,
  CASE
    WHEN day_credits_raw < :min_day_credits                     THEN 'NOT_ASSESSED'
    WHEN day_top_user_share_pct >= :critical_user_share_pct     THEN 'CRITICAL'
    WHEN day_top_user_share_pct >= :warn_user_share_pct         THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY usage_day DESC, credits DESC NULLS LAST;
