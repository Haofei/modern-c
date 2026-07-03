#!/usr/bin/env python3
"""Run nightly QEMU microbenchmarks and compare them to committed tolerances."""

from __future__ import annotations

import argparse
import csv
import math
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_BASELINE = ROOT / "tools/bench/nightly-baseline.tsv"
DEFAULT_OUTPUT = ROOT / "zig-out/nightly-bench-results.tsv"
DEFAULT_LOG_DIR = ROOT / "zig-out/nightly-bench-logs"


@dataclass(frozen=True)
class Bench:
    benchmark: str
    backend: str
    target: str
    metrics: tuple[str, ...]


EXPECTED_BENCHES: tuple[Bench, ...] = (
    Bench("mem", "selfhost", "mem-bench", ("MEMCPY-CYCLES", "MEMSET-CYCLES")),
    Bench("mem", "llvm", "llvm-mem-bench", ("MEMCPY-CYCLES", "MEMSET-CYCLES")),
    Bench(
        "uaccess",
        "selfhost",
        "uaccess-bench",
        ("UACCESS-TO-CYCLES", "UACCESS-FROM-CYCLES", "UACCESS-SMALL-CYCLES", "UACCESS-CYCLES"),
    ),
    Bench(
        "uaccess",
        "llvm",
        "llvm-uaccess-bench",
        ("UACCESS-TO-CYCLES", "UACCESS-FROM-CYCLES", "UACCESS-SMALL-CYCLES", "UACCESS-CYCLES"),
    ),
    Bench("sched", "selfhost", "sched-bench", ("SCHED-CYCLES",)),
    Bench("sched", "llvm", "llvm-sched-bench", ("SCHED-CYCLES",)),
    Bench("heap", "selfhost", "heap-bench", ("HEAPFREE-CYCLES",)),
    Bench("heap", "llvm", "llvm-heap-bench", ("HEAPFREE-CYCLES",)),
    Bench("ipc", "selfhost", "ipc-bench", ("IPC-CYCLES",)),
    Bench("ipc", "llvm", "llvm-ipc-bench", ("IPC-CYCLES",)),
)

BASELINE_COLUMNS = (
    "benchmark",
    "backend",
    "target",
    "metric",
    "baseline",
    "tolerance_pct",
    "tolerance_abs",
)
RESULT_COLUMNS = BASELINE_COLUMNS + ("value", "max_allowed", "status")


def expected_keys() -> set[tuple[str, str, str, str]]:
    keys: set[tuple[str, str, str, str]] = set()
    for bench in EXPECTED_BENCHES:
        for metric in bench.metrics:
            keys.add((bench.benchmark, bench.backend, bench.target, metric))
    return keys


