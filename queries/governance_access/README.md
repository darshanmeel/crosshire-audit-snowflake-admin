# Grants, Roles, Policies, Tags & Sharing Exposure

Who can reach what, and what the data itself is labelled as. The transitive grant graph on all
three rungs — `SHOW`, an installed procedure, and `ACCOUNT_USAGE` — plus roles that hold access for
nobody, masking and row-access policy coverage, the sensitivity tags and classifications that are
supposed to be the denominator of all of it, the cost-allocation tags chargeback depends on, the
data-quality rules that are supposed to be running, and everything that leaves the account through
a share or a listing.

📖 **Full interactive docs → [every query, explained](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access)** — why it matters, which rung it stands on, how to read every output column, and the caveats.

| # | Query | Tier | Rung | What it does |
|--:|---|---|---|---|
| 01 | [`access_grants_on_object_show`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-access_grants_on_object_show) | lite | SHOW | The one-hop answer, live, with nothing but `SHOW`: which roles hold a read-conferring grant written directly on this object. Flags a privilege granted straight to a **USER**, and a grant option held by a non-owner. A role in the result is not yet an answer — it is the question the next two queries take. |
| 02 | [`access_object_privileges_is`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-access_object_privileges_is) | lite | IS | The same one-hop answer as a **joinable view** rather than a `SHOW` result, live and with no admin grant. Also the clearest demonstration of the ladder: `INFORMATION_SCHEMA` has no role-hierarchy view, so it can say what privileges exist and can never say who can read. |
| 03 | [`access_share_exposure`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-access_share_exposure) | standard | AU | One row per share this account owns: the consumer accounts it is aimed at, the objects granted into it, and how much of that was added inside the window. `CRITICAL` when a share is aimed outbound with `SECURE_OBJECTS_ONLY` off. Inbound shares appear too, and the owner column is how you tell them apart. |
| 04 | [`access_stale_roles`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-access_stale_roles) | standard | AU | Roles that carry privileges and are held by nobody — no user, no parent role — and roles whose only holders have not logged in inside `:period_days`. Holding is not using, and the query says so rather than pretending otherwise. |
| 05 | [`access_who_can_read_object_au`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-access_who_can_read_object_au) ★ | standard | AU | **First-audit pick.** The full transitive closure resolved all the way to **users**, and the only rung that answers who *used to* have access. Ships two forms: seed-on-object, and build-the-role-graph-once for auditing many objects. |
| 06 | [`access_who_can_read_object_proc`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-access_who_can_read_object_proc) | standard | PROC | The same closure **live**, needing only `SHOW` and one `CREATE PROCEDURE` — no `IMPORTED PRIVILEGES` and no lag. Branches the caller cannot see are *marked* rather than silently dropped, which is the whole reason this rung exists. |
| 07 | [`gov_applied_sensitive_tags`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-gov_applied_sensitive_tags) | standard | AU | Inventory. Every applied `SEMANTIC_CATEGORY` / `PRIVACY_CATEGORY` (and account-defined) sensitivity tag, with `APPLY_METHOD` so a machine decision is never mistaken for a human one. The denominator the masking and classification queries join back to — and it cannot see a single *untagged* column, which is stated rather than hidden. |
| 08 | [`gov_classification_coverage`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-gov_classification_coverage) | deep | AU | The one coverage query in this domain with a **real denominator**: every base and external table, against the latest classification result. `CRITICAL` for never-classified; `WARN` for a last attempt that *failed*, which retries silently forever. |
| 09 | [`gov_data_quality_rule_results`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-gov_data_quality_rule_results) | deep | AU | Which Data Metric Function rules are **armed**, which are silently `SUSPENDED`, which are scheduled but have not billed a single interval, and what monitoring costs per table. `ACCOUNT_USAGE` carries no pass/fail — the breach verdict lives in an event table, and the query says where instead of guessing. |
| 10 | [`gov_masking_policy_coverage`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-gov_masking_policy_coverage) | standard | AU | Every live masking policy against what it is actually attached to. `CRITICAL` for a policy past its grace window with no attachment — a control that exists on paper and is routinely counted as coverage. `WARN` for an attachment whose `POLICY_STATUS` is not `ACTIVE`: present, and not applied. |
| 11 | [`gov_object_tag_coverage`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-gov_object_tag_coverage) | standard | AU | Databases, schemas and warehouses that carry tags but **not** the cost-allocation tag, plus cost tags with a blank value or one outside the tag's own `ALLOWED_VALUES`. Its universe is the tagged estate only — an object with no tags at all is invisible here, and that is the larger gap. |
| 12 | [`gov_policy_reference_coverage`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-gov_policy_reference_coverage) | standard | AU | Coverage per policy kind plus an `ANY_POLICY` rollup, against the whole object estate. Run it first when you do not yet know which policy families this account uses — it groups by whatever `POLICY_KIND` actually contains rather than testing assumed literals. |
| 13 | [`gov_row_access_policy_coverage`](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access#q-gov_row_access_policy_coverage) | deep | AU | Two findings in one: row-access policies attached to nothing, and tables somebody already declared sensitive with **column masking** but left with no row filter at all. Masking hides values in rows the reader should never have seen. |

## Rungs in this domain

This is the one domain where all five rungs would answer the same question differently, so it is
the domain where the ladder is the content rather than a footnote. Three queries answer
*who can read this object* — deliberately, not by duplication:

- **`access_grants_on_object_show`** (`show`) and **`access_object_privileges_is`**
  (`information_schema`) are **one hop**, live, and need no grant on the `SNOWFLAKE` database. They
  answer *what privileges exist on this object*. Neither rung has a role-hierarchy view, so neither
  can climb even one step further.
- **`access_who_can_read_object_proc`** (`procedure`) climbs the whole graph **live**, with only
  `SHOW` and one `CREATE PROCEDURE`, and *marks* the branches the caller cannot see.
- **`access_who_can_read_object_au`** (`account_usage`) resolves the closure all the way to users
  and is the only rung with **history** — who used to have access.

Everything else here is `ACCOUNT_USAGE` because there is no lower rung that can answer at all:
`POLICY_REFERENCES`, `TAG_REFERENCES` and `DATA_CLASSIFICATION_LATEST` have per-object
`INFORMATION_SCHEMA` twins that answer for one object at a time, which is the wrong shape for a
coverage question, and `MASKING_POLICIES`, `ROW_ACCESS_POLICIES`, `ROLES`, `SHARES` and
`GRANTS_TO_SHARES` have no live equivalent that spans an account.

## What this domain will not pretend to know

Three of these queries are asked for a coverage number, and only one of them can honestly produce
a denominator. That is written into the files rather than papered over:

- **`gov_classification_coverage`** has a real denominator — `ACCOUNT_USAGE.TABLES` — so its
  percentage means something.
- **`gov_applied_sensitive_tags`** and **`gov_object_tag_coverage`** read `TAG_REFERENCES`, which
  lists only objects that already carry at least one tag. They measure the gap *inside* the tagged
  estate and are blind to everything tagging never touched. A short result is ambiguous between a
  clean estate and an unexamined one, and the header says so.
- **`gov_data_quality_rule_results`** is asked which rules are *breaching*. No `ACCOUNT_USAGE` view
  carries a Data Metric Function result value; the outcomes are written to an event table
  (`SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS_RAW` and its flattened view), and
  `DATA_METRIC_FUNCTION_EXPECTATIONS` carries the boolean expectation without its result. So the
  query answers the question that has to come first — which rules are even running — and names
  where the other half lives.

<sub>★ = first-audit pick. This is a one-line index — the full write-up (output columns, bands, caveats) lives in the [interactive docs](https://learn.crosshire.ch/learn/tech/snowflake/audit/governance_access). The `.sql` files in this folder are the source of truth. Nothing here has been run against a live Snowflake account: every view and column is verified against `docs.snowflake.com` and each file carries `confidence: confirmed-docs` or, where a shape could not be doc-verified, `confidence: unverified` with the reason.</sub>
