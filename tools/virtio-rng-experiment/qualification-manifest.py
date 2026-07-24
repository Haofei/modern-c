#!/usr/bin/env python3
"""Write a reproducible virtio-rng qualification manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import re
import subprocess
from pathlib import Path

LINUX_BASE_COMMIT = "1590cf0329716306e948a8fc29f1d3ee87d3989f"


def command(*argv: str, cwd: Path | None = None) -> str:
    return subprocess.check_output(argv, cwd=cwd, text=True).strip()


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def version(*argv: str) -> str:
    try:
        return command(*argv).splitlines()[0]
    except (FileNotFoundError, subprocess.CalledProcessError):
        return "unavailable"


def git_state(repo: Path) -> dict[str, object]:
    diff = subprocess.check_output(
        ["git", "diff", "--binary", "HEAD", "--"],
        cwd=repo,
    )
    untracked = command(
        "git", "ls-files", "--others", "--exclude-standard", "-z", cwd=repo
    ).encode()
    return {
        "commit": command("git", "rev-parse", "HEAD", cwd=repo),
        "clean": not diff and not untracked,
        "tracked_diff_sha256": hashlib.sha256(diff).hexdigest(),
        "untracked_path_list_sha256": hashlib.sha256(untracked).hexdigest(),
    }


def parse_log(path: Path) -> dict[str, object]:
    text = path.read_text(errors="replace")
    lifecycle = re.findall(
        r"VRNG-LIFECYCLE: sequence=(\d+) device=(\d+) error=(-?\d+) "
        r"stage=(-?\d+) avail=(-?\d+) events=(\d+) mismatches=(\d+)",
        text,
    )
    control = re.findall(
        r"language shadow control=(C|Rust|MC) matched all (\d+) protocol "
        r"and (\d+) driver lifecycle events",
        text,
    )
    return {
        "path": str(path),
        "sha256": digest(path),
        "completed": "VRNG-LIVE: complete" in text,
        "runner_passed": "virtio-rng live " in text and " test passed" in text,
        "lifecycle_records": [
            {
                "sequence": int(row[0]),
                "device_cookie": int(row[1]),
                "teardown_error": int(row[2]),
                "stage": int(row[3]),
                "external_avail": int(row[4]),
                "events": int(row[5]),
                "mismatches": int(row[6]),
            }
            for row in lifecycle
        ],
        "matched_event_summaries": [
            {
                "controller": row[0],
                "protocol_events": int(row[1]),
                "lifecycle_events": int(row[2]),
            }
            for row in control
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--linux", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--kernel", required=True, type=Path)
    parser.add_argument("--initramfs", required=True, type=Path)
    parser.add_argument("--logs", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--command", action="append", default=[])
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[2]
    logs = sorted(path for path in args.logs.glob("*.log") if path.is_file())
    command("git", "cat-file", "-e", f"{LINUX_BASE_COMMIT}^{{commit}}", cwd=args.linux)
    manifest = {
        "schema": 1,
        "modern_c_source": git_state(repo),
        "linux_source": git_state(args.linux),
        "linux_upstream_base_commit": LINUX_BASE_COMMIT,
        "linux_experiment_history_root": command(
            "git", "rev-list", "--max-parents=0", "HEAD", cwd=args.linux
        ),
        "host": platform.platform(),
        "tools": {
            "mcc": version(str(repo / "zig-out/bin/mcc"), "--version"),
            "clang": version("clang", "--version"),
            "rustc": version("rustc", "--version"),
            "zig": version("zig", "version"),
            "qemu": version("qemu-system-x86_64", "--version"),
        },
        "artifacts": {
            "kernel_config": {"path": str(args.config), "sha256": digest(args.config)},
            "kernel": {"path": str(args.kernel), "sha256": digest(args.kernel)},
            "initramfs": {"path": str(args.initramfs), "sha256": digest(args.initramfs)},
        },
        "commands": args.command,
        "logs": [parse_log(path) for path in logs],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