def fail(message: str) -> None:
    print(f"FAIL: nightly-bench - {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_number(raw: str, field: str, row_id: str) -> float:
    try:
        value = float(raw)
    except ValueError:
        fail(f"{row_id} has non-numeric {field}: {raw!r}")
    if not math.isfinite(value):
        fail(f"{row_id} has non-finite {field}: {raw!r}")
    return value


def load_baseline(path: pathlib.Path) -> dict[tuple[str, str, str, str], dict[str, float | str]]:
    if not path.is_file():
        fail(f"baseline TSV not found: {path}")

    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        if tuple(reader.fieldnames or ()) != BASELINE_COLUMNS:
            fail(f"{path} header must be: {' '.join(BASELINE_COLUMNS)}")

        rows: dict[tuple[str, str, str, str], dict[str, float | str]] = {}
        for row in reader:
            key = (row["benchmark"], row["backend"], row["target"], row["metric"])
            row_id = "/".join(key)
            if key in rows:
                fail(f"duplicate baseline row: {row_id}")
            baseline = parse_number(row["baseline"], "baseline", row_id)
            tolerance_pct = parse_number(row["tolerance_pct"], "tolerance_pct", row_id)
            tolerance_abs = parse_number(row["tolerance_abs"], "tolerance_abs", row_id)
            if baseline <= 0:
                fail(f"{row_id} baseline must be > 0")
            if tolerance_pct < 0 or tolerance_abs < 0:
                fail(f"{row_id} tolerances must be >= 0")
            rows[key] = {
                "benchmark": row["benchmark"],
                "backend": row["backend"],
                "target": row["target"],
                "metric": row["metric"],
                "baseline": baseline,
                "tolerance_pct": tolerance_pct,
                "tolerance_abs": tolerance_abs,
            }

    want = expected_keys()
    got = set(rows)
    missing = sorted(want - got)
    extra = sorted(got - want)
    if missing:
        fail(f"baseline missing expected rows: {missing}")
    if extra:
        fail(f"baseline has unexpected rows: {extra}")
    return rows


def run_command(command: list[str], cwd: pathlib.Path) -> tuple[int, str]:
    proc = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return proc.returncode, proc.stdout


def metric_pattern(metric: str) -> re.Pattern[str]:
    return re.compile(rf"^{re.escape(metric)}\s+([0-9]+(?:\.[0-9]+)?)\b", re.MULTILINE)


def parse_metrics(output: str, bench: Bench) -> dict[str, float]:
    values: dict[str, float] = {}
    for metric in bench.metrics:
        match = metric_pattern(metric).search(output)
        if not match:
            if re.search(rf"^{re.escape(metric)}\b", output, re.MULTILINE):
                fail(f"{bench.target} printed {metric} without a numeric value")
            fail(f"{bench.target} did not print required metric {metric}")
        value = parse_number(match.group(1), metric, bench.target)
        if value <= 0:
            fail(f"{bench.target}/{metric} must be > 0, got {value:g}")
        values[metric] = value
    if bench.benchmark == "uaccess":
        large_copy_sum = values["UACCESS-TO-CYCLES"] + values["UACCESS-FROM-CYCLES"]
        if values["UACCESS-CYCLES"] != large_copy_sum:
            fail(
                f"{bench.target}/UACCESS-CYCLES must equal UACCESS-TO-CYCLES + "
                f"UACCESS-FROM-CYCLES ({values['UACCESS-CYCLES']:g} != {large_copy_sum:g})"
            )
    return values


def write_log(log_dir: pathlib.Path, bench: Bench, output: str) -> None:
    log_dir.mkdir(parents=True, exist_ok=True)
    (log_dir / f"{bench.target}.log").write_text(output, encoding="utf-8")


def compare_row(row: dict[str, float | str], value: float) -> tuple[float, str]:
    baseline = float(row["baseline"])
    tolerance_pct = float(row["tolerance_pct"])
    tolerance_abs = float(row["tolerance_abs"])
    max_allowed = baseline * (1.0 + tolerance_pct / 100.0) + tolerance_abs
    status = "PASS" if value <= max_allowed else "FAIL"
    return max_allowed, status


def run(args: argparse.Namespace) -> int:
    baseline = load_baseline(args.baseline)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.log_dir.mkdir(parents=True, exist_ok=True)

    if not args.no_install:
        code, output = run_command(["zig", "build", "install"], ROOT)
        write_log(args.log_dir, Bench("build", "host", "install", ()), output)
        if code != 0:
            fail("zig build install failed; see install.log")

    result_rows: list[dict[str, str]] = []
    failures: list[str] = []
    for bench in EXPECTED_BENCHES:
        code, output = run_command(["zig", "build", bench.target], ROOT)
        write_log(args.log_dir, bench, output)
        if code != 0:
            fail(f"zig build {bench.target} failed; see {args.log_dir / (bench.target + '.log')}")
        if re.search(r"^SKIP:", output, re.MULTILINE):
            fail(f"zig build {bench.target} skipped; see {args.log_dir / (bench.target + '.log')}")

        values = parse_metrics(output, bench)
        for metric, value in values.items():
            key = (bench.benchmark, bench.backend, bench.target, metric)
            base = baseline[key]
            max_allowed, status = compare_row(base, value)
            if status != "PASS":
                failures.append(
                    f"{bench.target}/{metric}: {value:g} > allowed {max_allowed:g} "
                    f"(baseline {float(base['baseline']):g}, tolerance {float(base['tolerance_pct']):g}% "
                    f"+ {float(base['tolerance_abs']):g})"
                )
            result_rows.append(
                {
                    "benchmark": bench.benchmark,
                    "backend": bench.backend,
                    "target": bench.target,
                    "metric": metric,
                    "baseline": f"{float(base['baseline']):.0f}",
                    "tolerance_pct": f"{float(base['tolerance_pct']):.0f}",
                    "tolerance_abs": f"{float(base['tolerance_abs']):.0f}",
                    "value": f"{value:.0f}",
                    "max_allowed": f"{max_allowed:.0f}",
                    "status": status,
                }
            )

    with args.output.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=RESULT_COLUMNS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(result_rows)

    if failures:
        for item in failures:
            print(f"FAIL: nightly-bench - {item}", file=sys.stderr)
        print(f"Wrote benchmark results to {args.output}", file=sys.stderr)
        return 1

    print(f"PASS: nightly-bench - wrote {len(result_rows)} metric rows to {args.output}")
    return 0


def check_baseline(args: argparse.Namespace) -> int:
    load_baseline(args.baseline)
    print(f"PASS: nightly-bench - baseline {args.baseline} covers all expected metrics")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    run_parser = sub.add_parser("run", help="run all nightly benchmarks")
    run_parser.add_argument("--baseline", type=pathlib.Path, default=DEFAULT_BASELINE)
    run_parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    run_parser.add_argument("--log-dir", type=pathlib.Path, default=DEFAULT_LOG_DIR)
    run_parser.add_argument("--no-install", action="store_true", help="skip the initial zig build install")
    run_parser.set_defaults(func=run)

    check_parser = sub.add_parser("check-baseline", help="validate committed baseline schema")
    check_parser.add_argument("--baseline", type=pathlib.Path, default=DEFAULT_BASELINE)
    check_parser.set_defaults(func=check_baseline)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
