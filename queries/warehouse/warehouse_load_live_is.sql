-- query_id: warehouse_load_live_is
-- title: Running and queued load on one warehouse right now - the live twin of the load history
-- domain: warehouse   tier: lite
-- rung: information_schema - the live, low-privilege rung. This exists so a sizing decision does not have to wait three hours for ACCOUNT_USAGE, and so someone without IMPORTED PRIVILEGES can still see the load.
-- reads: information_schema.warehouse_load_history
-- requires: ACCOUNTADMIN, or the MONITOR USAGE global privilege, or MONITOR on the warehouse, or ownership of it. No IMPORTED PRIVILEGES on the SNOWFLAKE database.
-- freshness: LIVE - the table function reads current telemetry with no ACCOUNT_USAGE lag. The documented cost of that is reach: only the last 14 days exist here, against a year in ACCOUNT_USAGE. The docs also warn that a range ending inside the last minute can be inaccurate, so the range deliberately stops one minute short of now.
-- params: :period_hours (default 6) how far back to look - under 8 hours the function returns 5-SECOND buckets, at or above 8 hours it returns 5-minute buckets, so this parameter silently changes the row grain; :warehouse_name (default WH_PLACEHOLDER) the ONE warehouse to probe - this function answers for a single warehouse and defaults to CURRENT_WAREHOUSE if the argument is dropped entirely; :warn_queued (default 0.5) overload-queue load per bucket that earns a WARN; :critical_queued (default 2) the same for CRITICAL
-- confidence: confirmed-docs
-- confidence_note: The signature and every argument and output column are documented at docs.snowflake.com/en/sql-reference/functions/warehouse_load_history - DATE_RANGE_START, DATE_RANGE_END and WAREHOUSE_NAME in, and START_TIME, END_TIME, WAREHOUSE_NAME, AVG_RUNNING, AVG_QUEUED_LOAD, AVG_QUEUED_PROVISIONING, AVG_BLOCKED out. The 14-day retention, the 5-second / 5-minute granularity switch at 8 hours, the CURRENT_WAREHOUSE default and the privilege list are all from that page. Not run against a live account: whether your driver accepts a bind in a named table-function argument is a client-side question this cannot verify.
-- empty_if: privilege_scoped, retention_window, no_activity
-- read_this: One row = one telemetry bucket for ONE warehouse. The two columns that decide the action are avg_running (how many statements were executing on average - a concurrency figure, not a percentage of the hardware) and avg_queued_load (statements waiting because the warehouse was overloaded). Load with no queue means the size is holding; queue with load means work is arriving faster than this warehouse can start it.
-- healthy: avg_queued_load at or near zero across the window, with avg_running rising and falling but never pinned. avg_queued_provisioning spikes only just after a resume, which is the cold start, not a fault.
-- investigate_if: avg_queued_load at or above :warn_queued in repeated buckets (WARN) or :critical_queued (CRITICAL) - the warehouse is turning work away. A false positive looks like one bucket immediately after a resume, where provisioning and overload queue both spike for seconds and then vanish: read the neighbouring rows before calling it a pattern. avg_blocked is NOT a sizing signal at all - it is transaction lock contention, and no warehouse change fixes it.
-- actions: 1) watch two or three more buckets before changing anything - this rung is live, so waiting costs nothing and a single bucket is not a pattern (free); 2) if the queue is concurrency, raise max_cluster_count so work runs side by side, and if the queue is one heavy statement at a time, raise the size instead (config); 3) if both are already right, move the competing workload to its own warehouse (spend).
-- next: warehouse_oversized_by_load (if the live picture is quiet and you want to know whether it has been quiet for a month), warehouse_multicluster_scale_out_need (if avg_queued_load is the column that is high), warehouse_inventory_show (if you need this warehouse's current size and cluster range before changing either)
-- covers: LIVE load for ONE warehouse over at most 14 days, without any admin grant - that is the whole point of this rung. It cannot see: any other warehouse in the same call, anything older than 14 days, credits or money of any kind, or which statements made the load. The account-wide, year-deep twin is snowflake.account_usage.warehouse_load_history, used by warehouse_oversized_by_load and warehouse_low_load_hours; climb to it when you need the population, not the probe.
-- caveats: The function returns ONE warehouse per call - it defaults to CURRENT_WAREHOUSE - so this is a probe you point at a name, never an account sweep. A bucket in which the warehouse did nothing may simply not be emitted, so a gap in the timeline is silence, not a measured zero. Query load is execution time accumulated in the bucket divided by the bucket length: AVG_RUNNING of 1.0 means one statement was executing on average, at any warehouse size, so it says nothing about how hard the hardware worked. The range ends one minute before now because the documentation warns that querying inside the last minute can be inaccurate.

SELECT
  warehouse_name,
  start_time,
  end_time,
  avg_running,
  avg_queued_load,
  avg_queued_provisioning,
  avg_blocked,
  ROUND(
    COALESCE(avg_running, 0) + COALESCE(avg_queued_load, 0)
    + COALESCE(avg_queued_provisioning, 0) + COALESCE(avg_blocked, 0), 3
  ) AS avg_total_load,
  CASE
    WHEN avg_running IS NULL AND avg_queued_load IS NULL THEN 'NOT_ASSESSED'
    WHEN avg_queued_load >= :critical_queued             THEN 'CRITICAL'
    WHEN avg_queued_load >= :warn_queued                 THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM TABLE(
  information_schema.warehouse_load_history(
    DATE_RANGE_START => DATEADD('hour',   -:period_hours, CURRENT_TIMESTAMP()),
    -- the docs warn that a range reaching into the last minute can be inaccurate
    DATE_RANGE_END   => DATEADD('minute', -1,             CURRENT_TIMESTAMP()),
    WAREHOUSE_NAME   => :warehouse_name
  )
)
ORDER BY avg_queued_load DESC NULLS LAST, start_time DESC;
