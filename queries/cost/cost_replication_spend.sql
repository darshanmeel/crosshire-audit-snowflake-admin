-- query_id: cost_replication_spend
-- title: What replication and failover cost per day - credits and bytes, per group and per database
-- domain: cost   tier: deep
-- rung: account_usage - both replication usage views are account-scoped history. The INFORMATION_SCHEMA replication functions exist but carry a short retention and are per-database, so they cannot produce the credits-per-terabyte comparison this query is built on.
-- reads: snowflake.account_usage.replication_group_usage_history, snowflake.account_usage.database_replication_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, and the query must be run in the TARGET account - both views are documented to report only for SECONDARY groups and databases, so running this on the primary returns nothing even when replication is working perfectly
-- freshness: LAGGED - up to 180 minutes on both views.
-- params: :period_days (default 30) rolling window; :min_credits_day (default 0.1) a replication object-day below this many credits returns NOT_ASSESSED; :credits_per_tb_warn (default 20) credits spent per terabyte transferred that raises WARN - a high ratio means credits are going into overhead rather than bytes; :credits_per_tb_critical (default 60) the same ratio that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: START_TIME, END_TIME, REPLICATION_GROUP_NAME, REPLICATION_GROUP_ID, CREDITS_USED and BYTES_TRANSFERRED are the complete documented column list of REPLICATION_GROUP_USAGE_HISTORY; START_TIME, END_TIME, DATABASE_NAME, DATABASE_ID, CREDITS_USED and BYTES_TRANSFERRED the complete list of DATABASE_REPLICATION_USAGE_HISTORY. Both are documented as reporting only for secondary objects in the target account, which is why that is stated as a hard requirement rather than a caveat. Not run live; the credits-per-terabyte band is a field heuristic.
-- empty_if: no_imported_privileges, account_usage_lag, replication_not_configured, no_activity
-- read_this: One row = one replicated object on one day, with SCOPE saying which of the two mechanisms billed it - a replication or failover GROUP, or an individually replicated DATABASE. CREDITS_USED is the cost; CREDITS_PER_TB is the efficiency, and it is the column that separates replicating a lot of data from replicating a little data very often.
-- healthy: credits roughly proportional to bytes, a stable daily rhythm, and no object appearing under both scopes. A large database replicated once a day moves a lot of bytes for few credits, which is exactly what the ratio should look like.
-- investigate_if: CREDITS_PER_TB is at or above :credits_per_tb_warn - the replication is paying overhead rather than moving data, which usually means a refresh schedule far more frequent than the data changes, or a table being rewritten in full and therefore re-replicated in full each cycle. Also investigate an object that costs credits every day but whose secondary nobody has ever failed over to or read from. False positive: the FIRST replication of a new object is a full copy and will dominate any window it falls in; and a genuinely low-volume but business-critical group with a tight RPO is supposed to have a poor ratio.
-- actions: 1) list what each replication group actually protects and confirm someone still needs the secondary - a group nobody would fail over to is pure cost (free); 2) match the refresh schedule to how often the data really changes, and stop replicating databases whose contents are reproducible rather than authoritative (config); 3) where the ratio is bad because a table is fully rewritten upstream, fix the load pattern to a merge - that reduces storage, Fail-safe and replication in one change (config).
-- next: cost_data_transfer_egress (if the replication bytes also cross a cloud or region boundary and are billed twice over), cost_database_storage_chargeback (if the replicated database is also carrying the storage bill), cost_dollarized_usage_by_day (if you need the replication line in money)
-- covers: SECONDARY objects in the TARGET account only, at hourly grain rolled to days. Group-level and database-level replication are complementary mechanisms, not duplicates: a database replicated inside a failover group bills on the group view, an individually replicated database on the database view. They are unioned here with a SCOPE column so neither is missed and neither is double-counted. Nothing about replication LATENCY or success is in either view - REPLICATION_GROUP_REFRESH_HISTORY answers that, and it is a different question.
-- caveats: Running this in the primary account returns nothing, which reads exactly like "replication costs nothing" and is the most likely misreading of this query - hence replication_not_configured in empty_if and the requirement stated above. The credits-per-terabyte ratio is undefined on a day that spent credits and moved no bytes; those rows are kept and reported with a null ratio rather than dropped, because a day that burns credits moving nothing is itself the finding. Bytes here are what replication transferred, not what the secondary now stores. An object that changes name mid-window appears as two objects; the ids are returned so you can spot that.

WITH group_usage AS (
  SELECT
    'REPLICATION_GROUP'                 AS scope,
    replication_group_name              AS object_name,
    TO_VARCHAR(replication_group_id)    AS object_id,
    DATE_TRUNC('day', start_time)::DATE AS usage_date,
    COALESCE(credits_used, 0)           AS credits_used,
    COALESCE(bytes_transferred, 0)      AS bytes_transferred
  FROM snowflake.account_usage.replication_group_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
database_usage AS (
  SELECT
    'DATABASE'                          AS scope,
    database_name                       AS object_name,
    TO_VARCHAR(database_id)             AS object_id,
    DATE_TRUNC('day', start_time)::DATE AS usage_date,
    COALESCE(credits_used, 0)           AS credits_used,
    COALESCE(bytes_transferred, 0)      AS bytes_transferred
  FROM snowflake.account_usage.database_replication_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
unioned AS (
  SELECT * FROM group_usage
  UNION ALL
  SELECT * FROM database_usage
),
object_day AS (
  SELECT
    scope,
    object_name,
    object_id,
    usage_date,
    COUNT(*)                  AS metered_hours,
    SUM(credits_used)         AS credits_used,
    SUM(bytes_transferred)    AS bytes_transferred
  FROM unioned
  GROUP BY 1, 2, 3, 4
),
scored AS (
  SELECT
    object_day.*,
    bytes_transferred / POWER(1024, 4)                          AS tb_transferred,
    credits_used / NULLIF(bytes_transferred / POWER(1024, 4), 0) AS credits_per_tb,
    SUM(credits_used) OVER (PARTITION BY scope, object_name)     AS object_credits_window,
    SUM(bytes_transferred) OVER (PARTITION BY scope, object_name) AS object_bytes_window,
    COUNT(*) OVER (PARTITION BY scope, object_name)              AS object_days_window,
    100.0 * credits_used / NULLIF(SUM(credits_used) OVER (), 0)  AS pct_of_replication_credits
  FROM object_day
)
SELECT
  usage_date,
  scope,
  object_name,
  object_id,
  metered_hours,
  ROUND(credits_used, 4)                                AS credits_used,
  ROUND(tb_transferred, 5)                              AS tb_transferred,
  ROUND(credits_per_tb, 2)                              AS credits_per_tb,
  ROUND(pct_of_replication_credits, 1)                  AS pct_of_replication_credits,
  object_days_window,
  ROUND(object_credits_window, 4)                       AS object_credits_window,
  ROUND(object_bytes_window / POWER(1024, 4), 5)        AS object_tb_window,
  CASE
    WHEN credits_used < :min_credits_day                     THEN 'NOT_ASSESSED'
    WHEN bytes_transferred = 0                               THEN 'CRITICAL'
    WHEN credits_per_tb >= :credits_per_tb_critical          THEN 'CRITICAL'
    WHEN credits_per_tb >= :credits_per_tb_warn              THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  credits_used DESC,
  usage_date DESC;
