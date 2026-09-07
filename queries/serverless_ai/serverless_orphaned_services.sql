-- query_id: serverless_orphaned_services
-- title: Snowpark Container / notebook services still running with nothing attached
-- domain: serverless_ai   tier: standard
-- rung: show - a running service is a NOW question, and SHOW is the only rung that answers it live. ACCOUNT_USAGE.SERVICES exists and lags up to three hours, which is long enough for a service to have been created, run all afternoon and still not appear.
-- reads: SHOW SERVICES IN ACCOUNT, result_scan(last_query_id())
-- requires: only the privileges the caller already holds - SHOW SERVICES IN ACCOUNT returns what the current role can see. MONITOR on the services, or ownership, is what makes a service visible.
-- freshness: LIVE - this is current state, not history. There is no window and no lag, and equally no memory: a service that was running yesterday and is gone today leaves no trace here.
-- params: :stale_days (default 7) days since the service was last created or resumed, beyond which a still-running service is treated as forgotten; :max_auto_suspend_secs (default 3600) an auto-suspend longer than this is treated as effectively no suspension at all
-- confidence: unverified
-- confidence_note: The SHOW SERVICES syntax and its output columns - name, status, database_name, schema_name, owner, compute_pool, current_instances, target_instances, min_instances, max_instances, auto_resume, auto_suspend_secs, created_on, updated_on, resumed_on, suspended_on, query_warehouse, is_job, is_async_job, managing_object_domain, managing_object_name - are documented at docs.snowflake.com/en/sql-reference/sql/show-services, as is the status value list and the rule that auto_suspend_secs of 0 or never set means Snowflake does NOT auto-suspend the service. This query is nevertheless marked unverified rather than confirmed-docs because SHOW output column LABELS are not a stable documented contract across Snowflake versions and are matched here by their quoted lower-case names; if a label has changed on your version the affected column errors rather than silently returning wrong values. Every value is cast through TRY_TO_ conversions for the same reason.
-- empty_if: privilege_scoped, feature_not_enabled, no_activity
-- read_this: One row = one service the caller can see. The two columns that matter are AUTO_SUSPEND_SECS and MANAGING_OBJECT_NAME. A service with auto_suspend_secs of zero never suspends itself, so it holds its compute pool nodes until a human stops it. MANAGING_OBJECT_NAME is what a notebook or another object puts there when it owns the service; when it is NULL the service is standalone, and a standalone always-on service with nobody using it is the orphan this query is named for.
-- healthy: every RUNNING service has an auto_suspend_secs someone chose, has a named owner, and was created or resumed recently enough that somebody is plainly still using it. Job services showing DONE are finished work and need no action.
-- investigate_if: a service is RUNNING with auto_suspend_secs of zero and was last resumed more than :stale_days ago - it has been holding compute-pool capacity for a week with no evidence anyone touched it. A false positive is a genuine always-on inference or web service, which is exactly what a container service is for; the test is whether anyone can name its consumer. Another false positive is a long-lived job service, which is why is_job is on the row. A true positive is a notebook someone started once and closed the browser tab on.
-- actions: 1) ask the OWNER role whether the service is still wanted, using MANAGING_OBJECT_NAME to find the notebook it belongs to - free; 2) set auto_suspend_secs on every service that is not deliberately always-on, and let auto_resume bring it back when it is next called - config; 3) drop the services nobody claims, and size the compute pool to what remains rather than to the forgotten peak - spend
-- next: serverless_credit_exposure (if SNOWPARK_CONTAINER_SERVICES is a visible line in the serverless mix), serverless_not_monitor_guarded (if you want to confirm no resource monitor can cap this)
-- caveats: SHOW is scoped to what the caller can see, so a service in a database the role has no access to is silently absent - an empty result is not proof there are no services. There is no last-request or last-invocation column anywhere in SHOW SERVICES, so idleness here is inferred from resumed_on and created_on ages, which is a weaker signal than a real usage timestamp and will call a long-running, continuously-used service stale. CURRENT_INSTANCES is what is running now, so a service that scaled to zero reads as cheap in this snapshot even if it has been expensive all week. Because this is a snapshot, running it once tells you less than running it on the same weekday two weeks apart.

