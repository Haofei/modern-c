#!/usr/bin/env python3
"""Check the fallback census admission baseline.

The human census report is intentionally broad and best-effort.  This checker is
the gate counterpart: it consumes a deterministic census JSONL produced by
fallback-census.sh --check and ensures C/LLVM admission coverage and headline
counts do not regress from the checked-in baseline.
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = ROOT / "tools" / "toolchain" / "fallback-census-baseline.tsv"
REPORT = ROOT / "tools" / "toolchain" / "fallback-census-report.py"

REQUIRED_COLUMNS = (
    "backend",
    "total_min",
    "admitted_min",
    "fallback_max",
    "unsupported_max",
    "admission_bps_min",
    "canonical_min",
    "specialized_max",
    "specialized_plan_defs_max",
)

PLAN_DEFINITION_ANCHORS = {
    "c": (ROOT / "src/lower_c_emitter.zig", "const specialized_plans = [_]bool{"),
    "llvm": (ROOT / "src/lower_llvm.zig", "const specialized_plans = [_]bool{"),
}


def fail(message: str) -> int:
    print(f"FAIL: fallback-census-ratchet-test - {message}", file=sys.stderr)
    return 1


def load_report_module() -> Any:
    spec = importlib.util.spec_from_file_location("fallback_census_report", REPORT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {REPORT.relative_to(ROOT)}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_int(value: str, field: str, line_no: int) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise AssertionError(f"baseline line {line_no}: {field} must be an integer, got {value!r}") from exc
    if parsed < 0:
        raise AssertionError(f"baseline line {line_no}: {field} must be non-negative")
    return parsed


def load_baseline(path: Path) -> dict[str, dict[str, int]]:
    if not path.is_file():
        raise AssertionError(f"missing baseline {path.relative_to(ROOT)}")

    rows: dict[str, dict[str, int]] = {}
    header: list[str] | None = None
    with path.open("r", encoding="utf-8") as handle:
        for line_no, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if header is None:
                header = fields
                if tuple(header) != REQUIRED_COLUMNS:
                    raise AssertionError(
                        f"baseline header must be tab-separated {'/'.join(REQUIRED_COLUMNS)}, got {'/'.join(header)}"
                    )
                continue
            if len(fields) != len(header):
                raise AssertionError(f"baseline line {line_no}: expected {len(header)} columns, got {len(fields)}")
            row = dict(zip(header, fields))
            backend = row["backend"]
            if backend in rows:
                raise AssertionError(f"baseline line {line_no}: duplicate backend {backend!r}")
            rows[backend] = {
                "total_min": parse_int(row["total_min"], "total_min", line_no),
                "admitted_min": parse_int(row["admitted_min"], "admitted_min", line_no),
                "fallback_max": parse_int(row["fallback_max"], "fallback_max", line_no),
                "unsupported_max": parse_int(row["unsupported_max"], "unsupported_max", line_no),
                "admission_bps_min": parse_int(row["admission_bps_min"], "admission_bps_min", line_no),
                "canonical_min": parse_int(row["canonical_min"], "canonical_min", line_no),
                "specialized_max": parse_int(row["specialized_max"], "specialized_max", line_no),
                "specialized_plan_defs_max": parse_int(row["specialized_plan_defs_max"], "specialized_plan_defs_max", line_no),
            }

    if header is None:
        raise AssertionError(f"baseline {path.relative_to(ROOT)} has no header")
    if not rows:
        raise AssertionError(f"baseline {path.relative_to(ROOT)} has no backend rows")
    return rows


def check_backend(backend: str, expected: dict[str, int], actual: dict[str, Any], failures: list[str]) -> None:
    comparisons = (
        ("total", ">=", "total_min"),
        ("admitted", ">=", "admitted_min"),
        ("fallback", "<=", "fallback_max"),
        ("unsupported", "<=", "unsupported_max"),
        ("admission_bps", ">=", "admission_bps_min"),
        ("canonical_admitted", ">=", "canonical_min"),
        ("specialized_admitted", "<=", "specialized_max"),
    )
    for actual_field, op, expected_field in comparisons:
        actual_value = int(actual[actual_field])
        expected_value = expected[expected_field]
        if op == ">=" and actual_value < expected_value:
            failures.append(
                f"{backend}: {actual_field} regressed to {actual_value}, below baseline {expected_field}={expected_value}"
            )
        elif op == "<=" and actual_value > expected_value:
            failures.append(
                f"{backend}: {actual_field} regressed to {actual_value}, above baseline {expected_field}={expected_value}"
            )


def specialized_plan_definition_count(backend: str) -> int:
    path, anchor = PLAN_DEFINITION_ANCHORS[backend]
    text = path.read_text(encoding="utf-8")
    start = text.find(anchor)
    if start < 0:
        raise AssertionError(f"{path.relative_to(ROOT)} is missing specialized-plan anchor {anchor!r}")
    end = text.find("};", start)
    if end < 0:
        raise AssertionError(f"{path.relative_to(ROOT)} has an unterminated specialized-plan registry")
    registry = text[start:end]
    return len(re.findall(r"\b[a-z][a-z0-9_]* != null", registry))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("census", type=Path, help="fallback census JSONL produced by fallback-census.sh --check")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    args = parser.parse_args()

    try:
        baseline = load_baseline(args.baseline)
        report = load_report_module()
        summaries = report.summarize_by_backend(str(args.census))
        if not summaries:
            raise AssertionError(f"{args.census} contains no census records")

        failures: list[str] = []
        for backend, expected in sorted(baseline.items()):
            actual = summaries.get(backend)
            if actual is None:
                failures.append(f"missing backend {backend!r} in census")
                continue
            check_backend(backend, expected, actual, failures)
            plan_defs = specialized_plan_definition_count(backend)
            if plan_defs > expected["specialized_plan_defs_max"]:
                failures.append(
                    f"{backend}: specialized plan definitions grew to {plan_defs}, "
                    f"above specialized_plan_defs_max={expected['specialized_plan_defs_max']}"
                )

        if failures:
            return fail("\n  - " + "\n  - ".join(failures))
    except AssertionError as exc:
        return fail(str(exc))

    checked = ", ".join(
        f"{backend}: total={summaries[backend]['total']} admitted={summaries[backend]['admitted']} "
        f"fallback={summaries[backend]['fallback']} unsupported={summaries[backend]['unsupported']} "
        f"admission_bps={summaries[backend]['admission_bps']} "
        f"canonical={summaries[backend]['canonical_admitted']} "
        f"specialized={summaries[backend]['specialized_admitted']} "
        f"plan_defs={specialized_plan_definition_count(backend)}"
        for backend in sorted(baseline)
    )
    print(f"PASS: fallback-census-ratchet-test - {checked}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
