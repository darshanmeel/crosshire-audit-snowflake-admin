-- query_id: serverless_alert_reliability
-- title: Are the alerts firing, succeeding, or silently erroring - and what do they cost
-- domain: serverless_ai   tier: standard
-- rung: account_usage - ALERT_HISTORY is the only rung with alert outcomes at all. INFORMATION_SCHEMA has an ALERT_HISTORY table function, but it is scoped to the current database, so it cannot answer an account-wide reliability question.
-- reads: snowflake.account_usage.alert_history, snowflake.account_usage.serverless_alert_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - ALERT_HISTORY carries a documented latency of up to 45 minutes, SERVERLESS_ALERT_HISTORY up to 180 minutes. An alert that failed in the last hour is probably here; its credits are probably not yet.
-- params: :period_days (default 30) rolling window in days; :min_runs (default 10) evaluations needed before the error rate is judged, below which the alert reports NOT_ASSESSED; :warn_error_pct (default 5) percentage of evaluations ending in an error state that raises WARN; :critical_error_pct (default 20) error percentage that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: ALERT_HISTORY columns NAME, DATABASE_NAME, SCHEMA_NAME, STATE, ERROR_CODE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME, SCHEDULED_FROM and WAS_AUTO_SUSPENDED are documented at docs.snowflake.com/en/sql-reference/account-usage/alert_history, together with the full STATE list SCHEDULED, EXECUTING, FAILED, CANCELLED, CONDITION_FALSE, CONDITION_FAILED, ACTION_FAILED and TRIGGERED. SERVERLESS_ALERT_HISTORY columns START_TIME, END_TIME, CREDITS_USED, ALERT_NAME, SCHEMA_NAME and DATABASE_NAME are documented on its own page; CREDITS_USED is documented as VARCHAR and is cast. Not run against a live account. Note that the view has NO SUCCEEDED state - a healthy evaluation is CONDITION_FALSE or TRIGGERED, and code that looks for SUCCEEDED finds nothing and calls it silence.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one alert over the window. The two columns that matter are ERROR_PCT and TRIGGERED_RUNS. An alert exists to notice something; ERROR_PCT is how often it could not even evaluate, and TRIGGERED_RUNS is how often it actually fired. Zero errors and zero triggers is the ambiguous case and the reason WAS_AUTO_SUSPENDED_EVER is on the row: an alert Snowflake suspended after repeated failures reports nothing at all, which looks identical to an alert with nothing to report.
-- healthy: ERROR_PCT is zero, WAS_AUTO_SUSPENDED_EVER is false, and the CONDITION_FALSE to TRIGGERED mix matches what the alert was written to watch for. Credits are small and proportional to the schedule.
-- investigate_if: ERROR_PCT crosses :warn_error_pct, or WAS_AUTO_SUSPENDED_EVER is true, or the alert has burned credits across the whole window and never once triggered. A false positive is a genuinely quiet alert on a genuinely quiet condition - check LAST_TRIGGERED_AT against when the thing it watches last happened. A true positive is an alert everyone believes is guarding something that has not evaluated successfully in weeks.
-- actions: 1) run the alert condition by hand and read the error message in this result - it is almost always a permission or a dropped object - free; 2) fix or resume the alert, and give it a schedule that matches how fast you need to know, since every evaluation is metered - config; 3) if an alert is genuinely never triggering because the risk it watched is gone, delete it rather than paying to evaluate it - free
-- next: serverless_task_cost_and_upsizing (if the alerts were watching tasks that are themselves failing), serverless_credit_exposure (if SERVERLESS_ALERTS is a visible line in the serverless mix)
-- caveats: The two views join on DATABASE_NAME, SCHEMA_NAME and the alert name, the only shared identity they publish - an alert dropped and recreated under the same name is reported as one alert. ALERT_HISTORY carries no credits and SERVERLESS_ALERT_HISTORY carries no outcome, so an alert running on a warehouse rather than serverless compute appears here with outcomes and NULL credits, which is correct and not a gap. CONDITION_FAILED and ACTION_FAILED are counted as errors alongside FAILED because all three mean the alert did not do its job; CANCELLED is reported separately because a cancellation is usually a human. Rows still in SCHEDULED or EXECUTING at query time are counted as in-flight, not as failures.

