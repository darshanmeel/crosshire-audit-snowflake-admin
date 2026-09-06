# CATALOGUE — the worklist this library is built from

**100 queries across 7 domains**, every one traced to the question it answers, the ladder rung it
stands on, and the internal audit finding it was derived from. This file is the plan; the `.sql`
files under [`queries/`](../queries/) are the delivery. Nothing here is a number — the findings
engine's outputs are client-derived and never leave it. What crosses over is the *shape of the
question* and the *shape of the SQL*, re-authored as one standalone `SELECT` against documented
Snowflake views.

Status: **2 of 100 written** (the two grant-graph queries, already shipped). The remaining 98 are
the build queue.

---

## The ladder — the house principle

`SHOW GRANTS ON` a table shows one hop. `ACCOUNT_USAGE` shows everything but needs
`ACCOUNTADMIN` and lags. Neither fact is a footnote: **which rung you are standing on changes what
the answer means.** So every query in this library declares its rung, and the rungs are ordered
cheapest-and-most-live first:

| Rung | What it is | Privilege | Freshness | Scope |
|---|---|---|---|---|
| `information_schema` | per-database views + table functions (and bare built-ins like `GET_QUERY_OPERATOR_STATS()`) | none beyond the caller's own grants | **LIVE** | current database; short retention (7–14 days) |
| `show` | `SHOW …` piped through `RESULT_SCAN(LAST_QUERY_ID())` | only `SHOW` | **LIVE** | what the caller's role can see; snapshot, no history |
| `procedure` | an installed Snowpark walker doing what no view can | `SHOW` + one `CREATE PROCEDURE` | **LIVE** | caller's visibility; blind branches are *marked*, not hidden |
| `account_usage` | `SNOWFLAKE.ACCOUNT_USAGE.*` | `IMPORTED PRIVILEGES` on `SNOWFLAKE` (ACCOUNTADMIN by default) | **LAGGED** (45 min – 8 h, documented per view) | whole account; **1 year of history** |
| `organization_usage` | `SNOWFLAKE.ORGANIZATION_USAGE.*` | org account roles (`ORGANIZATION_BILLING_VIEWER`, …) | **LAGGED** (24–72 h) | every account in the org; the **only** rung that knows currency |

**Prefer the lowest rung that can answer the question, and say why you climbed.** Ten queries here
stand on `SHOW`, and seven on `INFORMATION_SCHEMA` — five of those seven exist *only* to give an
`ACCOUNT_USAGE` answer its live, low-privilege twin (their ids end `_live_is`), and the other two
answer something `ACCOUNT_USAGE` cannot reach at all. That is the point, not duplication. The linter
enforces the claim: a file that says `rung: information_schema` while selecting from `ACCOUNT_USAGE`
fails the build.

---

## Rules this library is built under

1. **No live account.** Nothing here has been run against a real Snowflake account. Every view and
   column is verified against `docs.snowflake.com` and the query then claims
   `confidence: confirmed-docs`. A shape that could not be doc-verified (notably `SHOW` output
   column labels, which are not a stable documented contract) claims `confidence: unverified` and
   says so in `confidence_note`. **The bare word `confirmed` is reserved for a live run and the
   linter rejects it.**
2. **One standalone `SELECT` per file.** The findings engine is a collection layer
   (`CREATE TEMP TABLE …` from `ACCOUNT_USAGE`) plus logic over those temp tables. A library query
   must run start-to-finish in a Snowflake worksheet with no setup, so each one is a *flattening*
   of that pair, never a copy. The linter rejects the engine's fingerprints (`COLLECT_*` temp
   tables, `source:` banners, `edition=` markers).
   *One documented exception:* `access_who_can_read_object.au.sql` ships two forms of the same
   question (seed-on-object, and build-the-role-graph-once for auditing many objects).
3. **No identifiers from anywhere real.** No client, company, account, warehouse or database name
   from the findings engine or from anywhere else. Placeholders only. Grep before committing.
4. **Straight quotes, LF endings.** `dos2unix -q` and `tr -cd '\r' < f | wc -c` → `0`. The linter
   fails on CRLF and on curly quotes.
5. **`:period_days`, never a hard-coded window.** Every rolling window is a parameter with a
   documented default. A point-in-time snapshot (`SHOW`, an inventory) may have no window at all.
6. **Empty is not zero.** A query that could return nothing for a structural reason declares it in
   `empty_if:` from a controlled vocabulary, so "couldn't look" is never read as "nothing there".

---

## The header contract, in one screen

Every `queries/<domain>/<id>.sql` opens with this comment block. All 16 fields are required and
non-empty; `tier` rides on the `domain:` line. Parsed by
[`tools/header_schema.py`](../tools/header_schema.py), which is the single source of truth for
[`tools/build_manifest.py`](../tools/build_manifest.py) and
[`tools/lint_headers.py`](../tools/lint_headers.py).

