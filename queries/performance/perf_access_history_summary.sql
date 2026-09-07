-- query_id: perf_access_history_summary
-- title: Which tables and columns the workload actually reads and writes - and which are written but never read
-- domain: performance   tier: standard
-- rung: account_usage - ACCESS_HISTORY exists only here and needs Enterprise Edition on top of the grant; no live rung records which columns a statement touched
-- reads: snowflake.account_usage.access_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database, granted to ACCOUNTADMIN by default, AND Enterprise Edition or higher - the view does not exist on Standard
-- freshness: LAGGED - the documented latency on ACCESS_HISTORY is up to 180 minutes, with 365 days of retention and data beginning 2021-02-22. A pipeline that changed this morning will not be reflected yet.
-- params: :period_days (default 30) trailing window in days, up to 365; :min_writes (default 1) write statements an object needs before a never-read verdict is worth stating; :top_n (default 500) rows returned
-- confidence: confirmed-docs
-- confidence_note: The columns QUERY_ID, QUERY_START_TIME, USER_NAME, BASE_OBJECTS_ACCESSED, DIRECT_OBJECTS_ACCESSED and OBJECTS_MODIFIED, and the element keys objectName, objectDomain, columnName and the nested columns array, were checked against docs.snowflake.com/en/sql-reference/account-usage/access_history. Not run against a live account. BASE_OBJECTS_ACCESSED is used for reads rather than DIRECT_OBJECTS_ACCESSED, because base objects resolve through views to the tables that were really read - reading the direct array instead would credit the view and miss the table underneath.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, edition_gated, no_activity
-- read_this: One row = one object. The two columns that matter are READ_QUERIES and WRITE_QUERIES - an object with writes and no reads is either a landing table nobody consumes or a pipeline whose consumer moved, and both are worth a question. DISTINCT_COLUMNS_READ against the object width is the second reading: a wide table read three columns at a time is a projection problem, not a pruning one.
-- healthy: every written object has readers, the read counts match what you believe the pipeline is for, and the objects at the top by read volume are the ones the business would name.
-- investigate_if: WARN on an object written at least :min_writes times in the window and never read - that is the never-read finding, and it is the only one this query can honestly make. A false positive is easy to hit and must be checked: the object may be read by a consumer OUTSIDE this account through a share, read only quarterly and so outside the window, read by a statement that failed before it registered, or read through a path Access History does not record. Confirm before dropping anything.
-- actions: 1) ask the owner of a written-but-never-read object what consumes it, which costs nothing and resolves most rows (free); 2) if it genuinely has no consumer, stop producing it - dropping the task or the pipeline step removes both the compute and the storage, and is a config change, not a delete of data (config); 3) storage on a table nobody reads is the purest waste in the account, so a confirmed orphan is the one case in this domain where the action reduces the bill directly (spend).
-- next: perf_table_pruning_gap (for the objects with the largest read volume, to see whether those reads prune), perf_repeated_query_shapes (to find which shape drives the reads on a hot object), perf_clustering_recommendations (if a heavily read object is also badly pruned), access_who_can_read_object_au (to see who can reach an object you are about to stop producing)
-- covers: Objects that appear in at least one statement in the window - reads via BASE_OBJECTS_ACCESSED, writes via OBJECTS_MODIFIED. It CANNOT list objects that were never touched at all: an object absent from every statement is absent from this view, so a complete never-read census needs an object inventory joined in from INFORMATION_SCHEMA, which is out of scope for a single standalone statement here. The never-read verdict is therefore restricted to objects with writes and no reads, which the view can prove.
-- caveats: The window bounds the whole verdict - a quarterly consumer looks like no consumer in a 30-day window, so raise :period_days before acting on the never-read band. Column-level reads are counted from the nested columns array on base objects, and a statement selecting all columns registers all of them, so DISTINCT_COLUMNS_READ is a union across statements, not a per-statement width. OBJECTS_MODIFIED records the write side of DML; a table created by CREATE TABLE AS SELECT registers, but a table only altered by DDL is carried in OBJECT_MODIFIED_BY_DDL, which this query does not read - so a purely DDL-touched object can look untouched. Access History is Enterprise Edition or higher, and an empty result on Standard is edition_gated, not a clean account. Object names are the fully qualified names from your own account and appear verbatim in the output - treat the result as internal.

