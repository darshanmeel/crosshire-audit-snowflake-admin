-- query_id: perf_runaway_query_guardrail
-- title: Is a statement timeout actually set at account level, or is the default the only guardrail
-- domain: performance   tier: lite
-- rung: show - the lowest rung that can answer it. No ACCOUNT_USAGE view carries the account parameter set, and INFORMATION_SCHEMA has no parameters view, so SHOW piped through RESULT_SCAN is not a shortcut here, it is the only route.
-- reads: SHOW PARAMETERS IN ACCOUNT, result_scan(last_query_id())
-- requires: nothing beyond a role that can run SHOW PARAMETERS IN ACCOUNT - in practice an account-level role such as ACCOUNTADMIN or SECURITYADMIN. No IMPORTED PRIVILEGES.
-- freshness: LIVE - a point-in-time snapshot of the parameters in force this second. There is no history at this rung: SHOW cannot tell you when the value was last changed, or by whom.
-- params: :max_statement_timeout_seconds (default 3600) the longest single statement you are willing to pay for before Snowflake aborts it; :max_queued_timeout_seconds (default 600) the longest a statement may sit queued before it is cancelled rather than waited on
-- confidence: unverified
-- confidence_note: The command, the RESULT_SCAN pattern and the output column labels key, value, default, level and description are documented at docs.snowflake.com/en/sql-reference/sql/show-parameters, which also states SHOW output column names are lower-case and so must be double-quoted. This query is still marked unverified rather than confirmed-docs because SHOW output is not a versioned contract: a future release may add or rename a column, and nothing here has been run against a live account. The documented default for STATEMENT_TIMEOUT_IN_SECONDS is two days; STATEMENT_QUEUED_TIMEOUT_IN_SECONDS defaults to 0, meaning a queued statement waits indefinitely.
-- empty_if: privilege_scoped
-- read_this: One row = one of the two timeout parameters as it stands at the account level. The two columns that matter are VALUE_IN_FORCE and ORIGIN - a value that looks sane but shows ORIGIN as DEFAULT means nobody ever set it, and the number you are reading is a Snowflake default that a future release could move.
-- healthy: STATEMENT_TIMEOUT_IN_SECONDS explicitly set at or below :max_statement_timeout_seconds, and STATEMENT_QUEUED_TIMEOUT_IN_SECONDS explicitly set at or below :max_queued_timeout_seconds. Explicit is the point - a deliberate number written down beats an inherited one that happens to be acceptable.
-- investigate_if: CRITICAL when a timeout is 0, because 0 means no limit at all and one runaway statement can hold a warehouse until somebody notices. WARN when the value in force is only the Snowflake default, or when it exceeds your ceiling. A false positive looks like an account that runs deliberately long batch loads and sets the generous timeout on the batch WAREHOUSE instead - this query reads the ACCOUNT level only, so check the warehouse-level override before calling it a gap.
-- actions: 1) decide the two numbers with whoever owns the workload, which costs nothing and is the part most accounts skip (free); 2) ALTER ACCOUNT SET STATEMENT_TIMEOUT_IN_SECONDS and STATEMENT_QUEUED_TIMEOUT_IN_SECONDS to those numbers, then override upward on the one warehouse that genuinely needs longer (config); 3) nothing here costs money - a guardrail is the cheapest performance control in Snowflake, and its absence is what costs (spend).
-- next: perf_failed_queries (to see what already dies, and how much it burns first), perf_queuing_overload (if the queued timeout is the one that is unset and queues are real), perf_spilling_queries (if the statements you would be timing out are the ones spilling)
-- covers: The ACCOUNT level only. Warehouse-level and session-level overrides are invisible here, and they win over the account value for statements that run under them - so a clean result here does not prove every statement is bounded. It is a snapshot with no history: SHOW cannot answer when a parameter changed.
-- caveats: The header claims confidence unverified for a reason - the RESULT_SCAN column labels are the weak point, and if a future release renames them this query fails loudly rather than silently, which is the intended failure mode. RESULT_SCAN(LAST_QUERY_ID()) binds to the statement immediately before it, so the two statements in this file must be run together in one worksheet, in order, with nothing in between. VALUE_IN_FORCE is text in the SHOW output and is converted with TRY_TO_NUMBER, so a non-numeric value yields NULL and is reported NOT_ASSESSED rather than being silently treated as zero. The level column is empty when no explicit SET was ever applied, which is exactly how a default is detected here.

SHOW PARAMETERS IN ACCOUNT;

SELECT
  CASE
    WHEN TRY_TO_NUMBER("value") IS NULL                                             THEN 'NOT_ASSESSED'
    WHEN TRY_TO_NUMBER("value") = 0                                                 THEN 'CRITICAL'
    WHEN NULLIF(TRIM("level"), '') IS NULL                                          THEN 'WARN'
    WHEN "key" = 'STATEMENT_TIMEOUT_IN_SECONDS'
         AND TRY_TO_NUMBER("value") > :max_statement_timeout_seconds                THEN 'WARN'
    WHEN "key" = 'STATEMENT_QUEUED_TIMEOUT_IN_SECONDS'
         AND TRY_TO_NUMBER("value") > :max_queued_timeout_seconds                   THEN 'WARN'
    ELSE 'OK'
  END                                                     AS status,
  "key"                                                   AS parameter_name,
  TRY_TO_NUMBER("value")                                  AS value_in_force_seconds,
  TRY_TO_NUMBER("default")                                AS snowflake_default_seconds,
  NULLIF(TRIM("level"), '')                               AS set_at_level,
  IFF(NULLIF(TRIM("level"), '') IS NULL,
      'DEFAULT - never explicitly set',
      'EXPLICIT - set at this level')                     AS origin,
  ROUND(TRY_TO_NUMBER("value") / 3600.0, 2)               AS value_in_force_hours,
  "description"                                           AS parameter_description
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "key" IN ('STATEMENT_TIMEOUT_IN_SECONDS', 'STATEMENT_QUEUED_TIMEOUT_IN_SECONDS')
ORDER BY "key";
