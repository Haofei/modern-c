#!/usr/bin/env python3
"""Create a self-contained virtio-rng qualification evidence bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path


DIAGNOSTIC = re.compile(
    r"BUG:|WARNING:|KASAN:|KCSAN:|UBSAN:|kernel BUG|possible circular locking|"
    r"blocked for more than|language shadow(?: control=(?:C|Rust|MC))? mismatches="
)


def command(*args: str, cwd: Path | None = None) -> str:
    try:
        return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return f"unavailable: {error}"


def git_metadata(path: Path) -> dict[str, object]:
    status = command("git", "status", "--porcelain", cwd=path)
    return {
        "path": str(path.resolve()),
        "commit": command("git", "rev-parse", "HEAD", cwd=path),
        "branch": command("git", "branch", "--show-current", cwd=path),
        "dirty": bool(status),
        "status": status.splitlines() if status else [],
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_assignment(value: str) -> tuple[str, Path]:
    name, separator, raw_path = value.partition("=")
    if not separator or not name or not raw_path:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    return name, Path(raw_path)


def validate_case(name: str, text: str) -> tuple[bool, str]:
    if DIAGNOSTIC.search(text):
        return False, "kernel diagnostic or shadow mismatch present"
    if "kunit" in name:
        match = re.search(r"# Totals: pass:(\d+) fail:(\d+) skip:(\d+) total:(\d+)", text)
        if not match:
            return False, "KUnit totals missing"
        if int(match.group(2)) != 0:
            return False, f"KUnit failures={match.group(2)}"
        return True, f"KUnit pass={match.group(1)} skip={match.group(3)}"

    required = ["VRNG-LIVE: complete", "matched all"]
    if "fault" in name:
        required.append("VRNG-LIVE: fault matrix passed")
    if "pm" in name:
        required.append("VRNG-LIVE: suspend/restore matrix passed")
    if "hotplug" in name:
        required.append("VRNG-LIVE: transport hot-unplug/replug passed")
    missing = [marker for marker in required if marker not in text]
    if missing:
        return False, "missing marker(s): " + ", ".join(missing)
    events = re.findall(r"matched all (\d+) protocol events", text)
    return True, "protocol events=" + ",".join(events)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--linux", required=True, type=Path)
    parser.add_argument("--modern-c", required=True, type=Path)
    parser.add_argument("--case", action="append", default=[], type=parse_assignment)
    parser.add_argument("--artifact", action="append", default=[], type=parse_assignment)
    parser.add_argument("--skip", action="append", default=[], type=parse_assignment)
    parser.add_argument("--qemu-args", default="")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    evidence = args.output / "evidence"
    evidence.mkdir(exist_ok=True)
    cases: list[dict[str, object]] = []
    artifacts: list[dict[str, object]] = []

    for name, source in args.case:
        if not source.is_file():
            parser.error(f"case file does not exist: {source}")
        target = evidence / f"{name}{source.suffix or '.log'}"
        shutil.copy2(source, target)
        text = source.read_text(errors="replace")
        passed, detail = validate_case(name, text)
        cases.append(
            {
                "name": name,
                "passed": passed,
                "detail": detail,
                "path": str(target.relative_to(args.output)),
                "sha256": sha256(target),
            }
        )

    for name, reason_path in args.skip:
        cases.append(
            {
                "name": name,
                "passed": True,
                "skipped": True,
                "detail": str(reason_path),
                "path": None,
                "sha256": None,
            }
        )

    for name, source in args.artifact:
        if not source.is_file():
            parser.error(f"artifact does not exist: {source}")
        target = evidence / f"{name}{source.suffix}"
        shutil.copy2(source, target)
        artifacts.append(
            {
                "name": name,
                "path": str(target.relative_to(args.output)),
                "bytes": target.stat().st_size,
                "sha256": sha256(target),
            }
        )

    manifest = {
        "schema": "org.modern-c.virtio-rng-results.v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "processor": platform.processor(),
            "uname": " ".join(platform.uname()),
        },
        "tools": {
            "qemu": command("qemu-system-x86_64", "--version").splitlines()[0],
            "clang": command("clang", "--version").splitlines()[0],
            "python": sys.version.splitlines()[0],
        },
        "repositories": {
            "linux": git_metadata(args.linux),
            "modern_c": git_metadata(args.modern_c),
        },
        "qemu_args": args.qemu_args,
        "cases": cases,
        "artifacts": artifacts,
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    tap = ["TAP version 13", f"1..{len(cases)}"]
    for index, case in enumerate(cases, 1):
        status = "ok" if case["passed"] else "not ok"
        directive = f" # SKIP {case['detail']}" if case.get("skipped") else ""
        tap.append(f"{status} {index} - {case['name']}{directive}")
        tap.append(f"# {case['detail']}")
    (args.output / "results.tap").write_text("\n".join(tap) + "\n")

    suite = ET.Element("testsuite", name="virtio-rng", tests=str(len(cases)))
    failures = 0
    for case in cases:
        node = ET.SubElement(suite, "testcase", name=str(case["name"]))
        if case.get("skipped"):
            ET.SubElement(node, "skipped", message=str(case["detail"]))
        elif not case["passed"]:
            failures += 1
            ET.SubElement(node, "failure", message=str(case["detail"]))
        ET.SubElement(node, "system-out").text = str(case["detail"])
    suite.set("failures", str(failures))
    ET.ElementTree(suite).write(args.output / "junit.xml", encoding="unicode", xml_declaration=True)

    print(f"recorded {len(cases)} cases in {args.output}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
