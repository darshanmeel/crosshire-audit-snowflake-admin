-- query_id: perf_query_insights
-- title: What Snowflake itself says is wrong with these queries - the vendor verdict
-- domain: performance   tier: deep
-- rung: account_usage - QUERY_INSIGHTS is an ACCOUNT_USAGE-only view; nothing on a lower rung carries an engine-authored verdict
-- reads: snowflake.account_usage.query_insights
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - the documented latency on QUERY_INSIGHTS is up to 90 minutes. The view page states no explicit retention, so treat anything older than the ACCOUNT_USAGE norm as unproven rather than assuming a year.
-- params: :period_days (default 30) trailing window in days; :warn_occurrences (default 5) times one insight type must fire before it is WARN; :critical_occurrences (default 50) times it must fire to be CRITICAL; :top_n (default 200) rows returned, worst first
-- confidence: confirmed-docs
-- confidence_note: Every column named here - INSIGHT_TYPE_ID, INSIGHT_TOPIC, IS_OPPORTUNITY, MESSAGE, SUGGESTIONS, QUERY_HASH, QUERY_PARAMETERIZED_HASH - was checked against docs.snowflake.com/en/sql-reference/account-usage/query_insights. Not run against a live account. The documented INSIGHT_TOPIC values are TABLE_SCAN, QUERY, JOIN, AGGREGATE, UNION and WAREHOUSE; the INSIGHT_TYPE_ID string set is NOT a documented enum and is therefore never matched against a literal here, only grouped.
-- empty_if: no_imported_privileges, account_usage_lag, preview_unavailable, feature_not_enabled, no_activity
-- read_this: One row = one insight TYPE within one topic, rolled up across the window. The two columns that matter are OCCURRENCES and DISTINCT_SHAPES - one insight firing a thousand times on a single shape is one fix, while the same insight spread across two hundred shapes is a habit in how the account writes SQL.
-- healthy: few or no rows with IS_OPPORTUNITY true, and the ones that exist concentrated on a handful of shapes you already know about.
-- investigate_if: WARN at :warn_occurrences and CRITICAL at :critical_occurrences occurrences of an insight type flagged as an opportunity. A false positive looks like an insight on a deliberately unfiltered statement - a full extract, a validation count - where the engine is right that no filter was pushed down and you are right that none was wanted. Rows with IS_OPPORTUNITY false are informational and are reported as OK regardless of how often they fire.
-- actions: 1) read SAMPLE_SUGGESTIONS and apply it to the SQL, which is the whole point of the view and costs nothing (free); 2) where the suggestion is structural rather than textual - a clustering key, a search optimization path - route it through the pruning queries first so the change is justified by measured pruning, not by a hint alone (config); 3) treat a WAREHOUSE-topic insight as the only one that may end in spend, and even then confirm it against spill and queuing before resizing (spend).
-- next: perf_spilling_queries (if the WAREHOUSE topic dominates), perf_table_pruning_gap (if the TABLE_SCAN topic dominates), perf_repeated_query_shapes (to size the shape a JOIN or AGGREGATE insight fires on), perf_operator_stats_probe (to see the operator behind one SAMPLE_QUERY_ID)
-- covers: Only the statements Snowflake chose to write an insight for - this is a vendor opinion, not a census. Absence of an insight is not evidence a query is fine, and the view carries no bytes, credits or spill columns of its own, so the SIZE of each problem must come from QUERY_HISTORY or the pruning views.
-- caveats: The engine decides which queries earn an insight and that selection is not documented, so occurrence counts compare insight types against each other, never against total query volume. SUGGESTIONS is an ARRAY and MESSAGE a VARIANT; both are sampled here with ANY_VALUE, so the sample may not represent the whole group and both can carry object names from your own account - treat the output as internal. INSIGHT_TYPE_ID is grouped as an opaque string on purpose: matching it against hard-coded literals would break the moment Snowflake adds a type. The view has no QUERY_ID join back to QUERY_HISTORY beyond the two hashes and the sampled query id, so a per-statement drill-down is a second query, not a join here.

WITH insights AS (
  SELECT
    insight_topic,
    insight_type_id,
    is_opportunity,
    query_id,
    query_hash,
    query_parameterized_hash,
    warehouse_name,
    start_time,
    COALESCE(total_elapsed_time, 0) AS elapsed_ms,
    message,
    suggestions
  FROM snowflake.account_usage.query_insights
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
rolled AS (
  SELECT
    insight_topic,
    insight_type_id,
    is_opportunity,
    COUNT(*)                                        AS occurrences,
    COUNT(DISTINCT query_id)                        AS distinct_queries,
    COUNT(DISTINCT query_parameterized_hash)        AS distinct_shapes,
    COUNT(DISTINCT warehouse_name)                  AS distinct_warehouses,
    MIN(start_time)                                 AS first_seen,
    MAX(start_time)                                 AS last_seen,
    SUM(elapsed_ms)                                 AS flagged_elapsed_ms,
    MAX(elapsed_ms)                                 AS worst_elapsed_ms,
    ANY_VALUE(query_id)                             AS sample_query_id,
    ANY_VALUE(query_parameterized_hash)             AS sample_shape_hash,
    ANY_VALUE(warehouse_name)                       AS sample_warehouse_name,
    ANY_VALUE(message)                              AS sample_message,
    ANY_VALUE(suggestions)                          AS sample_suggestions
  FROM insights
  GROUP BY 1, 2, 3
)
SELECT
  CASE
    WHEN NOT COALESCE(is_opportunity, FALSE)                THEN 'OK'
    WHEN occurrences >= :critical_occurrences               THEN 'CRITICAL'
    WHEN occurrences >= :warn_occurrences                   THEN 'WARN'
    ELSE 'OK'
  END                                               AS status,
  insight_topic,
  insight_type_id,
  is_opportunity,
  occurrences,
  distinct_queries,
  distinct_shapes,
  distinct_warehouses,
  first_seen,
  last_seen,
  ROUND(flagged_elapsed_ms / 3600000.0, 3)          AS flagged_elapsed_hours,
  ROUND(worst_elapsed_ms   / 1000.0, 1)             AS worst_elapsed_seconds,
  sample_query_id,
  sample_shape_hash,
  sample_warehouse_name,
  sample_message,
  sample_suggestions
FROM rolled
ORDER BY
  IFF(COALESCE(is_opportunity, FALSE), 0, 1),
  occurrences DESC,
  flagged_elapsed_ms DESC
LIMIT :top_n;
