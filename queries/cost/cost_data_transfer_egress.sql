-- query_id: cost_data_transfer_egress
-- title: Bytes leaving the account per day and route - and the fan-out worth collapsing
-- domain: cost   tier: standard
-- rung: account_usage - the INFORMATION_SCHEMA data-transfer function exists but is scoped to the current database and a short retention, so it cannot see the account's whole egress surface. Fan-out only means something when every route is in front of you.
-- reads: snowflake.account_usage.data_transfer_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 120 minutes, which is the shortest lag of any billing-adjacent view in this domain.
-- params: :period_days (default 30) rolling window; :min_gb_day (default 1) a route-day moving fewer gigabytes than this returns NOT_ASSESSED; :fanout_warn_targets (default 2) distinct destination regions one source ships to that raises WARN; :fanout_critical_targets (default 4) the same count that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: START_TIME, END_TIME, SOURCE_CLOUD, SOURCE_REGION, TARGET_CLOUD, TARGET_REGION, BYTES_TRANSFERRED and TRANSFER_TYPE are the complete documented column list, and the documented TRANSFER_TYPE values are COPY, COPY_FILES, DATA_LAKE, EXTERNAL_ACCESS, EXTERNAL_FUNCTION, INTERNAL, POSTGRES, REPLICATION and SNOWPARK_CONTAINER_SERVICES. Not run live. Doc-verified and load-bearing: BYTES_TRANSFERRED is typed VARIANT, so it is cast before any arithmetic here - summing it untouched is the defect this note exists to prevent.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one egress route on one day - a source region shipping to a target region for one transfer type. GB_TRANSFERRED is the quantity; SOURCE_FANOUT_TARGETS beside it is the structural finding, counting how many distinct destinations that source region feeds across the whole window. One big route is a cost; the same bytes split across five destinations is usually the same data paid for five times.
-- healthy: egress concentrated on a small number of deliberate routes, mostly same-cloud, with a fan-out of one or two per source. INTERNAL transfers between regions of the same cloud are the cheap case and REPLICATION is expected if you run a secondary.
-- investigate_if: one source region feeds :fanout_warn_targets or more destinations with real volume - that is the case where a single relay or a replica in a shared region would collapse several bill lines into one. Also investigate any cross-CLOUD route, which is the most expensive class there is, and a COPY or COPY_FILES route moving large volume outward, which usually means an export job that could be replaced by a share. False positive: a genuine multi-region product where each destination serves its own users is fan-out by design, not by accident; and a one-off migration will show enormous volume for a few days and then vanish.
-- actions: 1) name the workload behind each large route before changing anything - the view gives you regions and a transfer type, never an object, so this step is unavoidable (free); 2) collapse fan-out by replicating once to a hub region and fanning out from there, and prefer a share over an export where the consumer is another Snowflake account (config); 3) relocating a database or a consumer to remove a cross-cloud hop is the last resort and only pays when the route is both large and permanent (spend).
-- next: cost_replication_spend (if REPLICATION is the biggest transfer type here), cost_dollarized_usage_by_day (if you need the data-transfer line in money rather than bytes), cost_database_storage_chargeback (if the fan-out is really a replicated copy in every region)
-- covers: BYTES ONLY, by route. This view carries no credits and no currency - the egress DOLLAR is the metered data-transfer service line and is read in cost_dollarized_usage_by_day. It also carries no object: which table, stage or share moved the bytes is not recorded, which is why every action above starts with identifying the workload by hand.
-- caveats: BYTES_TRANSFERRED is a VARIANT and is cast to a number here; a client that reads the column raw will silently get a semi-structured value rather than a total. The view records the transfer WINDOW, so a transfer straddling midnight is split across two day rows - a large single movement can look like two medium ones. Fan-out is counted per SOURCE region over the whole window, not per day, so a source that fed different destinations in different weeks still counts them all; that is intentional, because paying for five routes serially is the same money as paying for five in parallel. Day boundaries follow the session timezone, and the docs require UTC before reconciling with ORGANIZATION_USAGE. Egress priced by the cloud provider outside Snowflake's own metering never appears in this view at all.

WITH transfers AS (
  SELECT
    DATE_TRUNC('day', start_time)::DATE AS usage_date,
    COALESCE(source_cloud, 'UNKNOWN')   AS source_cloud,
    COALESCE(source_region, 'UNKNOWN')  AS source_region,
    COALESCE(target_cloud, 'UNKNOWN')   AS target_cloud,
    COALESCE(target_region, 'UNKNOWN')  AS target_region,
    COALESCE(transfer_type, 'UNKNOWN')  AS transfer_type,
    TO_NUMBER(bytes_transferred)        AS bytes_transferred
  FROM snowflake.account_usage.data_transfer_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
    AND bytes_transferred IS NOT NULL
),
route_day AS (
  SELECT
    usage_date,
    source_cloud,
    source_region,
    target_cloud,
    target_region,
    transfer_type,
    SUM(bytes_transferred) AS bytes_transferred,
    COUNT(*)               AS transfer_windows
  FROM transfers
  GROUP BY 1, 2, 3, 4, 5, 6
),
source_fanout AS (
  SELECT
    source_cloud,
    source_region,
    COUNT(DISTINCT target_cloud || ' / ' || target_region) AS source_fanout_targets,
    COUNT(DISTINCT transfer_type)                          AS source_transfer_types,
    SUM(bytes_transferred)                                 AS source_bytes_window
  FROM route_day
  GROUP BY 1, 2
),
scored AS (
  SELECT
    r.usage_date,
    r.source_cloud,
    r.source_region,
    r.target_cloud,
    r.target_region,
    r.transfer_type,
    r.transfer_windows,
    r.bytes_transferred,
    f.source_fanout_targets,
    f.source_transfer_types,
    f.source_bytes_window,
    r.bytes_transferred / POWER(1024, 3) AS gb_transferred,
    CASE
      WHEN r.source_cloud <> r.target_cloud   THEN 'CROSS_CLOUD'
      WHEN r.source_region <> r.target_region THEN 'CROSS_REGION_SAME_CLOUD'
      ELSE 'SAME_REGION'
    END AS egress_class,
    100.0 * r.bytes_transferred / NULLIF(f.source_bytes_window, 0) AS pct_of_source_bytes
  FROM route_day r
  JOIN source_fanout f
    ON f.source_cloud = r.source_cloud
   AND f.source_region = r.source_region
)
SELECT
  usage_date,
  source_cloud,
  source_region,
  target_cloud,
  target_region,
  transfer_type,
  egress_class,
  transfer_windows,
  ROUND(gb_transferred, 3)          AS gb_transferred,
  source_fanout_targets,
  source_transfer_types,
  ROUND(source_bytes_window / POWER(1024, 3), 3) AS source_gb_window,
  ROUND(pct_of_source_bytes, 1)     AS pct_of_source_bytes,
  CASE
    WHEN gb_transferred < :min_gb_day                          THEN 'NOT_ASSESSED'
    WHEN source_fanout_targets >= :fanout_critical_targets     THEN 'CRITICAL'
    WHEN egress_class = 'CROSS_CLOUD'                          THEN 'WARN'
    WHEN source_fanout_targets >= :fanout_warn_targets         THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  gb_transferred DESC,
  usage_date DESC;
