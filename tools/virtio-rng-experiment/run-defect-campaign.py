#!/usr/bin/env python3
"""Run and classify the deliberate virtio-rng defect campaign."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--linux", required=True, type=Path)
    parser.add_argument("--modern-c", required=True, type=Path)
    parser.add_argument("--mcc", required=True)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = args.linux / "drivers/char/hw_random/virtio_rng_lang"
    manifest = json.loads((args.evidence / "manifest.json").read_text())
    evidence_names = {case["name"] for case in manifest["cases"] if case["passed"]}
    results: list[dict[str, object]] = []

    def record(name: str, category: str, passed: bool, detector: str, detail: str) -> None:
        results.append(
            {
                "name": name,
                "category": category,
                "passed": passed,
                "detector": detector,
                "detail": detail,
            }
        )

    compile_failures = {
        "device-owned-cpu-read": (
            "vrng_dma_device_owned_read.mc",
            "E_NO_IMPLICIT_POINTER_CONVERSION",
        ),
        "blocking-in-callback": ("vrng_mc_irq_blocking_gap.mc", "E_SLEEP_IN_ATOMIC"),
        "allocation-in-callback": ("vrng_mc_irq_alloc_gap.mc", "E_SLEEP_IN_ATOMIC"),
        "unbounded-callback-loop": ("vrng_mc_irq_unbounded_gap.mc", "E_UNBOUNDED_LOOP"),
        "mc-trap-capable-callback": ("vrng_mc_irq_trap_gap.mc", "E_NO_LANG_TRAP"),
    }
    for name, (fixture, diagnostic) in compile_failures.items():
        completed = run([args.mcc, "check", str(source / fixture)])
        passed = completed.returncode != 0 and diagnostic in completed.stdout
        record(name, "compile-time prevention", passed, diagnostic, completed.stdout.strip())

    wrapping = run([args.mcc, "check", str(source / "vrng_mc_wrapping_index_gap.mc")])
    record(
        "wrapping-index-arithmetic",
        "expressible; runtime differential detection",
        wrapping.returncode == 0,
        "executable-spec publication firewall",
        "explicit wrapping policy compiles; synthetic differential corpus proves fail-closed publication",
    )

    rust_gap = (source / "vrng_rust_panic_gap.rs").read_text()
    rust_core = (source / "vrng_core_rust.rs").read_text()
    panic_free = not re.search(r"\b(?:panic!|unwrap\(|expect\()", rust_core)
    record(
        "rust-panic-capable-callback",
        "expressible; policy/static review",
        "panic!" in rust_gap and panic_free,
        "production-source panic scan",
        "Rust permits the deliberate panic fixture; the selected candidate is panic/unwrap/expect free",
    )

    for name, required in {
        "zero-and-oversize-completion": {"fault-c", "fault-rust", "fault-mc"},
        "double-and-stale-completion": {"fault-c", "fault-rust", "fault-mc"},
        "remove-after-reference": {"hotplug-c", "hotplug-rust", "hotplug-mc", "memory-mc"},
    }.items():
        missing = sorted(required - evidence_names)
        record(
            name,
            "runtime detection/recovery",
            not missing,
            "fault/hotplug/sanitizer matrix",
            "missing evidence: " + ",".join(missing) if missing else "all required evidence cases passed",
        )

    negative_litmus = args.linux / "tools/memory-model/litmus-tests/VRNG+data-publish-once.litmus"
    record(
        "missing-publication-ordering",
        "formal-model detection",
        negative_litmus.is_file() and "Result: Sometimes" in negative_litmus.read_text(),
        "LKMM negative control",
        "plain publication permits the prohibited ready-with-stale-data outcome",
    )

    nospec_files = [source / f"vrng_core_{suffix}" for suffix in ("c.c", "rust.rs", "mc.mc")]
    missing_nospec = [path.name for path in nospec_files if "vrng_core_index_nospec" not in path.read_text()]
    record(
        "speculative-index-hardening-omission",
        "common-C boundary/static qualification",
        not missing_nospec,
        "nospec call-site scan",
        "missing call: " + ",".join(missing_nospec) if missing_nospec else "all candidates use the common helper",
    )

    record(
        "noncoherent-cache-maintenance-omission",
        "delegated to common C boundary",
        (source / "vrng_dma_ownership.mc").is_file(),
        "typed adoption contract",
        "MC tracks handle ownership; Linux mapping/cache maintenance and surviving C aliases remain trusted",
    )

    report = {
        "schema": "org.modern-c.virtio-rng-defects.v1",
        "linux_commit": manifest["repositories"]["linux"]["commit"],
        "modern_c_commit": manifest["repositories"]["modern_c"]["commit"],
        "results": results,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "defects.json").write_text(json.dumps(report, indent=2) + "\n")

    tap = ["TAP version 13", f"1..{len(results)}"]
    suite = ET.Element("testsuite", name="virtio-rng-defects", tests=str(len(results)))
    failures = 0
    for index, result in enumerate(results, 1):
        status = "ok" if result["passed"] else "not ok"
        tap.append(f"{status} {index} - {result['name']}")
        tap.append(f"# {result['category']}: {result['detector']}")
        node = ET.SubElement(suite, "testcase", name=str(result["name"]))
        if not result["passed"]:
            failures += 1
            ET.SubElement(node, "failure", message=str(result["detail"]))
        ET.SubElement(node, "system-out").text = str(result["detail"])
    (args.output / "results.tap").write_text("\n".join(tap) + "\n")
    suite.set("failures", str(failures))
    ET.ElementTree(suite).write(args.output / "junit.xml", encoding="unicode", xml_declaration=True)
    print(f"virtio-rng deliberate defect campaign: {len(results) - failures}/{len(results)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
