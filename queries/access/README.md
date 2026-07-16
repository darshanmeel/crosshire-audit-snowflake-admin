# access — who can reach what

Grant-graph and privilege audits. Each question is answered down the
[IS → workaround → AU ladder](../../README.md#the-ladder-is--workaround--au): try
`INFORMATION_SCHEMA` first (live, low-priv); drop to a `SHOW`/procedure workaround
where IS is too thin; fall back to `ACCOUNT_USAGE` only when neither works (or you
need history).

| Question | 1 · IS | 2 · Workaround | 3 · AU |
|---|---|---|---|
| **Who can read this object?** (transitive) | [is](who_can_read_object.is.sql) — direct grants only, live (one hop) | [proc](who_can_read_object.proc.sql) — **full graph, live** ← use this | [au](who_can_read_object.au.sql) — full graph + history, admin-gated + lagged |

For *who can read this object*, IS can only see the first hop (no role-hierarchy
view), so the working answer is the **procedure** — it walks `SHOW GRANTS` live.
`ACCOUNT_USAGE` is the fallback when you can't install a procedure but hold the
admin grant, and the only rung that answers *who used to have access*.

**Coming:** role → what it can reach · user → everything they reach · grants
inventory (IS `OBJECT_PRIVILEGES` vs AU `GRANTS_TO_ROLES`) · future grants ·
dormant privileges (needs AU history).
