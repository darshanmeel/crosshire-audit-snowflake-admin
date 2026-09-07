-- query_id: ai_cortex_agent_usage
-- title: Which Cortex Agents are used, by whom, and at what token and credit cost
-- domain: serverless_ai   tier: standard
-- rung: account_usage - agent requests are billed centrally and reported only here. No INFORMATION_SCHEMA view and no SHOW command carries agent usage.
-- reads: snowflake.account_usage.cortex_agent_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - documented at up to 1 hour for the view, with the SQL cost-attribution fields lagging up to 8 hours. So an agent request can be visible with its token cost while the SQL it triggered has not yet been priced; the credits on a recent row can still move.
-- params: :period_days (default 30) rolling window in days; :min_requests (default 5) requests an agent-and-user pair needs before its cost per request is judged; :warn_credits_per_request (default 0.5) token credits per request that raises WARN; :critical_credits_per_request (default 2.0) credits per request that raises CRITICAL; :warn_user_share_pct (default 70) share of one agent's credits held by a single user that raises WARN
-- confidence: confirmed-docs
-- confidence_note: CORTEX_AGENT_USAGE_HISTORY columns START_TIME, END_TIME, USER_ID, USER_NAME, USER_TAGS, REQUEST_ID, PARENT_REQUEST_ID, AGENT_DATABASE_NAME, AGENT_SCHEMA_NAME, AGENT_ID, AGENT_NAME, AGENT_TAGS, TOKEN_CREDITS, TOKENS, TOKENS_GRANULAR, CREDITS_GRANULAR and METADATA are documented at docs.snowflake.com/en/sql-reference/account-usage/cortex_agent_usage_history, as is the row grain of one row per request and the meaning of PARENT_REQUEST_ID. Not run against a live account. TOKENS_GRANULAR, CREDITS_GRANULAR and METADATA are semi-structured and their internal keys are described only in prose on that page, so this query counts and sizes them rather than reaching inside them for a named key it cannot verify.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, cortex_not_used, no_activity
-- read_this: One row = one agent paired with one user over the window. The two columns that matter are TOP_LEVEL_REQUESTS and CREDITS_PER_TOP_LEVEL_REQUEST. An agent turn fans out into sub-requests that each get their own row, linked by PARENT_REQUEST_ID, so counting every row overstates how many questions were actually asked - TOP_LEVEL_REQUESTS counts only the rows with no parent, which is what a person would call a conversation turn, and the cost per one of those is the number worth comparing between agents.
-- healthy: cost per top-level request is stable across users of the same agent, the fan-out ratio is small and predictable, and the user list matches who the agent was built for.
-- investigate_if: CREDITS_PER_TOP_LEVEL_REQUEST crosses :warn_credits_per_request, or FANOUT_RATIO is far higher for one agent than for its peers - an agent that calls six tools to answer a question it could answer with one is paying for its own indecision. Also investigate an agent whose credits sit almost entirely with one user. A false positive is a deliberately deep research agent where fan-out is the design. A true positive is an agent whose tool list has grown until every turn touches all of it.
-- actions: 1) read one expensive REQUEST_ID and its children and see which tool the turns are spending on - free; 2) trim the agent tool list, tighten the instructions so it stops calling everything, and pin a smaller model for the routing step - config; 3) where the usage is real, attribute it: the USER_TAGS and AGENT_TAGS columns exist so agent spend can be charged back, and using them is cheaper than arguing about it later - config
-- next: ai_cortex_function_spend (if the agent turns are dominated by direct model calls), ai_cortex_analyst_spend (if the agent is routing to Analyst), ai_cortex_cost_guardrail (if you want the AI share of the whole bill)
-- caveats: The fan-out arithmetic assumes PARENT_REQUEST_ID is NULL on exactly the top-level request, which is what the documentation describes; if a version populates it differently the ratio changes meaning while still returning a number, so sanity-check FANOUT_RATIO against one known conversation before trusting it at scale. The eight-hour lag on SQL cost attribution means a recent window UNDERSTATES agent cost, and re-running the same window a day later will legitimately give a higher figure. TOKENS_GRANULAR and CREDITS_GRANULAR carry the per-model breakdown, and this query reports only how many entries they hold rather than parsing keys it could not doc-verify - open those arrays by hand on the worst rows. An agent dropped and recreated under the same name gets a new AGENT_ID and appears twice.

