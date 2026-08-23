#!/usr/bin/env python3
"""Aggregate function-body fallback census JSONL into a ranked worklist.

Reads the records emitted by src/fallback_census.zig (one JSON object per line:
backend, status, module, fn, blocks, term, ret, traps, cleanup, instrs,
call_targets) and prints,
per backend:

  * headline coverage: how many distinct functions the verified-MIR fast path
    already admits vs. how many still fall back to the transitional AST body;
  * a coarse ranked table (entry terminator x return-value kind x block/trap/cleanup
    buckets) — the actionable "family" view: attack the biggest bucket first;
  * a fine ranked table by exact MIR instruction-kind and builtin-call-target
    signature — names precisely which constructs a fallen-back family contains,
    i.e. the recognizer to build.

A function is de-duplicated across corpus roots by (backend, fn, shape) so an std
helper pulled in by many fixtures counts once, not once per importer.

Usage: fallback-census-report.py [census.jsonl]   (reads stdin if omitted)
"""
import collections
import json
import sys

STATUS_RANK = {"admitted": 0, "fallback": 1, "unsupported": 2}


def blocks_bucket(n):
    if n <= 1:
        return "1"
    if n == 2:
        return "2"
    if n <= 4:
        return "3-4"
    return "5+"


def traps_bucket(n):
    if n == 0:
        return "0"
    if n == 1:
        return "1"
    return "2+"


def load(path):
    fh = open(path) if path else sys.stdin
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def signature(rec):
    # Stable per-function identity across roots: same function has the same shape
    # regardless of which fixture imported it.
    return (
        rec.get("fn", ""),
        rec.get("term", ""),
        rec.get("ret", ""),
        rec.get("blocks", 0),
        rec.get("traps", 0),
        bool(rec.get("cleanup", False)),
        rec.get("instrs", ""),
        # Old census JSONL predates this dimension. Treating absence as an
        # empty set keeps those files readable while preventing distinct
        # builtin families from collapsing in newly generated data.
        rec.get("call_targets", ""),
    )


def summarize_backend(recs):
    """Return de-duplicated headline counts for one backend."""
    seen = {}
    status_of = {}
    for r in recs:
        sig = signature(r)
        if sig not in seen:
            seen[sig] = r
        # A function that ever fell back is a fallback (any root proves the gap).
        st = r.get("status", "")
        prev = status_of.get(sig)
        if prev is None or STATUS_RANK.get(st, 0) > STATUS_RANK.get(prev, 0):
            status_of[sig] = st

    total = len(seen)
    admitted = sum(1 for s in status_of.values() if s == "admitted")
    fallback = sum(1 for s in status_of.values() if s == "fallback")
    unsupported = sum(1 for s in status_of.values() if s == "unsupported")
    admission_bps = (admitted * 10000 // total) if total else 0
    return {
        "total": total,
        "admitted": admitted,
        "fallback": fallback,
        "unsupported": unsupported,
        "admission_bps": admission_bps,
        "seen": seen,
        "status_of": status_of,
    }


def summarize_by_backend(path):
    by_backend = collections.defaultdict(list)
    for rec in load(path):
        by_backend[rec.get("backend", "?")].append(rec)
    return {backend: summarize_backend(recs) for backend, recs in by_backend.items()}


def bar(frac, width=24):
    filled = int(round(frac * width))
    return "#" * filled + "." * (width - filled)


def report_backend(backend, recs):
    summary = summarize_backend(recs)
    seen = summary["seen"]
    status_of = summary["status_of"]
    total = summary["total"]
    admitted = summary["admitted"]
    fallback = summary["fallback"]
    unsupported = summary["unsupported"]
    not_admitted = fallback + unsupported

    print("=" * 78)
    print(f"  BACKEND: {backend.upper()}")
    print("=" * 78)
    if total == 0:
        print("  (no records)")
        print()
        return
    cov = admitted / total
    print(f"  distinct functions : {total}")
    print(f"  fast-path admitted : {admitted:5d}  ({cov*100:5.1f}%)  {bar(cov)}")
    print(f"  AST body fallback  : {fallback:5d}  ({fallback/total*100:5.1f}%)")
    print(f"  unsupported (no fb): {unsupported:5d}  ({unsupported/total*100:5.1f}%)")
    print()
    if not_admitted == 0:
        print("  No remaining fallbacks in this corpus. P0 closed here.")
        print()
        return

    fb_sigs = [sig for sig, s in status_of.items() if s in ("fallback", "unsupported")]

    # --- coarse "family" ranking ---
    coarse = collections.Counter()
    coarse_examples = collections.defaultdict(list)
    for sig in fb_sigs:
        r = seen[sig]
        key = (
            r.get("term", ""),
            r.get("ret", ""),
            blocks_bucket(r.get("blocks", 0)),
            traps_bucket(r.get("traps", 0)),
            "cleanup" if r.get("cleanup") else "no-cleanup",
        )
        coarse[key] += 1
        if len(coarse_examples[key]) < 3:
            coarse_examples[key].append(r.get("fn", "?"))

    print(f"  REMAINING FALLBACKS: {not_admitted} distinct functions")
    print("  --- ranked by family (term | ret | blocks | traps | cleanup) ---")
    print(f"  {'count':>5}  {'%fb':>5}  family")
    for key, cnt in coarse.most_common(20):
        term, ret, bb, tb, cl = key
        frac = cnt / not_admitted
        fam = f"term={term} ret={ret} blocks={bb} traps={tb} {cl}"
        print(f"  {cnt:>5}  {frac*100:4.0f}%  {fam}")
        print(f"         {'':>5} e.g. {', '.join(coarse_examples[key])}")
    print()

    # --- fine ranking by exact instruction/call-target signature ---
    fine = collections.Counter()
    fine_examples = collections.defaultdict(list)
    for sig in fb_sigs:
        r = seen[sig]
        key = (
            r.get("term", ""),
            r.get("ret", ""),
            r.get("instrs", ""),
            r.get("call_targets", ""),
        )
        fine[key] += 1
        if len(fine_examples[key]) < 3:
            fine_examples[key].append(r.get("fn", "?"))

    print("  --- ranked by exact MIR instruction signature (recognizer target) ---")
    print(f"  {'count':>5}  {'%fb':>5}  term/ret :: instrs :: call_targets")
    for key, cnt in fine.most_common(20):
        term, ret, instrs, call_targets = key
        frac = cnt / not_admitted
        print(
            f"  {cnt:>5}  {frac*100:4.0f}%  "
            f"{term}/{ret} :: {instrs} :: {call_targets}"
        )
        print(f"         {'':>5} e.g. {', '.join(fine_examples[key])}")
    print()


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else None
    by_backend = collections.defaultdict(list)
    for rec in load(path):
        by_backend[rec.get("backend", "?")].append(rec)

    if not by_backend:
        print("no census records found", file=sys.stderr)
        return 1

    for backend in sorted(by_backend):
        report_backend(backend, by_backend[backend])
    return 0


if __name__ == "__main__":
    sys.exit(main())
