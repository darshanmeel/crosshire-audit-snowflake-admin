# CrossHire — Snowflake Audit Query Library (admin)

A **copy-paste SQL library** for auditing a Snowflake account's **access &
governance, cost, warehouses, storage and query performance**. No app to install
and no dashboard — most files are a plain statement you paste into a Snowsight
worksheet and run.

What makes this different from a pile of `ACCOUNT_USAGE` queries: **every question
is answered from the most accessible source that can actually answer it** — because
`ACCOUNT_USAGE`, the source most audit guides reach for first, is exactly the one
most engineers are *not* allowed to read.

## The ladder: IS → workaround → AU

Every audit question here is answered along a **preference ladder**. Start at the
top rung and drop down only when the rung above cannot answer the question:

| Rung | Source | Privilege | Freshness | Use it… |
|--:|---|---|---|---|
| **1. IS** | `<db>.INFORMATION_SCHEMA.*` | any role (privilege-scoped) | **live** | first — it's live and needs no elevation |
| **2. Workaround** | `SHOW …` / a small stored procedure | often just `SHOW` / `USAGE` | **live** | when IS is too thin to answer |
| **3. AU** | `SNOWFLAKE.ACCOUNT_USAGE.*` | `IMPORTED PRIVILEGES` on `SNOWFLAKE` — **ACCOUNTADMIN** by default | **lagged** (minutes–hours) | last — or when you specifically need *history* |

Why this order and not the usual "just query `ACCOUNT_USAGE`":

1. **IS — INFORMATION&#95;SCHEMA first.** It is **live** and any role can read it
   (scoped to what that role may see). If IS can answer the question, that is the
   query you want — no ticket, no admin, no lag.
2. **Workaround — when IS can't.** IS is deliberately thin: no role graph, one
   database at a time, short retention. Where it falls short, a `SHOW`-command loop
   or a small stored procedure gets a **live** answer with minimal privilege.
3. **AU — ACCOUNT&#95;USAGE, last.** The richest source and the only one with
   *history* (`DELETED_ON`) — but it needs `IMPORTED PRIVILEGES` on the `SNOWFLAKE`
   database (**ACCOUNTADMIN** by default) and it **lags**. Reach for it only when
   neither IS nor a workaround can do the job, or when you truly need the
   backward-looking "who *used* to have access" answer.

Each folder ships the rungs that apply to a question, so you use the highest one
your privileges and freshness needs allow.

## Start here — "Who can actually read this object?"

The first audit is one hard question: given a table, **who can read it,
transitively** — through every role, database role, and user — answered down the
whole ladder.

| Rung | File | What it gives you |
|--:|---|---|
| **1. IS** | [`who_can_read_object.is.sql`](queries/access/who_can_read_object.is.sql) | `INFORMATION_SCHEMA.OBJECT_PRIVILEGES` — the **direct** grants on the object, live. But IS has **no role-hierarchy view**, so this is only the **first hop**; it cannot follow the chain. |
| **2. Workaround** | [`who_can_read_object.proc.sql`](queries/access/who_can_read_object.proc.sql) | A Snowpark-Python procedure that walks `SHOW GRANTS` recursively — the **full transitive answer, live**, needing only `SHOW`. This is the rung IS can't reach, and it's the one to use. |
| **3. AU** | [`who_can_read_object.au.sql`](queries/access/who_can_read_object.au.sql) | A recursive CTE over `GRANTS_TO_ROLES` + `GRANTS_TO_USERS` — the full closure **if** you have the `SNOWFLAKE` db. Fallback: admin-gated and lagged, but the only one that can also answer *historically*. |

The shape of the problem: `SHOW GRANTS ON` a table and
`INFORMATION_SCHEMA.OBJECT_PRIVILEGES` both show only the roles sitting *directly*
on the object — one hop — not the people who reach it through a chain of roles. IS
can't climb the chain, so we drop to rung 2: the procedure walks it live. Rung 3
(`ACCOUNT_USAGE`) is the fallback for when you can't install a procedure but you do
hold the admin grant — and the only rung that can replay history.

📖 **Full write-up** — why each rung exists, how to read the output, and the
footguns (`EXECUTE AS CALLER`, column drift, the `LAST_QUERY_ID` trap):
**[learn.crosshire.ch/learn/tech/snowflake/audit](https://learn.crosshire.ch/learn/tech/snowflake/audit)**
· field note: **[blogs.crosshire.ch/blogs/snowflake-grant-graph-audit](https://blogs.crosshire.ch/blogs/snowflake-grant-graph-audit)**

## Roadmap

Starts with **access & governance** and grows the way the
[Databricks library](https://github.com/darshanmeel/crosshire-audit-databricks-admin)
did — each domain a folder, each question answered down the IS → workaround → AU
ladder:

- **access** *(started)* — who-can-read, role → reach, user → reach, grants
  inventory, future grants, dormant privileges
- **cost** — credits by warehouse / user / query, serverless, storage $
- **warehouses** — sizing, queuing, auto-suspend gaps, spilling
- **queries** — longest / most-scanned, pruning, cache hit, failures
- **storage** — table bytes, time-travel + fail-safe, stages, drift

## Conventions

- **Identifiers are placeholders.** Every example targets `crosshire.silver.orders`
  and roles like `CROSSHIRE_ETL_SILVER` — swap in your own. No real account names
  appear anywhere in this repo.
- **Each file opens with a structured header** (see
  [`CONTRIBUTING.md`](CONTRIBUTING.md)): `rung`, `reads`, `requires`, `freshness`,
  `read_this`, `caveats`.
- **Never commit results.** `.gitignore` blocks `*.csv` — query output is real
  account data.
- **`confidence: unverified-live`** means the exact column labels / view shapes have
  **not** been run against a live account for this release. Snowflake drifts these
  (`SHOW` output columns, `ACCOUNT_USAGE` view shapes), so confirm on your version
  before you trust a zero.

## License

[Apache 2.0](LICENSE).