```sql
-- query_id:        matches the filename stem (a `.au` / `.proc` rung suffix becomes `_au` / `_proc`)
-- title:           one line, what it answers
-- domain:          <domain>   tier: lite | standard | deep
-- rung:            information_schema | show | procedure | account_usage | organization_usage  (+ gloss)
-- reads:           comma-separated Snowflake objects (AU/OU view, IS view or table function, SHOW command)
-- requires:        the exact grant or role needed
-- freshness:       LIVE | LAGGED (<the documented latency>) — and what that means for the answer
-- params:          :name (default X) meaning; :name2 (default Y) meaning
-- confidence:      confirmed-docs | unverified          ← never plain "confirmed"
-- confidence_note: what was doc-verified, and what was not
-- read_this:       what ONE ROW means, and which two columns matter
-- healthy:         the band that needs no action (a labelled field heuristic, tuned by :params)
-- investigate_if:  the band that does (WARN / CRITICAL thresholds, and what a false positive looks like)
-- actions:         1) free  2) config  3) spend        ← the action ladder, cheapest first
-- next:            query_id (if <condition>), query_id (if <condition>)
-- caveats:         every methodological hole, stated
-- runnable:        false        (optional — a non-SELECT install script)
-- empty_if:        token, token (optional — controlled vocabulary; see header_schema.EMPTY_IF_VOCAB)
-- covers:          (optional) what this rung sees and does not see, vs the other rungs
```

A **finding** query also emits a `status` column (`OK | WARN | CRITICAL | NOT_ASSESSED`, and only
those four — the linter checks) and sorts worst-first. An **inventory** query is a stable reference
you join to and writes `n/a - inventory` in the two band fields.

Generated artifacts, never hand-edited: [`queries/manifest.json`](../queries/manifest.json)
(`python tools/build_manifest.py`). CI gate: `python tools/lint_headers.py`.

---

## Divergence from the Databricks sibling

