-- query_id: warehouse_oversized_by_load
-- title: Warehouses that ran below one cluster's worth of work for most of the window - size-down candidates
-- domain: warehouse   tier: standard
-- rung: account_usage - the account-wide, year-deep load history. The live twin, information_schema.warehouse_load_history, reaches only 14 days and only one warehouse per call, so a population verdict has to climb.
-- reads: snowflake.account_usage.warehouse_load_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 3 hours documented. Fine for a sizing decision, which is about a month of behaviour; wrong for "did the resize I just did help?" - use warehouse_load_live_is for that.
-- params: :period_days (default 30) trailing window in days; :low_load (default 0.25) an active 5-minute bucket at or below this average running load counts as low - 0.25 means at most a quarter of one statement was executing on average; :queue_tolerance (default 0.1) any warehouse whose peak overload queue exceeds this is never called over-sized, however quiet its average; :warn_share (default 60) percent of active buckets that must be low to earn a WARN; :critical_share (default 85) the same for CRITICAL; :min_buckets (default 200) fewer active buckets than this and the window is too thin to judge
-- confidence: confirmed-docs
-- confidence_note: WAREHOUSE_LOAD_HISTORY and its columns START_TIME, END_TIME, WAREHOUSE_ID, WAREHOUSE_NAME, AVG_RUNNING, AVG_QUEUED_LOAD, AVG_QUEUED_PROVISIONING and AVG_BLOCKED are documented at docs.snowflake.com/en/sql-reference/account-usage/warehouse_load_history, as is the 5-minute bucket grain and the 3-hour latency. The interpretation of query load as concurrency rather than hardware utilization is also from that page. Thresholds are labelled field heuristics exposed as params, not measurements. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, no_activity
-- read_this: One row = one warehouse over the window. The two columns to read together are pct_low_load_buckets (how much of its working time this warehouse spent barely working) and peak_queued_overload (whether it ever ran out of room). A high first number with a zero second number is the size-down case; a high first number with a non-zero second number is a spiky workload, and shrinking it will hurt.
-- healthy: pct_low_load_buckets below :warn_share, or any value of it accompanied by a peak_queued_overload above :queue_tolerance - a warehouse that occasionally saturates is sized for its peak, which is what it is for.
-- investigate_if: pct_low_load_buckets at or above :warn_share (WARN) or :critical_share (CRITICAL) with no measurable overload queue - this warehouse has been paying for headroom it never used. The false positive that matters: query load is CONCURRENCY, not hardware utilization. A single enormous statement that saturates an X-Large for an hour registers as avg_running near 1.0 and lands squarely in the low band - so a warehouse whose work is one heavy statement at a time will be accused here and must not be shrunk on this evidence alone. Check spilling before resizing.
-- actions: 1) list the statements that ran on the warehouse in its busiest buckets and see whether they are many small ones or one large one - free, and it decides the whole question (free); 2) if they are many small ones, drop one size and watch warehouse_load_live_is for a queue appearing (config); 3) if they are one large one, do not resize - the fix is the query, or a second warehouse for the small work so the big warehouse is not kept awake by it (spend).
-- next: warehouse_low_load_hours (if you want the same verdict weighted by credits rather than by buckets), warehouse_load_live_is (if you want to watch the effect of a resize immediately instead of in three hours), warehouse_idle_credit_leak (if the low load turns out to be no load at all)
-- covers: Account-wide, every warehouse, a year of history at 5-minute grain. It does NOT see: credits, so it cannot tell you what the over-sizing cost - warehouse_low_load_hours joins the metering for that; the size of the warehouse, which lives in SHOW WAREHOUSES; or spilling, which is the opposite signal and lives in QUERY_HISTORY.
-- caveats: Buckets in which the warehouse did nothing are not emitted at all, so this query counts only ACTIVE buckets and deliberately says nothing about idle time - idle is warehouse_idle_credit_leak's question, and mixing the two would let a suspended warehouse look busy. AVG_RUNNING is execution time in the bucket divided by bucket length, so it is a concurrency measure that is blind to warehouse size: the same 0.2 means something very different on an X-Small and on a 4X-Large, and this query cannot tell them apart because the view carries no size. AVG_BLOCKED is transaction lock contention and is reported but never used in the verdict, because no resize fixes a lock.

WITH buckets AS (
  -- ACTIVE buckets only: a bucket with no running load is either absent or is idle, and idle
  -- is a different finding. Counting it here would make a sleeping warehouse look over-sized.
  SELECT
    warehouse_name,
    start_time,
    avg_running,
    avg_queued_load,
    avg_queued_provisioning,
    avg_blocked
  FROM snowflake.account_usage.warehouse_load_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND avg_running > 0
),
rolled AS (
  SELECT
    warehouse_name,
    COUNT(*)                                                        AS active_buckets,
    COUNT_IF(avg_running <= :low_load AND avg_queued_load = 0)      AS low_load_buckets,
    ROUND(AVG(avg_running), 3)                                      AS mean_running,
    ROUND(MEDIAN(avg_running), 3)                                   AS median_running,
    ROUND(MAX(avg_running), 3)                                      AS peak_running,
    ROUND(AVG(avg_queued_load), 4)                                  AS mean_queued_overload,
    ROUND(MAX(avg_queued_load), 3)                                  AS peak_queued_overload,
    ROUND(MAX(avg_queued_provisioning), 3)                          AS peak_queued_provisioning,
    ROUND(MAX(avg_blocked), 3)                                      AS peak_blocked,
    MIN(start_time)                                                 AS first_active_bucket,
    MAX(start_time)                                                 AS last_active_bucket
  FROM buckets
  GROUP BY 1
)
SELECT
  warehouse_name,
  active_buckets,
  low_load_buckets,
  ROUND(100 * low_load_buckets / NULLIF(active_buckets, 0), 1) AS pct_low_load_buckets,
  mean_running,
  median_running,
  peak_running,
  mean_queued_overload,
  peak_queued_overload,
  peak_queued_provisioning,
  peak_blocked,
  first_active_bucket,
  last_active_bucket,
  CASE
    WHEN active_buckets < :min_buckets
      THEN 'NOT_ASSESSED'
    WHEN peak_queued_overload > :queue_tolerance
      THEN 'OK'
    WHEN 100 * low_load_buckets / NULLIF(active_buckets, 0) >= :critical_share
      THEN 'CRITICAL'
    WHEN 100 * low_load_buckets / NULLIF(active_buckets, 0) >= :warn_share
      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM rolled
ORDER BY ROUND(100 * low_load_buckets / NULLIF(active_buckets, 0), 1) DESC, active_buckets DESC;
