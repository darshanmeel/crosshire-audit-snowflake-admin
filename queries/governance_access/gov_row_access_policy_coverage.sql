-- query_id: gov_row_access_policy_coverage
-- title: Row-access policies, and the masked tables that have no row filter at all
-- domain: governance_access   tier: deep
-- rung: account_usage - ROW_ACCESS_POLICIES and the account-wide POLICY_REFERENCES are ACCOUNT_USAGE only. The live rung can answer which policies sit on ONE object; nothing below this rung can tell you which tables were left out.
-- reads: snowflake.account_usage.row_access_policies, snowflake.account_usage.policy_references
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default). Row access policies are an Enterprise Edition feature.
-- freshness: LAGGED - both views carry a documented latency of up to 2 hours, so a policy attached this morning may still show as unattached; :grace_days keeps a brand-new policy out of the finding band.
-- params: :grace_days (default 7) a policy created inside this many days is not yet judged for having no attachment; :min_masked_columns (default 1) how many masked columns a table must carry before its missing row filter is reported; :critical_masked_columns (default 3) at this many masked columns on a table with no row-access policy the row is raised to CRITICAL
-- confidence: confirmed-docs
-- confidence_note: ROW_ACCESS_POLICIES and POLICY_REFERENCES are documented ACCOUNT_USAGE views and every column used is in their documented column lists, including the absence of a DELETED column on POLICY_REFERENCES. POLICY_KIND literals are NOT enumerated in the docs, so both policy families are matched with UPPER(policy_kind) LIKE patterns rather than assumed literals - if your account reports a different spelling, widen the two LIKE patterns and nothing else changes.
-- empty_if: no_imported_privileges, account_usage_lag, edition_gated, feature_not_enabled
-- read_this: Two kinds of row, told apart by finding_kind. ROW_POLICY rows are one per live row-access policy, and the column that matters is attachments_total. TABLE_WITHOUT_ROW_POLICY rows are one per table that carries column masking but no row filter, and the column that matters is masked_columns - somebody already declared that table sensitive, at column level only.
-- healthy: no policy is older than :grace_days with zero attachments, every attachment reports POLICY_STATUS ACTIVE, and no table carries masked columns without a row-access policy unless a person has said in writing that column masking is sufficient for it.
-- investigate_if: CRITICAL when a live policy has no attachment past the grace window, or when a table carries :critical_masked_columns or more masked columns and no row filter - masking hides values in rows the reader should not have seen at all. WARN for a table with fewer masked columns and no row filter, and for a policy whose attachments are not ACTIVE. False positive: a single-tenant table where every row is legitimately visible to every reader of the table, and a reference or dimension table that carries one masked column for a name.
-- actions: 1) list the TABLE_WITHOUT_ROW_POLICY rows and ask the data owner one question per table - is every row in here visible to everyone who can read it (free); 2) attach an existing row-access policy rather than writing a new one, so the tenancy predicate stays in one place (config); 3) where a new policy is genuinely needed, attach it to a tag and tag the tables, so the next table created inherits the filter instead of being missed (config).
-- next: gov_masking_policy_coverage (if the masking side needs the same audit), gov_policy_reference_coverage (if you want the coverage ratio across every policy kind), access_who_can_read_object_au (if a table with no row filter turns out to be readable by more roles than you expected)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE. It sees every row-access policy and every policy attachment in the account. It does NOT evaluate the policy body, so it cannot say whether an attached filter actually restricts anything. Its universe for the second finding is objects that already appear in POLICY_REFERENCES: a table with no policy of any kind is invisible to this query by construction.
-- caveats: The per-tenant question cannot be answered from these two views - no view marks a table as multi-tenant. This query substitutes a defensible proxy: a table on which somebody has already attached column masking has been declared sensitive by a human, and its missing row filter is therefore a real inconsistency rather than a guess. That proxy MISSES every sensitive table that carries no policy at all, so a clean result here is not a clean bill of health. POLICY_REFERENCES has no DELETED column, so liveness comes from POLICY_STATUS only. Views and materialized views appear alongside tables and are reported with their REF_ENTITY_DOMAIN rather than filtered out.