The [Databricks library](https://github.com/darshanmeel/crosshire-audit-databricks-admin) uses
`cost · performance · compute · jobs_pipelines · serving_ai · storage · governance_access`. Four of
those carry over unchanged in spirit. Three do not, because a Snowflake admin does not think that way:

- **`compute` → `warehouse`.** Databricks compute is clusters, pools and node types. Snowflake
  compute is *one object* — the warehouse — and the whole tuning surface (size, auto-suspend,
  auto-resume, min/max clusters, scaling policy, Query Acceleration) hangs off it.
- **`jobs_pipelines` + `serving_ai` → `serverless_ai`.** Snowflake's tasks, pipes, dynamic tables,
  alerts and Cortex share one property that dominates everything else about them: they are
  **serverless**, so no warehouse size and no resource monitor governs their spend. That shared
  blast radius is a better organising principle than "is it a pipeline or a model?".
- **`governance_access` splits into `governance_access` + `security`.** In Snowflake, "who can read
  this table" (a grant graph) and "can this person log in without MFA" (account posture) are
  answered from different views, by different people, on different days.

And two things the Databricks taxonomy has no slot for are placed deliberately rather than given a
thin domain of their own:

- **Data transfer, egress and replication → `cost`.** They are bill lines. An admin looks for them
  next to the credits, not in a "movement" chapter. (Databricks does the same:
  `cost_networking_egress` lives in cost.)
- **Share and listing exposure → `governance_access`.** "What leaves this account" is an access
  question. (Databricks likewise puts Delta Sharing exposure in governance.)

---

## The seven domains

| Domain | Queries | ★ | What it answers |
|---|--:|--:|---|
| [`cost`](#cost) | 16 | 4 | Credits, dollars and chargeback - including egress and replication, which are bill lines |
| [`warehouse`](#warehouse) | 13 | 1 | The one compute object a Snowflake admin tunes: size, idle, suspend/resume, clusters |
| [`performance`](#performance) | 14 | 1 | What the queries are doing: spilling, queuing, failures, pruning, plans |
| [`storage`](#storage) | 13 | 1 | Bytes, Time Travel, and which optimization feature is paying for itself |
| [`serverless_ai`](#serverless_ai) | 17 | 1 | Spend no warehouse size and no resource monitor governs - tasks, pipes, Cortex |
| [`governance_access`](#governance_access) | 13 | 1 | Who can reach what, and what the data is labelled as |
| [`security`](#security) | 14 | 1 | Identity, authentication, network and account posture |

Engine sections each domain absorbs:

- **`cost`** ← cost, movement, deep (credit_spike_anomaly)
- **`warehouse`** ← cost (warehouse-shaped findings), workload (warehouse-event findings), deep (warehouse_wake_analysis)
- **`performance`** ← workload, cost (pruning / clustering findings), deep (bytes_scanned_divergence)
- **`storage`** ← storage, cost (clustering findings), unsectioned (account_storage_trend, stage_storage_leak, drop_safety_gate)
- **`serverless_ai`** ← serverless, unsectioned (cortex_*, document_ai_spend, alert_reliability, bulk_load_reliability, snowpipe_streaming_migration)
- **`governance_access`** ← datagov, unsectioned (stale_roles, applied_sensitive_tags, classification_coverage, object_tag_coverage, data_quality_rule_results)
- **`security`** ← security, unsectioned (password_policy_strength, session_auth_posture, session_timeout_policy, idle_open_sessions, trust_center_findings_summary, failover_posture)

---

<a id="cost"></a>

### `cost` — Credits, spend & chargeback

Where the credits go and whether the number can be trusted: warehouse and serverless credits per day, per-query attribution, chargeback by query tag, cloud-services overage, spend anomalies - and the only rung that turns credits into money (ORGANIZATION_USAGE rate sheet, currency, prepaid runway). Egress and replication live here because they are bill lines, not a separate discipline.

*16 queries · 4 first-audit pick(s) · absorbs: cost, movement, deep (credit_spike_anomaly)*

| # | query_id | tier | rung | source finding | The question | reads |
|--:|---|---|---|---|---|---|
| 01 | `cost_attribution_fingerprint` | deep | AU | `attribution_fingerprint` | Which repeated query shapes carry the most attributed credits, so a fix lands on a pattern rather than one statement? | `snowflake.account_usage.query_attribution_history` |
| 02 | `cost_capacity_runway` | deep | OU | `capacity_runway` | How fast is prepaid capacity draining, and on the current burn rate what date does it run out? | `snowflake.organization_usage.remaining_balance_daily`<br>`snowflake.organization_usage.usage_in_currency_daily` |
| 03 | `cost_chargeback_by_query_tag` ★ | standard | AU | `chargeback_showback + query_tagging` | How do attributed credits split across QUERY_TAG values - and how many credits carry no tag at all, so the untagged denominator is real? | `snowflake.account_usage.query_attribution_history`<br>`snowflake.account_usage.query_history` |
| 04 | `cost_cloud_services_by_query_type` | standard | AU | `cloud_services_query_attribution` | Which statement types (SHOW, metadata, INFORMATION_SCHEMA, COPY) drive the cloud-services line? | `snowflake.account_usage.query_history` |
| 05 | `cost_cloud_services_overage` | standard | AU | `cloud_services_overage` | On which days did cloud-services credits exceed the 10% daily adjustment allowance and become billable? | `snowflake.account_usage.metering_daily_history` |
| 06 | `cost_credit_spike_anomaly` | deep | AU | `credit_spike_anomaly` | Which warehouse-days sit far outside that warehouse's own recent distribution - a spike, not just a big number? | `snowflake.account_usage.warehouse_metering_history` |
| 07 | `cost_credits_by_warehouse_day` ★ | lite | AU | `idle_credit_leak + chargeback_showback` | Which warehouse burned which credits on which day, split compute vs cloud services - the line the bill is actually made of? | `snowflake.account_usage.warehouse_metering_history` |
| 08 | `cost_data_transfer_egress` | standard | AU | `data_transfer_egress + egress_fanout_optimizer` | How many bytes left the account per day, to which cloud and region, and which target is the fan-out worth collapsing? | `snowflake.account_usage.data_transfer_history` |
| 09 | `cost_database_storage_chargeback` | standard | AU | `database_storage_chargeback` | Which database owns which share of storage bytes per day, including its Fail-safe tail, so storage can be charged back? | `snowflake.account_usage.database_storage_usage_history` |
| 10 | `cost_dollarized_usage_by_day` | standard | OU | `effective_rate_sheet` | What did each day's usage cost in real currency, already multiplied out by Snowflake? | `snowflake.organization_usage.usage_in_currency_daily` |
| 11 | `cost_effective_rate_sheet` ★ | standard | OU | `effective_rate_sheet` | What does this account actually pay per credit and per TB, per usage type and day - the contracted effective rate, not a list price? | `snowflake.organization_usage.rate_sheet_daily` |
| 12 | `cost_query_attribution_by_user` ★ | standard | AU | `chargeback_showback + audit_self_cost` | Which user's queries consumed which warehouse credits, so a cost line can be handed to a person instead of a warehouse? | `snowflake.account_usage.query_attribution_history` |
| 13 | `cost_query_tag_coverage_gap` | standard | AU | `chargeback_tag_coverage_gap` | Which warehouses and users run the most credits with an empty QUERY_TAG - i.e. where chargeback will silently fail? | `snowflake.account_usage.query_history`<br>`snowflake.account_usage.warehouse_metering_history` |
| 14 | `cost_replication_spend` | deep | AU | `replication_cost` | What do replication and failover groups cost in credits and bytes per day, per group and per database? | `snowflake.account_usage.replication_group_usage_history`<br>`snowflake.account_usage.database_replication_usage_history` |
| 15 | `cost_resource_monitor_coverage` | standard | AU | `resource_monitors` | Which warehouses burn credits with no resource monitor attached - i.e. which spend has no ceiling at all? | `snowflake.account_usage.resource_monitors`<br>`snowflake.account_usage.warehouse_metering_history` |
| 16 | `cost_warehouse_credits_live_is` | lite | IS | `idle_credit_leak (live rung)` | The same credits-by-warehouse answer TODAY, with no ACCOUNT_USAGE lag and no admin grant - what does the live rung see? | `information_schema.warehouse_metering_history` |

<a id="warehouse"></a>

### `warehouse` — Warehouses: sizing, idle, suspend/resume, multi-cluster

The compute objects an admin actually tunes. Config inventory, idle credit leak, over-sizing against real load, auto-suspend thrash, resume storms, wake analysis, multi-cluster spin-up cost and scaling misconfiguration, adaptive-warehouse candidacy and Query Acceleration sizing.

*13 queries · 1 first-audit pick(s) · absorbs: cost (warehouse-shaped findings), workload (warehouse-event findings), deep (warehouse_wake_analysis)*

| # | query_id | tier | rung | source finding | The question | reads |
|--:|---|---|---|---|---|---|
| 01 | `warehouse_adaptive_candidacy` | deep | AU | `adaptive_candidacy` | Which warehouses have a load profile spiky enough that an adaptive warehouse would beat a fixed size? | `snowflake.account_usage.warehouse_metering_history`<br>`snowflake.account_usage.query_attribution_history`<br>`snowflake.account_usage.warehouse_load_history` |
| 02 | `warehouse_auto_suspend_thrash` | deep | AU | `auto_suspend_thrash` | Which warehouses suspend and resume so often that the 60-second minimum billing on each resume outweighs the idle they saved? | `snowflake.account_usage.warehouse_events_history` |
| 03 | `warehouse_idle_credit_leak` ★ | lite | AU | `idle_credit_leak` | Which warehouses burned credits in hours where no query ran on them - compute paid for nothing? | `snowflake.account_usage.warehouse_metering_history`<br>`snowflake.account_usage.query_history` |
| 04 | `warehouse_inventory_show` | lite | SHOW | `warehouses (engine collector)` | What is every warehouse's current size, auto-suspend, auto-resume, cluster range, scaling policy and resource monitor - live? | `SHOW WAREHOUSES`<br>`result_scan(last_query_id())` |
| 05 | `warehouse_load_live_is` | lite | IS | `oversized_warehouse (live rung)` | What is the running / queued load on each warehouse right now, without waiting for the ACCOUNT_USAGE lag? | `information_schema.warehouse_load_history` |
| 06 | `warehouse_low_load_hours` | standard | AU | `warehouse_oversized_low_load` | For each warehouse, what share of its billed hours had near-zero average running load? | `snowflake.account_usage.warehouse_load_history`<br>`snowflake.account_usage.warehouse_metering_history` |
| 07 | `warehouse_multicluster_scale_out_need` | standard | AU | `multi_cluster_scale_out` | Which single-cluster warehouses queue enough concurrent work that scaling OUT, not UP, is the fix? | `snowflake.account_usage.query_history` |
| 08 | `warehouse_multicluster_scaling_misconfig` | standard | SHOW | `multicluster_scaling_misconfig` | Which multi-cluster warehouses are configured in a way that cannot behave as intended (MIN=MAX, ECONOMY on a latency workload, MIN>1 always-on)? | `SHOW WAREHOUSES`<br>`result_scan(last_query_id())` |
| 09 | `warehouse_multicluster_spinup_cost` | deep | AU | `multicluster_spinup_cost` | How many credits go to spinning additional clusters up and down rather than to running queries? | `snowflake.account_usage.warehouse_events_history`<br>`snowflake.account_usage.warehouse_metering_history` |
| 10 | `warehouse_oversized_by_load` | standard | AU | `oversized_warehouse` | Which warehouses ran at a fraction of one cluster's capacity for most of the window - the size-down candidates? | `snowflake.account_usage.warehouse_load_history` |
| 11 | `warehouse_qas_sizing` | deep | AU | `qas_sizing` | Which queries are eligible for Query Acceleration, how much of their time it could remove, and what scale factor that implies? | `snowflake.account_usage.query_acceleration_eligible`<br>`snowflake.account_usage.query_acceleration_history` |
| 12 | `warehouse_resume_storm_waste` | deep | AU | `resume_storm_waste + warehouse_event_resume_audit` | Which warehouses show bursts of resumes clustered in minutes - a storm, not a workload? | `snowflake.account_usage.warehouse_events_history` |
| 13 | `warehouse_wake_analysis` | deep | AU | `warehouse_wake_analysis` | What actually wakes each warehouse - a scheduled task, a BI tool, a human - and how long does it stay awake after? | `snowflake.account_usage.warehouse_events_history`<br>`snowflake.account_usage.query_history` |

<a id="performance"></a>

### `performance` — Query performance & workload

What the queries themselves are doing: spilling, queuing, failures, workload shape, repeated query fingerprints, Snowflake's own Query Insights verdicts, pruning effectiveness at partition and row level, and a single-query operator probe.

*14 queries · 1 first-audit pick(s) · absorbs: workload, cost (pruning / clustering findings), deep (bytes_scanned_divergence)*

| # | query_id | tier | rung | source finding | The question | reads |
|--:|---|---|---|---|---|---|
| 01 | `perf_access_history_summary` | standard | AU | `access_history_summary` | Which tables and columns does the workload actually read and write, and which are read by nobody? | `snowflake.account_usage.access_history` |
| 02 | `perf_bytes_scanned_divergence` | deep | AU | `bytes_scanned_divergence` | Where does a query's reported bytes-scanned diverge from the bytes its tables say were read - a number not to trust? | `snowflake.account_usage.query_history`<br>`snowflake.account_usage.table_query_pruning_history` |
| 03 | `perf_clustering_recommendations` | standard | AU | `clustering_recommendations` | Which badly-pruned tables are large and hot enough that a clustering key would pay for itself? | `snowflake.account_usage.table_query_pruning_history`<br>`snowflake.account_usage.table_storage_metrics` |
| 04 | `perf_failed_queries` | lite | AU | `failed_queries` | What is failing, with which error, how often, and how many credits do the failures burn before they fail? | `snowflake.account_usage.query_history` |
| 05 | `perf_operator_stats_probe` | deep | IS | `operator_findings` | For ONE query id you already found, which operator burned the time and which one spilled - the plan-level answer no view carries? | `get_query_operator_stats()` |
| 06 | `perf_query_history_live_is` | lite | IS | `spillage / failed_queries (live rung)` | What has the account run in the last few hours - live, no admin grant - when ACCOUNT_USAGE has not caught up yet? | `information_schema.query_history` |
| 07 | `perf_query_insights` | deep | AU | `query_insights` | What does Snowflake's own Query Insights say is wrong with these queries - the vendor's verdict, not ours? | `snowflake.account_usage.query_insights` |
| 08 | `perf_queuing_overload` | standard | AU | `query_queuing_overload` | Where is time going to queue-overload rather than execution, and on which warehouse and hour? | `snowflake.account_usage.query_history` |
| 09 | `perf_repeated_query_shapes` | deep | AU | `repeated_query_shapes` | Which query fingerprints repeat most, and what do they cost in aggregate - where one fix pays many times? | `snowflake.account_usage.aggregate_query_history` |
| 10 | `perf_row_pruning_gap` | deep | AU | `row_pruning_gap` | At row level, how much of what was read was actually returned - the pruning gap a partition ratio hides? | `snowflake.account_usage.table_pruning_history` |
| 11 | `perf_runaway_query_guardrail` | lite | SHOW | `runaway_query_guardrail` | Is STATEMENT_TIMEOUT_IN_SECONDS (and its queued twin) actually set at account level, or is the default the only guardrail? | `SHOW PARAMETERS IN ACCOUNT`<br>`result_scan(last_query_id())` |
| 12 | `perf_spilling_queries` ★ | standard | AU | `spillage` | Which queries spilled to local and remote storage - the signal that the warehouse is too small for the working set? | `snowflake.account_usage.query_history` |
| 13 | `perf_table_pruning_gap` | standard | AU | `pruning_issues + catalog_pruning_comparison` | Which tables are scanned with the worst partition-pruning ratio - full scans dressed up as filtered queries? | `snowflake.account_usage.table_query_pruning_history` |
| 14 | `perf_workload_hours` | lite | AU | `workload_hours + query_classification` | What shape is the workload - by hour of day, statement type and warehouse - so a change lands in the right window? | `snowflake.account_usage.query_history` |

<a id="storage"></a>

### `storage` — Storage, time travel & table optimization

What is stored, what it costs, and which optimization feature is paying for itself: table storage metrics, Time Travel and Fail-safe bloat, stage leaks, account storage trend, automatic clustering, Search Optimization, Iceberg, DML churn and a drop-safety gate before anyone deletes anything.

*13 queries · 1 first-audit pick(s) · absorbs: storage, cost (clustering findings), unsectioned (account_storage_trend, stage_storage_leak, drop_safety_gate)*

| # | query_id | tier | rung | source finding | The question | reads |
|--:|---|---|---|---|---|---|
| 01 | `storage_account_trend` | lite | AU | `account_storage_trend` | How has total account storage moved day by day - is the bill growing because of data or because of retention? | `snowflake.account_usage.storage_usage` |
| 02 | `storage_auto_clustering_spend` | standard | AU | `auto_clustering` | Which tables spend the most credits on Automatic Clustering, and how much churn is it reclustering? | `snowflake.account_usage.automatic_clustering_history` |
| 03 | `storage_clustering_benefit_review` | deep | AU | `clustering_review` | For each clustered table, did the pruning actually improve enough to justify the clustering credits? | `snowflake.account_usage.automatic_clustering_history`<br>`snowflake.account_usage.table_query_pruning_history` |
| 04 | `storage_drop_safety_gate` | deep | AU | `drop_safety_gate` | Before dropping a table: what depends on it, who read it last, and how many bytes would go into Fail-safe? | `snowflake.account_usage.object_dependencies`<br>`snowflake.account_usage.table_storage_metrics`<br>`snowflake.account_usage.access_history` |
| 05 | `storage_iceberg_inventory` | standard | AU | `iceberg_inventory` | Which Iceberg tables exist, which catalog are they managed by, and what do their optimization jobs cost? | `snowflake.account_usage.tables`<br>`snowflake.account_usage.iceberg_storage_optimization_history` |
| 06 | `storage_materialized_view_refresh_spend` | standard | AU | `serverless_feature_no_benefit` | What do materialized views cost to keep refreshed, and which of them is queried too rarely to be worth it? | `snowflake.account_usage.materialized_view_refresh_history`<br>`snowflake.account_usage.access_history` |
| 07 | `storage_metrics_live_is` | lite | IS | `storage_breakdown (live rung)` | What do this database's tables occupy right now - active, Time Travel and Fail-safe - without an admin grant? | `information_schema.table_storage_metrics` |
| 08 | `storage_search_optimization_active` | standard | SHOW | `search_optimization_active` | Which tables currently have Search Optimization switched on, and on which columns? | `SHOW TABLES IN ACCOUNT`<br>`result_scan(last_query_id())` |
| 09 | `storage_search_optimization_benefit` | deep | AU | `search_optimization_candidates` | Where Search Optimization is on, what benefit did Snowflake measure - and where is it earning nothing? | `snowflake.account_usage.search_optimization_benefits`<br>`snowflake.account_usage.search_optimization_history` |
| 10 | `storage_stage_leak` | standard | AU | `stage_storage_leak` | How many bytes sit in internal stages that no load has consumed - the storage line nobody owns? | `snowflake.account_usage.stage_storage_usage_history` |
| 11 | `storage_table_breakdown` | lite | AU | `storage_breakdown` | Account-wide, which tables hold the bytes, split active vs Time Travel vs Fail-safe vs retained-for-clone? | `snowflake.account_usage.table_storage_metrics` |
| 12 | `storage_table_dml_churn` | deep | AU | `time_travel_bloat` | Which tables are rewritten most - the churn that turns a small table into a large Time Travel bill? | `snowflake.account_usage.table_dml_history` |
| 13 | `storage_time_travel_bloat` ★ | standard | AU | `time_travel_bloat` | Which tables carry more Time Travel and Fail-safe bytes than live data - retention paid for on churn nobody restores? | `snowflake.account_usage.table_storage_metrics` |

<a id="serverless_ai"></a>

### `serverless_ai` — Serverless, tasks, pipes, dynamic tables & Cortex

Everything Snowflake runs without a warehouse you sized - and therefore everything a resource monitor does not guard. Serverless credit exposure, tasks and task graphs, alerts, Snowpipe (batch and streaming), bulk load reliability, dynamic tables, container services, and the whole Cortex / AI spend surface.

*17 queries · 1 first-audit pick(s) · absorbs: serverless, unsectioned (cortex_*, document_ai_spend, alert_reliability, bulk_load_reliability, snowpipe_streaming_migration)*

| # | query_id | tier | rung | source finding | The question | reads |
|--:|---|---|---|---|---|---|
| 01 | `ai_cortex_agent_usage` | standard | AU | `cortex_agent_usage` | Which Cortex Agents are being used, by whom, and at what token and credit cost? | `snowflake.account_usage.cortex_agent_usage_history` |
| 02 | `ai_cortex_analyst_spend` | standard | AU | `cortex_analyst_spend` | What does Cortex Analyst cost per day, and how concentrated are its requests in a few users? | `snowflake.account_usage.cortex_analyst_usage_history` |
| 03 | `ai_cortex_cost_guardrail` | standard | AU | `cortex_cost_guardrail` | Account-wide, what share of the daily bill is now AI spend, and is it trending past the ceiling anyone agreed to? | `snowflake.account_usage.metering_daily_history` |
| 04 | `ai_cortex_fine_tuning_spend` | deep | AU | `cortex_fine_tuning_spend` | What has fine-tuning cost per base model and job, and did any run repeatedly on the same data? | `snowflake.account_usage.cortex_fine_tuning_usage_history` |
| 05 | `ai_cortex_function_spend` | standard | AU | `cortex_ai_function_spend` | Which Cortex AI functions and models consume the most credits and tokens? | `snowflake.account_usage.cortex_functions_usage_history` |
| 06 | `ai_cortex_search_spend` | standard | AU | `cortex_search_spend` | What do Cortex Search services cost to serve and refresh, and which one serves almost no queries for that money? | `snowflake.account_usage.cortex_search_daily_usage_history`<br>`snowflake.account_usage.cortex_search_serving_usage_history` |
| 07 | `ai_document_processing_spend` | standard | AU | `document_ai_spend` | What does document processing (Document AI / AI_EXTRACT) cost per day and per document type? | `snowflake.account_usage.cortex_document_processing_usage_history` |
| 08 | `serverless_alert_reliability` | standard | AU | `alert_reliability` | Are the alerts that are supposed to catch problems actually firing and succeeding - or silently erroring? | `snowflake.account_usage.alert_history`<br>`snowflake.account_usage.serverless_alert_history` |
| 09 | `serverless_bulk_load_reliability` | standard | AU | `bulk_load_reliability` | Which COPY loads partially fail or get retried, and how many rows are quietly being dropped? | `snowflake.account_usage.copy_history` |
| 10 | `serverless_credit_exposure` ★ | standard | AU | `serverless_credit_exposure + serverless_credit_breakdown` | How many credits per day are serverless - i.e. spent by features no warehouse size and no resource monitor governs - and by which service? | `snowflake.account_usage.metering_history` |
| 11 | `serverless_dynamic_table_refresh` | standard | AU | `serverless_feature_no_benefit` | Which dynamic tables refresh most expensively, and which keep refreshing on data that has not changed? | `snowflake.account_usage.dynamic_table_refresh_history` |
| 12 | `serverless_not_monitor_guarded` | standard | AU | `serverless_not_monitor_guarded` | Which serverless services are burning credits that no resource monitor could ever have capped? | `snowflake.account_usage.metering_history`<br>`snowflake.account_usage.resource_monitors` |
| 13 | `serverless_orphaned_services` | standard | SHOW | `orphaned_notebook_service` | Which Snowpark Container / notebook services are still running with nothing attached to them? | `SHOW SERVICES IN ACCOUNT`<br>`result_scan(last_query_id())` |
| 14 | `serverless_snowpipe_small_files` | standard | AU | `snowpipe_small_file_overhead` | Which pipes pay the per-file overhead on tiny files - credits per GB far above what batching would cost? | `snowflake.account_usage.pipe_usage_history`<br>`snowflake.account_usage.copy_history` |
| 15 | `serverless_snowpipe_streaming_migration` | deep | AU | `snowpipe_streaming_migration` | How is the Snowpipe Streaming file-migration backlog behaving, and is any channel falling behind? | `snowflake.account_usage.snowpipe_streaming_file_migration_history`<br>`snowflake.account_usage.snowpipe_streaming_client_history` |
| 16 | `serverless_task_cost_and_upsizing` | standard | AU | `serverless_task_cost_and_upsizing` | Which serverless tasks cost the most credits, which failed, and which ones Snowflake keeps sizing up run after run? | `snowflake.account_usage.serverless_task_history`<br>`snowflake.account_usage.task_history` |
| 17 | `serverless_task_history_live_is` | lite | IS | `serverless_task_cost_and_upsizing (live rung)` | What have serverless tasks done in the last few days, live, from the current database? | `information_schema.serverless_task_history` |

<a id="governance_access"></a>

### `governance_access` — Grants, roles, policies, tags & sharing exposure

Who can reach what, and what the data itself is labelled as. The transitive grant graph on all three rungs (SHOW, the procedure, ACCOUNT_USAGE), stale roles, masking and row-access policy coverage, sensitive-data tags, classification coverage, data-quality rule results, and outbound share exposure.

*13 queries · 1 first-audit pick(s) · absorbs: datagov, unsectioned (stale_roles, applied_sensitive_tags, classification_coverage, object_tag_coverage, data_quality_rule_results)*

| # | query_id | tier | rung | source finding | The question | reads |
|--:|---|---|---|---|---|---|
| 01 | `access_grants_on_object_show` | lite | SHOW | `who_can_read_object (rung 1)` | Which roles hold a read-conferring grant DIRECTLY on this object - the one-hop answer, live, with only SHOW? | `SHOW GRANTS ON TABLE`<br>`result_scan(last_query_id())` |
| 02 | `access_object_privileges_is` | lite | IS | `who_can_read_object (rung 1, view form)` | What privileges exist on this object according to INFORMATION_SCHEMA - and why is that a different question from who can read it? | `information_schema.object_privileges` |
| 03 | `access_share_exposure` | standard | AU | `datagov (outbound sharing)` | What leaves this account through shares and listings - which objects, to which consumer accounts? | `snowflake.account_usage.grants_to_shares`<br>`snowflake.account_usage.shares` |
| 04 | `access_stale_roles` | standard | AU | `stale_roles` | Which roles hold grants but are held by nobody, or by users who have not logged in - access that exists for no one? | `snowflake.account_usage.grants_to_roles`<br>`snowflake.account_usage.grants_to_users`<br>`snowflake.account_usage.roles`<br>`snowflake.account_usage.login_history` |
| 05 | `access_who_can_read_object_au` ★ | standard | AU | `who_can_read_object (rung 3) [SHIPPED]` | The same transitive closure resolved all the way to users - and the only rung that answers who USED to have access. | `snowflake.account_usage.grants_to_roles`<br>`snowflake.account_usage.grants_to_users` |
| 06 | `access_who_can_read_object_proc` | standard | PROC | `who_can_read_object (rung 2) [SHIPPED]` | Given an object, every role and user who can read it transitively - LIVE, needing only SHOW, with unreadable branches marked rather than hidden. | `SHOW GRANTS ON OBJECT`<br>`SHOW GRANTS OF ROLE`<br>`SHOW GRANTS OF DATABASE ROLE`<br>`result_scan(last_query_id())` |
| 07 | `gov_applied_sensitive_tags` | standard | AU | `applied_sensitive_tags` | Which columns carry a SEMANTIC_CATEGORY or PRIVACY_CATEGORY tag - i.e. which data is declared sensitive? | `snowflake.account_usage.tag_references`<br>`snowflake.account_usage.tags` |
| 08 | `gov_classification_coverage` | deep | AU | `classification_coverage` | How much of the estate has ever been classified, and how stale is the newest classification? | `snowflake.account_usage.data_classification_latest`<br>`snowflake.account_usage.tables` |
| 09 | `gov_data_quality_rule_results` | deep | AU | `data_quality_rule_results` | Which Data Metric Function rules are currently breaching, on which tables, and what does running them cost? | `snowflake.account_usage.data_metric_function_references`<br>`snowflake.account_usage.data_quality_monitoring_usage_history` |
| 10 | `gov_masking_policy_coverage` | standard | AU | `governance_masking` | Which masking policies exist, what are they attached to, and which sensitive columns have none? | `snowflake.account_usage.masking_policies`<br>`snowflake.account_usage.policy_references` |
| 11 | `gov_object_tag_coverage` | standard | AU | `object_tag_coverage` | Which databases, schemas and warehouses carry a cost-allocation tag, and which do not - the gap that breaks chargeback? | `snowflake.account_usage.tag_references`<br>`snowflake.account_usage.tags` |
| 12 | `gov_policy_reference_coverage` | standard | AU | `governance_coverage` | Across every policy kind, what fraction of the objects that should carry one actually do? | `snowflake.account_usage.policy_references`<br>`snowflake.account_usage.tables` |
| 13 | `gov_row_access_policy_coverage` | deep | AU | `governance_row_access` | Which row-access policies exist and which tables that hold per-tenant data are not covered by one? | `snowflake.account_usage.row_access_policies`<br>`snowflake.account_usage.policy_references` |

<a id="security"></a>

### `security` — Identity, authentication, network & account posture

The posture questions an auditor asks first: MFA coverage, how people actually log in, network policies, session and password policy, key/credential rotation, service-account auth readiness, how much work runs as ACCOUNTADMIN, account parameters, integrations, Trust Center findings and failover posture.

*14 queries · 1 first-audit pick(s) · absorbs: security, unsectioned (password_policy_strength, session_auth_posture, session_timeout_policy, idle_open_sessions, trust_center_findings_summary, failover_posture)*

| # | query_id | tier | rung | source finding | The question | reads |
|--:|---|---|---|---|---|---|
| 01 | `sec_account_parameters` | lite | SHOW | `account_parameters` | Which account-level parameters differ from the Snowflake default, and which of those weaken a security posture? | `SHOW PARAMETERS IN ACCOUNT`<br>`result_scan(last_query_id())` |
| 02 | `sec_accountadmin_workload` | lite | AU | `accountadmin_workload` | How much real work runs as ACCOUNTADMIN or SECURITYADMIN, and by whom - privilege used as a default rather than an exception? | `snowflake.account_usage.query_history` |
| 03 | `sec_credential_rotation_hygiene` | standard | AU | `credential_rotation_hygiene` | Which stored secrets and key-pair credentials have not been rotated, and how old are the oldest? | `snowflake.account_usage.credentials`<br>`snowflake.account_usage.users` |
| 04 | `sec_failover_posture` | standard | SHOW | `failover_posture` | Do failover groups exist, what do they cover, and when did each last refresh - is the DR story real? | `SHOW FAILOVER GROUPS`<br>`result_scan(last_query_id())` |
| 05 | `sec_integrations` | lite | SHOW | `integrations` | What external integrations exist (security, storage, notification, API), which are disabled, and who owns them? | `SHOW INTEGRATIONS`<br>`result_scan(last_query_id())` |
| 06 | `sec_login_breakdown` | lite | AU | `login_breakdown + login_concentration` | How do people actually authenticate (password, SSO, key pair, OAuth), how often does it fail, and from where? | `snowflake.account_usage.login_history` |
| 07 | `sec_mfa_coverage` ★ | lite | AU | `mfa_coverage` | Which human users can log in without MFA - and of those, which ones actually did in the window? | `snowflake.account_usage.users`<br>`snowflake.account_usage.login_history` |
| 08 | `sec_network_policies` | lite | SHOW | `network_policies` | Is there a network policy at account level at all, and what does it actually allow? | `SHOW NETWORK POLICIES`<br>`result_scan(last_query_id())` |
| 09 | `sec_network_policy_references` | standard | AU | `network_policies` | Which users and integrations have a network policy attached, and which network rules do those policies point at? | `snowflake.account_usage.network_policies`<br>`snowflake.account_usage.network_rule_references`<br>`snowflake.account_usage.network_rules` |
| 10 | `sec_password_policy_strength` | lite | AU | `password_policy_strength` | What do the password policies on this account actually require, and where is none attached? | `snowflake.account_usage.password_policies`<br>`snowflake.account_usage.policy_references` |
| 11 | `sec_service_account_auth_readiness` | standard | AU | `service_account_auth_readiness` | Which service accounts still authenticate by password rather than key pair or OAuth - the deprecation that will break them? | `snowflake.account_usage.users` |
| 12 | `sec_session_auth_posture` | standard | AU | `session_auth_posture + idle_open_sessions` | How did live sessions authenticate, which clients opened them, and which have sat idle for hours? | `snowflake.account_usage.sessions` |
| 13 | `sec_session_timeout_policy` | standard | AU | `session_timeout_policy` | Is a session policy attached anywhere, or is the four-hour default idle timeout the only limit in force? | `snowflake.account_usage.session_policies`<br>`snowflake.account_usage.policy_references` |
| 14 | `sec_trust_center_findings` | standard | AU | `trust_center_findings_summary` | What does Snowflake's own Trust Center currently flag as open, by severity and scanner package? | `snowflake.account_usage.trust_center_findings` |

---

## The ten first-audit picks (★)

Balanced the way the Databricks first-audit is: **validate the bill first**, then see where the money goes, then the top posture risks — so you trust the numbers before you act on them.

| Order | query_id | domain | rung | Why it is first |
|--:|---|---|---|---|
| 1 | `cost_credits_by_warehouse_day` | `cost` | AU | the bill, by the object that produced it |
| 2 | `cost_effective_rate_sheet` | `cost` | OU | turns credits into money at YOUR contracted rate, not a list price |
| 3 | `cost_query_attribution_by_user` | `cost` | AU | hands a cost line to a person instead of a warehouse |
| 4 | `cost_chargeback_by_query_tag` | `cost` | AU | and tells you what fraction of the bill nobody can attribute at all |
| 5 | `warehouse_idle_credit_leak` | `warehouse` | AU | the single most common Snowflake waste: paying for a warehouse nobody queried |
| 6 | `serverless_credit_exposure` | `serverless_ai` | AU | the spend no warehouse size and no resource monitor governs |
| 7 | `perf_spilling_queries` | `performance` | AU | the clearest under-sizing signal there is |
| 8 | `storage_time_travel_bloat` | `storage` | AU | retention paid for on churn nobody restores |
| 9 | `sec_mfa_coverage` | `security` | AU | the first question every auditor asks |
| 10 | `access_who_can_read_object_au` | `governance_access` | AU | who can actually read the table you care about - transitively |

---

## Provenance

Every query above traces to a finding in the internal audit engine (its `source` column). The seven
marked `(live rung)` or `(rung 1)` trace to a finding too — they are the low-privilege twin of the
ACCOUNT_USAGE query beside them, and they are the ladder's whole argument.

All **92** findings in the engine (60 sectioned across `cost · security · datagov · workload ·
storage · serverless · movement · deep`, plus 32 unsectioned) map onto at least one query here. A
handful of queries carry two source findings because the engine split one question across a
collection stem and a diagnostic; the flattened library form answers both.

What crossed over: **the question, and the shape of the SQL.** What did not, and never will: any
number, any client name, any warehouse / database / role / user identifier, any threshold tuned to
one account's data. Thresholds here are labelled field heuristics exposed as `:params`.

## Doc verification

Views and columns were checked against these pages (cached during cataloguing):

- `SNOWFLAKE.ACCOUNT_USAGE` view index — <https://docs.snowflake.com/en/sql-reference/account-usage>
- `SNOWFLAKE.ORGANIZATION_USAGE` view index — <https://docs.snowflake.com/en/sql-reference/organization-usage>
- `INFORMATION_SCHEMA` views + table functions — <https://docs.snowflake.com/en/sql-reference/info-schema>
- `GET_QUERY_OPERATOR_STATS` — <https://docs.snowflake.com/en/sql-reference/functions/get_query_operator_stats>

Two notes for whoever writes the SQL:

- `ACCOUNT_USAGE.COLUMN_QUERY_PRUNING_HISTORY` appears in the internal engine but is **not** in the
  documented ACCOUNT_USAGE view list. This catalogue routes every pruning question through
  `TABLE_QUERY_PRUNING_HISTORY` and `TABLE_PRUNING_HISTORY`, which are documented. If you need the
  column-level view, verify it first and mark the query `unverified` if you cannot.
- `GET_QUERY_OPERATOR_STATS()` takes **one** query id. `perf_operator_stats_probe` is therefore a
  probe you point at an id you already found upstream, not an account-wide sweep — its `read_this`
  must say so.
