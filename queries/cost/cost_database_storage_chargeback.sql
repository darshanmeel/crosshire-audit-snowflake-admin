-- query_id: cost_database_storage_chargeback
-- title: Storage bytes per database per day, Fail-safe tail included - the storage chargeback line
-- domain: cost   tier: standard
-- rung: account_usage - the INFORMATION_SCHEMA storage function is scoped to the current database, so it cannot produce a SHARE of the account, which is the entire point of a chargeback. Only this rung sees every database at once.
-- reads: snowflake.account_usage.database_storage_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - up to 180 minutes. Storage moves slowly, so the lag matters far less here than on any credits view; a day-old picture of storage is very nearly today's picture.
-- params: :period_days (default 30) rolling window of daily storage observations; :min_gb (default 10) a database averaging fewer gigabytes than this is too small to band and returns NOT_ASSESSED; :failsafe_warn_pct (default 50) Fail-safe bytes as a percentage of live database bytes that raises WARN; :failsafe_critical_pct (default 100) the same ratio that raises CRITICAL - at 100 the safety tail is larger than the data it protects
-- confidence: confirmed-docs
-- confidence_note: USAGE_DATE, DATABASE_ID, DATABASE_NAME, DELETED, AVERAGE_DATABASE_BYTES, AVERAGE_FAILSAFE_BYTES, AVERAGE_HYBRID_TABLE_STORAGE_BYTES, AVERAGE_ARCHIVE_STORAGE_COOL_BYTES and AVERAGE_ARCHIVE_STORAGE_COLD_BYTES are documented columns of this view, and DELETED is documented as a TIMESTAMP rather than a boolean. Not run live. Doc-verified and quoted in the caveats because it changes what this query IS: Snowflake states the view is for comparing databases RELATIVELY, not for computing exact charges.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, no_activity
-- read_this: One row = one database over the window. PCT_OF_ACCOUNT_BYTES is the chargeback number - that database's share of everything stored - and FAILSAFE_PCT_OF_ACTIVE beside it is the quality check on that share: a database can own a large slice of the bill because it holds a lot of data, or because it holds a lot of churn that Fail-safe is still keeping.
-- healthy: shares that match what each database is for, Fail-safe well under :failsafe_warn_pct of live bytes, and a growth column that is flat or explainable. Fail-safe is 7 days of non-configurable retention on permanent tables, so a small steady tail is correct and unavoidable.
-- investigate_if: FAILSAFE_PCT_OF_ACTIVE is at or above :failsafe_warn_pct - you are paying to protect churn rather than data, which almost always means a table is being rewritten in full when it could be merged incrementally. Also investigate a dropped database (DROPPED_ON not null) still carrying bytes, and any database whose GROWTH_PCT is large while its share of the account is already large. False positive: a database that has just had a large one-off delete or rebuild will carry a big Fail-safe tail for exactly seven days and then not.
-- actions: 1) publish the share column as the chargeback split and reconcile the total against the invoice before anyone is billed on it - the docs are explicit that these bytes are proportional, not exact (free); 2) for a high Fail-safe ratio, find the rewritten tables and change the load pattern to a merge, and shorten Time Travel where the retention is longer than anyone actually uses (config); 3) transient or temporary tables carry no Fail-safe at all and are the right home for a genuinely reproducible staging layer (config).
-- next: cost_dollarized_usage_by_day (if you need this share expressed in money rather than bytes), cost_credits_by_warehouse_day (if compute rather than storage turns out to be the bill), cost_effective_rate_sheet (if you need the per-TB rate to price these bytes yourself)
-- covers: DATABASE grain, account-wide, daily. It cannot see inside a database - which table holds the bytes is a TABLE_STORAGE_METRICS question in the storage domain, not a cost one. Stage storage and internal-stage leaks are not in this view either. Because it is an average per day, a spike that lasted six hours is smoothed away here.
-- caveats: Snowflake documents this view as suitable for comparing databases relative to one another rather than for calculating charges: apply each database's PCT_OF_ACCOUNT_BYTES to the storage total on the invoice instead of pricing these bytes directly. DELETED is a timestamp, so a dropped database keeps appearing with real bytes until its retention expires - that is correct and is surfaced as DROPPED_ON rather than filtered away, because dropped-but-still-billed storage is a finding in its own right. The archive cool and cold columns require the 2025_07 behavior change bundle on some accounts; if your account rejects them, delete those two expressions and nothing else changes. Bytes here are daily AVERAGES, not end-of-day snapshots, so growth measured between the first and last day of the window smooths over intra-day movement.