SHOW SERVICES IN ACCOUNT;

SELECT
  "name"                                                              AS service_name,
  "database_name"                                                     AS database_name,
  "schema_name"                                                       AS schema_name,
  "owner"                                                             AS owner_role,
  "status"                                                            AS service_status,
  "compute_pool"                                                      AS compute_pool,
  "query_warehouse"                                                   AS query_warehouse,
  TRY_TO_BOOLEAN("is_job"::VARCHAR)                                   AS is_job,
  TRY_TO_BOOLEAN("is_async_job"::VARCHAR)                             AS is_async_job,
  TRY_TO_BOOLEAN("auto_resume"::VARCHAR)                              AS auto_resume,
  TRY_TO_NUMBER("auto_suspend_secs"::VARCHAR)                         AS auto_suspend_secs,
  TRY_TO_NUMBER("current_instances"::VARCHAR)                         AS current_instances,
  TRY_TO_NUMBER("target_instances"::VARCHAR)                          AS target_instances,
  TRY_TO_NUMBER("min_instances"::VARCHAR)                             AS min_instances,
  TRY_TO_NUMBER("max_instances"::VARCHAR)                             AS max_instances,
  "managing_object_domain"                                            AS managing_object_domain,
  "managing_object_name"                                              AS managing_object_name,
  TRY_TO_TIMESTAMP("created_on"::VARCHAR)                             AS created_on,
  TRY_TO_TIMESTAMP("updated_on"::VARCHAR)                             AS updated_on,
  TRY_TO_TIMESTAMP("resumed_on"::VARCHAR)                             AS resumed_on,
  TRY_TO_TIMESTAMP("suspended_on"::VARCHAR)                           AS suspended_on,
  "external_access_integrations"                                      AS external_access_integrations,
  "comment"                                                           AS service_comment,
  DATEDIFF('day',
           COALESCE(TRY_TO_TIMESTAMP("resumed_on"::VARCHAR),
                    TRY_TO_TIMESTAMP("created_on"::VARCHAR)),
           CURRENT_TIMESTAMP())                                       AS days_since_last_start,
  COALESCE(TRY_TO_NUMBER("auto_suspend_secs"::VARCHAR), 0) = 0        AS never_auto_suspends,
  "managing_object_name" IS NULL                                      AS standalone_service,
  CASE
    WHEN TRY_TO_BOOLEAN("is_job"::VARCHAR)
      OR UPPER("status") NOT IN ('RUNNING', 'PENDING')                                 THEN 'NOT_ASSESSED'
    WHEN COALESCE(TRY_TO_NUMBER("auto_suspend_secs"::VARCHAR), 0) = 0
     AND DATEDIFF('day',
                  COALESCE(TRY_TO_TIMESTAMP("resumed_on"::VARCHAR),
                           TRY_TO_TIMESTAMP("created_on"::VARCHAR)),
                  CURRENT_TIMESTAMP()) >= :stale_days                                  THEN 'CRITICAL'
    WHEN COALESCE(TRY_TO_NUMBER("auto_suspend_secs"::VARCHAR), 0) = 0                  THEN 'WARN'
    WHEN TRY_TO_NUMBER("auto_suspend_secs"::VARCHAR) > :max_auto_suspend_secs          THEN 'WARN'
    WHEN "managing_object_name" IS NULL
     AND DATEDIFF('day',
                  COALESCE(TRY_TO_TIMESTAMP("resumed_on"::VARCHAR),
                           TRY_TO_TIMESTAMP("created_on"::VARCHAR)),
                  CURRENT_TIMESTAMP()) >= :stale_days                                  THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY never_auto_suspends DESC, days_since_last_start DESC NULLS LAST, service_name;