WITH row_policy_refs AS (
  SELECT
    pr.policy_db                                                       AS policy_db,
    pr.policy_schema                                                   AS policy_schema,
    pr.policy_name                                                     AS policy_name,
    COUNT(*)                                                           AS attachment_rows,
    COUNT(DISTINCT pr.ref_database_name || '.' || pr.ref_schema_name || '.'
               || pr.ref_entity_name)                                  AS objects_attached,
    COUNT(DISTINCT pr.tag_name)                                        AS tag_attachments,
    SUM(IFF(UPPER(COALESCE(pr.policy_status, '')) <> 'ACTIVE', 1, 0))  AS attachments_not_active
  FROM snowflake.account_usage.policy_references pr
  WHERE UPPER(pr.policy_kind) LIKE '%ROW%ACCESS%'
  GROUP BY 1, 2, 3
),
object_policy_mix AS (
  SELECT
    pr.ref_database_name                                                          AS ref_database_name,
    pr.ref_schema_name                                                            AS ref_schema_name,
    pr.ref_entity_name                                                            AS ref_entity_name,
    MAX(pr.ref_entity_domain)                                                     AS ref_entity_domain,
    SUM(IFF(UPPER(pr.policy_kind) LIKE '%MASKING%', 1, 0))                        AS masking_attachments,
    SUM(IFF(UPPER(pr.policy_kind) LIKE '%ROW%ACCESS%', 1, 0))                     AS row_access_attachments,
    COUNT(DISTINCT IFF(UPPER(pr.policy_kind) LIKE '%MASKING%',
                       pr.ref_column_name, NULL))                                 AS masked_columns
  FROM snowflake.account_usage.policy_references pr
  WHERE pr.ref_entity_name IS NOT NULL
  GROUP BY 1, 2, 3
)
-- Part A - the row-access policy inventory: which policies exist and what they protect.
SELECT
  'ROW_POLICY'                                             AS finding_kind,
  rp.policy_catalog                                        AS policy_database,
  rp.policy_schema                                         AS policy_schema,
  rp.policy_name                                           AS policy_name,
  rp.policy_owner                                          AS policy_owner,
  NULL::VARCHAR                                            AS object_database,
  NULL::VARCHAR                                            AS object_schema,
  NULL::VARCHAR                                            AS object_name,
  NULL::VARCHAR                                            AS object_kind,
  COALESCE(rr.objects_attached, 0) + COALESCE(rr.tag_attachments, 0) AS attachments_total,
  COALESCE(rr.objects_attached, 0)                         AS objects_attached,
  NULL::NUMBER                                             AS masked_columns,
  COALESCE(rr.attachments_not_active, 0)                   AS attachments_not_active,
  rp.created                                               AS created,
  CASE
    WHEN COALESCE(rr.objects_attached, 0) + COALESCE(rr.tag_attachments, 0) = 0
     AND rp.created >= DATEADD('day', -:grace_days, CURRENT_TIMESTAMP())  THEN 'NOT_ASSESSED'
    WHEN COALESCE(rr.objects_attached, 0) + COALESCE(rr.tag_attachments, 0) = 0
                                                                          THEN 'CRITICAL'
    WHEN COALESCE(rr.attachments_not_active, 0) > 0                       THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM snowflake.account_usage.row_access_policies rp
LEFT JOIN row_policy_refs rr
  ON  rr.policy_db     = rp.policy_catalog
  AND rr.policy_schema = rp.policy_schema
  AND rr.policy_name   = rp.policy_name
WHERE rp.deleted IS NULL

UNION ALL

-- Part B - tables somebody already declared sensitive with column masking, but left unfiltered.
SELECT
  'TABLE_WITHOUT_ROW_POLICY'                               AS finding_kind,
  NULL::VARCHAR                                            AS policy_database,
  NULL::VARCHAR                                            AS policy_schema,
  NULL::VARCHAR                                            AS policy_name,
  NULL::VARCHAR                                            AS policy_owner,
  om.ref_database_name                                     AS object_database,
  om.ref_schema_name                                       AS object_schema,
  om.ref_entity_name                                       AS object_name,
  om.ref_entity_domain                                     AS object_kind,
  om.masking_attachments                                   AS attachments_total,
  0                                                        AS objects_attached,
  om.masked_columns                                        AS masked_columns,
  0                                                        AS attachments_not_active,
  NULL::TIMESTAMP_LTZ                                      AS created,
  CASE
    WHEN om.masked_columns >= :critical_masked_columns  THEN 'CRITICAL'
    ELSE 'WARN'
  END AS status
FROM object_policy_mix om
WHERE om.row_access_attachments = 0
  AND om.masked_columns >= :min_masked_columns
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  finding_kind,
  attachments_total DESC,
  policy_name,
  object_name;
