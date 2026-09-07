-- query_id: warehouse_wake_analysis
-- title: What actually wakes each warehouse, and how long it stays awake afterwards
-- domain: warehouse   tier: deep
-- rung: account_usage - it takes the resume event and the statement that caused it, and only this rung has both. WAREHOUSE_EVENTS_HISTORY carries the QUERY_ID on the resume, and QUERY_HISTORY carries what that statement was.
-- reads: snowflake.account_usage.warehouse_events_history, snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - the events view is documented at up to 3 hours and QUERY_HISTORY at up to 45 minutes. Because the events view is the slower of the two, a recent resume can appear here with its query already present, but not the other way round, so the attribution never degrades into a wrong name - only into an absent one.
-- params: :period_days (default 30) trailing window in days; :short_awake_seconds (default 300) an awake stretch at or below this counts as a brief one - the warehouse woke, did very little, and went back to sleep; :warn_wakes (default 50) brief wakes from one source that earn a WARN; :critical_wakes (default 200) the same for CRITICAL; :min_wakes (default 5) fewer wakes from a source than this and there is no pattern to report
-- confidence: confirmed-docs
-- confidence_note: WAREHOUSE_EVENTS_HISTORY carries TIMESTAMP, WAREHOUSE_NAME, EVENT_NAME, EVENT_REASON, EVENT_STATE, USER_NAME, ROLE_NAME and QUERY_ID, all documented, with RESUME_WAREHOUSE and SUSPEND_WAREHOUSE among the documented EVENT_NAME values and WAREHOUSE_AUTORESUME among the documented EVENT_REASON values. QUERY_HISTORY carries QUERY_ID, USER_NAME, ROLE_NAME, QUERY_TYPE, QUERY_TAG and IS_CLIENT_GENERATED_STATEMENT, all documented. The classification of a waker uses only IS_CLIENT_GENERATED_STATEMENT, which is a documented boolean, rather than any pattern-match on query text - so it can be wrong about intent but it is never a guess about the data. Pairing a resume with the next suspend is this query's construction, because the events view has no end timestamp. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = one warehouse and one waker - a user seen through a particular kind of statement. The two columns that answer the question are wakes (how often this source started the warehouse) and median_awake_seconds (how long it then stayed up). A long tail of brief wakes from one non-client source is a scheduler running more often than anyone remembers agreeing to; a handful of long wakes from a client is a person doing their job.
-- healthy: few wakers per warehouse, each with a median_awake_seconds that plausibly matches the work - a batch warehouse woken once a night and awake for the length of the batch is exactly right.
-- investigate_if: wakes at or above :warn_wakes (WARN) or :critical_wakes (CRITICAL) with median_awake_seconds at or below :short_awake_seconds - something is pinging this warehouse awake to do almost nothing. A false positive: a monitoring or health-check statement is a legitimate reason to wake a warehouse in some shops, and it will look exactly like this - the waker_user and distinct_waker_query_tags columns are there so you can recognise it and stop re-finding it every month.
-- actions: 1) name the waker - the user and the tag on the row are usually enough for someone to say what it is, and that conversation is free (free); 2) move whatever it is off this warehouse, or point it at metadata that needs no warehouse at all, or let it run on a schedule that shares one wake instead of buying many (config); 3) if it must run this often and must have compute, give it its own small warehouse so it stops waking the expensive one (spend).
-- next: warehouse_idle_credit_leak (if the wakes are cheap but the awake stretches after them are not), warehouse_auto_suspend_thrash (if the awake stretches are short because auto_suspend is short, rather than because the work is small), warehouse_inventory_show (if the fix is an auto_suspend change and you need the current value)
-- covers: Every warehouse-level resume with the statement that triggered it, account-wide, up to a year back. It does NOT see: cluster-level resumes, which are deliberately excluded because a cluster spinning up is a scaling event and not a wake - warehouse_multicluster_spinup_cost owns those; nor what ran DURING the awake stretch, only what started it; nor the credits, which are in WAREHOUSE_METERING_HISTORY.
-- caveats: The waker is the statement recorded on the resume event, which is the statement that triggered the wake - not necessarily the statement that mattered. A resume with no QUERY_ID, or one whose query row has aged out of the window, is reported honestly as unattributed rather than dropped, so the wake counts still add up. The awake stretch is reconstructed by pairing each resume with the next warehouse-level suspend, so the final wake in the window has no measured length and is counted in wakes but excluded from the median - wakes_with_a_measured_sleep on the row is the denominator that actually was measured. A warehouse suspended by a resource monitor rather than by auto-suspend closes the stretch just the same, which is correct for duration but means a short median is not by itself proof that auto_suspend is short.

