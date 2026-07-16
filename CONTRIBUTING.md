# Contributing

## The ladder

Every audit question is answered along the **IS → workaround → AU** ladder (see the
[README](README.md#the-ladder-is--workaround--au)). A question ships the rungs that
apply to it:

- **IS** (`*.is.sql`) — `INFORMATION_SCHEMA`. Live, low-privilege. Try this first.
- **Workaround** (`*.proc.sql` or `*.show.sql`) — a `SHOW`-command recipe or a small
  stored procedure, for what IS is too thin to answer. Still live, still low-priv.
- **AU** (`*.au.sql`) — `ACCOUNT_USAGE`. Admin-gated and lagged; the fallback, and
  the only rung with history.

Not every question has all three. If IS answers it completely, you may not need a
workaround or AU rung at all. If only `ACCOUNT_USAGE` can answer it, ship just the
`.au.sql` and say so in the header.

## File header

Every `.sql` opens with a structured comment block:

```
-- query_id: who_can_read_object          -- shared across the rung files for one question
-- title: <one line>
-- domain: access   tier: ★ starter        -- ★ = run-this-first
-- rung: IS | WORKAROUND | AU
-- reads: <views / SHOW commands / tables it touches>
-- requires: <the exact privilege needed>
-- freshness: LIVE | LAGGED (<how much>)
-- params: <what to edit before running>
-- confidence: confirmed | unverified-live
-- confidence_note: <what has NOT been checked against a live account, if anything>
-- read_this: <what one output row means, and the columns that matter>
-- covers: <what this rung answers — and, crucially, what it does NOT>
-- caveats: <privilege-scoping, drift, retention, per-db limits, etc.>
-- next: <the other rung files, or related questions>
<the statement(s)>
```

## Rules

- **No real identifiers.** Targets are placeholders (`crosshire.silver.orders`,
  `CROSSHIRE_ETL_SILVER`). Never paste a real database, schema, role, user, or
  account name.
- **Never commit results.** `*.csv` is git-ignored; output is real account data.
- **Be honest about drift.** Snowflake changes `SHOW` output columns and
  `ACCOUNT_USAGE` view shapes across versions. If a query wasn't run against a live
  account for this release, mark `confidence: unverified-live` and say what to
  verify.
- **Say what a rung can't do.** The `covers:` line must name the limitation that
  makes you drop to the next rung (e.g. "IS has no role graph → one hop only").
