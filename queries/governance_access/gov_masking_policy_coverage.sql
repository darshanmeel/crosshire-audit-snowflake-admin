-- query_id: gov_masking_policy_coverage
-- title: Masking policies, what each one is actually attached to, and which mask nothing
-- domain: governance_access   tier: standard
-- rung: account_usage - MASKING_POLICIES and POLICY_REFERENCES are ACCOUNT_USAGE only. The INFORMATION_SCHEMA POLICY_REFERENCES table function answers the reverse question for ONE object at a time; there is no live rung that enumerates every policy and every attachment in one statement.
-- reads: snowflake.account_usage.masking_policies, snowflake.account_usage.policy_references
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default). Column-level masking policies are an Enterprise Edition feature.
-- freshness: LAGGED - both views carry a documented latency of up to 2 hours. A policy created and attached this morning can still read as unattached, which is why :grace_days exists.
-- params: :grace_days (default 7) a policy created inside this many days is not yet judged for having no attachment, because a policy is normally written before it is applied; :min_attachments (default 1) how many object-or-tag attachments a live policy must carry to count as in use
-- confidence: confirmed-docs
-- confidence_note: MASKING_POLICIES and POLICY_REFERENCES are documented ACCOUNT_USAGE views and every column used is in their documented column lists, including the fact that POLICY_REFERENCES has NO DELETED column and liveness is read from POLICY_STATUS. One thing could not be doc-verified: the docs describe POLICY_KIND as the type of policy and list the policy families covered, but do not enumerate the literal strings, so this query matches UPPER(policy_kind) LIKE a masking pattern rather than an assumed literal. POLICY_STATUS values ARE enumerated in the docs and ACTIVE is used as documented.
-- empty_if: no_imported_privileges, account_usage_lag, edition_gated, feature_not_enabled
-- read_this: One row = one live masking policy. The two columns that matter are objects_attached and tag_attachments: together they are the only evidence that the policy masks anything at all. A policy body can be perfect and still protect nothing.
-- healthy: every live policy carries at least :min_attachments attachments, every attachment reports POLICY_STATUS ACTIVE, and the count of unattached policies (reported on every row as masking_policies_unattached) is zero.
-- investigate_if: CRITICAL when a policy older than :grace_days is attached to nothing - it is a control that exists on paper only, and it is usually mistaken for coverage. WARN when a policy has attachments whose status is not ACTIVE: the documented non-ACTIVE values all mean the policy is present but NOT being applied to that column, which is the worst of both worlds because the object looks governed. False positive: a policy deliberately kept as a template, and a policy attached only through a tag whose tagged objects have not been created yet.
-- actions: 1) attach each CRITICAL policy or delete it - an unattached policy is a false assurance and costs nothing to remove (free); 2) fix every non-ACTIVE attachment: the documented causes are a second masking policy already on the column, or a missing or mistyped secondary-argument column, both config errors (config); 3) move attachment from per-column grants to a tag-based policy so new columns inherit the mask instead of being missed (config).
-- next: gov_applied_sensitive_tags (if you need the other half of the ratio - which columns are DECLARED sensitive and therefore should carry a mask), gov_policy_reference_coverage (if you want the same question across every policy kind at once), gov_row_access_policy_coverage (if the object needs row filtering and not just column masking)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE. It sees every policy and every attachment. It does NOT see whether the mask actually fires for a given reader - that depends on the policy body and the querying role, which no view evaluates for you. It also cannot tell you which UNMASKED columns should have been masked, because a masking policy view has no way to enumerate sensitive columns; that denominator lives in the tag and classification queries.
-- caveats: The unattached-policy finding is the reliable half of this query; the coverage half is not answerable from these two views alone and is deliberately not faked here. POLICY_REFERENCES has no DELETED column, so a stale attachment row is distinguished only by POLICY_STATUS. Tag-based attachment is counted separately from object attachment because one tag row can cover thousands of columns and would otherwise dwarf the object count. The join is on the fully-qualified policy identity (database, schema, name); a policy renamed inside the latency window can briefly appear twice or not at all.

WITH masking_refs AS (
  SELECT
    pr.policy_db                                                              AS policy_db,
    pr.policy_schema                                                          AS policy_schema,
    pr.policy_name                                                            AS policy_name,
    COUNT(*)                                                                  AS attachment_rows,
    COUNT(DISTINCT pr.ref_database_name || '.' || pr.ref_schema_name || '.'
               || pr.ref_entity_name)                                         AS objects_attached,
    COUNT(DISTINCT pr.ref_column_name)                                        AS columns_attached,
    COUNT(DISTINCT pr.tag_name)                                               AS tag_attachments,
    SUM(IFF(UPPER(COALESCE(pr.policy_status, '')) <> 'ACTIVE', 1, 0))         AS attachments_not_active,
    ARRAY_AGG(DISTINCT pr.policy_status)                                      AS attachment_statuses,
    ARRAY_AGG(DISTINCT pr.ref_entity_domain)                                  AS attached_object_kinds
  FROM snowflake.account_usage.policy_references pr
  WHERE UPPER(pr.policy_kind) LIKE '%MASKING%'
  GROUP BY 1, 2, 3
)
SELECT
  mp.policy_catalog                                                    AS policy_database,
  mp.policy_schema                                                     AS policy_schema,
  mp.policy_name                                                       AS policy_name,
  mp.policy_owner                                                      AS policy_owner,
  mp.policy_signature                                                  AS policy_signature,
  mp.policy_return_type                                                AS policy_return_type,
  mp.created                                                           AS created,
  mp.last_altered                                                      AS last_altered,
  COALESCE(mr.objects_attached, 0)                                     AS objects_attached,
  COALESCE(mr.columns_attached, 0)                                     AS columns_attached,
  COALESCE(mr.tag_attachments, 0)                                      AS tag_attachments,
  COALESCE(mr.objects_attached, 0) + COALESCE(mr.tag_attachments, 0)   AS attachments_total,
  COALESCE(mr.attachments_not_active, 0)                               AS attachments_not_active,
  mr.attachment_statuses                                               AS attachment_statuses,
  mr.attached_object_kinds                                             AS attached_object_kinds,
  COUNT(*) OVER ()                                                     AS masking_policies_total,
  SUM(IFF(COALESCE(mr.objects_attached, 0) + COALESCE(mr.tag_attachments, 0) = 0, 1, 0))
      OVER ()                                                          AS masking_policies_unattached,
  CASE
    WHEN COALESCE(mr.objects_attached, 0) + COALESCE(mr.tag_attachments, 0) = 0
     AND mp.created >= DATEADD('day', -:grace_days, CURRENT_TIMESTAMP())     THEN 'NOT_ASSESSED'
    WHEN COALESCE(mr.objects_attached, 0) + COALESCE(mr.tag_attachments, 0)
         < :min_attachments                                                  THEN 'CRITICAL'
    WHEN COALESCE(mr.attachments_not_active, 0) > 0                          THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM snowflake.account_usage.masking_policies mp
LEFT JOIN masking_refs mr
  ON  mr.policy_db     = mp.policy_catalog
  AND mr.policy_schema = mp.policy_schema
  AND mr.policy_name   = mp.policy_name
WHERE mp.deleted IS NULL
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  attachments_total DESC,
  policy_database,
  policy_schema,
  policy_name;
