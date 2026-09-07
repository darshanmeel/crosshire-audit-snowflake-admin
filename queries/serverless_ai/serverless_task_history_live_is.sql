-- query_id: serverless_task_history_live_is
-- title: What serverless tasks have done - LIVE, from INFORMATION_SCHEMA
-- domain: serverless_ai   tier: lite
-- rung: information_schema - the live, unlagged twin of serverless_task_cost_and_upsizing. Use it when ACCOUNT_USAGE has not caught up, or to confirm that a task you just changed is metering the way you expected.
-- reads: information_schema.serverless_task_history
-- requires: ACCOUNTADMIN, or the global MONITOR USAGE privilege. This is the one INFORMATION_SCHEMA function on the ladder that is NOT low-privilege - it needs a global grant, but it still needs no IMPORTED PRIVILEGES on SNOWFLAKE and it is not lagged.
-- freshness: LIVE - no ACCOUNT_USAGE latency. History is reported in one-hour increments, so the current partial hour is understated until it closes.
-- params: :period_days (default 7) how far back to ask the table function; the function is documented to support shorter ranges than the ACCOUNT_USAGE view, so keep this small
-- confidence: confirmed-docs
-- confidence_note: The SERVERLESS_TASK_HISTORY table function, its DATE_RANGE_START / DATE_RANGE_END / TASK_NAME arguments and its four output columns START_TIME, END_TIME, TASK_NAME and CREDITS_USED are documented at docs.snowflake.com/en/sql-reference/functions/serverless_task_history. CREDITS_USED is documented as TEXT, so it is cast with TRY_TO_DOUBLE rather than assumed numeric. Not run against a live account. The documentation does not state a maximum lookback for this function, so a :period_days larger than the function accepts will error rather than silently truncate.
-- empty_if: privilege_scoped, retention_window, no_activity, serverless_only
-- read_this: One row = one task over the window. TOTAL_CREDITS is the metered serverless spend the LIVE rung can see right now; METERED_HOURS is how many one-hour buckets that task appeared in. A task with credits but only one or two metered hours ran once; a task with credits in nearly every hour is standing spend.
-- healthy: n/a - inventory. This is the live rung's view of the same tasks; the bands live in serverless_task_cost_and_upsizing, which has the run outcomes this function does not carry.
-- investigate_if: n/a - inventory. The one thing to react to here is a task appearing that you did not expect to be serverless at all - a task with no warehouse assigned meters here, and that is often a surprise.
-- actions: 1) reconcile this live list against the tasks you believe exist, and note any task here that nobody scheduled - free; 2) give a task that should not be serverless an explicit warehouse, so its credits land under a resource monitor instead - config; 3) if a task must stay serverless and must stay expensive, budget it as a standing line rather than as an incident - spend
-- next: serverless_task_cost_and_upsizing (if you need failures, retries and the upsizing signal), serverless_credit_exposure (if you want the serverless total this sits inside)
-- covers: This rung sees serverless task METERING and nothing else - no state, no error, no database or schema, and no warehouse-backed tasks at all. It is unlagged and needs no IMPORTED PRIVILEGES, which is exactly why it exists next to the ACCOUNT_USAGE query. It cannot answer "did the task succeed"; only TASK_HISTORY can, and that lives one rung up.
-- caveats: Snowflake documents this function as generally deprecated in favour of the ACCOUNT_USAGE view, which carries more columns and a longer range. It is kept here because it is the only LIVE answer to the serverless-task question, and being deprecated is not the same as being wrong. The function returns only four columns, so tasks that share a name across different databases and schemas are indistinguishable here and are reported together - go to the ACCOUNT_USAGE query to separate them. Session must have an INFORMATION_SCHEMA in scope or the call must be fully qualified.

SELECT
  task_name,
  ROUND(SUM(TRY_TO_DOUBLE(credits_used)), 4)     AS total_credits,
  ROUND(AVG(TRY_TO_DOUBLE(credits_used)), 6)     AS avg_credits_per_metered_hour,
  ROUND(MAX(TRY_TO_DOUBLE(credits_used)), 6)     AS max_credits_in_one_hour,
  COUNT(*)                                       AS metered_hours,
  MIN(start_time)                                AS first_metered_at,
  MAX(end_time)                                  AS last_metered_at,
  DATEDIFF('hour', MIN(start_time), MAX(end_time)) AS span_hours
FROM TABLE(
       information_schema.serverless_task_history(
         DATE_RANGE_START => DATEADD('day', -:period_days, CURRENT_TIMESTAMP()),
         DATE_RANGE_END   => CURRENT_TIMESTAMP()
       )
     )
GROUP BY task_name
ORDER BY total_credits DESC NULLS LAST;
