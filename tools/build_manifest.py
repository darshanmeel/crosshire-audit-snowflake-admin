#!/usr/bin/env python3
"""Generate queries/manifest.json FROM the SQL headers (single source of truth).

The headers in queries/<domain>/*.sql are authoritative; this script parses them and
emits a deterministic, domain-keyed manifest. Never hand-edit manifest.json.

    python tools/build_manifest.py            # regenerate manifest.json in place
    python tools/build_manifest.py --check    # exit 1 if manifest.json is stale (CI)

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import header_schema as hs  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
QUERIES = ROOT / "queries"
MANIFEST = QUERIES / "manifest.json"

# Manifest entry field order.
ENTRY_FIELDS = [
    "query_id",
    "title",
    "domain",
    "tier",
    "rung",
    "rung_note",
    "stars",
    "runnable",
    "empty_if",
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
    "covers",
    "sql_url",
    "learn_url",
]


def entry_for(hdr: dict, path: Path) -> dict:
    qid = hdr["query_id"]
    domain = hdr["domain"]
    # sql_url points at the FILE, which may carry a suffix (e.g. `.au`, `.proc`) that the
    # query_id does not — two rungs of one question live in two files with distinct ids.
    e = dict(hdr)
    e["sql_url"] = f"{hs.REPO}/{domain}/{path.name}"
    e["learn_url"] = f"{hs.LEARN}/{domain}#q-{qid}"
    return {k: e[k] for k in ENTRY_FIELDS}


def build() -> dict:
    manifest: dict[str, list] = {}
    for p in hs.iter_query_files(QUERIES):
        hdr = hs.parse_header(p.read_text(encoding="utf-8"), path=str(p))
        manifest.setdefault(hdr["domain"], []).append(entry_for(hdr, p))
    # Fail loudly on an unknown domain rather than bucketing it to a non-deterministic tail
    # that would make the byte-for-byte --check gate flaky across a rename.
    unknown = sorted(set(manifest) - hs.DOMAINS)
    if unknown:
        raise hs.HeaderError(f"unknown domain(s) {unknown} - not in header_schema.DOMAINS")
    domain_order = sorted(hs.DOMAINS)
    ordered = {}
    for domain in sorted(manifest, key=domain_order.index):
        ordered[domain] = sorted(manifest[domain], key=lambda e: e["query_id"])
    return ordered


def serialize(manifest: dict) -> str:
    return json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if manifest.json is stale")
    args = ap.parse_args()

    text = serialize(build())
    if args.check:
        current = MANIFEST.read_text(encoding="utf-8") if MANIFEST.exists() else ""
        if current != text:
            print("manifest.json is STALE - run: python tools/build_manifest.py", file=sys.stderr)
            return 1
        print("manifest.json is in sync.")
        return 0
    MANIFEST.write_text(text, encoding="utf-8", newline="\n")
    n = sum(len(v) for v in json.loads(text).values())
    print(f"wrote {MANIFEST} ({n} queries across {len(json.loads(text))} domains)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
