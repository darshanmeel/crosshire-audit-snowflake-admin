-- query_id: perf_bytes_scanned_divergence
-- title: Where a scan number stops being trustworthy - statement-reported scans against table-reported scans
-- domain: performance   tier: deep
-- rung: account_usage - both sides of the comparison are ACCOUNT_USAGE views, and the comparison is the whole point: neither view alone can tell you it is wrong
-- reads: snowflake.account_usage.query_history, snowflake.account_usage.table_query_pruning_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default
-- freshness: LAGGED - and unevenly, which is itself a source of divergence. QUERY_HISTORY lags up to 45 minutes; TABLE_QUERY_PRUNING_HISTORY lags up to 4 hours. Run this against a window whose tail is older than the slower lag, or the most recent day will look divergent purely because one side has not landed yet.
-- params: :period_days (default 30) trailing window in days, up to 365; :settle_days (default 1) days trimmed off the RECENT end of the window so the slower view has landed - the honest fix for the uneven lag; :min_queries (default 10) statements a shape needs on a day before it is judged; :warn_divergence_pct (default 20) percentage points of partition-accounting divergence at which the row is WARN; :critical_divergence_pct (default 50) at which it is CRITICAL; :top_n (default 200) rows returned, worst first
-- confidence: confirmed-docs
-- confidence_note: QUERY_HASH, PARTITIONS_SCANNED, PARTITIONS_TOTAL, BYTES_SCANNED, PERCENTAGE_SCANNED_FROM_CACHE and QUERY_ACCELERATION_PARTITIONS_SCANNED on QUERY_HISTORY, and QUERY_HASH, WAREHOUSE_NAME, NUM_QUERIES and PARTITIONS_SCANNED on TABLE_QUERY_PRUNING_HISTORY, were all checked against docs.snowflake.com. Not run against a live account. One shape fact governs the whole design: TABLE_QUERY_PRUNING_HISTORY carries NO bytes column, so a literal bytes-to-bytes comparison is impossible. The comparison here is therefore made in PARTITIONS, which both views report, and bytes-per-partition is derived from the statement side only and printed as context.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one query shape on one warehouse on one day. The two columns that matter are DIVERGENCE_PCT and CACHE_PCT - divergence is how far the partitions the STATEMENTS claim to have scanned sit from the partitions the TABLES say were scanned, and the cache column is the most common innocent explanation for the gap.
-- healthy: divergence near zero on the shapes that carry real volume. The two views are counting the same work from two directions, so they should broadly agree, and where they do the scan numbers can be trusted for sizing and chargeback.
-- investigate_if: WARN at :warn_divergence_pct and CRITICAL at :critical_divergence_pct percentage points of divergence on a shape with at least :min_queries statements that day. A false positive is common enough to name three kinds: a high CACHE_PCT means the statement was served from cache and never touched the tables; a non-zero QUERY_ACCELERATION_PARTITIONS_SCANNED means the acceleration service scanned on the warehouse behalf; and any statement reading a stage, an external table or a shared object scans bytes that the table-side view never sees. Rule those three out before treating divergence as a defect.
-- actions: 1) check the three innocent explanations first - cache, query acceleration, and non-table sources - which costs nothing and resolves most rows (free); 2) if a shape still diverges, stop using its BYTES_SCANNED as a chargeback or sizing input and drive the decision from the table side instead, which is the more conservative number (config); 3) nothing here is fixed by spending - this query protects a number, it does not improve one (spend).
-- next: perf_table_pruning_gap (for the table-side story on the same tables), perf_repeated_query_shapes (to see the shape and its text), perf_spilling_queries (if the statements behind a divergent shape also spill), perf_operator_stats_probe (to see, for one query id, exactly which operator scanned what)
-- covers: Only shapes present on BOTH sides, matched on QUERY_HASH, warehouse and day. A statement that scanned no table at all cannot appear, which is correct but means the query cannot find the extreme case where the table side is entirely empty - it finds disagreement, not absence. It is deliberately restricted to successful statements, since a statement that failed part-way has no reason to reconcile.
-- caveats: The join grain is a compromise. QUERY_HISTORY is per statement while TABLE_QUERY_PRUNING_HISTORY is per interval, and the two interval definitions are not documented as identical, so both sides are rolled to a calendar DAY before joining - a shape whose behaviour changes within a day is averaged. QUERY_HASH is the canonicalised-text hash, not the parameterised one, so two literal variants of the same SQL are separate rows here by design. The table side sums PARTITIONS_SCANNED across every table a shape touched, so a shape joining five tables legitimately reports more partitions than a single-table statement of the same name. AVG_BYTES_PER_PARTITION is derived from the statement side only and is context, not evidence. :settle_days exists because the uneven lag would otherwise manufacture a finding on the newest day of every run.

