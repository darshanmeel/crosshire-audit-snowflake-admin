-- query_id: warehouse_multicluster_scaling_misconfig
-- title: Multi-cluster warehouses configured so they cannot behave the way someone intended
-- domain: warehouse   tier: standard
-- rung: show - a configuration question, and configuration exists on no other rung. There is no ACCOUNT_USAGE view of warehouse settings to climb to, so SHOW is not a compromise here, it is the answer.
-- reads: SHOW WAREHOUSES, result_scan(last_query_id())
-- requires: only the privilege to see the warehouse - SHOW WAREHOUSES returns what the current role can see (MONITOR or USAGE on the warehouse, or ownership). No IMPORTED PRIVILEGES on SNOWFLAKE.
-- freshness: LIVE - this is current configuration, so a fix made a second ago is already reflected. There is no history: this file cannot tell you when a setting was changed or by whom. WAREHOUSE_EVENTS_HISTORY carries ALTER_WAREHOUSE events if that is the question.
-- params: :min_max_clusters (default 2) only judge warehouses whose maximum cluster count is at least this - the default reports multi-cluster warehouses only, and 1 widens it to every warehouse; :latency_policy_to_avoid (default ECONOMY) the scaling policy that is flagged on a multi-cluster warehouse, because it deliberately delays starting a cluster and that is the wrong trade for a latency-sensitive workload - it is a parameter and not a constant precisely because it is a judgement about your workload, not a fact about Snowflake
-- confidence: unverified
-- confidence_note: The output columns name, state, type, size, min_cluster_count, max_cluster_count, started_clusters, auto_suspend, auto_resume, scaling_policy and resource_monitor are all listed on docs.snowflake.com/en/sql-reference/sql/show-warehouses, and that page also documents that min and max cluster count are always 1 for a single-cluster warehouse. But the same page declares five of its own columns internal and due for removal, so the SHOW result shape is not a stable documented contract and this file may not claim confirmed-docs. Separately, the ECONOMY judgement is a workload opinion exposed as a parameter, not a documented Snowflake behaviour claim - the warehouse overview page fetched for this library does not carry the STANDARD versus ECONOMY comparison at all.
-- empty_if: privilege_scoped
-- read_this: One row = one warehouse, with a reasons string naming every configuration shape that was flagged on it. The two columns to read are reasons - which says in words what is wrong - and flags, which is just how many of them there are, so the list sorts worst-first. A row with an empty reasons string is a multi-cluster warehouse that is configured coherently.
-- healthy: min_cluster_count of 1 with a max_cluster_count above it, auto_resume on, and an auto_suspend that is set to something. That is a warehouse that costs one cluster when quiet and can grow when it is not.
-- investigate_if: any flag fires. MIN equal to MAX above 1 (CRITICAL) means the warehouse is not really multi-cluster at all - it runs a fixed number of clusters and pays for all of them, permanently. No auto-suspend on a multi-cluster warehouse (CRITICAL) means those clusters never stand down. MIN above 1 (WARN) is a deliberate always-on floor, which is sometimes exactly right for a latency-critical service and sometimes a setting nobody remembers making. Auto-resume off (WARN) means a query arriving at a suspended warehouse fails rather than waits. The scaling-policy flag (WARN) is the one most likely to be a false positive, because ECONOMY is the correct choice for a batch warehouse - which is why it is a parameter you can point at the other policy, or turn off by naming something no warehouse uses.
-- actions: 1) ask who set MIN above 1 and why - in most accounts nobody can name a reason, and the question costs nothing (free); 2) set min_cluster_count to 1 and let max carry the peak, give every multi-cluster warehouse an auto_suspend, and turn auto_resume on unless a failing query is genuinely the behaviour you want (config); 3) if an always-on floor really is required for latency, keep it but move the workload that does not need it onto its own warehouse, so the floor is paid for one thing rather than everything (spend).
-- next: warehouse_multicluster_spinup_cost (if a flagged warehouse is multi-cluster and you need what its scaling actually costs), warehouse_multicluster_scale_out_need (if you are considering raising max_cluster_count and want the evidence first), warehouse_inventory_show (if you want the full unfiltered configuration of every warehouse)
-- covers: CURRENT configuration for every warehouse THIS ROLE can see. It cannot see: a warehouse the role has no privilege on; when any of these settings was last changed; or what the configuration cost - the spin-up bill is warehouse_multicluster_spinup_cost and the idle bill is warehouse_idle_credit_leak.
-- caveats: SHOW is role-scoped, so an empty result is a statement about privileges rather than about the account - run it as a role with account-wide visibility before reading absence as evidence. RESULT_SCAN(LAST_QUERY_ID()) must run in the same session immediately after the SHOW, so this file is two statements. Every numeric comes back as a string through RESULT_SCAN and is TRY_CAST, so a drifted column becomes NULL and the row reports NOT_ASSESSED rather than quietly passing as healthy. auto_resume is compared case-insensitively against a set of truthy spellings because its rendering through RESULT_SCAN is not a documented contract; an unrecognised spelling is treated as not-on and will raise a flag, which is the safe direction for a warning but is worth checking on a version whose output you have not seen.

