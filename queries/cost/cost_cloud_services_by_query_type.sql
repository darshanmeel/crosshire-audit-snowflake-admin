-- query_id: cost_cloud_services_by_query_type
-- title: Which statement types drive the cloud-services line - SHOW, metadata, INFORMATION_SCHEMA, COPY
-- domain: cost   tier: standard
-- rung: account_usage - QUERY_HISTORY is the only place a cloud-services credit is attached to an individual statement. The INFORMATION_SCHEMA query-history function has no credit column, so the live rung cannot answer this.
-- reads: snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 45 minutes, the shortest lag of any view this domain uses. Recent enough to check whether a change you made an hour ago stopped the traffic.
-- params: :period_days (default 30) rolling window; :min_credits (default 0.5) a statement type below this many gross cloud-services credits returns NOT_ASSESSED; :type_warn_pct (default 15) share of the window's gross cloud-services credits held by one statement type that raises WARN; :type_critical_pct (default 40) the same share that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: QUERY_TYPE, CREDITS_USED_CLOUD_SERVICES, WAREHOUSE_NAME, USER_NAME, EXECUTION_STATUS, TOTAL_ELAPSED_TIME and START_TIME are documented QUERY_HISTORY columns. Not run live. NOT doc-verified and deliberately not relied on: the full enumeration of QUERY_TYPE values - the query groups by whatever the column contains rather than testing against a hard-coded list, so a value this library has never seen still appears in its own row.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one QUERY_TYPE over the window. CLOUD_SERVICES_CREDITS_GROSS is what that statement type consumed before the daily allowance, and PCT_OF_CLOUD_SERVICES is its share of the whole gross line. WAREHOUSELESS_EXECUTIONS beside them is the diagnostic: statements that ran without a warehouse are pure cloud-services work, which is exactly the traffic this query exists to find.
-- healthy: the gross cloud-services line is spread across the statement types you would expect from real work - SELECTs and DML - with metadata types a small tail. Cloud services on a healthy account are a by-product of querying, not a workload of their own.
-- investigate_if: a metadata statement type holds at or above :type_warn_pct of the gross line, or CREDITS_PER_1K_EXECUTIONS is high on a type with a huge execution count - a BI tool or a catalogue crawler polling SHOW or INFORMATION_SCHEMA on a timer is the classic cause, and it is usually one connection doing it thousands of times. False positive: gross is not billed. A large share here costs nothing at all if cost_cloud_services_overage shows the account stayed inside the daily allowance every day, so always read that query before acting on this one.
-- actions: 1) confirm in cost_cloud_services_overage that any of this was actually billed, then take the top type and its user list to whoever owns that tool (free); 2) reduce the traffic at the source - cache metadata in the client, widen a polling interval, batch small COPY statements so per-file overhead stops multiplying (config); 3) nothing here justifies buying compute; the fix for cloud services is always less metadata traffic or more compute to raise the allowance, never a bigger warehouse (spend).
-- next: cost_cloud_services_overage (if you need the billed number rather than this gross one), cost_query_tag_coverage_gap (if one untagged tool drives the traffic and you cannot tell whose it is), cost_attribution_fingerprint (if the traffic is one repeated statement shape)
-- covers: PER-STATEMENT and GROSS. Cloud-services credits consumed by background services that issue no user statement - and the daily adjustment itself - are not here; METERING_DAILY_HISTORY carries those. The sum of this column across the window will therefore be larger than what the account paid, by exactly the allowance it received.
-- caveats: CREDITS_USED_CLOUD_SERVICES per statement is GROSS and pre-allowance, so every total here is an upper bound - it explains the bill, it is not the bill. Failed statements are included: a failing metadata poll still consumes cloud services and excluding it would hide the worst offenders. A statement with a NULL warehouse is metadata-only work by definition and is counted; the WAREHOUSELESS_EXECUTIONS column is there so that population is visible rather than assumed. Grouping is by QUERY_TYPE alone, so two very different workloads that happen to issue the same statement type share a row - use the distinct-user and distinct-warehouse counts to decide whether a row is one tool or many.

WITH statements AS (
  SELECT
    COALESCE(query_type, 'UNKNOWN')          AS query_type,
    user_name,
    warehouse_name,
    execution_status,
    COALESCE(credits_used_cloud_services, 0) AS cloud_services_credits,
    COALESCE(total_elapsed_time, 0)          AS elapsed_ms
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
by_type AS (
  SELECT
    query_type,
    COUNT(*)                                      AS executions,
    COUNT_IF(warehouse_name IS NULL)              AS warehouseless_executions,
    COUNT_IF(execution_status <> 'SUCCESS')       AS non_success_executions,
    COUNT(DISTINCT user_name)                     AS distinct_users,
    COUNT(DISTINCT warehouse_name)                AS distinct_warehouses,
    SUM(cloud_services_credits)                   AS cloud_services_credits_gross,
    MAX(cloud_services_credits)                   AS max_cloud_services_credits_single,
    SUM(elapsed_ms) / 1000.0                      AS elapsed_seconds_total
  FROM statements
  GROUP BY query_type
),
scored AS (
  SELECT
    by_type.*,
    100.0 * cloud_services_credits_gross
          / NULLIF(SUM(cloud_services_credits_gross) OVER (), 0) AS pct_of_cloud_services,
    1000.0 * cloud_services_credits_gross / NULLIF(executions, 0) AS credits_per_1k_executions,
    100.0 * warehouseless_executions / NULLIF(executions, 0)      AS warehouseless_pct
  FROM by_type
)
SELECT
  query_type,
  executions,
  warehouseless_executions,
  ROUND(warehouseless_pct, 1)                  AS warehouseless_pct,
  non_success_executions,
  distinct_users,
  distinct_warehouses,
  ROUND(cloud_services_credits_gross, 4)       AS cloud_services_credits_gross,
  ROUND(pct_of_cloud_services, 1)              AS pct_of_cloud_services,
  ROUND(credits_per_1k_executions, 4)          AS credits_per_1k_executions,
  ROUND(max_cloud_services_credits_single, 5)  AS max_cloud_services_credits_single,
  ROUND(elapsed_seconds_total, 1)              AS elapsed_seconds_total,
  CASE
    WHEN cloud_services_credits_gross < :min_credits          THEN 'NOT_ASSESSED'
    WHEN pct_of_cloud_services >= :type_critical_pct          THEN 'CRITICAL'
    WHEN pct_of_cloud_services >= :type_warn_pct              THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  cloud_services_credits_gross DESC;
