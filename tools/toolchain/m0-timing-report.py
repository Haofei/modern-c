#!/usr/bin/env python3
"""Turn the persisted m0-parallel gate timings into a stable bottleneck report."""

import argparse
import csv
from pathlib import Path


def die(message: str) -> None:
    raise SystemExit(f"m0-timing-report: {message}")


def parse_rows(path: Path) -> list[tuple[str, int, int]]:
    rows: list[tuple[str, int, int]] = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            die(f"{path}:{number}: expected gate, elapsed-ms, result")
        gate, elapsed_text, result_text = fields
        try:
            elapsed_ms = int(elapsed_text)
            result = int(result_text)
        except ValueError:
            die(f"{path}:{number}: elapsed-ms and result must be integers")
        if not gate or elapsed_ms < 0 or result < 0:
            die(f"{path}:{number}: invalid timing row")
        rows.append((gate, elapsed_ms, result))
    if not rows:
        die(f"{path}: no timing rows")
    return sorted(rows, key=lambda row: (-row[1], row[0]))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--tsv", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--wall-ms", required=True, type=int)
    parser.add_argument("--outer-jobs", required=True, type=int)
    parser.add_argument("--inner-jobs", required=True, type=int)
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args()

    if args.wall_ms < 0 or args.outer_jobs < 1 or args.inner_jobs < 1 or args.top < 1:
        die("wall-ms must be non-negative; jobs and top must be positive")
    rows = parse_rows(args.input)
    total_ms = sum(row[1] for row in rows)
    args.tsv.parent.mkdir(parents=True, exist_ok=True)
    with args.tsv.open("w", newline="") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        writer.writerow(("rank", "gate", "elapsed_ms", "result", "share_of_gate_time_pct"))
        for rank, (gate, elapsed_ms, result) in enumerate(rows, 1):
            share = 0.0 if total_ms == 0 else elapsed_ms * 100.0 / total_ms
            writer.writerow((rank, gate, elapsed_ms, result, f"{share:.2f}"))

    args.summary.parent.mkdir(parents=True, exist_ok=True)
    parallelism = 0.0 if args.wall_ms == 0 else total_ms / args.wall_ms
    with args.summary.open("w") as handle:
        handle.write("m0 timing report\n")
        handle.write(
            f"wall_ms={args.wall_ms}\tgate_sum_ms={total_ms}\t"
            f"effective_parallelism={parallelism:.2f}\touter_jobs={args.outer_jobs}\tinner_jobs={args.inner_jobs}\n"
        )
        handle.write("rank\tgate\telapsed_ms\tresult\tshare_of_gate_time_pct\n")
        for rank, (gate, elapsed_ms, result) in enumerate(rows[: args.top], 1):
            share = 0.0 if total_ms == 0 else elapsed_ms * 100.0 / total_ms
            handle.write(f"{rank}\t{gate}\t{elapsed_ms}\t{result}\t{share:.2f}\n")


if __name__ == "__main__":
    main()
