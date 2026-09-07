-- query_id: ai_cortex_fine_tuning_spend
-- title: Fine-tuning cost per base model, and the runs that look like repeats
-- domain: serverless_ai   tier: deep
-- rung: account_usage - fine-tuning is billed centrally and reported nowhere else. There is no INFORMATION_SCHEMA view and no SHOW command for it.
-- reads: snowflake.account_usage.cortex_fine_tuning_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - the ACCOUNT_USAGE index lists this view in the one-hour family; the view page does not publish its own figure. Rows appear when a training job TERMINATES, so a long run in progress is invisible here no matter how much latency has passed.
-- params: :period_days (default 90) rolling window in days, kept wide because fine-tuning is episodic and a thirty-day window often contains one run and no pattern; :min_credits (default 0.01) token credits below which a metered window is noise; :warn_repeats (default 2) how many times the same base model and the same billed token count may appear before the runs look like repeats; :critical_repeats (default 4) that count which raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: CORTEX_FINE_TUNING_USAGE_HISTORY and all five of its columns - START_TIME, END_TIME, MODEL_NAME, TOKEN_CREDITS and TOKENS - are documented at docs.snowflake.com/en/sql-reference/account-usage/cortex_fine_tuning_usage_history, together with the fact that MODEL_NAME is the BASE model and that the time range brackets jobs that terminated in it. Not run against a live account. The repeat detection here is DERIVED, not reported: the view has no job id, so identical billed token counts against the same base model is the only repeat signature the data supports, and it is labelled as a signature rather than as a fact.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, cortex_not_used, no_activity
-- read_this: One row = one base model paired with one billed token count, over the window. The two columns that matter are TOKEN_CREDITS and OCCURRENCES. Fine-tuning the same base model on the same corpus bills the same token count every time, so an OCCURRENCES above one against an identical TOKENS value is the shape of a job that was run again - a retry, a forgotten schedule, or two teams training the same thing.
-- healthy: OCCURRENCES is one for every row, the base models are ones somebody chose deliberately, and total credits match the number of training runs the team says it did.
-- investigate_if: OCCURRENCES crosses :warn_repeats on a row carrying real credits - the same training appears to have been paid for several times. A false positive is genuine iterative training where each run really does process the same corpus size with different hyperparameters, which is legitimate and expensive and should be a decision rather than an accident. Another false positive is coincidence on very small token counts, which is why :min_credits exists. A true positive is a pipeline that re-trains on every deploy.
-- actions: 1) ask the owning team how many fine-tuning runs they intended in this window and compare it against OCCURRENCES - free; 2) put a manual gate in front of the training step so it cannot be triggered by an ordinary deploy, and record which adapter came from which run - config; 3) if repeated training is genuinely needed, budget it as a recurring line and check whether a smaller base model reaches the same quality for fewer tokens - spend
-- next: ai_cortex_function_spend (if the fine-tuned models are then being called at volume), ai_cortex_cost_guardrail (if you want the AI share of the whole bill)
-- caveats: The view has NO job identifier, NO job name, NO user and NO output-model name, so this query cannot tell you who ran a job or which adapter it produced - only that a base model was trained and what it cost. The repeat signature is exactly as strong as the assumption that identical token counts mean identical corpora, and no stronger; two different corpora of the same size collide. Rows bracket jobs by TERMINATION time, so a job that started before the window and finished inside it is fully counted here, and a job that started inside and has not finished is entirely absent. TOKEN_CREDITS is metered credits and not currency.

WITH runs AS (
  SELECT
    model_name,
    tokens,
    SUM(token_credits)                      AS token_credits,
    COUNT(*)                                AS occurrences,
    COUNT(DISTINCT TO_DATE(start_time))     AS distinct_days,
    MIN(start_time)                         AS first_terminated_window,
    MAX(end_time)                           AS last_terminated_window,
    SUM(DATEDIFF('second', start_time, end_time)) AS total_metered_seconds
  FROM snowflake.account_usage.cortex_fine_tuning_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2
),
model_totals AS (
  SELECT
    model_name,
    SUM(token_credits)  AS model_token_credits,
    SUM(tokens)         AS model_tokens,
    SUM(occurrences)    AS model_metered_windows
  FROM runs
  GROUP BY 1
),
scored AS (
  SELECT
    r.model_name,
    r.tokens,
    ROUND(r.token_credits, 5)                                             AS token_credits,
    r.occurrences,
    r.distinct_days,
    r.first_terminated_window,
    r.last_terminated_window,
    r.total_metered_seconds,
    CASE WHEN r.tokens > 0
         THEN ROUND(1000000.0 * r.token_credits / r.tokens, 5) END        AS credits_per_million_tokens,
    ROUND(m.model_token_credits, 5)                                       AS model_token_credits,
    m.model_tokens,
    m.model_metered_windows,
    CASE WHEN m.model_token_credits > 0
         THEN ROUND(100.0 * r.token_credits / m.model_token_credits, 2) END
                                                                          AS share_of_model_credits_pct,
    CASE WHEN r.occurrences > 1
         THEN ROUND(r.token_credits * (r.occurrences - 1) / r.occurrences, 5) END
                                                                          AS credits_in_apparent_repeats
  FROM runs r
  JOIN model_totals m
    ON m.model_name = r.model_name
)
SELECT
  model_name              AS base_model_name,
  tokens                  AS billed_tokens_per_occurrence,
  occurrences,
  token_credits,
  credits_per_million_tokens,
  credits_in_apparent_repeats,
  share_of_model_credits_pct,
  model_token_credits,
  model_tokens,
  model_metered_windows,
  distinct_days,
  total_metered_seconds,
  first_terminated_window,
  last_terminated_window,
  CASE
    WHEN token_credits < :min_credits            THEN 'NOT_ASSESSED'
    WHEN occurrences >= :critical_repeats        THEN 'CRITICAL'
    WHEN occurrences >= :warn_repeats            THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY occurrences DESC, token_credits DESC NULLS LAST;
