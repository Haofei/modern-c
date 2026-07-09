#!/usr/bin/env python3
"""Keep the live production-readiness ledger count tied to its table rows."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "docs/compiler-production-readiness.md"
HEADER = re.compile(
    r"^Ledger count: \*\*(\d+) finished or in-worktree evidence slices, "
    r"(\d+) in progress, (\d+) pending umbrella workstreams\*\*\.\s*$"
)


def fail(message: str) -> int:
    print(f"FAIL: readiness-ledger-test - {message}", file=sys.stderr)
    return 1


def main() -> int:
    text = PATH.read_text(encoding="utf-8")
    lines = text.splitlines()
    header = next((HEADER.match(line) for line in lines if line.startswith("Ledger count:")), None)
    if header is None:
        return fail("ledger header is missing or does not use the evidence-slice format")

    finished, in_progress, pending = map(int, header.groups())
    try:
        start = lines.index("### Finished Or In Worktree") + 1
        end = lines.index("### In Progress")
    except ValueError:
        return fail("finished or in-progress ledger headings are missing")

    rows = [line for line in lines[start:end] if line.startswith("| ") and not line.startswith("| Item |")]
    if finished != len(rows):
        return fail(f"header says {finished} finished/in-worktree rows, table contains {len(rows)}")
    if in_progress != 0:
        return fail(f"header says {in_progress} in-progress rows; update the table and this guard together")
    if pending != 3:
        return fail(f"header says {pending} pending umbrellas; update the closure matrix and this guard together")

    print(f"PASS: readiness-ledger-test - {finished} evidence slices, {pending} pending umbrellas")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
