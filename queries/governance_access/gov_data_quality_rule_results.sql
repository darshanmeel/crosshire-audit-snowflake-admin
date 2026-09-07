-- query_id: gov_data_quality_rule_results
-- title: Which data-quality rules are armed, which are silently suspended, and what they cost
-- domain: governance_access   tier: deep
-- rung: account_usage - DATA_METRIC_FUNCTION_REFERENCES exists on both rungs, but the INFORMATION_SCHEMA form is a table function scoped to one object and carries no cost, so only this rung can pair every rule in the account with what running it billed.
-- reads: snowflake.account_usage.data_metric_function_references, snowflake.account_usage.data_quality_monitoring_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default). Data Metric Functions are an Enterprise Edition feature.
-- freshness: LAGGED - both views carry a documented latency of up to 3 hours. A rule suspended an hour ago can still read as STARTED, so confirm the schedule state on the object before acting on a CRITICAL row.
-- params: :period_days (default 30) the window over which monitoring credits and evaluation activity are summed; :credit_alert (default 1) monitoring credits above this on a single table in the window are flagged, since a data-quality check that costs more than the pipeline it guards is a finding of its own
-- confidence: confirmed-docs
-- confidence_note: Both views are documented ACCOUNT_USAGE views and every column used is in their documented column lists, including SCHEDULE_STATUS with its documented STARTED and SUSPENDED values and LEVEL with TABLE and SCHEMA. The important verified fact is a NEGATIVE one: neither view carries a metric VALUE or a pass/fail outcome, and DATA_METRIC_FUNCTION_EXPECTATIONS carries the boolean expectation expression without its result. The documented home of the outcomes is the event table SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS_RAW and its flattened view, which are not ACCOUNT_USAGE views and are therefore out of this query scope.
-- empty_if: no_imported_privileges, account_usage_lag, edition_gated, feature_not_enabled, no_activity
-- read_this: One row = one data metric function attached to one table or schema. The two columns that matter are schedule_status (whether the rule is running at all) and billing_intervals_in_window (whether it has actually run inside :period_days). This query answers whether your rules are ARMED and what they cost; it deliberately does NOT claim to answer which are breaching - see caveats for where that answer lives.
-- healthy: every association reports schedule_status STARTED, every one shows billing_intervals_in_window above zero, and credits_used_in_window stays small relative to what the monitored pipeline costs.
-- investigate_if: CRITICAL when schedule_status is SUSPENDED - a suspended rule fails silently and looks identical to a passing one on every dashboard built from the association list. WARN when a rule is STARTED but the table shows no monitoring billing in the window, which usually means the schedule never fired or the object was replaced, and WARN when credits_used_in_window exceeds :credit_alert. False positive: a rule attached inside the last few days, and a TRIGGER_ON_CHANGES schedule on a table that genuinely did not change in the window.
-- actions: 1) list the SUSPENDED associations and ask whether each was suspended deliberately - the answer is almost always that it was temporary and nobody resumed it (free); 2) resume or drop them, since an association that is neither running nor wanted is a control that reports success by absence (config); 3) move expensive per-row metrics to a coarser schedule or a smaller column set before adding more rules, and read the cost per table rather than per rule (spend).
-- next: gov_classification_coverage (if the tables carrying rules are not the tables holding the sensitive data), gov_policy_reference_coverage (if governance coverage rather than data quality is the question), gov_masking_policy_coverage (if a monitored table also needs its columns masked)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE plus a rolling cost window. It sees every DMF association, its schedule, the role it runs as, and what monitoring billed per table. It does NOT see a single metric value, a threshold breach, or an anomaly-detection verdict - ACCOUNT_USAGE carries none of them.
-- caveats: The catalogue question asks which rules are BREACHING, and this rung cannot answer that half honestly. The documented home of DMF results is the event table SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS_RAW and its flattened view SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS, neither of which is an ACCOUNT_USAGE view, so the breach verdict is a separate query against a separate object with separate privileges. What this query does answer is the question that has to come first: which rules are even running. Cost is attributed per TABLE by the usage view, not per metric, so credits_per_metric_on_table divides evenly across the metrics on a table and is an apportionment rather than a measurement. Schema-level associations (LEVEL SCHEMA) cover tables that are never named in this view, so their row count understates how many objects they touch.

WITH dmf_cost AS (
  SELECT
    h.database_name                     AS database_name,
    h.schema_name                       AS schema_name,
    h.table_name                        AS table_name,
    SUM(h.credits_used)                 AS credits_used,
    COUNT(*)                            AS billing_intervals,
    MAX(h.end_time)                     AS last_billed_at
  FROM snowflake.account_usage.data_quality_monitoring_usage_history h
  WHERE h.start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3
)
SELECT
  r.ref_database_name                                                          AS database_name,
  r.ref_schema_name                                                            AS schema_name,
  r.ref_entity_name                                                            AS table_name,
  r.ref_entity_domain                                                          AS object_kind,
  r.metric_database_name || '.' || r.metric_schema_name || '.' || r.metric_name AS metric,
  r.argument_signature                                                         AS argument_signature,
  r.ref_arguments                                                              AS ref_arguments,
  r.level                                                                      AS association_level,
  r.schedule                                                                   AS schedule,
  r.schedule_status                                                            AS schedule_status,
  r.anomaly_detection_status                                                   AS anomaly_detection_status,
  r.use_role                                                                   AS use_role,
  COALESCE(c.credits_used, 0)                                                  AS credits_used_in_window,
  COALESCE(c.billing_intervals, 0)                                             AS billing_intervals_in_window,
  c.last_billed_at                                                             AS last_billed_at,
  COUNT(*) OVER (PARTITION BY r.ref_database_name, r.ref_schema_name,
                              r.ref_entity_name)                               AS metrics_on_this_table,
  ROUND(COALESCE(c.credits_used, 0)
        / NULLIF(COUNT(*) OVER (PARTITION BY r.ref_database_name, r.ref_schema_name,
                                             r.ref_entity_name), 0), 6)        AS credits_per_metric_on_table,
  CASE
    WHEN UPPER(COALESCE(r.schedule_status, '')) LIKE 'SUSPENDED%'    THEN 'CRITICAL'
    WHEN COALESCE(c.billing_intervals, 0) = 0                        THEN 'WARN'
    WHEN COALESCE(c.credits_used, 0) > :credit_alert                 THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM snowflake.account_usage.data_metric_function_references r
LEFT JOIN dmf_cost c
  ON  c.database_name = r.ref_database_name
  AND c.schema_name   = r.ref_schema_name
  AND c.table_name    = r.ref_entity_name
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  credits_used_in_window DESC,
  database_name,
  schema_name,
  table_name,
  metric;
