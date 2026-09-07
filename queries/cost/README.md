# `cost` — Credits, spend & chargeback

Where the credits go, and whether the number can be trusted. Warehouse and serverless credits per
day, per-query attribution, chargeback by `QUERY_TAG`, cloud-services overage, spend anomalies — and
the only rung that turns credits into money (`ORGANIZATION_USAGE` rate sheet, currency, prepaid
runway). Egress and replication live here because they are bill lines, not a separate discipline.

📖 **Full interactive docs → [every query, explained](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost)** — why it matters, what it does, how to read every output column, and the caveats.

**16 queries · 4 first-audit picks (★) · absorbs the engine's `cost`, `movement` and `deep` (credit spike) findings.**

## The ladder in this domain

Every query declares the rung it stands on, because the rung changes what the answer *means*:

| Rung | Queries | What you gain — and give up |
|---|--:|---|
| `information_schema` | 1 | **LIVE**, needs only `MONITOR USAGE`, no `IMPORTED PRIVILEGES` — but 6 months, no attribution column, no Adaptive Warehouses. |
| `account_usage` | 12 | Whole account, 1 year of history, per-query credits — at the price of `IMPORTED PRIVILEGES` and a 45-minute-to-8-hour lag. |
| `organization_usage` | 3 | The **only** rung that knows a currency, a contracted rate, or a remaining balance — at the price of an org role and a 24–72 hour lag. |

`cost_warehouse_credits_live_is` and `cost_credits_by_warehouse_day` are the same question on two
rungs, deliberately. The live one restates the bill with no lag; only the `ACCOUNT_USAGE` one can
separate the credits a query consumed from the credits idle time consumed.

## Queries

| # | Query | Tier | Rung | What it answers |
|--:|---|---|---|---|
| 01 | [`cost_credits_by_warehouse_day`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_credits_by_warehouse_day) ★ | lite | AU | Which warehouse burned which credits on which day, split compute vs cloud services — plus the share of compute that no query claimed, which is idle you paid for. |
| 02 | [`cost_effective_rate_sheet`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_effective_rate_sheet) ★ | standard | OU | What this account actually pays per credit and per TB after contract discounts — the contracted effective rate, not a list price — and whether it moved under you. |
| 03 | [`cost_query_attribution_by_user`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_query_attribution_by_user) ★ | standard | AU | Which user's queries consumed which warehouse credits, so a cost line can be handed to a person instead of a warehouse. |
| 04 | [`cost_chargeback_by_query_tag`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_chargeback_by_query_tag) ★ | standard | AU | How attributed credits split across `QUERY_TAG` values — and how many credits carry no tag at all, so the untagged denominator is real. |
| 05 | [`cost_attribution_fingerprint`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_attribution_fingerprint) | deep | AU | Which repeated query *shapes* carry the most attributed credits, so a fix lands on a pattern rather than on one statement. |
| 06 | [`cost_capacity_runway`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_capacity_runway) | deep | OU | How fast prepaid capacity is draining — measured two independent ways — and the date it runs out at the current burn. |
| 07 | [`cost_cloud_services_by_query_type`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_cloud_services_by_query_type) | standard | AU | Which statement types (`SHOW`, metadata, `INFORMATION_SCHEMA`, `COPY`) drive the cloud-services line, and which of them ran with no warehouse at all. |
| 08 | [`cost_cloud_services_overage`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_cloud_services_overage) | standard | AU | On which days cloud-services credits exceeded the 10% daily adjustment allowance and actually became billable. |
| 09 | [`cost_credit_spike_anomaly`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_credit_spike_anomaly) | deep | AU | Which warehouse-days sit far outside that warehouse's *own* recent distribution — a spike, not merely a big number. |
| 10 | [`cost_data_transfer_egress`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_data_transfer_egress) | standard | AU | How many bytes left the account per day, to which cloud and region, and which source's fan-out is worth collapsing. |
| 11 | [`cost_database_storage_chargeback`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_database_storage_chargeback) | standard | AU | Which database owns which share of storage bytes per day, including its Fail-safe tail, so storage can be charged back. |
| 12 | [`cost_dollarized_usage_by_day`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_dollarized_usage_by_day) | standard | OU | What each day's usage cost in real currency, already multiplied out by Snowflake — and which day broke from the median. |
| 13 | [`cost_query_tag_coverage_gap`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_query_tag_coverage_gap) | standard | AU | Which warehouses and users run the most credits with an empty `QUERY_TAG` — i.e. where chargeback will silently fail. |
| 14 | [`cost_replication_spend`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_replication_spend) | deep | AU | What replication and failover groups cost in credits and bytes per day, per group and per database — and where credits go into overhead rather than data. |
| 15 | [`cost_resource_monitor_coverage`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_resource_monitor_coverage) | standard | AU | Which warehouses burn credits with no resource monitor attached — i.e. which spend has no ceiling at all, weighted by what it actually spent. |
| 16 | [`cost_warehouse_credits_live_is`](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost#q-cost_warehouse_credits_live_is) | lite | IS | The same credits-by-warehouse answer **today**, with no `ACCOUNT_USAGE` lag and no `IMPORTED PRIVILEGES` — what the live rung can and cannot see. |

<sub>★ = first-audit pick. AU = `SNOWFLAKE.ACCOUNT_USAGE` · OU = `SNOWFLAKE.ORGANIZATION_USAGE` · IS = `INFORMATION_SCHEMA`. This is a one-line index — the full write-up (output columns, bands, caveats) lives in the [interactive docs](https://learn.crosshire.ch/learn/tech/snowflake/audit/cost). The `.sql` files in this folder are the source of truth.</sub>

## Reading order

Validate the bill before you act on it:

1. **`cost_credits_by_warehouse_day`** — the bill, by the object that produced it.
2. **`cost_effective_rate_sheet`** — turn those credits into money at *your* contracted rate.
3. **`cost_query_attribution_by_user`** — hand a cost line to a person.
4. **`cost_chargeback_by_query_tag`** — and learn what fraction of the bill nobody can attribute at all.

Then follow the `next:` links in each header; every query names the queries it hands off to and the
condition under which it does.

## What these queries will not tell you

- **They are not run against a live account.** Every view and column is verified against
  `docs.snowflake.com`, and each file claims `confidence: confirmed-docs` — never the bare word
  `confirmed`, which is reserved for a live run.
- **Credits are not money** on any `ACCOUNT_USAGE` query here. Only the three `organization_usage`
  queries know a currency.
- **Gross is not billed.** Per-query and per-warehouse cloud-services credits are pre-adjustment;
  `cost_cloud_services_overage` holds the only post-allowance number in the domain.
- **Serverless spend is not here.** Tasks, pipes, dynamic tables and Cortex burn credits no
  warehouse size and no resource monitor governs — that is the [`serverless_ai`](../serverless_ai/)
  domain.
- **Idle is not attribution.** `QUERY_ATTRIBUTION_HISTORY` excludes warehouse idle time by design,
  so it will always sum to less than `WAREHOUSE_METERING_HISTORY`. The gap is the finding, not an error.
- **Thresholds are field heuristics**, exposed as `:params` with documented defaults. None is tuned
  to any account's data.