WITH evaluations AS (
  SELECT
    database_name,
    schema_name,
    name                                                                      AS alert_name,
    COUNT(*)                                                                  AS run_count,
    COUNT(CASE WHEN UPPER(state) = 'TRIGGERED'       THEN 1 END)              AS triggered_runs,
    COUNT(CASE WHEN UPPER(state) = 'CONDITION_FALSE' THEN 1 END)              AS condition_false_runs,
    COUNT(CASE WHEN UPPER(state) IN ('FAILED', 'CONDITION_FAILED', 'ACTION_FAILED')
               THEN 1 END)                                                    AS error_runs,
    COUNT(CASE WHEN UPPER(state) = 'CANCELLED'       THEN 1 END)              AS cancelled_runs,
    COUNT(CASE WHEN UPPER(state) IN ('SCHEDULED', 'EXECUTING') THEN 1 END)    AS in_flight_runs,
    BOOLOR_AGG(was_auto_suspended)                                            AS was_auto_suspended_ever,
    MAX(CASE WHEN UPPER(state) = 'TRIGGERED' THEN scheduled_time END)         AS last_triggered_at,
    MAX(scheduled_time)                                                       AS last_scheduled_at,
    MAX(error_code)                                                           AS last_error_code,
    MAX(error_message)                                                        AS sample_error_message,
    COUNT(DISTINCT scheduled_from)                                            AS distinct_trigger_sources
  FROM snowflake.account_usage.alert_history
  WHERE scheduled_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
),
spend AS (
  SELECT
    database_name,
    schema_name,
    alert_name,
    SUM(TRY_TO_DOUBLE(credits_used))    AS total_credits,
    COUNT(*)                            AS metered_hours
  FROM snowflake.account_usage.serverless_alert_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
),
scored AS (
  SELECT
    e.database_name,
    e.schema_name,
    e.alert_name,
    e.run_count,
    e.triggered_runs,
    e.condition_false_runs,
    e.error_runs,
    e.cancelled_runs,
    e.in_flight_runs,
    e.was_auto_suspended_ever,
    e.last_triggered_at,
    e.last_scheduled_at,
    e.last_error_code,
    e.sample_error_message,
    e.distinct_trigger_sources,
    ROUND(s.total_credits, 4)                                        AS total_credits,
    s.metered_hours,
    CASE WHEN e.run_count > 0
         THEN ROUND(100.0 * e.error_runs / e.run_count, 2) END       AS error_pct,
    CASE WHEN e.run_count > 0
         THEN ROUND(100.0 * e.triggered_runs / e.run_count, 2) END   AS triggered_pct
  FROM evaluations e
  LEFT JOIN spend s
    ON  s.database_name = e.database_name
    AND s.schema_name   = e.schema_name
    AND s.alert_name    = e.alert_name
)
SELECT
  database_name,
  schema_name,
  alert_name,
  run_count,
  triggered_runs,
  triggered_pct,
  condition_false_runs,
  error_runs,
  error_pct,
  cancelled_runs,
  in_flight_runs,
  was_auto_suspended_ever,
  last_triggered_at,
  last_scheduled_at,
  total_credits,
  metered_hours,
  last_error_code,
  sample_error_message,
  distinct_trigger_sources,
  CASE
    WHEN was_auto_suspended_ever                                     THEN 'CRITICAL'
    WHEN run_count >= :min_runs AND error_pct >= :critical_error_pct THEN 'CRITICAL'
    WHEN run_count >= :min_runs AND error_pct >= :warn_error_pct     THEN 'WARN'
    WHEN run_count >= :min_runs AND triggered_runs = 0
         AND COALESCE(total_credits, 0) > 0                          THEN 'WARN'
    WHEN run_count < :min_runs                                       THEN 'NOT_ASSESSED'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY error_pct DESC NULLS LAST, total_credits DESC NULLS LAST, run_count DESC;
