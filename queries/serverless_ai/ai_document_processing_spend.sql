-- query_id: ai_document_processing_spend
-- title: Document processing spend per day, per function and per model
-- domain: serverless_ai   tier: standard
-- rung: account_usage - document processing is billed per query and reported only here. There is no INFORMATION_SCHEMA view for it and no SHOW command that carries pages or documents.
-- reads: snowflake.account_usage.cortex_document_processing_usage_history
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database (granted to ACCOUNTADMIN by default)
-- freshness: LAGGED - the ACCOUNT_USAGE index lists this view in the one-hour family; the view page does not publish its own figure. Rows are bucketed into hourly windows, so the current hour is always partial.
-- params: :period_days (default 30) rolling window in days; :min_pages (default 50) pages a group must have processed before its unit cost is judged, below which it reports NOT_ASSESSED; :warn_credits_per_page (default 0.01) credits per page that raises WARN; :critical_credits_per_page (default 0.05) credits per page that raises CRITICAL
-- confidence: confirmed-docs
-- confidence_note: CORTEX_DOCUMENT_PROCESSING_USAGE_HISTORY and all ten of its columns - QUERY_ID, CREDITS_USED, START_TIME, END_TIME, FUNCTION_NAME, MODEL_NAME, OPERATION_NAME, PAGE_COUNT, DOCUMENT_COUNT and FEATURE_COUNT - are documented at docs.snowflake.com/en/sql-reference/account-usage/cortex_document_processing_usage_history, including the OPERATION_NAME values inference and train, which are documented in LOWER case and are therefore compared here through UPPER rather than matched literally. Not run against a live account.
-- empty_if: no_imported_privileges, account_usage_lag, retention_window, cortex_not_used, no_activity
-- read_this: One row = one day x one function x one model x one operation. The two columns that matter are CREDITS_PER_PAGE and PAGE_COUNT. Document processing is billed on pages, not on documents, so a hundred-page contract and a one-page invoice are a hundred times apart no matter that both are one document - CREDITS_PER_PAGE is the unit price and PAGE_COUNT is the volume it is multiplied by. OPERATION_NAME separates training a model from running it, which are different budgets with different owners.
-- healthy: CREDITS_PER_PAGE is flat across days for a given function and model, training operations are rare and deliberate, and AVG_PAGES_PER_DOCUMENT matches the kind of document the team says it is processing.
-- investigate_if: CREDITS_PER_PAGE crosses :warn_credits_per_page, or training operations appear on days nobody planned a training run, or AVG_PAGES_PER_DOCUMENT jumps - that last one usually means someone started feeding whole scanned bundles where single documents were expected. A false positive is a legitimate switch to a larger model for a harder document class. A true positive is a re-processing loop that pays for the same pages twice.
-- actions: 1) take the QUERY_ID grain this view carries and join a sample back to QUERY_HISTORY to find who is running these - free; 2) split the extraction so cheap document classes go through a smaller model and only the hard class uses the expensive one, and stop re-processing documents that have already been extracted - config; 3) if the volume is genuine, negotiate the page volume into the capacity plan rather than treating it as an AI experiment - spend
-- next: ai_cortex_cost_guardrail (if you want the AI share of the whole bill), ai_cortex_function_spend (if the same extraction is also being done with direct model calls)
-- caveats: There is NO document-type column on this view. FUNCTION_NAME and MODEL_NAME, plus the pages-per-document ratio, are the closest axis to a document type that the data supports, and this query reports on those rather than inventing a classification. QUERY_ID is the only link to a caller: the view has no user and no warehouse column, so attribution requires a join to QUERY_HISTORY that is deliberately not made here, because doing so would drag a 45-minute-lagged view into a differently-lagged one. FEATURE_COUNT is populated only for extraction-style operations, which is documented, so it is reported and never used as a denominator. CREDITS_USED is metered credits and not currency.

WITH usage AS (
  SELECT
    TO_DATE(start_time)                     AS usage_day,
    function_name,
    model_name,
    operation_name,
    SUM(credits_used)                       AS credits_used,
    SUM(page_count)                         AS page_count,
    SUM(document_count)                     AS document_count,
    SUM(feature_count)                      AS feature_count,
    COUNT(DISTINCT query_id)                AS distinct_queries,
    COUNT(*)                                AS metered_rows,
    MIN(start_time)                         AS first_seen_at,
    MAX(end_time)                           AS last_seen_at
  FROM snowflake.account_usage.cortex_document_processing_usage_history
  WHERE start_time >= DATEADD('day', -:period_days, CURRENT_TIMESTAMP())
  GROUP BY 1, 2, 3, 4
),
day_totals AS (
  SELECT
    usage_day,
    SUM(credits_used)   AS day_credits,
    SUM(page_count)     AS day_pages,
    SUM(document_count) AS day_documents
  FROM usage
  GROUP BY 1
),
scored AS (
  SELECT
    u.usage_day,
    u.function_name,
    u.model_name,
    u.operation_name,
    ROUND(u.credits_used, 6)                                              AS credits_used,
    u.page_count,
    u.document_count,
    u.feature_count,
    u.distinct_queries,
    u.metered_rows,
    u.first_seen_at,
    u.last_seen_at,
    CASE WHEN u.page_count > 0
         THEN ROUND(u.credits_used / u.page_count, 8) END                 AS credits_per_page,
    CASE WHEN u.document_count > 0
         THEN ROUND(u.credits_used / u.document_count, 8) END             AS credits_per_document,
    CASE WHEN u.document_count > 0
         THEN ROUND(u.page_count * 1.0 / u.document_count, 2) END         AS avg_pages_per_document,
    ROUND(d.day_credits, 6)                                               AS day_credits,
    d.day_pages,
    d.day_documents,
    CASE WHEN d.day_credits > 0
         THEN ROUND(100.0 * u.credits_used / d.day_credits, 2) END        AS share_of_day_pct,
    UPPER(u.operation_name) = 'TRAIN'                                     AS is_training_operation
  FROM usage u
  JOIN day_totals d
    ON d.usage_day = u.usage_day
)
SELECT
  usage_day,
  function_name,
  model_name,
  operation_name,
  is_training_operation,
  credits_used,
  page_count,
  document_count,
  feature_count,
  credits_per_page,
  credits_per_document,
  avg_pages_per_document,
  share_of_day_pct,
  day_credits,
  day_pages,
  day_documents,
  distinct_queries,
  metered_rows,
  first_seen_at,
  last_seen_at,
  CASE
    WHEN page_count < :min_pages                          THEN 'NOT_ASSESSED'
    WHEN credits_per_page >= :critical_credits_per_page   THEN 'CRITICAL'
    WHEN credits_per_page >= :warn_credits_per_page       THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM scored
ORDER BY usage_day DESC, credits_used DESC NULLS LAST;
