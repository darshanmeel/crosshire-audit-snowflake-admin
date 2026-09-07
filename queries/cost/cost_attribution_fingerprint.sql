-- query_id: cost_attribution_fingerprint
-- title: Which repeated query SHAPES carry the credits - so a fix lands on a pattern, not a statement
-- domain: cost   tier: deep
-- rung: account_usage - QUERY_PARAMETERIZED_HASH and the per-query credit both live on QUERY_ATTRIBUTION_HISTORY and on no lower rung. There is no live equivalent of a per-query credit figure anywhere in Snowflake.
-- reads: snowflake.account_usage.query_attribution_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, or the USAGE_VIEWER / GOVERNANCE_VIEWER database role on SNOWFLAKE
-- freshness: LAGGED - up to 8 hours. A shape introduced this morning will not be here yet, so this query answers what has been expensive, never what just started being expensive.
-- params: :period_days (default 30) rolling window; :min_executions (default 5) a shape must recur at least this often to be treated as a pattern rather than a one-off; :shape_warn_pct (default 5) share of the window's attributed credits carried by one shape that raises WARN; :shape_critical_pct (default 15) the same share that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: QUERY_HASH, QUERY_PARAMETERIZED_HASH, QUERY_ID, USER_NAME, WAREHOUSE_NAME, START_TIME, CREDITS_ATTRIBUTED_COMPUTE and CREDITS_USED_QUERY_ACCELERATION are all documented QUERY_ATTRIBUTION_HISTORY columns. Not run live. Doc-verified and load-bearing: this view carries NO QUERY_TEXT, which is why the output hands you a sample QUERY_ID to look up rather than the SQL itself.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one query SHAPE - a QUERY_PARAMETERIZED_HASH, i.e. the same statement with different literals bound into it. CREDITS_ATTRIBUTED_TOTAL is what that whole pattern cost across the window; EXECUTIONS is how many times a single fix would pay off. MOST_EXPENSIVE_QUERY_ID is the handle: take it to QUERY_HISTORY to read the actual SQL, which this view does not carry.
-- healthy: the credit distribution across shapes has a long tail and no single shape above :shape_warn_pct. A dashboard query that runs ten thousand times cheaply is healthy; a shape that runs ten thousand times and holds a fifth of the bill is not.
-- investigate_if: one shape holds at or above :shape_warn_pct of attributed credits across :min_executions or more runs - that is the highest-leverage fix available, because every improvement multiplies by the execution count. Also look at a shape whose P95_CREDITS is far above its MEDIAN_CREDITS: the same SQL is cheap most of the time and occasionally catastrophic, which is a data-skew or a pruning problem rather than a SQL problem. False positive: a legitimate nightly full rebuild will always dominate a shape ranking and is not a defect.
-- actions: 1) pull MOST_EXPENSIVE_QUERY_ID into QUERY_HISTORY and read the SQL and its pruning before touching anything - the shape ranking says where to look and nothing more (free); 2) if the shape is a scheduled job re-reading the same data, cache or incrementalise it, and give it a QUERY_TAG so its cost stays visible afterwards (config); 3) resize or accelerate only when the median run is already efficient and the cost is genuine volume (spend).
-- next: cost_query_attribution_by_user (if you need who runs the shape and on which warehouse), cost_chargeback_by_query_tag (if the shape should have carried a tag and did not), cost_credit_spike_anomaly (if the shape appears only on the days a warehouse spiked)
-- covers: EXECUTION credits for statements that ran on a warehouse. Shapes with no warehouse behind them, sub-100ms statements, and Adaptive Warehouse jobs are all outside this view. Parameterized hashing groups a statement with its literals varied; two statements that differ structurally - a different column list, a different join - are DIFFERENT shapes here even when a human would call them the same query.
-- caveats: QUERY_PARAMETERIZED_HASH groups by parameterized text, so a workload built by string concatenation rather than bound parameters will fragment into many shapes and hide exactly the pattern this query exists to find - if the ranking looks suspiciously flat, that is usually why. A stored procedure's child statements are separate shapes from the call that issued them; group on ROOT_QUERY_ID if you want the procedure as one unit. Percentiles are computed over the attributed credits of individual executions, so a shape with few executions has a noisy P95. The credits themselves are a weighted apportionment under concurrency, not an isolated measurement.

WITH attributed AS (
  SELECT
    query_parameterized_hash,
    query_hash,
    query_id,
    user_name,
    warehouse_name,
    start_time,
    COALESCE(credits_attributed_compute, 0)
      + COALESCE(credits_used_query_acceleration, 0) AS credits_attributed
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
shape AS (
  SELECT
    query_parameterized_hash,
    COUNT(*)                                          AS executions,
    COUNT(DISTINCT query_hash)                        AS distinct_exact_texts,
    COUNT(DISTINCT user_name)                         AS distinct_users,
    COUNT(DISTINCT warehouse_name)                    AS distinct_warehouses,
    COUNT(DISTINCT DATE_TRUNC('day', start_time)::DATE) AS active_days,
    SUM(credits_attributed)                           AS credits_attributed_total,
    AVG(credits_attributed)                           AS avg_credits_per_execution,
    MEDIAN(credits_attributed)                        AS median_credits_per_execution,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY credits_attributed) AS p95_credits_per_execution,
    MAX(credits_attributed)                           AS max_credits_per_execution,
    MAX_BY(query_id, credits_attributed)              AS most_expensive_query_id,
    MIN(start_time)                                   AS first_seen,
    MAX(start_time)                                   AS last_seen
  FROM attributed
  WHERE query_parameterized_hash IS NOT NULL
  GROUP BY query_parameterized_hash
),
scored AS (
  SELECT
    shape.*,
    100.0 * credits_attributed_total
          / NULLIF(SUM(credits_attributed_total) OVER (), 0) AS pct_of_attributed_credits,
    p95_credits_per_execution
          / NULLIF(median_credits_per_execution, 0)          AS p95_to_median_ratio
  FROM shape
)
SELECT
  query_parameterized_hash,
  executions,
  active_days,
  distinct_exact_texts,
  distinct_users,
  distinct_warehouses,
  ROUND(credits_attributed_total, 3)        AS credits_attributed_total,
  ROUND(pct_of_attributed_credits, 1)       AS pct_of_attributed_credits,
  ROUND(avg_credits_per_execution, 5)       AS avg_credits_per_execution,
  ROUND(median_credits_per_execution, 5)    AS median_credits_per_execution,
  ROUND(p95_credits_per_execution, 5)       AS p95_credits_per_execution,
  ROUND(max_credits_per_execution, 5)       AS max_credits_per_execution,
  ROUND(p95_to_median_ratio, 2)             AS p95_to_median_ratio,
  most_expensive_query_id,
  first_seen,
  last_seen,
  CASE
    WHEN executions < :min_executions                            THEN 'NOT_ASSESSED'
    WHEN pct_of_attributed_credits >= :shape_critical_pct        THEN 'CRITICAL'
    WHEN pct_of_attributed_credits >= :shape_warn_pct            THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  credits_attributed_total DESC;
