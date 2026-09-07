-- query_id: warehouse_multicluster_scale_out_need
-- title: Single-cluster warehouses that queue enough concurrent work to need scaling OUT, not UP
-- domain: warehouse   tier: standard
-- rung: account_usage - the queue-time columns on QUERY_HISTORY are what separate "too small" from "too few clusters", and only this rung has a month of them. INFORMATION_SCHEMA.QUERY_HISTORY carries the same columns live but over hours, which is enough to confirm a change and not enough to justify one.
-- reads: snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 45 minutes documented, which is the shortest lag of any ACCOUNT_USAGE view used in this domain. A change made this morning will be visible here by lunchtime.
-- params: :period_days (default 30) trailing window in days; :min_statements (default 200) fewer statements than this on a warehouse and the window is too thin to judge; :warn_pct_queued (default 5) percent of statements that waited on overload which earns a WARN; :critical_pct_queued (default 20) the same for CRITICAL; :spill_share_veto (default 25) if more than this percent of statements also spilled, the warehouse is under-sized as well as under-clustered and scaling out alone will not fix it
-- confidence: confirmed-docs
-- confidence_note: QUERY_HISTORY documents WAREHOUSE_NAME, WAREHOUSE_SIZE, CLUSTER_NUMBER, EXECUTION_STATUS, START_TIME, TOTAL_ELAPSED_TIME, EXECUTION_TIME, QUEUED_OVERLOAD_TIME, QUEUED_PROVISIONING_TIME, BYTES_SPILLED_TO_LOCAL_STORAGE and BYTES_SPILLED_TO_REMOTE_STORAGE, and documents its duration columns as milliseconds. Using CLUSTER_NUMBER to infer that a warehouse only ever ran one cluster is this query's construction and is stated in caveats. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity, retention_window
-- read_this: One row = one warehouse that was only ever observed running a single cluster. The two columns that decide the action are pct_statements_queued - how often work waited because the warehouse was already full - and pct_statements_that_spilled, which is the veto. Queuing without spilling is the scale-OUT case: the work fits, there is just too much of it at once. Queuing with spilling means the individual statements are too big for the size, and adding clusters would simply spill on more of them.
-- healthy: pct_statements_queued below :warn_pct_queued. Occasional overload queuing on a warehouse that is otherwise quiet is normal and costs almost nothing.
-- investigate_if: pct_statements_queued at or above :warn_pct_queued (WARN) or :critical_pct_queued (CRITICAL) with pct_statements_that_spilled below :spill_share_veto. The false positive that matters most here is the reverse case, and it is why the spill column is on the row: a warehouse whose statements are individually too large queues too, and the fix for that is a bigger size or a better query, never more clusters. worst_single_overload_wait_seconds is the second check - one pathological wait is a different story from a steady toll.
-- actions: 1) look at when the queuing happens - if it is one window a day, moving a job is free and adds no clusters at all (free); 2) if the concurrency is genuine and spread through the day, raise max_cluster_count from 1 and leave min at 1, so the warehouse grows only while it needs to (config); 3) if it queues constantly rather than in bursts, a second warehouse for the competing workload is more predictable than scaling, because scaling pays a start minimum every time it grows (spend).
-- next: warehouse_multicluster_scaling_misconfig (if you are about to raise max_cluster_count and want to avoid the shapes that do not work), warehouse_multicluster_spinup_cost (if you have already scaled out and want to know what it cost), warehouse_oversized_by_load (if the queuing turns out to be rare and the warehouse is mostly idle)
-- covers: Every warehouse on which no statement was ever recorded on a cluster above the first, account-wide, up to a year back. It does NOT see: warehouses that HAVE scaled out - they are excluded by design, because for them the question is cost, not need, and that is warehouse_multicluster_spinup_cost. It also does not see the configured max_cluster_count, only the clusters actually used, so a warehouse configured for four clusters that never needed a second one appears here as a single-cluster warehouse.
-- caveats: Single-cluster status is INFERRED from the highest CLUSTER_NUMBER ever recorded on the warehouse's statements in the window, not read from configuration - a multi-cluster warehouse that simply never scaled will therefore appear here, and its queuing means the scaling threshold is not being reached rather than that a cluster needs adding. Check its max_cluster_count in warehouse_inventory_show before acting. Only successful statements are counted, so a warehouse whose queuing ends in timeouts under-reports here. QUEUED_PROVISIONING_TIME is reported but never used in the verdict: it is the cold-start wait after a resume, and no amount of clustering removes it. All duration columns are milliseconds and are converted to seconds on the way out.

WITH statements AS (
  SELECT
    warehouse_name,
    COALESCE(cluster_number, 1) AS cluster_number,
    start_time,
    total_elapsed_time,
    execution_time,
    queued_overload_time,
    queued_provisioning_time,
    COALESCE(bytes_spilled_to_local_storage, 0)
      + COALESCE(bytes_spilled_to_remote_storage, 0) AS bytes_spilled
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    -- a NULL size means the statement never used warehouse compute at all
    AND warehouse_size IS NOT NULL
    AND execution_status = 'SUCCESS'
),
rolled AS (
  SELECT
    warehouse_name,
    MAX(cluster_number)                                       AS max_cluster_number_seen,
    COUNT(*)                                                  AS statements,
    COUNT_IF(queued_overload_time > 0)                        AS statements_queued_on_overload,
    COUNT_IF(bytes_spilled > 0)                               AS statements_that_spilled,
    ROUND(SUM(queued_overload_time)     / 1000.0, 1)          AS overload_queue_seconds,
    ROUND(SUM(queued_provisioning_time) / 1000.0, 1)          AS provisioning_queue_seconds,
    ROUND(SUM(execution_time)           / 1000.0, 1)          AS execution_seconds,
    ROUND(MAX(queued_overload_time)     / 1000.0, 1)          AS worst_single_overload_wait_seconds,
    ROUND(MEDIAN(total_elapsed_time)    / 1000.0, 2)          AS median_statement_seconds,
    MIN(start_time)                                           AS first_statement,
    MAX(start_time)                                           AS last_statement
  FROM statements
  GROUP BY 1
)
SELECT
  warehouse_name,
  max_cluster_number_seen,
  statements,
  statements_queued_on_overload,
  ROUND(100 * statements_queued_on_overload / NULLIF(statements, 0), 1) AS pct_statements_queued,
  overload_queue_seconds,
  execution_seconds,
  ROUND(100 * overload_queue_seconds / NULLIF(execution_seconds, 0), 1) AS queue_to_execution_pct,
  worst_single_overload_wait_seconds,
  provisioning_queue_seconds,
  statements_that_spilled,
  ROUND(100 * statements_that_spilled / NULLIF(statements, 0), 1)       AS pct_statements_that_spilled,
  median_statement_seconds,
  first_statement,
  last_statement,
  CASE
    WHEN statements < :min_statements
      THEN 'NOT_ASSESSED'
    WHEN 100 * statements_that_spilled / NULLIF(statements, 0) > :spill_share_veto
      THEN 'WARN'
    WHEN 100 * statements_queued_on_overload / NULLIF(statements, 0) >= :critical_pct_queued
      THEN 'CRITICAL'
    WHEN 100 * statements_queued_on_overload / NULLIF(statements, 0) >= :warn_pct_queued
      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM rolled
WHERE max_cluster_number_seen = 1
ORDER BY overload_queue_seconds DESC, statements_queued_on_overload DESC;
