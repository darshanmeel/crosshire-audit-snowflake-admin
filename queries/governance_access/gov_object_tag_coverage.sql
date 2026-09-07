-- query_id: gov_object_tag_coverage
-- title: Which databases, schemas and warehouses carry a cost-allocation tag - and which do not
-- domain: governance_access   tier: standard
-- rung: account_usage - TAG_REFERENCES is the only view that lists tag applications across every object domain at once. The live rung can answer for one object at a time, which is the wrong shape for a chargeback gap.
-- reads: snowflake.account_usage.tag_references, snowflake.account_usage.tags
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default). Object tagging is an Enterprise Edition feature.
-- freshness: LAGGED - both views carry a documented latency of up to 2 hours. A warehouse tagged this morning may still read as untagged, so re-check anything created inside that window before chasing an owner.
-- params: :cost_tag_name (default COST_CENTER) the tag your chargeback is keyed on, compared case-insensitively; :domain_filter (default %) a LIKE pattern over the object domain, so you can look at WAREHOUSE alone rather than all three
-- confidence: confirmed-docs
-- confidence_note: TAG_REFERENCES and TAGS are documented ACCOUNT_USAGE views and every column used is in their documented column lists, including ALLOWED_VALUES being a VARIANT that is NULL when the tag has no allow-list, and APPLY_METHOD with its documented values. The DOMAIN values used here (DATABASE, SCHEMA, WAREHOUSE) are documented as examples of the domain column rather than as a closed list, so the filter is a case-insensitive IN test that will simply return nothing rather than break if an account spells one differently.
-- empty_if: no_imported_privileges, account_usage_lag, tagging_not_used, edition_gated
-- read_this: One row = one database, schema or warehouse that carries AT LEAST ONE tag. The two columns that matter are has_cost_tag and cost_tag_value: an object with tags but no cost tag is the chargeback gap, and an object with a cost tag whose value is blank or off the allow-list is the gap that hides inside a passing count.
-- healthy: every object in every domain shows has_cost_tag TRUE with a non-blank value that is inside the allow-list, and objects_in_domain equals objects_in_domain_with_cost_tag on every row.
-- investigate_if: CRITICAL when an object carries other tags but not the cost tag - somebody tagged it, so the tagging process reached it and skipped the one tag the bill depends on. WARN when the cost tag is present with a blank value, or with a value outside the allow-list the tag itself declares, because both roll up into a bucket nobody owns. False positive: shared or system objects that legitimately belong to no cost centre, and an account that allocates cost at a different grain than the object.
-- actions: 1) run it once per domain with :domain_filter and hand each list to the team that owns those objects - the gap is usually one team, not a systemic failure (free); 2) give the cost tag an ALLOWED_VALUES list if it has none, which turns a free-text field into a validated one and makes the WARN band meaningful (config); 3) apply the tag at DATABASE level and let schemas inherit, rather than tagging each schema, so newly created schemas do not reopen the gap (config).
-- next: gov_applied_sensitive_tags (for the sensitivity half of tagging rather than the cost half), gov_classification_coverage (if you need a coverage number with a REAL denominator, which this query cannot have), access_stale_roles (if an untagged object also has no attributable owner role)
-- covers: ACCOUNT-WIDE, LAGGED, CURRENT-STATE, TAGGED-ONLY. It sees every tag application on databases, schemas and warehouses. Its universe is objects that already carry at least one tag - TAG_REFERENCES cannot list an object that has never been tagged at all, so this query measures the gap INSIDE the tagged estate and is blind to objects the tagging process never touched.
-- caveats: The denominator here is objects known to the tagging system, NOT the object estate - a warehouse with no tags whatsoever is absent from this result entirely and is a bigger gap than anything the query reports. That is a property of TAG_REFERENCES, and it is why a clean result must be read alongside a warehouse or database inventory from another rung before anyone calls chargeback complete. The allow-list check compares a VARCHAR tag value against a VARIANT array, so a value that differs only in case or whitespace reads as off-list. When a tag is applied to a column, OBJECT_NAME holds the parent table, which is why this query filters to the three container domains and leaves table and column tags to the sensitivity query. The tag definition is resolved by name across databases, so two identically-named cost tags in different schemas resolve to the oldest one.