SHOW WAREHOUSES;

WITH wh AS (
  SELECT
    "name"                                   AS warehouse_name,
    "state"                                  AS state,
    "type"                                   AS warehouse_type,
    "size"                                   AS warehouse_size,
    TRY_CAST("min_cluster_count" AS NUMBER)  AS min_clusters,
    TRY_CAST("max_cluster_count" AS NUMBER)  AS max_clusters,
    TRY_CAST("started_clusters"  AS NUMBER)  AS started_clusters,
    TRY_CAST("auto_suspend"      AS NUMBER)  AS auto_suspend_seconds,
    "auto_resume"                            AS auto_resume,
    UPPER("scaling_policy")                  AS scaling_policy,
    "resource_monitor"                       AS resource_monitor,
    "owner"                                  AS owner_role
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
),
flagged AS (
  SELECT
    warehouse_name,
    state,
    warehouse_type,
    warehouse_size,
    min_clusters,
    max_clusters,
    started_clusters,
    auto_suspend_seconds,
    auto_resume,
    scaling_policy,
    resource_monitor,
    owner_role,
    CASE WHEN max_clusters > 1 AND min_clusters = max_clusters
         THEN 1 ELSE 0 END AS flag_pinned_cluster_count,
    CASE WHEN min_clusters > 1
         THEN 1 ELSE 0 END AS flag_always_on_floor,
    CASE WHEN max_clusters > 1 AND scaling_policy = UPPER(:latency_policy_to_avoid)
         THEN 1 ELSE 0 END AS flag_delayed_scaling_policy,
    CASE WHEN max_clusters > 1 AND (auto_suspend_seconds IS NULL OR auto_suspend_seconds = 0)
         THEN 1 ELSE 0 END AS flag_never_suspends,
    CASE WHEN max_clusters > 1
          AND UPPER(COALESCE(auto_resume, '')) NOT IN ('TRUE', 'ON', 'Y', 'YES')
         THEN 1 ELSE 0 END AS flag_no_auto_resume
  FROM wh
)
SELECT
  warehouse_name,
  state,
  warehouse_type,
  warehouse_size,
  min_clusters,
  max_clusters,
  started_clusters,
  auto_suspend_seconds,
  auto_resume,
  scaling_policy,
  resource_monitor,
  owner_role,
  flag_pinned_cluster_count
    + flag_always_on_floor
    + flag_delayed_scaling_policy
    + flag_never_suspends
    + flag_no_auto_resume AS flags,
  ARRAY_TO_STRING(
    ARRAY_CONSTRUCT_COMPACT(
      IFF(flag_pinned_cluster_count = 1,
          'min equals max above 1 - a fixed cluster count that cannot scale and never shrinks', NULL),
      IFF(flag_always_on_floor = 1,
          'min above 1 - extra clusters run whenever the warehouse is up', NULL),
      IFF(flag_delayed_scaling_policy = 1,
          'scaling policy deliberately delays starting a cluster - wrong trade for latency-sensitive work', NULL),
      IFF(flag_never_suspends = 1,
          'no auto-suspend - the clusters never stand down on their own', NULL),
      IFF(flag_no_auto_resume = 1,
          'auto-resume off - a query arriving at a suspended warehouse fails instead of waiting', NULL)
    ), ' | '
  ) AS reasons,
  CASE
    WHEN max_clusters IS NULL OR min_clusters IS NULL
      THEN 'NOT_ASSESSED'
    WHEN flag_pinned_cluster_count = 1 OR flag_never_suspends = 1
      THEN 'CRITICAL'
    WHEN flag_always_on_floor + flag_delayed_scaling_policy + flag_no_auto_resume > 0
      THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM flagged
WHERE max_clusters IS NULL
   OR max_clusters >= :min_max_clusters
ORDER BY flags DESC, warehouse_name;
