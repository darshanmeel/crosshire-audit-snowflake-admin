-- query_id: serverless_task_cost_and_upsizing
-- title: Serverless task cost, failures, and the tasks Snowflake keeps sizing up
-- domain: serverless_ai   tier: standard
-- rung: account_usage - it takes both views to answer this. SERVERLESS_TASK_HISTORY has the credits and no outcome; TASK_HISTORY has the outcome and no credits. Neither alone is the answer.
-- reads: snowflake.account_usage.serverless_task_history, snowflake.account_usage.task_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - SERVERLESS_TASK_HISTORY up to 180 minutes, TASK_HISTORY up to 45 minutes. The two views therefore disagree about the most recent hours by design; the newest runs can show an outcome with no credits yet attached.
-- params: :period_days (default 30) rolling window in days; :min_runs_per_half (default 5) metered hours needed in EACH half of the window before the upsizing ratio is trusted; :warn_upsize_ratio (default 1.3) recent credits-per-second divided by earlier credits-per-second that raises WARN; :critical_upsize_ratio (default 2.0) the same ratio that raises CRITICAL; :warn_fail_pct (default 5) percentage of runs in FAILED state that raises WARN; :critical_fail_pct (default 20) failure percentage that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: SERVERLESS_TASK_HISTORY columns START_TIME, END_TIME, CREDITS_USED, TASK_ID, TASK_NAME, SCHEMA_NAME and DATABASE_NAME, and TASK_HISTORY columns NAME, DATABASE_NAME, SCHEMA_NAME, STATE, ERROR_CODE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME, SCHEDULED_FROM and ATTEMPT_NUMBER are all documented on their respective account-usage pages, as are the STATE values SUCCEEDED, FAILED, CANCELLED and SKIPPED and the SCHEDULED_FROM values including AUTOMATIC RETRY and MANUAL RETRY. CREDITS_USED is documented as VARCHAR and is cast. Not run against a live account. Snowflake does not publish a per-run compute-size column for serverless tasks, so the upsizing signal here is a DERIVED ratio of credits per elapsed second, not a size Snowflake reports.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity, serverless_only
-- read_this: One row = one serverless task. The two columns that matter are TOTAL_CREDITS and UPSIZE_RATIO. UPSIZE_RATIO compares credits burned per elapsed second in the recent half of the window against the earlier half: Snowflake sizes serverless task compute itself, run after run, so a task whose cost per second climbs while its work does not is a task Snowflake has decided to run bigger. FAILED_PCT sits beside it because an expensive task that also fails is paying for nothing.
-- healthy: UPSIZE_RATIO near 1.0, FAILED_PCT at zero, and RETRY_RUNS at zero. A task whose credits track its data volume and whose cost per second is flat is behaving exactly as serverless is supposed to.
-- investigate_if: UPSIZE_RATIO crosses :warn_upsize_ratio while the rows the task processes have not grown - Snowflake is compensating for a query that got slower, and you are paying for the compensation. A false positive is a task whose workload genuinely doubled in the second half of the window, or one whose runs are so few that the halves are not comparable, which is why :min_runs_per_half exists and reports NOT_ASSESSED below it. A true positive is a flat workload with a rising cost per second.
-- actions: 1) read the task query text in TASK_HISTORY and confirm the work really is unchanged - free; 2) give the task an explicit warehouse instead of serverless compute if you want a fixed ceiling and a resource monitor, or set a target that stops Snowflake sizing it up on your behalf - config; 3) if the task must stay serverless and must stay big, size the budget for it deliberately - spend
-- next: serverless_task_history_live_is (if ACCOUNT_USAGE has not caught up and you need the live answer), serverless_alert_reliability (if the failing tasks are the ones an alert was supposed to catch), serverless_credit_exposure (if you want the serverless total these tasks sit inside)
-- caveats: The join between the two views is on DATABASE_NAME, SCHEMA_NAME and the task name, because there is no shared surrogate key - a task dropped and recreated with the same name in the same schema will be reported as one task. Credits per elapsed second is a proxy for compute size and nothing more: a task that got slower for its own reasons and a task Snowflake sized up look the same in this column, which is why the healthy band asks you to check the workload before acting. TASK_HISTORY carries no credits, and warehouse-backed tasks appear there but never in SERVERLESS_TASK_HISTORY, so a task with outcomes and no credits in this result is warehouse-backed and out of scope here. The window halves are computed from :period_days, so an odd value splits unevenly by up to one day.