WITH daily AS (
  SELECT
    usage_date,
    database_id,
    database_name,
    deleted,
    COALESCE(average_database_bytes, 0)              AS database_bytes,
    COALESCE(average_failsafe_bytes, 0)              AS failsafe_bytes,
    COALESCE(average_hybrid_table_storage_bytes, 0)  AS hybrid_table_bytes,
    COALESCE(average_archive_storage_cool_bytes, 0)  AS archive_cool_bytes,
    COALESCE(average_archive_storage_cold_bytes, 0)  AS archive_cold_bytes
  FROM snowflake.account_usage.database_storage_usage_history
  WHERE usage_date >= DATEADD('day', -:period_days, CURRENT_DATE())
),
per_database AS (
  SELECT
    database_id,
    database_name,
    MAX(deleted)                                       AS dropped_on,
    COUNT(DISTINCT usage_date)                         AS days_observed,
    MIN(usage_date)                                    AS first_day,
    MAX(usage_date)                                    AS last_day,
    AVG(database_bytes)                                AS avg_database_bytes,
    AVG(failsafe_bytes)                                AS avg_failsafe_bytes,
    AVG(hybrid_table_bytes)                            AS avg_hybrid_table_bytes,
    AVG(archive_cool_bytes + archive_cold_bytes)       AS avg_archive_bytes,
    AVG(database_bytes + failsafe_bytes + hybrid_table_bytes
        + archive_cool_bytes + archive_cold_bytes)     AS avg_billable_bytes,
    MIN_BY(database_bytes + failsafe_bytes, usage_date) AS bytes_at_window_start,
    MAX_BY(database_bytes + failsafe_bytes, usage_date) AS bytes_at_window_end
  FROM daily
  GROUP BY database_id, database_name
),
scored AS (
  SELECT
    per_database.*,
    100.0 * avg_billable_bytes
          / NULLIF(SUM(avg_billable_bytes) OVER (), 0)      AS pct_of_account_bytes,
    100.0 * avg_failsafe_bytes / NULLIF(avg_database_bytes, 0) AS failsafe_pct_of_active,
    100.0 * (bytes_at_window_end - bytes_at_window_start)
          / NULLIF(bytes_at_window_start, 0)                AS growth_pct
  FROM per_database
)
SELECT
  database_name,
  database_id,
  dropped_on,
  days_observed,
  first_day,
  last_day,
  ROUND(avg_database_bytes / POWER(1024, 3), 2)     AS avg_database_gb,
  ROUND(avg_failsafe_bytes / POWER(1024, 3), 2)     AS avg_failsafe_gb,
  ROUND(avg_hybrid_table_bytes / POWER(1024, 3), 2) AS avg_hybrid_table_gb,
  ROUND(avg_archive_bytes / POWER(1024, 3), 2)      AS avg_archive_gb,
  ROUND(avg_billable_bytes / POWER(1024, 3), 2)     AS avg_billable_gb,
  ROUND(pct_of_account_bytes, 2)                    AS pct_of_account_bytes,
  ROUND(failsafe_pct_of_active, 1)                  AS failsafe_pct_of_active,
  ROUND(growth_pct, 1)                              AS growth_pct,
  CASE
    WHEN avg_database_bytes / POWER(1024, 3) < :min_gb           THEN 'NOT_ASSESSED'
    WHEN failsafe_pct_of_active >= :failsafe_critical_pct        THEN 'CRITICAL'
    WHEN failsafe_pct_of_active >= :failsafe_warn_pct            THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY
  DECODE(status, 'CRITICAL', 0, 'WARN', 1, 'OK', 2, 3),
  avg_billable_bytes DESC;
