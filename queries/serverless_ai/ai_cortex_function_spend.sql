-- query_id: ai_cortex_function_spend
-- title: Which Cortex AI functions and models burn the credits and the tokens
-- domain: serverless_ai   tier: standard
-- rung: account_usage - there is no INFORMATION_SCHEMA view for Cortex usage at all. Token accounting is account-wide billing metadata and ACCOUNT_USAGE is the only rung that carries it.
-- reads: snowflake.account_usage.cortex_functions_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - the view page does not publish a latency figure; the ACCOUNT_USAGE index lists this family as same-day. Treat the newest hours as incomplete and read the window, not the edge.
-- params: :period_days (default 30) rolling window in days; :min_credits (default 0.1) token credits a function-and-model pair must have burned before it is judged; :warn_share_pct (default 25) share of the window's Cortex credits concentrated in one function-and-model pair that raises WARN; :critical_share_pct (default 50) that share which raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: CORTEX_FUNCTIONS_USAGE_HISTORY and its columns START_TIME, END_TIME, FUNCTION_NAME, MODEL_NAME, WAREHOUSE_ID, TOKENS and TOKEN_CREDITS are documented at docs.snowflake.com/en/sql-reference/account-usage/cortex_functions_usage_history. Not run against a live account. One thing the same page states and this query must repeat: Snowflake documents this view as NO LONGER UPDATED, naming CORTEX_AISQL_USAGE_HISTORY as its replacement. On an account created or upgraded after that change the view can be present and permanently empty, which is a coverage gap and not a zero - see the caveats before reporting "no AI spend".
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, cortex_not_used, no_activity
-- read_this: One row = one Cortex function paired with one model over the window. The two columns that matter are TOKEN_CREDITS and CREDITS_PER_MILLION_TOKENS. The first is what that pair cost; the second is the unit price you are actually paying for it, and it is the column that makes two models comparable when one is called ten times as often as the other. MODEL_NAME is empty for functions that take no model argument, which is documented and is not a data defect.
-- healthy: spend is spread across the functions you meant to be using, CREDITS_PER_MILLION_TOKENS matches the model tier you chose, and no single pair dominates the window unless you deliberately built on one model.
-- investigate_if: one function-and-model pair crosses :warn_share_pct of all Cortex credits, or a large model appears against a function that a smaller one would answer just as well. A false positive is a deliberate single-model architecture, where concentration is the design. A true positive is a default model that nobody chose being used at scale because it was the parameter left unset.
-- actions: 1) list the callers of the dominant function by looking up the WAREHOUSE_ID that ran them and asking that team what they are doing - free; 2) pin an explicit, smaller model where the task does not need the large one, and cache or batch the calls that repeat on the same input - config; 3) if the volume is real and wanted, move the workload onto provisioned throughput rather than paying per token at retail - spend
-- next: ai_cortex_cost_guardrail (if you want the share of the whole bill this represents), ai_cortex_agent_usage (if the calls are coming from an agent rather than from SQL), ai_cortex_analyst_spend (if the same teams are also using Analyst)
-- caveats: The deprecation stated in confidence_note is the first caveat and the most dangerous one: an empty result from this view may mean the account has moved to CORTEX_AISQL_USAGE_HISTORY, not that no AI ran. Verify against METERING_HISTORY, where AI_SERVICES credits will still show, before concluding anything. Beyond that: the view has no user column, so cost cannot be handed to a person from here - WAREHOUSE_ID is the only attribution axis and it is an id, not a name, so it must be resolved elsewhere. Rows are hourly windows rather than individual calls, so COUNT here is metered hours and never a call count. TOKENS is what was billed, which is not the same as what a caller believes it sent.

WITH usage AS (
  SELECT
    function_name,
    NULLIF(TRIM(COALESCE(model_name, '')), '')      AS model_name,
    SUM(token_credits)                              AS token_credits,
    SUM(tokens)                                     AS tokens,
    COUNT(*)                                        AS metered_hours,
    COUNT(DISTINCT warehouse_id)                    AS distinct_warehouses,
    COUNT(DISTINCT TO_DATE(start_time))             AS active_days,
    MIN(start_time)                                 AS first_seen_at,
    MAX(end_time)                                   AS last_seen_at
  FROM snowflake.account_usage.cortex_functions_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
window_total AS (
  SELECT
    SUM(token_credits)   AS all_token_credits,
    SUM(tokens)          AS all_tokens
  FROM usage
),
scored AS (
  SELECT
    u.function_name,
    u.model_name,
    ROUND(u.token_credits, 5)                                              AS token_credits,
    u.tokens,
    u.metered_hours,
    u.distinct_warehouses,
    u.active_days,
    u.first_seen_at,
    u.last_seen_at,
    CASE WHEN u.tokens > 0
         THEN ROUND(1000000.0 * u.token_credits / u.tokens, 5) END         AS credits_per_million_tokens,
    CASE WHEN t.all_token_credits > 0
         THEN ROUND(100.0 * u.token_credits / t.all_token_credits, 2) END  AS share_of_cortex_credits_pct,
    CASE WHEN t.all_tokens > 0
         THEN ROUND(100.0 * u.tokens / t.all_tokens, 2) END                AS share_of_cortex_tokens_pct,
    ROUND(t.all_token_credits, 5)                                          AS window_cortex_credits
  FROM usage u
  CROSS JOIN window_total t
)
SELECT
  function_name,
  model_name,
  token_credits,
  tokens,
  credits_per_million_tokens,
  share_of_cortex_credits_pct,
  share_of_cortex_tokens_pct,
  window_cortex_credits,
  metered_hours,
  active_days,
  distinct_warehouses,
  first_seen_at,
  last_seen_at,
  CASE
    WHEN token_credits < :min_credits                          THEN 'NOT_ASSESSED'
    WHEN share_of_cortex_credits_pct >= :critical_share_pct    THEN 'CRITICAL'
    WHEN share_of_cortex_credits_pct >= :warn_share_pct        THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY token_credits DESC NULLS LAST;