WITH reads AS (
  SELECT
    GET(f.value, 'objectName')::string   AS object_name,
    GET(f.value, 'objectDomain')::string AS object_domain,
    a.query_id,
    a.user_name,
    a.query_start_time,
    GET(f.value, 'columns')              AS read_columns
  FROM snowflake.account_usage.access_history a,
       LATERAL FLATTEN(input => a.base_objects_accessed) f
  WHERE a.query_start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
read_columns_flat AS (
  SELECT
    r.object_name,
    r.object_domain,
    GET(c.value, 'columnName')::string AS column_name
  FROM reads r,
       LATERAL FLATTEN(input => r.read_columns, outer => TRUE) c
),
read_rollup AS (
  SELECT
    object_name,
    object_domain,
    COUNT(DISTINCT query_id)         AS read_queries,
    COUNT(DISTINCT user_name)        AS distinct_readers,
    MIN(query_start_time)            AS first_read,
    MAX(query_start_time)            AS last_read
  FROM reads
  GROUP BY 1, 2
),
column_rollup AS (
  SELECT
    object_name,
    object_domain,
    COUNT(DISTINCT column_name)      AS distinct_columns_read
  FROM read_columns_flat
  WHERE column_name IS NOT NULL
  GROUP BY 1, 2
),
writes AS (
  SELECT
    GET(f.value, 'objectName')::string   AS object_name,
    GET(f.value, 'objectDomain')::string AS object_domain,
    a.query_id,
    a.user_name,
    a.query_start_time
  FROM snowflake.account_usage.access_history a,
       LATERAL FLATTEN(input => a.objects_modified) f
  WHERE a.query_start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
),
write_rollup AS (
  SELECT
    object_name,
    object_domain,
    COUNT(DISTINCT query_id)         AS write_queries,
    COUNT(DISTINCT user_name)        AS distinct_writers,
    MIN(query_start_time)            AS first_write,
    MAX(query_start_time)            AS last_write
  FROM writes
  GROUP BY 1, 2
),
combined AS (
  SELECT
    COALESCE(r.object_name, w.object_name)     AS object_name,
    COALESCE(r.object_domain, w.object_domain) AS object_domain,
    COALESCE(r.read_queries, 0)                AS read_queries,
    COALESCE(r.distinct_readers, 0)            AS distinct_readers,
    r.first_read,
    r.last_read,
    COALESCE(w.write_queries, 0)               AS write_queries,
    COALESCE(w.distinct_writers, 0)            AS distinct_writers,
    w.first_write,
    w.last_write,
    COALESCE(c.distinct_columns_read, 0)       AS distinct_columns_read
  FROM read_rollup r
  FULL OUTER JOIN write_rollup w
    ON  w.object_name   = r.object_name
    AND w.object_domain = r.object_domain
  LEFT JOIN column_rollup c
    ON  c.object_name   = COALESCE(r.object_name, w.object_name)
    AND c.object_domain = COALESCE(r.object_domain, w.object_domain)
)
SELECT
  CASE
    WHEN read_queries = 0 AND write_queries >= :min_writes THEN 'WARN'
    ELSE 'OK'
  END                                          AS status,
  object_name,
  object_domain,
  read_queries,
  write_queries,
  distinct_readers,
  distinct_writers,
  distinct_columns_read,
  first_read,
  last_read,
  first_write,
  last_write
FROM combined
ORDER BY
  IFF(read_queries = 0 AND write_queries >= :min_writes, 0, 1),
  read_queries DESC,
  write_queries DESC
LIMIT :top_n;
