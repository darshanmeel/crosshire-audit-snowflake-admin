#!/usr/bin/env python3
"""Header-schema + hygiene linter for the Snowflake query library.

Checks, over every queries/<domain>/*.sql:
  - all 16 header fields present and non-empty
  - query_id matches the filename stem (a `.au` / `.proc` rung suffix is allowed and must
    then be reflected in the query_id); domain == folder; tier / rung / confidence in enum
  - `reads:` entries are well-formed Snowflake objects (ACCOUNT_USAGE / ORGANIZATION_USAGE /
    INFORMATION_SCHEMA view or table function, a SHOW command, or a documented system function)
  - the rung the header CLAIMS matches what the query actually reads - the ladder gate. A file
    that says `rung: information_schema` while selecting from ACCOUNT_USAGE is the single most
    misleading defect this library can ship, so it fails the build.
  - params declares :period_days when the body uses it; no hard-coded DATEADD windows
  - every `next:` target resolves to a real query_id
  - no internal-pipeline vocabulary leaks (the engine's COLLECT_ temp tables, collector /
    verifier, findings/ paths, edition= markers)
  - `confidence` is never the bare word "confirmed" - nothing here has been run live
  - manifest.json is in sync (delegates to build_manifest --check)

    python tools/lint_headers.py

Exit code 0 = clean, 1 = violations. Stdlib only.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import header_schema as hs  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
QUERIES = ROOT / "queries"

# Vocabulary that must never appear in a public query file (header or body). The COLLECT_ and
# edition= entries are the ones that matter: they are the fingerprints of a copy-paste out of
# the internal findings engine's collection layer, which this library must never carry.
FORBIDDEN = [
    (re.compile(r"\bCOLLECT_[A-Z_]+\b"), "internal engine temp table 'COLLECT_*'"),
    (re.compile(r"^--\s*=====\s*source\s*:", re.M), "internal engine 'source:' banner"),
    (re.compile(r"edition\s*=\s*account_usage"), "internal engine 'edition=' marker"),
    (re.compile(r"\bcollector\b", re.I), "internal 'collector'"),
    (re.compile(r"\bverifier\b", re.I), "internal 'verifier'"),
    (re.compile(r"findings/"), "internal 'findings/...' path"),
    (re.compile(r"crosshire_audit\b"), "internal 'crosshire_audit' package path"),
    (re.compile(r"^--\s*feeds\s*:", re.M), "internal 'feeds:' header"),
    (re.compile(r"lookback_days"), "old ':lookback_days' param (use :period_days)"),
    (re.compile(r"[‘’“”]"), "curly quote (use straight quotes in SQL)"),
]

# Queries that emit a `status` column may only emit these labels, so a scorecard that tallies
# exactly this set can never silently miss an off-contract band.
STATUS_ENUM = {"OK", "WARN", "CRITICAL", "NOT_ASSESSED"}
_STATUS_CASE_RE = re.compile(r"CASE\b((?:(?!\bEND\s+AS\b).)*?)\bEND\s+AS\s+status\b", re.I | re.S)
_STATUS_VALUE_RE = re.compile(r"\b(?:THEN|ELSE)\s+'([^']*)'", re.I)
_NESTED_CASE_RE = re.compile(r"\bCASE\b(?:(?!\bCASE\b|\bEND\b).)*?\bEND\b", re.I | re.S)

# Hard-coded time windows that must have become :period_days.
WINDOW_BAD = [
    (re.compile(r"DATEADD\s*\(\s*'?day'?\s*,\s*-\d+", re.I), "hard-coded DATEADD() window (use :period_days)"),
    (re.compile(r"DATEADD\s*\(\s*'?month'?\s*,\s*-\d+", re.I), "hard-coded DATEADD() month window (use :period_days)"),
    (re.compile(r"INTERVAL\s+'\d+\s+DAYS?'", re.I), "hard-coded INTERVAL window (use :period_days)"),
    (re.compile(r"CURRENT_DATE\s*\(\s*\)\s*-\s*\d+"), "hard-coded CURRENT_DATE() - <n> window (use :period_days)"),
]

# A `reads:` entry must look like one of these. This is a SHAPE gate, not a name oracle - it
# catches "system.billing.usage" (a Databricks table pasted in) and free prose, but it cannot
# know whether SNOWFLAKE.ACCOUNT_USAGE.FOO exists. That check is the author's, against
# docs.snowflake.com, and is what the `confidence: confirmed-docs` claim asserts.
READS_SHAPES = [
    re.compile(r"^snowflake\.account_usage\.[a-z_][a-z0-9_]*$", re.I),
    re.compile(r"^snowflake\.organization_usage\.[a-z_][a-z0-9_]*$", re.I),
    re.compile(r"^(?:[a-z_][a-z0-9_]*\.)?information_schema\.[a-z_][a-z0-9_]*(?:\(\))?$", re.I),
    re.compile(r"^show\s+[a-z0-9_ ]+$", re.I),
    re.compile(r"^result_scan\(last_query_id\(\)\)$", re.I),
    re.compile(r"^(?:snowflake\.)?[a-z_][a-z0-9_]*\(\)$", re.I),  # system function, e.g. GET_QUERY_OPERATOR_STATS()
]

# The ladder gate: what a rung is allowed to read.
# The `information_schema` rung also covers a bare built-in table function such as
# GET_QUERY_OPERATOR_STATS() - same standing on the ladder (live, session/warehouse-scoped,
# no IMPORTED PRIVILEGES), it just is not spelled with an INFORMATION_SCHEMA prefix.
RUNG_MUST_READ = {
    "account_usage": re.compile(r"snowflake\.account_usage\.", re.I),
    "organization_usage": re.compile(r"snowflake\.organization_usage\.", re.I),
    "information_schema": re.compile(r"(information_schema\.|(?<![.\w])[a-z_][a-z0-9_]*\(\))", re.I),
    "show": re.compile(r"(?:^|;\s*)show\s", re.I),
}
# ... and what it must NOT read (climbing a rung without saying so).
RUNG_MUST_NOT_READ = {
    "information_schema": re.compile(r"snowflake\.(account_usage|organization_usage)\.", re.I),
    "show": re.compile(r"snowflake\.(account_usage|organization_usage)\.", re.I),
    "account_usage": re.compile(r"snowflake\.organization_usage\.", re.I),
}


def status_labels(span: str) -> list[str]:
    """The status CASE's own THEN/ELSE labels, with nested CASE...END blocks stripped first so a
    categorical CASE used inside a WHEN condition can't leak its branch literals into the set."""
    prev = None
    while prev != span:
        prev = span
        span = _NESTED_CASE_RE.sub(" ", span)
    return _STATUS_VALUE_RE.findall(span)