WITH lifecycle AS (
  SELECT
    e.warehouse_name,
    e.timestamp   AS event_ts,
    e.event_reason,
    e.query_id    AS trigger_query_id,
    e.user_name   AS event_user_name,
    e.role_name   AS event_role_name,
    CASE
      WHEN e.event_name = 'RESUME_WAREHOUSE' THEN 'RESUME'
      ELSE 'SUSPEND'
    END AS phase
  FROM snowflake.account_usage.warehouse_events_history e
  WHERE e.timestamp >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND e.warehouse_name IS NOT NULL
    -- warehouse-level only: a cluster spinning up is scaling, not a wake
    AND e.event_name IN ('RESUME_WAREHOUSE', 'SUSPEND_WAREHOUSE')
    AND (e.event_state = 'COMPLETED' OR e.event_state IS NULL)
),
sequenced AS (
  SELECT
    warehouse_name,
    event_ts,
    phase,
    event_reason,
    trigger_query_id,
    event_user_name,
    event_role_name,
    LEAD(phase)    OVER (PARTITION BY warehouse_name ORDER BY event_ts) AS next_phase,
    LEAD(event_ts) OVER (PARTITION BY warehouse_name ORDER BY event_ts) AS next_ts
  FROM lifecycle
),
awake AS (
  SELECT
    warehouse_name,
    event_ts AS resumed_at,
    event_reason,
    trigger_query_id,
    event_user_name,
    event_role_name,
    CASE
      WHEN next_phase = 'SUSPEND' THEN DATEDIFF('second', event_ts, next_ts)
    END AS awake_seconds
  FROM sequenced
  WHERE phase = 'RESUME'
),
attributed AS (
  SELECT
    a.warehouse_name,
    a.resumed_at,
    a.awake_seconds,
    a.event_reason,
    COALESCE(q.user_name, a.event_user_name) AS waker_user,
    COALESCE(q.query_type, 'UNKNOWN')        AS waker_query_type,
    q.query_tag                              AS waker_query_tag,
    CASE
      WHEN q.query_id IS NULL                     THEN 'UNATTRIBUTED - resume carries no matching statement'
      WHEN q.is_client_generated_statement = TRUE THEN 'CLIENT - a driver, console or BI session'
      ELSE 'NON-CLIENT - a task, pipe or other server-side statement'
    END AS waker_kind
  FROM awake a
  LEFT JOIN snowflake.account_usage.query_history q
    ON q.query_id   = a.trigger_query_id
   AND q.start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
rolled AS (
  SELECT
    warehouse_name,
    waker_kind,
    waker_user,
    waker_query_type,
    COUNT(*)                                  AS wakes,
    COUNT_IF(awake_seconds IS NOT NULL)        AS wakes_with_a_measured_sleep,
    COUNT_IF(event_reason = 'WAREHOUSE_AUTORESUME') AS auto_resumes,
    COUNT(DISTINCT waker_query_tag)            AS distinct_waker_query_tags,
    ROUND(MEDIAN(awake_seconds), 0)            AS median_awake_seconds,
    ROUND(AVG(awake_seconds), 0)               AS mean_awake_seconds,
    MAX(awake_seconds)                         AS longest_awake_seconds,
    SUM(awake_seconds)                         AS total_awake_seconds,
    MIN(resumed_at)                            AS first_wake,
    MAX(resumed_at)                            AS last_wake
  FROM attributed
  GROUP BY 1, 2, 3, 4
)
SELECT
  warehouse_name,
  waker_kind,
  waker_user,
  waker_query_type,
  wakes,
  wakes_with_a_measured_sleep,
  auto_resumes,
  distinct_waker_query_tags,
  median_awake_seconds,
  mean_awake_seconds,
  longest_awake_seconds,
  total_awake_seconds,
  ROUND(total_awake_seconds / 3600.0, 2) AS total_awake_hours,
  first_wake,
  last_wake,
  CASE
    WHEN wakes < :min_wakes OR wakes_with_a_measured_sleep = 0 THEN 'NOT_ASSESSED'
    WHEN wakes >= :critical_wakes AND median_awake_seconds <= :short_awake_seconds THEN 'CRITICAL'
    WHEN wakes >= :warn_wakes     AND median_awake_seconds <= :short_awake_seconds THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM rolled
ORDER BY total_awake_seconds DESC NULLS LAST, wakes DESC;
