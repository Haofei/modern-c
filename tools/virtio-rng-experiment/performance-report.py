#!/usr/bin/env python3
"""Summarize raw virtio-rng performance and engineering measurements."""

from __future__ import annotations

import argparse
import csv
import json
import platform
import re
import statistics
import subprocess
from collections import defaultdict
from pathlib import Path


def command(*args: str) -> str:
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return f"unavailable: {error}"


def git_metadata(path: Path) -> dict[str, object]:
    try:
        status = subprocess.check_output(
            ("git", "status", "--porcelain", "--untracked-files=normal"),
            cwd=path,
            text=True,
        ).strip()
        commit = subprocess.check_output(("git", "rev-parse", "HEAD"), cwd=path, text=True).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return {"path": str(path), "error": str(error)}
    return {
        "path": str(path.resolve()),
        "commit": commit,
        "dirty": bool(status),
        "status": status.splitlines() if status else [],
    }


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * fraction))]


def source_metrics(path: Path) -> dict[str, int]:
    text = path.read_text()
    return {
        "lines": len(text.splitlines()),
        "unsafe_markers": len(re.findall(r"\bunsafe\b", text)),
        "ffi_markers": len(re.findall(r"\b(?:extern|EXPORT_SYMBOL|no_mangle)\b", text)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--linux", required=True, type=Path)
    parser.add_argument("--modern-c", required=True, type=Path)
    parser.add_argument("--linux-commit")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--live", action="append", default=[])
    parser.add_argument("--host-context", default="containerized benchmark; see environment metadata")
    args = parser.parse_args()
    source = args.linux / "drivers/char/hw_random/virtio_rng_lang"

    grouped: dict[tuple[str, str], list[float]] = defaultdict(list)
    with (args.output / "microbench.csv").open() as stream:
        for row in csv.DictReader(stream):
            grouped[(row["language"], row["benchmark"])].append(float(row["ns_per_operation"]))
    microbench = []
    for (language, benchmark), values in sorted(grouped.items()):
        microbench.append(
            {
                "language": language,
                "benchmark": benchmark,
                "samples": len(values),
                "median_ns": statistics.median(values),
                "mean_ns": statistics.mean(values),
                "stdev_ns": statistics.pstdev(values),
                "p95_ns": percentile(values, 0.95),
                "min_ns": min(values),
                "max_ns": max(values),
            }
        )

    throughput = []
    for assignment in args.live:
        name, path = assignment.split("=", 1)
        text = Path(path).read_text(errors="replace")
        rates = re.findall(r"\b([0-9]+(?:\.[0-9]+)?)([KMG]?B)/s\b", text)
        throughput.append({"name": name, "reported_rates": ["".join(rate) + "/s" for rate in rates]})

    objects = {}
    for language in ("c", "rust", "mc"):
        path = args.output / f"vrng_core_{language}.o"
        stack_sizes = command("llvm-readobj", "--stack-sizes", str(path))
        parsed_stack_sizes = [int(value, 16) for value in re.findall(r"Size: (0x[0-9A-Fa-f]+)", stack_sizes)]
        objects[language] = {
            "bytes": path.stat().st_size,
            "sections": command("size", "-A", str(path)),
            "undefined": command("nm", "-u", str(path)).splitlines(),
            "maximum_reported_stack_bytes": max(parsed_stack_sizes, default=None),
            "stack_sizes": stack_sizes,
        }

    sources = {
        "c_core": source_metrics(source / "vrng_core_c.c"),
        "rust_core": source_metrics(source / "vrng_core_rust.rs"),
        "mc_core": source_metrics(source / "vrng_core_mc.mc"),
        "common_glue": source_metrics(args.linux / "drivers/char/hw_random/virtio-rng.c"),
        "shadow_firewall": source_metrics(source / "vrng_shadow.c"),
    }
    report = {
        "schema": "org.modern-c.virtio-rng-performance.v1",
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "uname": " ".join(platform.uname()),
            "clang": command("clang", "--version").splitlines()[0],
            "rustc": command("rustc", "--version"),
            "qemu": command("qemu-system-x86_64", "--version").splitlines()[0],
            "cpu": command("lscpu"),
        },
        "repositories": {
            "linux": (
                {"path": str(args.linux), "commit": args.linux_commit,
                 "dirty": False, "status": [], "source": "git-archive"}
                if args.linux_commit else git_metadata(args.linux)
            ),
            "modern_c": git_metadata(args.modern_c),
        },
        "limitations": [
            args.host_context,
            "QEMU throughput is TCG and backend/rate limited; it is not bare-metal latency",
            "reported dd rates are integration observations, not controlled throughput distributions",
            "completion-to-wakeup latency and hardware instructions/branches are unavailable under this TCG-only host",
        ],
        "microbench": microbench,
        "qemu_throughput": throughput,
        "objects": objects,
        "sources": sources,
        "build_times": list(csv.DictReader((args.output / "build-times.csv").open())),
    }
    (args.output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")

    lines = ["# virtio-rng performance summary", "", "## Host microbenchmark", ""]
    lines.append("| Language | Benchmark | Median ns | p95 ns | Min-Max ns |")
    lines.append("| --- | --- | ---: | ---: | ---: |")
    for row in microbench:
        lines.append(
            f"| {row['language']} | {row['benchmark']} | {row['median_ns']:.3f} | "
            f"{row['p95_ns']:.3f} | {row['min_ns']:.3f}-{row['max_ns']:.3f} |"
        )
    lines.extend(["", "## Object and source metrics", ""])
    lines.append("| Language | Object bytes | Max reported stack | Source lines | Unsafe markers |")
    lines.append("| --- | ---: | ---: | ---: | ---: |")
    for language in ("c", "rust", "mc"):
        source_row = sources[f"{language}_core"]
        lines.append(
            f"| {language} | {objects[language]['bytes']} | "
            f"{objects[language]['maximum_reported_stack_bytes']} | {source_row['lines']} | "
            f"{source_row['unsafe_markers']} |"
        )
    lines.extend(["", "## Interpretation", ""])
    lines.extend(f"- {item}" for item in report["limitations"])
    (args.output / "summary.md").write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
