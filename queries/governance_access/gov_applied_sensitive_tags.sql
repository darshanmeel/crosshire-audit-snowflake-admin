-- query_id: gov_applied_sensitive_tags
-- title: Which columns are declared sensitive - the applied SEMANTIC and PRIVACY category tags
-- domain: governance_access   tier: standard
-- rung: account_usage - TAG_REFERENCES on this rung is account-wide. The INFORMATION_SCHEMA TAG_REFERENCES table function is live but answers for one object at a time, so it cannot produce the sensitivity inventory the other governance queries need as their denominator.
-- reads: snowflake.account_usage.tag_references, snowflake.account_usage.tags
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default). Object tagging is an Enterprise Edition feature.
-- freshness: LAGGED - both views carry a documented latency of up to 2 hours. A classification run that finished in the last hour may not be reflected yet, so a column that looks untagged here can already be tagged.
-- params: :semantic_tag (default SEMANTIC_CATEGORY) the Snowflake system tag naming WHAT the data is; :privacy_tag (default PRIVACY_CATEGORY) the system tag naming how identifying it is; :extra_tag_pattern (default %PII%) an extra name pattern so account-defined sensitivity tags are picked up alongside the two system ones
-- confidence: confirmed-docs
-- confidence_note: TAG_REFERENCES and TAGS are documented ACCOUNT_USAGE views and every column used is in their documented column lists, including APPLY_METHOD with its documented values (CLASSIFIED, MANUAL, PROPAGATED, NULL, NONE) and TAG_ID being NULL for system tags, which is what tag_origin is derived from. The tag NAMES themselves are parameters rather than hard-coded literals precisely because the system-tag naming is the part an account can diverge on.
-- empty_if: no_imported_privileges, account_usage_lag, tagging_not_used, edition_gated
-- read_this: One row = one sensitivity tag applied to one column or object. The two columns that matter are object_name with column_name (what is declared sensitive) and tag_value (what it is declared AS). apply_method is the third thing to look at: CLASSIFIED means a machine decided this, MANUAL means a person did.
-- healthy: n/a - inventory. This query is a reference list, not a verdict; the other governance queries join to it for their denominator.
-- investigate_if: n/a - inventory. The finding you are usually after is the DIFFERENCE between this list and gov_masking_policy_coverage - a column declared sensitive and left unmasked - which is why the two are meant to be read together rather than each alone.
-- actions: 1) export this list and hand it to whoever signs off the data-protection register - it is the account statement of what is considered sensitive, and it is usually shorter than anyone expects (free); 2) review every row with apply_method CLASSIFIED and no human confirmation, since an auto-applied category that nobody checked carries a false confidence (config); 3) where a category is right but no masking policy is attached to it, attach the policy to the TAG rather than to the column, so the next column classified the same way inherits the mask (config).
-- next: gov_masking_policy_coverage (to see which of these declared-sensitive columns actually carry a mask), gov_classification_coverage (to see how much of the estate has never been looked at, which is what an empty result here really means), gov_object_tag_coverage (for the cost-allocation half of tagging rather than the sensitivity half)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE, TAGGED-ONLY. It sees every applied sensitivity tag in the account. It cannot see a single UNTAGGED column: TAG_REFERENCES lists only objects that carry at least one tag, so this query can never tell you what it missed. That is a property of the view, not of this query, and it is the reason a small result here is ambiguous between a clean estate and an unexamined one.
-- caveats: An empty or short result means one of two very different things - nothing is sensitive, or nothing has been examined - and only gov_classification_coverage can tell them apart. System tags carry a NULL TAG_ID, so the join to TAGS is a LEFT JOIN and tag_owner and allowed_values are NULL for them; that is expected, not missing data. When a tag is applied to a column, OBJECT_NAME holds the PARENT table name and COLUMN_NAME holds the column, so an object-level and a column-level tag look similar until you read DOMAIN. Tags applied to an object whose parent was dropped are excluded through OBJECT_DELETED. PROPAGATED tags are inherited rather than declared and are reported with their apply_method so they are not mistaken for a decision someone made.

SELECT
  tr.domain                                                    AS object_domain,
  tr.object_database                                           AS object_database,
  tr.object_schema                                             AS object_schema,
  tr.object_name                                               AS object_name,
  tr.column_name                                               AS column_name,
  tr.tag_database                                              AS tag_database,
  tr.tag_schema                                                AS tag_schema,
  tr.tag_name                                                  AS tag_name,
  tr.tag_value                                                 AS tag_value,
  tr.apply_method                                              AS apply_method,
  IFF(tr.tag_id IS NULL, TRUE, FALSE)                          AS is_system_tag,
  t.tag_owner                                                  AS tag_owner,
  t.allowed_values                                             AS tag_allowed_values,
  t.propagate                                                  AS tag_propagate,
  COUNT(*) OVER (PARTITION BY UPPER(tr.tag_name))              AS references_for_this_tag,
  COUNT(*) OVER (PARTITION BY UPPER(tr.tag_name), tr.tag_value) AS references_for_this_value,
  COUNT(*) OVER ()                                             AS sensitivity_tag_references_total
FROM snowflake.account_usage.tag_references tr
LEFT JOIN snowflake.account_usage.tags t
  ON  t.tag_database = tr.tag_database
  AND t.tag_schema   = tr.tag_schema
  AND t.tag_name     = tr.tag_name
  AND t.deleted IS NULL
WHERE tr.object_deleted IS NULL
  AND (
        UPPER(tr.tag_name) = :semantic_tag
     OR UPPER(tr.tag_name) = :privacy_tag
     OR UPPER(tr.tag_name) LIKE :extra_tag_pattern
      )
ORDER BY
  tr.object_database,
  tr.object_schema,
  tr.object_name,
  tr.column_name,
  tr.tag_name;
