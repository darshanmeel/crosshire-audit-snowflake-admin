# CrossHire — Snowflake grant-graph audit

**Who can actually read this Snowflake table?** — answered two ways.

`SHOW GRANTS ON` a table shows only the roles granted *directly* on it — one hop —
not the people who reach it through a chain of roles. This repo answers the real
question: **given an object, every role and user who can read it, transitively.**

Two files in [`queries/governance_access/`](queries/governance_access/), two rungs of the same ladder:

| File | Rung | Privilege | Freshness | Use it |
|---|---|---|---|---|
| [`queries/governance_access/access_who_can_read_object.proc.sql`](queries/governance_access/access_who_can_read_object.proc.sql) | **workaround** — a Snowpark procedure that walks `SHOW GRANTS` live | only `SHOW` | **live** | **first** — no admin, answers the instant you call it |
| [`queries/governance_access/access_who_can_read_object.au.sql`](queries/governance_access/access_who_can_read_object.au.sql) | **fallback** — a recursive CTE over `ACCOUNT_USAGE` | `IMPORTED PRIVILEGES` on `SNOWFLAKE` (**ACCOUNTADMIN** by default) | **lagged** | when you can't install a procedure but hold the admin grant — or need **history** |

## This is the first two of a hundred

The grant graph is the question that made this repo; it is not the only one. The full worklist —
**100 queries across 7 domains** (`cost · warehouse · performance · storage · serverless_ai ·
governance_access · security`), each traced to its ladder rung, the question it answers and the
views it reads — is **[`docs/CATALOGUE.md`](docs/CATALOGUE.md)**. Ten of them are marked ★ as the
first-audit picks. The two files below are the first two written; the other 98 are the build queue.

Every query carries a structured header (`rung`, `reads`, `requires`, `freshness`, `read_this`,
`healthy` / `investigate_if` bands, a free→config→spend action ladder, `caveats`), parsed by
[`tools/header_schema.py`](tools/header_schema.py) into
[`queries/manifest.json`](queries/manifest.json) via `python tools/build_manifest.py`.
`python tools/lint_headers.py` is the gate — it fails a half-documented query, a broken
cross-link, a hard-coded time window, and above all **a query that claims a lower ladder rung than
it actually reads**.

🧰 Sibling library: **[crosshire-audit-databricks-admin](https://github.com/darshanmeel/crosshire-audit-databricks-admin)** — the same idea for Databricks system tables (100 queries, 7 domains). `docs/CATALOGUE.md` documents where the Snowflake taxonomy deliberately diverges from it.

## Why a procedure, not just `ACCOUNT_USAGE`?

Most guides say "query `ACCOUNT_USAGE.GRANTS_TO_ROLES`." But that schema is
**restricted to `ACCOUNTADMIN`** for security and it **lags** up to a few hours — so
most engineers can't use it, and even those who can can't trust it for *"did the
grant I just changed take?"*.

The **procedure** needs only `SHOW`, the privilege every role already has, and
answers **live**. It loops `SHOW GRANTS` up the role graph — hopping account roles
and database roles, guarding cycles and `SYSTEM$` pseudo-roles, running
`EXECUTE AS CALLER` so branches you can't see come back marked `[UNREADABLE]`
instead of crashing the walk. Read the result with `RESULT_SCAN(LAST_QUERY_ID())`
(pin the id immediately — it moves), or materialize into a `TEMP TABLE`.

The **`ACCOUNT_USAGE` CTE** is the fallback. It ships two forms: a **primary** that
seeds on the object and climbs, and an **alternate** that builds the role graph once
(object-independent) and puts the object filter in the final `SELECT` — handy when
you audit many objects. Both **resolve all the way to users** via `GRANTS_TO_USERS`;
a role-only result stops one hop short of the people. It is also the only rung that
answers *historically* — drop the `deleted_on IS NULL` filters to see who **used to**
have access.

Two privilege details make it a *read* audit rather than a *grant* dump:

- The seed keeps only **read-conferring** grants on the object —
  `privilege IN ('SELECT', 'OWNERSHIP')` — so a role granted merely `INSERT` or
  `REFERENCES` (which cannot read) is not counted.
- The climb follows only the **`USAGE`** edge on a role. In Snowflake, *holding* a
  role is a `USAGE` grant; **owning** a role (`OWNERSHIP`) is not the same thing, so
  filtering to `USAGE` avoids counting role owners who can't actually activate it.

## What about `INFORMATION_SCHEMA`?

`INFORMATION_SCHEMA.OBJECT_PRIVILEGES` answers a **different** question — *what
privileges exist directly on an object* (one hop) — not *who can read it
transitively*. It has no role-hierarchy view, so it can't walk the graph. It's a
useful direct-grants lookup, but it is not a rung for this question, so it isn't
included here.

## Read the full story

- 📖 Field note: **[blogs.crosshire.ch/blogs/snowflake-grant-graph-audit](https://blogs.crosshire.ch/blogs/snowflake-grant-graph-audit)** — why one hop lies, the footguns, the whole procedure.
- 📚 Learn: **[learn.crosshire.ch/learn/tech/snowflake/audit](https://learn.crosshire.ch/learn/tech/snowflake/audit)** — the procedure and `ACCOUNT_USAGE` versions explained, categorized.
- 🧰 Sibling library: **[crosshire-audit-databricks-admin](https://github.com/darshanmeel/crosshire-audit-databricks-admin)**.

## Notes

- **Identifiers are placeholders.** Everything targets `crosshire.silver.orders` and
  roles like `CROSSHIRE_ETL_SILVER` — swap in your own. No real account names appear.
- **Nothing here has been run against a live Snowflake account.** A query claims
  `confidence: confirmed-docs` when every view and column it names was checked against
  `docs.snowflake.com`, and `confidence: unverified` when it could not be — `SHOW GRANTS`
  output column labels are not a documented, stable contract and drift across versions.
  The bare word `confirmed` is reserved for a live run and the linter rejects it. Run the
  procedure with `debug => TRUE` once to print the real column labels before you trust a zero.
- **Never commit results** — `.gitignore` blocks `*.csv`; output is real account data.

## License

Dual-licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
Unless you say otherwise, any contribution you submit is licensed the same way, with no extra terms.
