-- query_id: gov_classification_coverage
-- title: How much of the estate has ever been classified, and how stale the newest result is
-- domain: governance_access   tier: deep
-- rung: account_usage - DATA_CLASSIFICATION_LATEST exists only here, and the denominator needs the account-wide table list, which INFORMATION_SCHEMA cannot give you for more than one database at a time.
-- reads: snowflake.account_usage.data_classification_latest, snowflake.account_usage.tables
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default). Sensitive-data classification is an Enterprise Edition feature.
-- freshness: LAGGED - DATA_CLASSIFICATION_LATEST carries a documented latency of up to 3 hours and TABLES up to 90 minutes. A classification that finished this morning may not appear yet, so a freshly classified table can still read as never classified.
-- params: :stale_days (default 180) a classification older than this is treated as stale, because a table reclassifies its meaning every time its schema changes; :min_rows (default 1) tables with fewer rows than this are left out of the denominator, so empty scratch tables do not drag coverage down
-- confidence: confirmed-docs
-- confidence_note: DATA_CLASSIFICATION_LATEST and TABLES are documented ACCOUNT_USAGE views and every column used is in their documented column lists. The failure test is taken directly from the documented meaning of LAST_CLASSIFICATION_ATTEMPT - the docs state that an attempt timestamp later than LAST_CLASSIFIED_ON indicates the most recent attempt failed. The join is on TABLE_ID, which is documented on both views as the internal table identifier, rather than on names, which change.
-- empty_if: no_imported_privileges, account_usage_lag, edition_gated, feature_not_enabled
-- read_this: One row = one table in scope. The two columns that matter are last_classified_on and days_since_classified; coverage_pct is repeated on every row so a single row also tells you the account-level answer. A NULL last_classified_on is the finding, not missing data - it means this table has never been looked at.
-- healthy: coverage_pct is at or above whatever fraction of the estate your data-protection register claims is covered, no table shows last_attempt_failed, and days_since_classified stays under :stale_days on everything that holds personal data.
-- investigate_if: CRITICAL when a table has never been classified - every downstream governance claim about it is an assumption. WARN when the last attempt FAILED (an attempt newer than the last success, which usually means a permission or an unsupported column type and is quietly retried forever), or when the newest result is older than :stale_days. False positive: a table created after the last classification run, and derived or staging tables that nobody intends to classify - narrow the denominator with :min_rows or by schema rather than lowering the threshold.
-- actions: 1) read coverage_pct against what your data-protection register says is covered - the gap between the two is the finding, and it costs nothing to measure (free); 2) fix the failing attempts first: they are cheaper than new coverage and they are silently retrying, so each one is a recurring cost as well as a gap (config); 3) turn on automatic classification for the schemas that hold customer data so coverage tracks the estate rather than a one-off sweep (spend).
-- next: gov_applied_sensitive_tags (to see what the classifications that DID run actually declared), gov_masking_policy_coverage (to see whether anything was masked as a result), gov_policy_reference_coverage (for the same coverage question across policy kinds rather than classification)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE. It sees the latest classification result per table and the whole table estate, so unlike the tag queries it CAN name what it missed. It does not see classification history - only the latest state per table - so it cannot tell you whether a table used to be classified and stopped.
-- caveats: The docs are explicit that a DATA_CLASSIFICATION_LATEST row is removed when its table is dropped, renamed or RECLASSIFIED, so a table renamed since its classification reads as never classified and a reclassification in progress can briefly do the same. Coverage against every base and external table is a crude ratio - narrow it with :min_rows or by schema before treating the percentage as a target. Views and materialized views are excluded from the denominator because classification applies to the underlying tables. ROW_COUNT on ACCOUNT_USAGE.TABLES is itself a lagged estimate, so :min_rows filters approximately.

WITH estate AS (
  SELECT
    t.table_id                                          AS table_id,
    t.table_catalog                                     AS database_name,
    t.table_schema                                      AS schema_name,
    t.table_name                                        AS table_name,
    t.table_type                                        AS table_type,
    t.is_transient                                      AS is_transient,
    t.row_count                                         AS row_count,
    t.bytes                                             AS bytes,
    t.created                                           AS table_created_on
  FROM snowflake.account_usage.tables t
  WHERE t.deleted IS NULL
    AND t.table_type IN ('BASE TABLE', 'EXTERNAL TABLE')
    AND COALESCE(t.row_count, 0) >= :min_rows
),
latest AS (
  -- projected here so the view own STATUS column cannot collide with this query status band
  SELECT
    c.table_id                                        AS table_id,
    c.status                                          AS classification_status,
    c.trigger_type                                    AS trigger_type,
    c.last_classified_on                              AS last_classified_on,
    c.last_classification_attempt                     AS last_classification_attempt,
    c.error_message                                   AS error_message
  FROM snowflake.account_usage.data_classification_latest c
)
SELECT
  e.database_name                                                         AS database_name,
  e.schema_name                                                           AS schema_name,
  e.table_name                                                            AS table_name,
  e.table_type                                                            AS table_type,
  e.is_transient                                                          AS is_transient,
  e.row_count                                                             AS row_count,
  e.bytes                                                                 AS bytes,
  e.table_created_on                                                      AS table_created_on,
  c.classification_status                                                 AS classification_status,
  c.trigger_type                                                       AS trigger_type,
  c.last_classified_on                                                    AS last_classified_on,
  DATEDIFF('day', c.last_classified_on, CURRENT_TIMESTAMP())              AS days_since_classified,
  c.last_classification_attempt                                           AS last_classification_attempt,
  IFF(c.last_classification_attempt > c.last_classified_on, TRUE, FALSE)  AS last_attempt_failed,
  c.error_message                                                         AS error_message,
  COUNT(*) OVER ()                                                        AS tables_in_scope,
  SUM(IFF(c.last_classified_on IS NOT NULL, 1, 0)) OVER ()                AS tables_ever_classified,
  ROUND(100.0 * SUM(IFF(c.last_classified_on IS NOT NULL, 1, 0)) OVER ()
        / NULLIF(COUNT(*) OVER (), 0), 1)                                 AS coverage_pct,
  MAX(c.last_classified_on) OVER ()                                       AS newest_classification_in_account,
  CASE
    WHEN c.last_classified_on IS NULL                                      THEN 'CRITICAL'
    WHEN c.last_classification_attempt > c.last_classified_on              THEN 'WARN'
    WHEN DATEDIFF('day', c.last_classified_on, CURRENT_TIMESTAMP())
         > :stale_days                                                     THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM estate e
LEFT JOIN latest c
  ON c.table_id = e.table_id
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  bytes DESC NULLS LAST,
  database_name,
  schema_name,
  table_name;
