# Storage, Time Travel & Table Optimization

What is stored, what it costs, and which optimization feature is paying for itself. Table storage
metrics on two rungs, Time Travel and Fail-safe bloat, the internal-stage line nobody owns, the
account storage trend, Automatic Clustering and Search Optimization weighed against the benefit
Snowflake itself measured, Iceberg, DML churn — and a drop-safety gate to run before anyone deletes
anything.

📖 **Full interactive docs → [every query, explained](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage)** — why it matters, which rung it stands on, how to read every output column, and the caveats.

| # | Query | Tier | Rung | What it does |
|--:|---|---|---|---|
| 01 | [`storage_account_trend`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_account_trend) | lite | AU | One row per day for the whole account: total, table, stage, Fail-safe and hybrid bytes, with the day-on-day delta, a 7-day average and the change since the window opened — so you can see whether the bill is growing on *data* or on *retention*. |
| 02 | [`storage_auto_clustering_spend`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_auto_clustering_spend) | standard | AU | Automatic Clustering credits per table over the window, with bytes and rows reclustered, active days and credits per TB reclustered — the shape that separates bulk work from constant re-triggering. |
| 03 | [`storage_clustering_benefit_review`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_clustering_benefit_review) | deep | AU | Splits the window in half and asks whether pruning *improved* while the clustering credits were being spent. Credits with a flat, low prune percentage is the signature of a key that no longer matches the queries. |
| 04 | [`storage_drop_safety_gate`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_drop_safety_gate) | deep | AU | ⚠️ Run before any `DROP TABLE`. Per table: what still references it (and whether the reference is `BY_ID` or a danglable `BY_NAME`), who read it last through views included, and how many bytes would enter Fail-safe — a cost you cannot shorten or cancel afterwards. |
| 05 | [`storage_iceberg_inventory`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_iceberg_inventory) | standard | AU | Every live Iceberg table with its size, clustering key and retention, joined to what its compaction jobs cost. `ACCOUNT_USAGE` carries **no catalog column**, so the catalog attribution is a labelled inference and the query hands you the `SHOW ICEBERG TABLES` follow-up. |
| 06 | [`storage_materialized_view_refresh_spend`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_materialized_view_refresh_spend) | standard | AU | Refresh credits per materialized view against how many queries actually named it, as credits-per-query-served. Handles the documented landmine that `CREDITS_USED` on this view is a **VARCHAR**. |
| 07 | [`storage_metrics_live_is`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_metrics_live_is) | lite | IS | The **live, low-privilege twin** of `storage_table_breakdown`: active / Time Travel / Fail-safe / retained-for-clone bytes for the current database, with no admin grant and no `ACCOUNT_USAGE` lag. |
| 08 | [`storage_search_optimization_active`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_search_optimization_active) | standard | SHOW | Which tables have Search Optimization on, how large the access path is relative to the table, and how far a build has got. `SHOW` is not a fallback here — no `ACCOUNT_USAGE` view carries the flag. Emits a ready-to-run `DESCRIBE SEARCH OPTIMIZATION` per row, because `SHOW TABLES` cannot name the optimized columns. |
| 09 | [`storage_search_optimization_benefit`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_search_optimization_benefit) | deep | AU | Weighs Search Optimization credits against the partitions it pruned *that natural pruning would not have*. The benefits view is documented as **sampled**, so an absent benefit row is reported `NOT_ASSESSED`, never as proof of waste. |
| 10 | [`storage_stage_leak`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_stage_leak) | standard | AU | One row for the account: the **floor** of the internal-stage series over the window — whatever never drained is what has been sitting there paying rent. The view has no per-stage breakdown, so the query is honest about ending at a size and a direction. |
| 11 | [`storage_table_breakdown`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_table_breakdown) | lite | AU | Account-wide table storage split active vs Time Travel vs Fail-safe vs retained-for-clone, with dropped-but-still-billed tables labelled. The inventory the other storage queries join back to. |
| 12 | [`storage_table_dml_churn`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_table_dml_churn) | deep | AU | Rows *displaced* — removed plus updated — against rows added, per table. The rewrite ratio is the mechanism that turns a small table into a large Time Travel bill, and an append-only table with huge volume correctly does not look like a problem. |
| 13 | [`storage_time_travel_bloat`](https://learn.crosshire.ch/learn/tech/snowflake/audit/storage#q-storage_time_travel_bloat) ★ | standard | AU | **First-audit pick.** Tables whose Time Travel plus Fail-safe rivals or exceeds their live data — retention paid for on churn nobody has restored. Sorted by wasted *bytes*, not by ratio, so a big table with a modest ratio outranks a tiny one with a dramatic one. |

## Rungs in this domain

Eleven of the thirteen stand on `ACCOUNT_USAGE`, and that is not laziness — it is the shape of the
question. Storage history, dependency graphs and serverless feature billing have no
`INFORMATION_SCHEMA` equivalent that spans an account. The two exceptions are the argument:

- **`storage_metrics_live_is`** (`information_schema`) is the live, low-privilege twin of
  `storage_table_breakdown`. Run it first, per database, before asking anyone for
  `IMPORTED PRIVILEGES`.
- **`storage_search_optimization_active`** (`show`) is not a fallback at all. No `ACCOUNT_USAGE` view
  records *which tables have Search Optimization enabled* — `SEARCH_OPTIMIZATION_HISTORY` only bills
  it. `SHOW` is the only rung that can answer, which is why it carries `confidence: unverified`:
  `SHOW` output labels are not a versioned contract.

## Reading an empty result

Every query declares `empty_if:` from a controlled vocabulary, so zero rows is attributable. In this
domain the ones that bite are `feature_not_enabled` (nothing is clustered / search-optimized, so
there is nothing to bill), `edition_gated` (`ACCESS_HISTORY` and materialized views need Enterprise+,
which turns `storage_drop_safety_gate` and `storage_materialized_view_refresh_spend` into
`NOT_ASSESSED` rather than a falsely clean bill of health), and `account_usage_lag` — up to **6 hours**
on `TABLE_DML_HISTORY`, the slowest view in this library.

<sub>★ = first-audit pick. This is a one-line index — the full write-up (output columns, bands, actions, caveats) lives in the <a href="https://learn.crosshire.ch/learn/tech/snowflake/audit/storage">interactive docs</a>. The <code>.sql</code> files in this folder are the source of truth. Nothing here has been run against a live Snowflake account: every view and column is verified against <code>docs.snowflake.com</code> and each query says so in its <code>confidence</code> field.</sub>
