"""Shared parser for the Snowflake query-library header schema.

Every query file in queries/<domain>/*.sql opens with a comment header. This module
parses that header into a dict. It is the single source of truth for the header contract:
build_manifest.py and lint_headers.py both import it. See docs/CATALOGUE.md for the schema.

Ported from the Databricks sibling (crosshire-audit-databricks-admin), with three
Snowflake-specific changes:

  * `rung:`      — which rung of the access ladder the query stands on
                   (information_schema -> show -> account_usage -> organization_usage,
                   plus `procedure` for the installed Snowpark walker). This is the
                   house principle: prefer the live, low-privilege rung; say why when
                   you climb.
  * `freshness:` — LIVE (IS / SHOW / the procedure) vs LAGGED (ACCOUNT_USAGE carries a
                   documented latency, up to ~3h on most views). A Snowflake auditor who
                   confuses the two will answer "did my grant change take?" with stale data.
  * `confidence: confirmed-docs | unverified` — this library is authored WITHOUT a live
                   Snowflake account. "confirmed-docs" means every view and column named
                   was checked against docs.snowflake.com; it is NOT "confirmed" — nothing
                   here has been run against a real account.

Stdlib only — no third-party dependencies.
"""
from __future__ import annotations

import re
from pathlib import Path

# The 17 canonical header fields, in schema order. `tier` rides on the `domain:` line.
FIELDS = [
    "query_id",
    "title",
    "domain",
    "rung",
    "reads",
    "requires",
    "freshness",
    "params",
    "confidence",
    "confidence_note",
    "read_this",
    "healthy",
    "investigate_if",
    "actions",
    "next",
    "caveats",
]

# Optional header fields (absent => a default).
#   runnable: false  — a COPY-PASTE-ONLY file (the CREATE PROCEDURE install script) that must
#                      NOT flow into a manifest-driven runner as if it were a SELECT.
#   empty_if:        — controlled-vocabulary coverage reasons the query can return zero rows.
#   covers:          — free prose on what this rung does and does not see (the ladder note).
OPTIONAL_FIELDS = ["runnable", "empty_if", "covers"]

# Controlled vocabulary for `empty_if:` — the machine-checkable COVERAGE reasons a query can
# return zero rows, so an empty result is attributable to a real gap ("couldn't look") instead
# of being misread as a zero ("nothing there").
EMPTY_IF_VOCAB = {
    "no_imported_privileges",   # no IMPORTED PRIVILEGES on the SNOWFLAKE database -> ACCOUNT_USAGE unreachable
    "account_usage_lag",        # the AU view's documented latency has not caught up yet
    "retention_window",         # activity older than the view's retention (AU 1y; IS 7-14d) is purged
    "edition_gated",            # the feature needs Enterprise+ / Business Critical (e.g. some policies)
    "feature_not_enabled",      # the feature was never turned on (search optimization, clustering, QAS)
    "no_activity",              # genuinely no matching activity in the window
    "privilege_scoped",         # SHOW / INFORMATION_SCHEMA results are scoped to the caller's role
    "current_database_only",    # INFORMATION_SCHEMA is per-database; other databases are invisible
    "org_scope_required",       # needs ORGADMIN / the ORGANIZATION_USAGE schema
    "preview_unavailable",      # Preview view may not exist in this region / on this version
    "serverless_only",          # only populated by serverless features (tasks, pipes, Cortex)
    "cortex_not_used",          # no Cortex / AI feature has been called on this account
    "replication_not_configured",  # no replication or failover group exists
    "tagging_not_used",         # object tagging / query tagging is not in use on this account
}

# confirmed-docs = every view + column named was checked against docs.snowflake.com.
# unverified     = shape is inferred (SHOW output labels, drifting columns) and NOT doc-checked.
# Nothing here may ever say plain "confirmed" — that word is reserved for a live run.
CONFIDENCE_ENUM = {"confirmed-docs", "unverified"}

TIER_ENUM = {"lite", "standard", "deep"}

# The access ladder, cheapest / most-live rung first.
RUNG_ENUM = {
    "information_schema",   # live, low-privilege, per-database, short retention
    "show",                 # live, only SHOW; needs RESULT_SCAN to become a SELECT
    "procedure",            # an installed Snowpark walker — live, does what no view can
    "account_usage",        # IMPORTED PRIVILEGES on SNOWFLAKE; lagged; account-wide; 1y history
    "organization_usage",   # ORGADMIN; the only rung that sees currency + org-wide accounts
}

DOMAINS = {
    "cost",
    "warehouse",
    "performance",
    "storage",
    "serverless_ai",
    "governance_access",
    "security",
}

# First-audit picks (the ten * queries). Kept here so the manifest is deterministic;
# documented in README.md and docs/CATALOGUE.md.
STARS = {
    "cost_credits_by_warehouse_day",
    "cost_query_attribution_by_user",
    "cost_chargeback_by_query_tag",
    "cost_effective_rate_sheet",
    "warehouse_idle_credit_leak",
    "perf_spilling_queries",
    "storage_time_travel_bloat",
    "serverless_credit_exposure",
    "sec_mfa_coverage",
    "access_who_can_read_object_au",
}

REPO = "https://github.com/darshanmeel/crosshire-audit-snowflake-admin/blob/main/queries"
LEARN = "/learn/tech/snowflake/audit"

