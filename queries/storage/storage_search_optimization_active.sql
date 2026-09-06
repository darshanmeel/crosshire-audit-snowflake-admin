-- query_id: storage_search_optimization_active
-- title: Which tables have Search Optimization switched on, live, with only SHOW
-- domain: storage   tier: standard
-- rung: show - ACCOUNT_USAGE has no view that lists which tables have the search optimization property. SEARCH_OPTIMIZATION_HISTORY only bills it, and TABLES does not carry the flag, so SHOW is not a fallback here - it is the only rung that can answer at all.
-- reads: SHOW TABLES IN ACCOUNT, result_scan(last_query_id())
-- requires: a role with USAGE on the databases and schemas, and enough privilege on each table to see it in SHOW. No IMPORTED PRIVILEGES and no ACCOUNTADMIN.
-- freshness: LIVE - SHOW reads current object metadata, so a search optimization build you started a minute ago appears immediately, with search_optimization_progress showing how far it has got. This is the rung to use when checking whether a change took effect.
-- params: :min_so_gb (default 0) floor in GiB on the search optimization structure size - raise it to see only the builds large enough to matter on a bill
-- confidence: unverified
-- confidence_note: The output columns search_optimization, search_optimization_progress, search_optimization_bytes, is_iceberg and cluster_by are listed on docs.snowflake.com/en/sql-reference/sql/show-tables, but SHOW output is not a versioned contract the way a documented view is: labels have been added across releases and RESULT_SCAN returns them as text regardless of what they look like. Every numeric column is therefore cast defensively - TRY_TO_NUMBER for the byte and row counts, TRY_TO_DOUBLE for the fractional progress percentage - rather than trusted. Not run against a live account.
-- empty_if: feature_not_enabled, privilege_scoped, edition_gated
-- read_this: One row = one table with search optimization switched on, as your role can see it. so_gb is the size of the search access path - a separate structure you are billed for on TOP of the table - and so_pct_of_table is that size relative to the table itself. build_progress below 100 means the structure is still being built and is still costing serverless credits to finish. This query cannot tell you WHICH COLUMNS are optimized: SHOW TABLES has no such column, so the last column hands you the DESCRIBE statement that does.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: 1) run the describe_stmt in the last column for each row to see the actual optimized columns and expression types - free, and the only way to learn whether somebody optimized the whole table when two columns would have done (free); 2) compare this list against storage_search_optimization_benefit and remove the property from any table that appears here and earns nothing there (config); 3) where only a couple of predicates matter, replace a whole-table ADD SEARCH OPTIMIZATION with per-column ON EQUALITY clauses - a smaller structure costs less to build and less to maintain (config).
-- next: storage_search_optimization_benefit (if you want to know what each of these is earning), storage_clustering_benefit_review (if the same tables are also clustered - paying for two access paths on one table deserves a reason)
-- covers: What YOUR ROLE can see, right now. A table in a database your role has no USAGE on is invisible here, silently - which is the standing weakness of the SHOW rung and the reason the ACCOUNT_USAGE benefit query beside it exists. There is no history on this rung either: a table that had search optimization removed yesterday is simply absent, with no trace.
-- caveats: SHOW TABLES IN ACCOUNT can be slow and heavy on a large account, and the documented LIMIT ceiling for SHOW is 10000 rows - above that you must scope the SHOW to a database or schema and run it more than once, or the result is silently short. RESULT_SCAN(LAST_QUERY_ID()) reads the immediately preceding statement, so the SHOW and the SELECT must be run as a pair with nothing between them; running the SELECT alone scans whatever you last ran, which is a wrong answer that looks like a right one. Column names from SHOW are lowercase and must stay double-quoted. search_optimization_bytes is the structure size, not the storage the table itself occupies, and it is billed as its own line.

SHOW TABLES IN ACCOUNT;

SELECT
    "database_name"                                      AS database_name,
    "schema_name"                                        AS schema_name,
    "name"                                               AS table_name,
    "kind"                                               AS table_kind,
    "search_optimization"                                AS search_optimization,
    TRY_TO_DOUBLE("search_optimization_progress")        AS build_progress_pct,
    ROUND(TRY_TO_NUMBER("search_optimization_bytes") / POWER(1024, 3), 3) AS so_gb,
    ROUND(TRY_TO_NUMBER("bytes") / POWER(1024, 3), 3)    AS table_gb,
    ROUND(100 * TRY_TO_NUMBER("search_optimization_bytes")
          / NULLIF(TRY_TO_NUMBER("bytes"), 0), 1)        AS so_pct_of_table,
    TRY_TO_NUMBER("rows")                                AS row_count,
    "cluster_by"                                         AS clustering_key,
    "is_iceberg"                                         AS is_iceberg,
    "owner"                                              AS table_owner,
    "created_on"                                         AS created_on,
    'DESCRIBE SEARCH OPTIMIZATION ON TABLE "' || "database_name" || '"."' || "schema_name"
        || '"."' || "name" || '";'                       AS describe_stmt
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE UPPER("search_optimization") = 'ON'
  AND COALESCE(TRY_TO_NUMBER("search_optimization_bytes"), 0) >= :min_so_gb * POWER(1024, 3)
ORDER BY TRY_TO_NUMBER("search_optimization_bytes") DESC NULLS LAST;
