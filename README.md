# CrossHire — Snowflake grant-graph audit

**Who can actually read this Snowflake table?** — answered two ways.

`SHOW GRANTS ON` a table shows only the roles granted *directly* on it — one hop —
not the people who reach it through a chain of roles. This repo answers the real
question: **given an object, every role and user who can read it, transitively.**

Two files, two rungs of the same ladder:

| File | Rung | Privilege | Freshness | Use it |
|---|---|---|---|---|
| [`who_can_read_object.proc.sql`](who_can_read_object.proc.sql) | **workaround** — a Snowpark procedure that walks `SHOW GRANTS` live | only `SHOW` | **live** | **first** — no admin, answers the instant you call it |
| [`who_can_read_object.au.sql`](who_can_read_object.au.sql) | **fallback** — a recursive CTE over `ACCOUNT_USAGE` | `IMPORTED PRIVILEGES` on `SNOWFLAKE` (**ACCOUNTADMIN** by default) | **lagged** | when you can't install a procedure but hold the admin grant — or need **history** |

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
- **`unverified-live`.** `SHOW GRANTS` output columns and `ACCOUNT_USAGE` view shapes
  drift across Snowflake versions and are not verified against a live account for this
  release. Run the procedure with `debug => TRUE` once to print the real column
  labels, and confirm the `ACCOUNT_USAGE` columns on your version, before you trust a
  zero.
- **Never commit results** — `.gitignore` blocks `*.csv`; output is real account data.