WITH tagged_objects AS (
  SELECT
    UPPER(tr.domain)                                                          AS object_domain,
    COALESCE(tr.object_database, '')                                          AS object_database,
    COALESCE(tr.object_schema, '')                                            AS object_schema,
    tr.object_name                                                            AS object_name,
    COUNT(*)                                                                  AS tags_on_object,
    ARRAY_AGG(DISTINCT tr.tag_name)                                           AS tags_present,
    MAX(IFF(UPPER(tr.tag_name) = :cost_tag_name, 1, 0))                       AS has_cost_tag,
    MAX(IFF(UPPER(tr.tag_name) = :cost_tag_name, tr.tag_value, NULL))         AS cost_tag_value,
    MAX(IFF(UPPER(tr.tag_name) = :cost_tag_name, tr.apply_method, NULL))      AS cost_tag_apply_method
  FROM snowflake.account_usage.tag_references tr
  WHERE tr.object_deleted IS NULL
    AND UPPER(tr.domain) IN ('DATABASE', 'SCHEMA', 'WAREHOUSE')
    AND UPPER(tr.domain) LIKE :domain_filter
  GROUP BY 1, 2, 3, 4
),
cost_tag_def AS (
  SELECT
    t.tag_database                                                            AS tag_database,
    t.tag_schema                                                              AS tag_schema,
    t.tag_name                                                                AS tag_name,
    t.allowed_values                                                          AS allowed_values
  FROM snowflake.account_usage.tags t
  WHERE t.deleted IS NULL
    AND UPPER(t.tag_name) = :cost_tag_name
  QUALIFY ROW_NUMBER() OVER (ORDER BY t.created) = 1
)
SELECT
  o.object_domain                                                             AS object_domain,
  o.object_database                                                           AS object_database,
  o.object_schema                                                             AS object_schema,
  o.object_name                                                               AS object_name,
  o.tags_on_object                                                            AS tags_on_object,
  o.tags_present                                                              AS tags_present,
  o.has_cost_tag = 1                                                          AS has_cost_tag,
  o.cost_tag_value                                                            AS cost_tag_value,
  o.cost_tag_apply_method                                                     AS cost_tag_apply_method,
  d.tag_database || '.' || d.tag_schema || '.' || d.tag_name                  AS cost_tag_definition,
  d.allowed_values                                                            AS cost_tag_allowed_values,
  COUNT(*) OVER (PARTITION BY o.object_domain)                                AS objects_in_domain,
  SUM(o.has_cost_tag) OVER (PARTITION BY o.object_domain)                     AS objects_in_domain_with_cost_tag,
  ROUND(100.0 * SUM(o.has_cost_tag) OVER (PARTITION BY o.object_domain)
        / NULLIF(COUNT(*) OVER (PARTITION BY o.object_domain), 0), 1)         AS domain_cost_tag_pct,
  CASE
    WHEN o.has_cost_tag = 0                                                        THEN 'CRITICAL'
    WHEN NULLIF(TRIM(COALESCE(o.cost_tag_value, '')), '') IS NULL                  THEN 'WARN'
    WHEN d.allowed_values IS NOT NULL
     AND NOT ARRAY_CONTAINS(o.cost_tag_value::VARIANT, d.allowed_values)           THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM tagged_objects o
LEFT JOIN cost_tag_def d
  ON 1 = 1
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 1 WHEN 'WARN' THEN 2 WHEN 'OK' THEN 3 ELSE 4 END,
  o.object_domain,
  o.object_database,
  o.object_schema,
  o.object_name;
