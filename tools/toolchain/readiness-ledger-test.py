#!/usr/bin/env python3
"""Keep the live production-readiness ledger count tied to its table rows."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "docs/compiler-production-readiness.md"
HEADER = re.compile(
    r"^Evidence register: \*\*(\d+) bounded implementation or regression entries, "
    r"(\d+) active slices, (\d+) open architectural workstreams?\*\*\.\s*$"
)


def fail(message: str) -> int:
    print(f"FAIL: readiness-ledger-test - {message}", file=sys.stderr)
    return 1


def main() -> int:
    text = PATH.read_text(encoding="utf-8")
    lines = text.splitlines()
    header = next((HEADER.match(line) for line in lines if line.startswith("Evidence register:")), None)
    if header is None:
        return fail("evidence-register header is missing or does not use the required format")

    evidence, active, open_workstreams = map(int, header.groups())
    try:
        start = lines.index("### Evidence Register") + 1
        end = lines.index("### Bounded Workstream Status")
    except ValueError:
        return fail("evidence-register or bounded-workstream headings are missing")

    rows = [line for line in lines[start:end] if line.startswith("| ") and not line.startswith("| Item |")]
    if evidence != len(rows):
        return fail(f"header says {evidence} evidence entries, table contains {len(rows)}")
    if active != 0:
        return fail(f"header says {active} active slices; update the table and this guard together")
    if open_workstreams != 0:
        return fail(f"header says {open_workstreams} open workstreams; update the closure matrices and this guard together")

    print(f"PASS: readiness-ledger-test - {evidence} evidence entries, {open_workstreams} open workstreams")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
