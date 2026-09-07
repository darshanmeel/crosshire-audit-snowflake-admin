-- query_id: cost_chargeback_by_query_tag
-- title: Attributed credits split by QUERY_TAG - and the untagged share that breaks the denominator
-- domain: cost   tier: standard
-- rung: account_usage - QUERY_ATTRIBUTION_HISTORY carries both the credits and the tag, and QUERY_HISTORY carries the cloud-services half. Neither exists below this rung.
-- reads: snowflake.account_usage.query_attribution_history, snowflake.account_usage.query_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (the USAGE_VIEWER or GOVERNANCE_VIEWER database role on SNOWFLAKE also reaches QUERY_ATTRIBUTION_HISTORY)
-- freshness: LAGGED - and the two halves lag DIFFERENTLY: QUERY_HISTORY up to 45 minutes, QUERY_ATTRIBUTION_HISTORY up to 8 hours. In the newest hours the compute side will look smaller than the cloud-services side purely because of that skew.
-- params: :period_days (default 30) rolling window; :untagged_warn_pct (default 20) share of attributed credits carrying no tag that raises WARN on the untagged row; :untagged_critical_pct (default 50) the same share that raises CRITICAL; :untagged_label (default UNTAGGED) the literal written into the QUERY_TAG column for statements that carried none
-- confidence: confirmed-docs
-- confidence_note: QUERY_TAG is a documented column on BOTH views - on QUERY_ATTRIBUTION_HISTORY as well as QUERY_HISTORY - which is what lets the credits be grouped by tag without a per-query join. CREDITS_ATTRIBUTED_COMPUTE and CREDITS_USED_QUERY_ACCELERATION are documented on the attribution view; CREDITS_USED_CLOUD_SERVICES on the history view. Not run live: whether an empty tag arrives as NULL or as an empty string is not documented, so both are normalised here.
-- empty_if: no_imported_privileges, account_usage_lag, tagging_not_used, no_activity
-- read_this: One row = one QUERY_TAG value over the window, plus one row for everything that carried no tag at all. CREDITS_ATTRIBUTED_TOTAL is the chargeback number; UNTAGGED_PCT_OF_CREDITS is stamped on EVERY row on purpose, because a tag's share only means something once you know what fraction of the bill was never attributable in the first place.
-- healthy: the untagged row holds less than :untagged_warn_pct of attributed credits, and the tagged rows map onto teams or pipelines someone can name. A tag taxonomy nobody can decode is not healthier than no tags.
-- investigate_if: the untagged row is at or above :untagged_warn_pct - your chargeback denominator is fiction and every tagged percentage is inflated by exactly the amount you cannot see. Also investigate a tag that appears in only a handful of statements yet carries a large share: that is usually one ad-hoc session that borrowed a production tag. False positive: an account that deliberately tags only the workloads it charges back will show a large untagged remainder that is genuinely nobody's chargeback line.
-- actions: 1) take the untagged share to cost_query_tag_coverage_gap to find WHICH warehouses and users produce it before asking anyone to change code (free); 2) set QUERY_TAG at the session or user level in the orchestration layer rather than per statement - most untagged credit comes from tools that never set it once (config); 3) split the shared warehouse behind an untaggable workload so the bill is separable by object even when the tag is not there (spend).
-- next: cost_query_tag_coverage_gap (if the untagged share is large and you need to know where it comes from), cost_query_attribution_by_user (if a tag has no owner and you need the people behind it), cost_attribution_fingerprint (if one tag is really one repeated statement)
-- covers: EXECUTION credits only, tagged as the statement itself was tagged. Warehouse idle time carries no query and therefore no tag - it can never appear in any row here, which is why the tagged rows will not add up to the warehouse bill. Serverless spend has no QUERY_TAG at all. The cloud-services column is joined in from QUERY_HISTORY and is GROSS, before the daily allowance.
-- caveats: The two halves are aggregated separately by tag and then joined on the tag, NOT joined per query - that is deliberate, because a per-query join of two year-scale views is expensive and buys nothing here. It does mean a tag can appear with credits on one side and not the other when the lag skew is in play. Cloud-services credits are gross: cost_cloud_services_overage holds the number that is actually billed. Attribution excludes sub-100ms statements, so a heavily-tagged but tiny workload under-reports. Comparing tag shares across a period in which the tagging convention changed compares two different things.

WITH attributed AS (
  SELECT
    COALESCE(NULLIF(TRIM(query_tag), ''), :untagged_label) AS tag_key,
    COALESCE(credits_attributed_compute, 0)
      + COALESCE(credits_used_query_acceleration, 0)       AS credits_attributed
  FROM snowflake.account_usage.query_attribution_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
attributed_by_tag AS (
  SELECT
    tag_key,
    COUNT(*)                  AS attributed_queries,
    SUM(credits_attributed)   AS credits_attributed_total
  FROM attributed
  GROUP BY tag_key
),
cloud_by_tag AS (
  SELECT
    COALESCE(NULLIF(TRIM(query_tag), ''), :untagged_label) AS tag_key,
    COUNT(*)                                               AS statements,
    COUNT(DISTINCT user_name)                              AS distinct_users,
    COUNT(DISTINCT warehouse_name)                         AS distinct_warehouses,
    SUM(COALESCE(credits_used_cloud_services, 0))          AS credits_cloud_services_gross
  FROM snowflake.account_usage.query_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY tag_key
),
joined AS (
  SELECT
    COALESCE(a.tag_key, c.tag_key)                     AS query_tag,
    COALESCE(a.attributed_queries, 0)                  AS attributed_queries,
    COALESCE(a.credits_attributed_total, 0)            AS credits_attributed_total,
    COALESCE(c.statements, 0)                          AS statements,
    COALESCE(c.distinct_users, 0)                      AS distinct_users,
    COALESCE(c.distinct_warehouses, 0)                 AS distinct_warehouses,
    COALESCE(c.credits_cloud_services_gross, 0)        AS credits_cloud_services_gross
  FROM attributed_by_tag a
  FULL OUTER JOIN cloud_by_tag c ON a.tag_key = c.tag_key
),
scored AS (
  SELECT
    joined.*,
    IFF(query_tag = :untagged_label, TRUE, FALSE)                           AS is_untagged,
    100.0 * credits_attributed_total
          / NULLIF(SUM(credits_attributed_total) OVER (), 0)                AS pct_of_attributed_credits,
    100.0 * SUM(IFF(query_tag = :untagged_label, credits_attributed_total, 0)) OVER ()
          / NULLIF(SUM(credits_attributed_total) OVER (), 0)                AS untagged_pct_of_credits
  FROM joined
)
SELECT
  query_tag,
  is_untagged,
  attributed_queries,
  statements,
  distinct_users,
  distinct_warehouses,
  ROUND(credits_attributed_total, 3)      AS credits_attributed_total,
  ROUND(credits_cloud_services_gross, 3)  AS credits_cloud_services_gross,
  ROUND(pct_of_attributed_credits, 1)     AS pct_of_attributed_credits,
  ROUND(untagged_pct_of_credits, 1)       AS untagged_pct_of_credits,
  CASE
    WHEN NOT is_untagged                                        THEN 'OK'
    WHEN credits_attributed_total = 0                           THEN 'NOT_ASSESSED'
    WHEN untagged_pct_of_credits >= :untagged_critical_pct      THEN 'CRITICAL'
    WHEN untagged_pct_of_credits >= :untagged_warn_pct          THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  credits_attributed_total DESC;