WITH requests AS (
  SELECT
    agent_database_name,
    agent_schema_name,
    agent_name,
    agent_id,
    user_name,
    request_id,
    parent_request_id,
    token_credits,
    tokens,
    start_time,
    end_time,
    ARRAY_SIZE(tokens_granular)                                        AS tokens_granular_entries,
    ARRAY_SIZE(credits_granular)                                       AS credits_granular_entries,
    ARRAY_SIZE(agent_tags)                                             AS agent_tag_count,
    ARRAY_SIZE(user_tags)                                              AS user_tag_count,
    DATEDIFF('millisecond', start_time, end_time)                      AS latency_ms
  FROM snowflake.account_usage.cortex_agent_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
by_agent_user AS (
  SELECT
    agent_database_name,
    agent_schema_name,
    agent_name,
    agent_id,
    user_name,
    COUNT(*)                                                           AS request_rows,
    COUNT(CASE WHEN parent_request_id IS NULL THEN 1 END)              AS top_level_requests,
    COUNT(CASE WHEN parent_request_id IS NOT NULL THEN 1 END)          AS sub_requests,
    SUM(token_credits)                                                 AS token_credits,
    SUM(tokens)                                                        AS tokens,
    AVG(latency_ms)                                                    AS avg_latency_ms,
    MAX(latency_ms)                                                    AS max_latency_ms,
    MAX(tokens_granular_entries)                                       AS max_tokens_granular_entries,
    MAX(credits_granular_entries)                                      AS max_credits_granular_entries,
    MAX(agent_tag_count)                                               AS agent_tag_count,
    MAX(user_tag_count)                                                AS user_tag_count,
    COUNT(DISTINCT TO_DATE(start_time))                                AS active_days,
    MIN(start_time)                                                    AS first_request_at,
    MAX(end_time)                                                      AS last_request_at
  FROM requests
  GROUP BY 1, 2, 3, 4, 5
),
agent_totals AS (
  SELECT
    agent_id,
    SUM(token_credits)          AS agent_token_credits,
    SUM(top_level_requests)     AS agent_top_level_requests,
    COUNT(DISTINCT user_name)   AS agent_distinct_users,
    MAX(token_credits)          AS agent_top_user_credits
  FROM by_agent_user
  GROUP BY 1
),
scored AS (
  SELECT
    a.agent_database_name,
    a.agent_schema_name,
    a.agent_name,
    a.agent_id,
    a.user_name,
    a.request_rows,
    a.top_level_requests,
    a.sub_requests,
    ROUND(a.token_credits, 5)                                                     AS token_credits,
    a.tokens,
    a.active_days,
    ROUND(a.avg_latency_ms, 0)                                                    AS avg_latency_ms,
    a.max_latency_ms,
    a.max_tokens_granular_entries,
    a.max_credits_granular_entries,
    a.agent_tag_count,
    a.user_tag_count,
    a.first_request_at,
    a.last_request_at,
    CASE WHEN a.top_level_requests > 0
         THEN ROUND(a.token_credits / a.top_level_requests, 6) END                AS credits_per_top_level_request,
    CASE WHEN a.top_level_requests > 0
         THEN ROUND(a.tokens / a.top_level_requests, 1) END                       AS tokens_per_top_level_request,
    CASE WHEN a.top_level_requests > 0
         THEN ROUND(a.request_rows * 1.0 / a.top_level_requests, 2) END           AS fanout_ratio,
    ROUND(t.agent_token_credits, 5)                                               AS agent_token_credits,
    t.agent_top_level_requests,
    t.agent_distinct_users,
    CASE WHEN t.agent_token_credits > 0
         THEN ROUND(100.0 * a.token_credits / t.agent_token_credits, 2) END       AS user_share_of_agent_pct,
    CASE WHEN t.agent_token_credits > 0
         THEN ROUND(100.0 * t.agent_top_user_credits / t.agent_token_credits, 2) END
                                                                                  AS agent_top_user_share_pct
  FROM by_agent_user a
  JOIN agent_totals t
    ON t.agent_id = a.agent_id
)
SELECT
  agent_database_name,
  agent_schema_name,
  agent_name,
  agent_id,
  user_name,
  top_level_requests,
  sub_requests,
  request_rows,
  fanout_ratio,
  token_credits,
  tokens,
  credits_per_top_level_request,
  tokens_per_top_level_request,
  user_share_of_agent_pct,
  agent_token_credits,
  agent_top_level_requests,
  agent_distinct_users,
  agent_top_user_share_pct,
  active_days,
  avg_latency_ms,
  max_latency_ms,
  max_tokens_granular_entries,
  max_credits_granular_entries,
  agent_tag_count,
  user_tag_count,
  first_request_at,
  last_request_at,
  CASE
    WHEN top_level_requests < :min_requests                                   THEN 'NOT_ASSESSED'
    WHEN credits_per_top_level_request >= :critical_credits_per_request       THEN 'CRITICAL'
    WHEN credits_per_top_level_request >= :warn_credits_per_request           THEN 'WARN'
    WHEN agent_top_user_share_pct      >= :warn_user_share_pct                THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY token_credits DESC NULLS LAST, credits_per_top_level_request DESC NULLS LAST;