def lint_file(path: Path, all_ids: set[str]) -> list[str]:
    errs: list[str] = []
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(ROOT)

    if "\r" in text:
        errs.append(f"{rel}: CRLF line endings (repo is LF-only - run dos2unix)")

    try:
        hdr = hs.parse_header(text, path=str(rel))
    except hs.HeaderError as e:
        return errs + [str(e)]

    for f in hs.FIELDS:
        if f == "domain":
            continue  # domain + tier ride on the combined 'domain:' line, validated below
        if not str(hdr.get(f, "")).strip():
            errs.append(f"{rel}: field '{f}' is empty")

    if hdr["query_id"] != path.stem.replace(".", "_"):
        errs.append(
            f"{rel}: query_id '{hdr['query_id']}' != filename stem '{path.stem}' "
            f"(a rung suffix like '.au' must appear in the query_id as '_au')"
        )
    if hdr["domain"] != path.parent.name:
        errs.append(f"{rel}: domain '{hdr['domain']}' != folder '{path.parent.name}'")
    if hdr["tier"] not in hs.TIER_ENUM:
        errs.append(f"{rel}: tier '{hdr['tier']}' not in {sorted(hs.TIER_ENUM)}")
    if hdr["rung"] not in hs.RUNG_ENUM:
        errs.append(f"{rel}: rung '{hdr['rung']}' not in {sorted(hs.RUNG_ENUM)}")
    if hdr["confidence"] not in hs.CONFIDENCE_ENUM:
        errs.append(
            f"{rel}: confidence '{hdr['confidence']}' not in {sorted(hs.CONFIDENCE_ENUM)} "
            f"(plain 'confirmed' is reserved for a live run and may never be claimed here)"
        )
    rn = hdr["_raw"].get("runnable")
    if rn is not None and not rn.strip().lower().startswith(("true", "false")):
        errs.append(f"{rel}: optional 'runnable' must start with 'true' or 'false', got {rn!r}")
    for tok in hdr["empty_if"]:
        if tok not in hs.EMPTY_IF_VOCAB:
            errs.append(f"{rel}: empty_if token '{tok}' not in vocabulary {sorted(hs.EMPTY_IF_VOCAB)}")

    # reads: every entry must be a well-formed Snowflake object reference.
    for r in hdr["reads"]:
        if not any(rx.match(r) for rx in READS_SHAPES):
            errs.append(f"{rel}: reads entry {r!r} is not a recognizable Snowflake object")

    # The ladder gate.
    reads_blob = " ; ".join(hdr["reads"])
    rung = hdr["rung"]
    must = RUNG_MUST_READ.get(rung)
    if must and not must.search(reads_blob):
        errs.append(f"{rel}: rung '{rung}' but no matching object in reads: {hdr['reads']}")
    must_not = RUNG_MUST_NOT_READ.get(rung)
    if must_not and must_not.search(reads_blob):
        errs.append(
            f"{rel}: rung '{rung}' claims a lower rung than it reads - reads {hdr['reads']}. "
            f"Say which rung you are on."
        )

    # SQL body = everything after the leading comment block.
    body = "\n".join(l for l in text.splitlines() if not l.startswith("--"))

    # Window hygiene: the only allowed rolling window is :period_days. Genuine point-in-time
    # snapshots (SHOW, inventories) are allowed to omit it entirely. Scans the SQL body ONLY -
    # an "up to 3 hours" phrase in a caveats: sentence is prose, not an executable window.
    for rx, label in WINDOW_BAD:
        if rx.search(body):
            errs.append(f"{rel}: {label}")
    param_names = {p["name"] for p in hdr["params"]}
    if ":period_days" in body and "period_days" not in param_names:
        errs.append(f"{rel}: body uses :period_days but params does not declare it")

    for qid in [n["query_id"] for n in hdr["next"]]:
        if qid not in all_ids:
            errs.append(f"{rel}: next target '{qid}' is not a real query_id")

    for rx, label in FORBIDDEN:
        if rx.search(text):
            errs.append(f"{rel}: forbidden {label}")

    for span in _STATUS_CASE_RE.findall(body):
        for lit in status_labels(span):
            if lit not in STATUS_ENUM:
                errs.append(f"{rel}: status label '{lit}' not in status enum {sorted(STATUS_ENUM)}")

    return errs


def main() -> int:
    files = list(hs.iter_query_files(QUERIES))
    all_ids = set()
    for p in files:
        try:
            all_ids.add(hs.parse_header(p.read_text(encoding="utf-8"), path=str(p))["query_id"])
        except hs.HeaderError:
            all_ids.add(p.stem.replace(".", "_"))

    errs: list[str] = []
    for p in files:
        errs.extend(lint_file(p, all_ids))

    print(f"linted {len(files)} query files")
    if errs:
        print(f"\n{len(errs)} violation(s):", file=sys.stderr)
        for e in errs:
            print("  " + e, file=sys.stderr)

    def _sync_ok(script: str) -> bool:
        r = subprocess.run(
            [sys.executable, str(ROOT / "tools" / script), "--check"],
            capture_output=True, text=True,
        )
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        return r.returncode == 0

    manifest_ok = _sync_ok("build_manifest.py")

    if errs or not manifest_ok:
        return 1
    print("all header + manifest checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