WITH runs AS (
  SELECT
    database_name,
    schema_name,
    task_name,
    start_time,
    end_time,
    TRY_TO_DOUBLE(credits_used)                                        AS credits,
    GREATEST(DATEDIFF('second', start_time, end_time), 1)              AS metered_seconds,
    CASE WHEN start_time >= DATEADD('day', -(:period_days / 2), CURRENT_TIMESTAMP())
         THEN 'recent' ELSE 'earlier' END                              AS window_half
  FROM snowflake.account_usage.serverless_task_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
cost AS (
  SELECT
    database_name,
    schema_name,
    task_name,
    SUM(credits)                                                       AS total_credits,
    COUNT(*)                                                           AS metered_hours,
    MIN(start_time)                                                    AS first_metered_at,
    MAX(end_time)                                                      AS last_metered_at,
    SUM(CASE WHEN window_half = 'recent'  THEN credits END)            AS recent_credits,
    SUM(CASE WHEN window_half = 'recent'  THEN metered_seconds END)    AS recent_seconds,
    COUNT(CASE WHEN window_half = 'recent'  THEN 1 END)                AS recent_rows,
    SUM(CASE WHEN window_half = 'earlier' THEN credits END)            AS earlier_credits,
    SUM(CASE WHEN window_half = 'earlier' THEN metered_seconds END)    AS earlier_seconds,
    COUNT(CASE WHEN window_half = 'earlier' THEN 1 END)                AS earlier_rows
  FROM runs
  GROUP BY 1, 2, 3
),
outcomes AS (
  SELECT
    database_name,
    schema_name,
    name                                                               AS task_name,
    COUNT(*)                                                           AS run_count,
    COUNT(CASE WHEN UPPER(state) = 'FAILED'    THEN 1 END)             AS failed_runs,
    COUNT(CASE WHEN UPPER(state) = 'SKIPPED'   THEN 1 END)             AS skipped_runs,
    COUNT(CASE WHEN UPPER(state) = 'CANCELLED' THEN 1 END)             AS cancelled_runs,
    COUNT(CASE WHEN UPPER(scheduled_from) LIKE '%RETRY%' THEN 1 END)   AS retry_runs,
    MAX(attempt_number)                                                AS max_attempt_number,
    MAX(error_code)                                                    AS last_error_code,
    MAX(error_message)                                                 AS sample_error_message
  FROM snowflake.account_usage.task_history
  WHERE scheduled_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
),
scored AS (
  SELECT
    c.database_name,
    c.schema_name,
    c.task_name,
    ROUND(c.total_credits, 4)                                          AS total_credits,
    c.metered_hours,
    c.first_metered_at,
    c.last_metered_at,
    o.run_count,
    o.failed_runs,
    o.skipped_runs,
    o.cancelled_runs,
    o.retry_runs,
    o.max_attempt_number,
    o.last_error_code,
    o.sample_error_message,
    CASE WHEN o.run_count > 0
         THEN ROUND(100.0 * o.failed_runs / o.run_count, 2) END        AS failed_pct,
    CASE WHEN c.recent_seconds > 0
         THEN c.recent_credits / c.recent_seconds END                  AS recent_credits_per_sec,
    CASE WHEN c.earlier_seconds > 0
         THEN c.earlier_credits / c.earlier_seconds END                AS earlier_credits_per_sec,
    CASE WHEN c.earlier_seconds > 0 AND c.recent_seconds > 0 AND c.earlier_credits > 0
         THEN ROUND((c.recent_credits / c.recent_seconds)
                  / (c.earlier_credits / c.earlier_seconds), 3) END    AS upsize_ratio,
    c.recent_rows,
    c.earlier_rows
  FROM cost c
  LEFT JOIN outcomes o
    ON  o.database_name = c.database_name
    AND o.schema_name   = c.schema_name
    AND o.task_name     = c.task_name
)
SELECT
  database_name,
  schema_name,
  task_name,
  total_credits,
  metered_hours,
  run_count,
  failed_runs,
  failed_pct,
  skipped_runs,
  cancelled_runs,
  retry_runs,
  max_attempt_number,
  ROUND(recent_credits_per_sec, 8)   AS recent_credits_per_sec,
  ROUND(earlier_credits_per_sec, 8)  AS earlier_credits_per_sec,
  upsize_ratio,
  recent_rows,
  earlier_rows,
  first_metered_at,
  last_metered_at,
  last_error_code,
  sample_error_message,
  CASE
    WHEN failed_pct   >= :critical_fail_pct                                            THEN 'CRITICAL'
    WHEN upsize_ratio >= :critical_upsize_ratio
         AND recent_rows >= :min_runs_per_half AND earlier_rows >= :min_runs_per_half  THEN 'CRITICAL'
    WHEN failed_pct   >= :warn_fail_pct                                                THEN 'WARN'
    WHEN upsize_ratio >= :warn_upsize_ratio
         AND recent_rows >= :min_runs_per_half AND earlier_rows >= :min_runs_per_half  THEN 'WARN'
    WHEN upsize_ratio IS NULL
         OR recent_rows < :min_runs_per_half OR earlier_rows < :min_runs_per_half      THEN 'NOT_ASSESSED'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY total_credits DESC NULLS LAST, upsize_ratio DESC NULLS LAST;
