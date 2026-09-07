-- query_id: gov_policy_reference_coverage
-- title: Across every policy kind, what fraction of the estate actually carries one
-- domain: governance_access   tier: standard
-- rung: account_usage - the account-wide POLICY_REFERENCES view is ACCOUNT_USAGE only, and the denominator needs ACCOUNT_USAGE.TABLES because INFORMATION_SCHEMA can only count the tables in one database at a time.
-- reads: snowflake.account_usage.policy_references, snowflake.account_usage.tables
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default). Several policy kinds are Enterprise Edition or higher.
-- freshness: LAGGED - POLICY_REFERENCES carries a documented latency of up to 2 hours and TABLES up to 90 minutes. The two do not lag by the same amount, so a table created in the last hour can be in the denominator before its policy attachment is in the numerator, which biases coverage DOWN, never up.
-- params: :warn_coverage_pct (default 60) below this percentage a policy kind is flagged WARN; :critical_coverage_pct (default 20) below this it is CRITICAL; :include_views (default 1) set to 0 to count only tables and external tables in the denominator, since a view usually inherits protection from its base table
-- confidence: confirmed-docs
-- confidence_note: POLICY_REFERENCES and TABLES are documented ACCOUNT_USAGE views and every column used is in their documented column lists, including the documented TABLE_TYPE values used to build the denominator. POLICY_KIND is documented as the type of policy but its literal values are NOT enumerated, so this query GROUPS BY whatever POLICY_KIND actually contains rather than testing against assumed literals - which is also why it is the right query to run first when you do not yet know which policy families this account uses.
-- empty_if: no_imported_privileges, account_usage_lag, edition_gated, feature_not_enabled
-- read_this: One row per policy kind found in the account, plus one ANY_POLICY row that counts an object as covered if it carries a policy of any kind at all. The two columns that matter are coverage_pct and objects_total - and the second is the one that decides whether the first means anything.
-- healthy: the ANY_POLICY row is at or above :warn_coverage_pct for the subset of the estate you have decided needs governing, and no policy kind shows attachments_not_active above zero.
-- investigate_if: CRITICAL below :critical_coverage_pct, WARN below :warn_coverage_pct - but read the caveat first, because a low number here is only a finding once the denominator has been narrowed to objects that are supposed to carry a policy. The number that is ALWAYS a finding regardless of denominator is attachments_not_active above zero: an attachment that exists and is not ACTIVE is a control that looks applied and is not. False positive: an account where most tables are staging or scratch and legitimately need no policy - the raw ratio will look alarming and mean nothing.
-- actions: 1) narrow the denominator before acting - re-run with :include_views 0, and treat the trend across weeks as the signal rather than the absolute percentage (free); 2) fix every non-ACTIVE attachment, which is a config error and not a coverage question (config); 3) attach policies through tags rather than object by object, so coverage tracks the estate instead of falling behind it every time a table is created (config).
-- next: gov_masking_policy_coverage (if the masking kind is the one that is low), gov_row_access_policy_coverage (if the row-access kind is the one that is low), gov_applied_sensitive_tags (if you need a denominator that means something - the columns actually declared sensitive)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE. It sees every policy attachment of every kind in one pass, which is the only view of policy coverage this ladder offers. It does NOT know which objects OUGHT to carry a policy, so the denominator is the whole estate and the percentage is a crude ratio by construction.
-- caveats: Coverage against every table in the account is a ratio, not a target - most estates contain large amounts of staging and derived data that correctly carries no policy, so a low percentage is a prompt to narrow the denominator, not evidence of a failure. The ANY_POLICY row is produced with a GROUPING SETS rollup, so a genuinely NULL POLICY_KIND would be indistinguishable from the rollup row; POLICY_KIND is not nullable in practice but the collision is stated rather than hidden. TABLES excludes dropped tables via DELETED but includes transient and temporary ones unless you narrow TABLE_TYPE. A tag-based attachment is counted once, on the tag, not once per column it reaches - so tag-driven governance UNDERSTATES coverage here.

WITH object_universe AS (
  SELECT
    t.table_catalog || '.' || t.table_schema || '.' || t.table_name AS object_key
  FROM snowflake.account_usage.tables t
  WHERE t.deleted IS NULL
    AND t.table_type IN ('BASE TABLE', 'EXTERNAL TABLE', 'VIEW', 'MATERIALIZED VIEW')
    AND (:include_views = 1 OR t.table_type IN ('BASE TABLE', 'EXTERNAL TABLE'))
),
universe_total AS (
  SELECT COUNT(DISTINCT object_key) AS objects_total
  FROM object_universe
),
covered AS (
  SELECT
    COALESCE(UPPER(pr.policy_kind), 'ANY_POLICY')                             AS policy_kind,
    COUNT(DISTINCT pr.policy_db || '.' || pr.policy_schema || '.'
               || pr.policy_name)                                             AS distinct_policies,
    COUNT(*)                                                                  AS attachment_rows,
    SUM(IFF(UPPER(COALESCE(pr.policy_status, '')) <> 'ACTIVE', 1, 0))         AS attachments_not_active,
    COUNT(DISTINCT pr.ref_database_name || '.' || pr.ref_schema_name || '.'
               || pr.ref_entity_name)                                         AS objects_covered,
    COUNT(DISTINCT pr.ref_column_name)                                        AS columns_covered,
    COUNT(DISTINCT pr.tag_name)                                               AS tags_carrying_policy
  FROM snowflake.account_usage.policy_references pr
  GROUP BY GROUPING SETS ((UPPER(pr.policy_kind)), ())
)
SELECT
  c.policy_kind                                                              AS policy_kind,
  c.distinct_policies                                                        AS distinct_policies,
  c.attachment_rows                                                          AS attachment_rows,
  c.attachments_not_active                                                   AS attachments_not_active,
  c.objects_covered                                                          AS objects_covered,
  c.columns_covered                                                          AS columns_covered,
  c.tags_carrying_policy                                                     AS tags_carrying_policy,
  ut.objects_total                                                           AS objects_total,
  GREATEST(ut.objects_total - c.objects_covered, 0)                          AS objects_without_this_kind,
  ROUND(100.0 * c.objects_covered / NULLIF(ut.objects_total, 0), 1)          AS coverage_pct,
  CASE
    WHEN ut.objects_total = 0                                                          THEN 'NOT_ASSESSED'
    WHEN 100.0 * c.objects_covered / NULLIF(ut.objects_total, 0)
         < :critical_coverage_pct                                                      THEN 'CRITICAL'
    WHEN 100.0 * c.objects_covered / NULLIF(ut.objects_total, 0)
         < :warn_coverage_pct                                                          THEN 'WARN'
    WHEN c.attachments_not_active > 0                                                  THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM covered c
CROSS JOIN universe_total ut
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  coverage_pct,
  policy_kind;