WITH bounds AS (
  SELECT
    DATEADD('day', -:period_days, CURRENT_TIMESTAMP()) AS window_start,
    DATEADD('day', -:settle_days, CURRENT_TIMESTAMP()) AS window_end
),
statement_side AS (
  SELECT
    DATE_TRUNC('day', q.start_time)                                        AS day,
    q.query_hash,
    q.warehouse_name,
    COUNT(*)                                                               AS statements,
    SUM(COALESCE(q.partitions_scanned, 0))                                 AS qh_partitions_scanned,
    SUM(COALESCE(q.partitions_total, 0))                                   AS qh_partitions_total,
    SUM(COALESCE(q.bytes_scanned, 0))                                      AS qh_bytes_scanned,
    SUM(COALESCE(q.query_acceleration_partitions_scanned, 0))              AS qas_partitions_scanned,
    AVG(COALESCE(q.percentage_scanned_from_cache, 0))                      AS avg_cache_fraction,
    SUM(COALESCE(q.execution_time, 0))                                     AS execution_ms,
    ANY_VALUE(q.query_id)                                                  AS sample_query_id,
    ANY_VALUE(q.query_parameterized_hash)                                  AS sample_shape_hash,
    ANY_VALUE(LEFT(q.query_text, 300))                                     AS query_text_head
  FROM snowflake.account_usage.query_history q
  CROSS JOIN bounds b
  WHERE q.start_time >= b.window_start
    AND q.start_time <  b.window_end
    AND UPPER(q.execution_status) = 'SUCCESS'
    AND q.query_hash IS NOT NULL
    AND q.warehouse_name IS NOT NULL
    AND COALESCE(q.is_client_generated_statement, FALSE) = FALSE
  GROUP BY 1, 2, 3
),
table_side AS (
  SELECT
    DATE_TRUNC('day', t.interval_start_time)      AS day,
    t.query_hash,
    t.warehouse_name,
    SUM(COALESCE(t.num_queries, 0))               AS tp_query_count,
    SUM(COALESCE(t.partitions_scanned, 0))        AS tp_partitions_scanned,
    SUM(COALESCE(t.partitions_pruned, 0))         AS tp_partitions_pruned,
    COUNT(DISTINCT t.database_name || '.' || t.schema_name || '.' || t.table_name) AS tables_touched,
    SUM(COALESCE(t.aggregate_query_execution_time, 0)) AS tp_execution_ms
  FROM snowflake.account_usage.table_query_pruning_history t
  CROSS JOIN bounds b
  WHERE t.interval_start_time >= b.window_start
    AND t.interval_start_time <  b.window_end
    AND t.query_hash IS NOT NULL
    AND t.warehouse_name IS NOT NULL
  GROUP BY 1, 2, 3
),
joined AS (
  SELECT
    s.day,
    s.query_hash,
    s.warehouse_name,
    s.statements,
    s.qh_partitions_scanned,
    s.qh_partitions_total,
    s.qh_bytes_scanned,
    s.qas_partitions_scanned,
    s.avg_cache_fraction,
    s.execution_ms,
    s.sample_query_id,
    s.sample_shape_hash,
    s.query_text_head,
    t.tp_query_count,
    t.tp_partitions_scanned,
    t.tp_partitions_pruned,
    t.tables_touched,
    t.tp_execution_ms,
    ABS(s.qh_partitions_scanned - t.tp_partitions_scanned)                                  AS partition_gap,
    ROUND(DIV0(ABS(s.qh_partitions_scanned - t.tp_partitions_scanned),
               NULLIF(GREATEST(s.qh_partitions_scanned, t.tp_partitions_scanned), 0)) * 100, 2) AS divergence_pct,
    ROUND(s.avg_cache_fraction, 2)                                                          AS cache_pct,
    ROUND(DIV0(s.qh_bytes_scanned, NULLIF(s.qh_partitions_scanned, 0)) / POWER(1024, 2), 3) AS avg_mb_per_partition
  FROM statement_side s
  JOIN table_side t
    ON  t.day            = s.day
    AND t.query_hash     = s.query_hash
    AND t.warehouse_name = s.warehouse_name
)
SELECT
  CASE
    WHEN statements < :min_queries                     THEN 'NOT_ASSESSED'
    WHEN divergence_pct >= :critical_divergence_pct     THEN 'CRITICAL'
    WHEN divergence_pct >= :warn_divergence_pct         THEN 'WARN'
    ELSE 'OK'
  END                                                  AS status,
  day,
  query_hash,
  warehouse_name,
  statements,
  tp_query_count                                       AS table_side_query_count,
  divergence_pct,
  cache_pct,
  qas_partitions_scanned,
  tables_touched,
  qh_partitions_scanned                                AS statement_side_partitions_scanned,
  tp_partitions_scanned                                AS table_side_partitions_scanned,
  partition_gap,
  qh_partitions_total                                  AS statement_side_partitions_total,
  tp_partitions_pruned                                 AS table_side_partitions_pruned,
  ROUND(qh_bytes_scanned / POWER(1024, 3), 3)          AS statement_side_gb_scanned,
  avg_mb_per_partition,
  ROUND(execution_ms    / 3600000.0, 3)                AS statement_side_execution_hours,
  ROUND(tp_execution_ms / 3600000.0, 3)                AS table_side_execution_hours,
  sample_query_id,
  sample_shape_hash,
  query_text_head
FROM joined
ORDER BY
  IFF(statements < :min_queries, 1, 0),
  divergence_pct DESC,
  partition_gap DESC
LIMIT :top_n;
