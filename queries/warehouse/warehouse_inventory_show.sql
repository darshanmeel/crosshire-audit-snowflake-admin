-- query_id: warehouse_inventory_show
-- title: Every warehouse's live configuration - size, auto-suspend, cluster range, scaling policy, monitor
-- domain: warehouse   tier: lite
-- rung: show - the lowest rung that can answer a CONFIG question at all. ACCOUNT_USAGE has no warehouse-config view, so there is nothing to climb to.
-- reads: SHOW WAREHOUSES, result_scan(last_query_id())
-- requires: only the privilege to see the warehouse - SHOW WAREHOUSES returns what the current role can see (MONITOR or USAGE on the warehouse, or ownership). No IMPORTED PRIVILEGES on SNOWFLAKE.
-- freshness: LIVE - SHOW reads current object state, so an ALTER WAREHOUSE made a second ago is already visible. There is no history here at all: a warehouse dropped yesterday does not appear, and yesterday's auto_suspend value is gone.
-- params: :name_pattern (default %) SQL LIKE pattern narrowing the inventory - the default returns every warehouse the role can see
-- confidence: unverified
-- confidence_note: The output column names of SHOW WAREHOUSES are listed on docs.snowflake.com/en/sql-reference/sql/show-warehouses, but that same page declares five of its columns internal and says they will be removed - so the SHOW result shape is NOT a stable documented contract and this file may not claim confirmed-docs. If a column name has drifted on your version, the RESULT_SCAN reference fails loudly rather than returning a wrong value. Types come back as VARCHAR through RESULT_SCAN, hence the explicit TRY_CAST on every numeric.
-- empty_if: privilege_scoped
-- read_this: One row = one warehouse as it is configured RIGHT NOW. The two columns that decide most of this domain's money are auto_suspend_seconds (how long you pay for nothing after the last query) and max_cluster_count (whether this object can multiply its own cost). This is an INVENTORY - it has no verdict; it is the reference the finding queries in this domain join back to when they need a config value.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: 1) export this table and treat it as the config baseline every later warehouse finding is read against (free); 2) fill in the blanks it exposes - a NULL resource_monitor, a NULL or zero auto_suspend_seconds, a min_cluster_count above 1 - each is a config decision someone made and nobody has revisited (config); 3) nothing here justifies spend on its own - price a change only after a finding query has costed it (spend).
-- next: warehouse_multicluster_scaling_misconfig (if any row shows max_cluster_count above 1), warehouse_idle_credit_leak (if auto_suspend_seconds is large, zero or null anywhere), warehouse_oversized_by_load (if you want to know whether the sizes here match the work)
-- covers: CURRENT config for the warehouses THIS ROLE can see. It cannot see: a warehouse the role has no privilege on, any historical value of a setting, or what the warehouse actually did. WAREHOUSE_EVENTS_HISTORY is the rung that carries config CHANGES over time (RESIZE_WAREHOUSE / ALTER_WAREHOUSE events); WAREHOUSE_METERING_HISTORY carries what it cost. Neither carries current config, which is why this question never leaves the SHOW rung.
-- caveats: SHOW is role-scoped, so an empty or short result is a privilege statement, not an account statement - run it as a role with account-wide visibility before reading absence as evidence. RESULT_SCAN(LAST_QUERY_ID()) must run in the same session immediately after the SHOW, so this file is two statements and cannot be split. auto_suspend is documented in SECONDS; a NULL or 0 there means the warehouse never auto-suspends, which is a very different bill from a small number. resource_monitor may come back as the literal string 'null' rather than a SQL NULL on some versions, so the derived has_resource_monitor flag tests for both.

SHOW WAREHOUSES;

-- One row per warehouse, live. Everything numeric is TRY_CAST because RESULT_SCAN hands
-- SHOW output back as strings; a drifted column would otherwise become a silent 0.
WITH wh AS (
  SELECT
    "name"                                    AS warehouse_name,
    "state"                                   AS state,
    "type"                                    AS warehouse_type,
    "size"                                    AS warehouse_size,
    TRY_CAST("min_cluster_count"  AS NUMBER)  AS min_cluster_count,
    TRY_CAST("max_cluster_count"  AS NUMBER)  AS max_cluster_count,
    TRY_CAST("started_clusters"   AS NUMBER)  AS started_clusters,
    TRY_CAST("running"            AS NUMBER)  AS running_statements,
    TRY_CAST("queued"             AS NUMBER)  AS queued_statements,
    TRY_CAST("auto_suspend"       AS NUMBER)  AS auto_suspend_seconds,
    "auto_resume"                             AS auto_resume,
    "scaling_policy"                          AS scaling_policy,
    "resource_monitor"                        AS resource_monitor,
    "owner"                                   AS owner_role,
    "created_on"                              AS created_on,
    "resumed_on"                              AS last_resumed_on,
    "updated_on"                              AS last_updated_on,
    "comment"                                 AS comment
  FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
)
SELECT
  warehouse_name,
  state,
  warehouse_type,
  warehouse_size,
  min_cluster_count,
  max_cluster_count,
  started_clusters,
  running_statements,
  queued_statements,
  auto_suspend_seconds,
  auto_resume,
  scaling_policy,
  resource_monitor,
  owner_role,
  created_on,
  last_resumed_on,
  last_updated_on,
  comment,
  -- derived facts, not verdicts: the three shapes every later query in this domain asks about
  IFF(COALESCE(max_cluster_count, 1) > 1, TRUE, FALSE)                              AS is_multi_cluster,
  IFF(auto_suspend_seconds IS NULL OR auto_suspend_seconds = 0, TRUE, FALSE)        AS never_auto_suspends,
  IFF(resource_monitor IS NULL OR LOWER(resource_monitor) = 'null', FALSE, TRUE)    AS has_resource_monitor
FROM wh
WHERE warehouse_name ILIKE :name_pattern
ORDER BY warehouse_name;