_FIELD_RE = re.compile(r"^--\s*(" + "|".join(FIELDS + OPTIONAL_FIELDS) + r")\s*:\s?(.*)$")
_DOMAIN_RE = re.compile(r"^\s*(\S+)\s+tier\s*:\s*(\S+)\s*$")
_PARAM_RE = re.compile(r":(\w+)\s*\(default\s+([^)]+)\)\s*(.*)")
# A next-token is a query_id optionally followed by a parenthetical condition.
# The condition may itself contain commas, so we split the field only on TOP-LEVEL commas.
_NEXT_SPLIT_RE = re.compile(r",(?![^(]*\))")
_NEXT_RE = re.compile(r"^([a-z0-9_]+)\s*(?:\(\s*(?:if\s+)?(.*?)\s*\))?$", re.I)
_ACTION_SPLIT_RE = re.compile(r"\s*\d+\)\s*")
# `rung:` may carry a trailing gloss after the token, e.g. "account_usage - the fallback".
_RUNG_RE = re.compile(r"^([a-z_]+)\b")


class HeaderError(ValueError):
    pass


def _raw_fields(text: str) -> dict[str, str]:
    """Extract raw (string) field values from the leading comment block."""
    fields: dict[str, str] = {}
    current: str | None = None
    for line in text.splitlines():
        if not line.startswith("--"):
            # First non-comment line ends the header block.
            break
        m = _FIELD_RE.match(line)
        if m:
            current = m.group(1)
            fields[current] = m.group(2).strip()
        else:
            # Continuation line: append to the field in progress.
            cont = line[2:].strip()
            if current is not None and cont:
                fields[current] = (fields[current] + " " + cont).strip()
    return fields


def parse_params(value: str) -> list[dict]:
    out = []
    for chunk in value.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        m = _PARAM_RE.search(chunk)
        if not m:
            continue
        name, default, meaning = m.group(1), m.group(2).strip(), m.group(3).strip()
        val: object = default
        try:
            val = int(default)
        except ValueError:
            try:
                val = float(default)
            except ValueError:
                val = default
        out.append({"name": name, "default": val, "meaning": meaning})
    return out


def parse_next(value: str) -> list[dict]:
    out = []
    if not value or value.strip().lower().startswith("n/a"):
        return out
    # Split on TOP-LEVEL commas only: a next-token's "(if ...)" condition may itself contain
    # commas, and a plain str.split(",") would shred it and silently drop the target. A
    # non-empty token that still fails to parse is raised loudly rather than dropped — a broken
    # cross-link must fail the linter, not vanish into an empty list that quietly passes.
    for token in _NEXT_SPLIT_RE.split(value):
        token = token.strip()
        if not token:
            continue
        m = _NEXT_RE.match(token)
        if not m:
            raise HeaderError(f"malformed next-entry token {token!r}")
        out.append({"query_id": m.group(1), "if": (m.group(2) or "").strip()})
    return out


def parse_actions(value: str) -> list[str]:
    if not value or value.strip().lower().startswith("n/a"):
        return []
    return [p.strip() for p in _ACTION_SPLIT_RE.split(value) if p.strip()]


def parse_reads(value: str) -> list[str]:
    """`reads:` is a comma-separated list of ACCOUNT_USAGE / ORGANIZATION_USAGE /
    INFORMATION_SCHEMA views (or table functions), or SHOW commands. Every entry must be a
    real, documented object — that is what lint_headers.py checks."""
    return [r.strip() for r in value.split(",") if r.strip()]


def parse_header(text: str, *, path: str = "<memory>") -> dict:
    """Parse a full SQL file's text into a structured header dict.

    Raises HeaderError on a structurally-broken header (missing required field or
    malformed domain line). Value-level validation lives in lint_headers.py.
    """
    raw = _raw_fields(text)
    for f in FIELDS:
        if f not in raw:
            raise HeaderError(f"{path}: missing required header field '{f}'")

    dm = _DOMAIN_RE.match(raw["domain"])
    if not dm:
        raise HeaderError(
            f"{path}: 'domain:' line must read '<domain>   tier: <tier>', got {raw['domain']!r}"
        )
    domain, tier = dm.group(1), dm.group(2)

    rm = _RUNG_RE.match(raw["rung"].strip().lower())
    if not rm:
        raise HeaderError(f"{path}: 'rung:' line must start with a rung token, got {raw['rung']!r}")
    rung = rm.group(1)

    try:
        nxt = parse_next(raw["next"])
    except HeaderError as e:
        raise HeaderError(f"{path}: {e}") from None

    runnable = not raw.get("runnable", "true").strip().lower().startswith("false")
    empty_if = [t.strip().lower() for t in raw.get("empty_if", "").split(",") if t.strip()]

    return {
        "query_id": raw["query_id"].strip(),
        "title": raw["title"].strip(),
        "domain": domain,
        "tier": tier,
        "rung": rung,
        "rung_note": raw["rung"].strip(),
        "stars": raw["query_id"].strip() in STARS,
        "runnable": runnable,
        "empty_if": empty_if,
        "reads": parse_reads(raw["reads"]),
        "requires": raw["requires"].strip(),
        "freshness": raw["freshness"].strip(),
        "params": parse_params(raw["params"]),
        "confidence": raw["confidence"].strip(),
        "confidence_note": raw["confidence_note"].strip(),
        "read_this": raw["read_this"].strip(),
        "healthy": raw["healthy"].strip(),
        "investigate_if": raw["investigate_if"].strip(),
        "actions": parse_actions(raw["actions"]),
        "next": nxt,
        "caveats": raw["caveats"].strip(),
        "covers": raw.get("covers", "").strip(),
        "_raw": raw,
    }


def iter_query_files(queries_dir: Path):
    for p in sorted(queries_dir.rglob("*.sql")):
        yield p


def load_all(queries_dir: Path) -> dict[str, dict]:
    """query_id -> parsed header, for every .sql under queries_dir."""
    out = {}
    for p in iter_query_files(queries_dir):
        hdr = parse_header(p.read_text(encoding="utf-8"), path=str(p))
        out[hdr["query_id"]] = hdr
    return out
