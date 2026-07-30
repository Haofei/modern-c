#!/usr/bin/env python3
"""Validate the pilot gate manifest against build registration and tiers."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "gate-manifest.json"
PROFILE_MANIFEST = ROOT / "docs" / "profile-manifest.json"
BUILD_DIR = ROOT / "build"
TIERS = BUILD_DIR / "tiers.zig"

REQUIRED_FIELDS = {
    "id",
    "owner",
    "category",
    "tier",
    "required_tools",
    "blocking_profiles",
    "build_tiers",
    "skip_policy",
}
KNOWN_EXECUTION_TIERS = {"pr", "nightly", "release"}
KNOWN_BUILD_TIERS = {"m0", "fast", "c0"}
KNOWN_SKIP_POLICIES = {"no-skip", "tool-required", "documented-skip"}


def fail(message: str) -> None:
    print(f"FAIL: gate-manifest-test - {message}", file=sys.stderr)
    sys.exit(1)


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        fail(f"missing {path.relative_to(ROOT)}")
    except json.JSONDecodeError as exc:
        fail(f"{path.relative_to(ROOT)} is not valid JSON: {exc}")


def registered_gates() -> set[str]:
    gates: set[str] = set()
    for path in BUILD_DIR.glob("*.zig"):
        text = path.read_text(encoding="utf-8")
        gates.update(re.findall(r'addScriptTest(?:Opts)?\(\s*ctx,\s*"([^"]+)"', text))
        gates.update(re.findall(r'addRawCmd\(\s*ctx,\s*"([^"]+)"', text))
        gates.update(re.findall(r'(?:ctx\.)?b\.step\(\s*"([^"]+)"', text))
        gates.update(re.findall(r'ctx\.cmds\.put\(\s*"([^"]+)"', text))
    return gates


def block_after(source: str, start: str, end: str) -> str:
    start_index = source.find(start)
    if start_index < 0:
        fail(f"cannot find tiers block start {start!r}")
    end_index = source.find(end, start_index)
    if end_index < 0:
        fail(f"cannot find tiers block end {end!r}")
    return source[start_index:end_index]


def tier_dependencies() -> dict[str, set[str]]:
    source = TIERS.read_text(encoding="utf-8")
    blocks = {
        "m0": block_after(source, 'const m0_step = b.step("m0"', 'const fast_step = b.step("fast"'),
        "fast": block_after(source, 'const fast_step = b.step("fast"', 'const c0_step = b.step("c0"'),
        "c0": block_after(source, 'const c0_step = b.step("c0"', 'const c1_step = b.step("c1"'),
    }
    return {
        tier: set(re.findall(rf'{tier}_step\.dependOn\(ctx\.cmd\("([^"]+)"\)\);', block))
        for tier, block in blocks.items()
    }


def string_list(gate_id: str, gate: dict[str, Any], field: str) -> list[str]:
    value = gate.get(field)
    if not isinstance(value, list) or not value:
        fail(f"gate {gate_id} must define non-empty {field}")
    for item in value:
        if not isinstance(item, str) or not item:
            fail(f"gate {gate_id} has invalid {field} item {item!r}")
    return value


def main() -> None:
    manifest = load_json(MANIFEST)
    if manifest.get("schema_version") != 1:
        fail("schema_version must be 1")
    if manifest.get("profiles") != "docs/profile-manifest.json":
        fail("profiles must point at docs/profile-manifest.json")

    profiles_manifest = load_json(PROFILE_MANIFEST)
    known_profiles = {
        profile["id"]
        for profile in profiles_manifest.get("profiles", [])
        if isinstance(profile, dict) and isinstance(profile.get("id"), str)
    }
    if not known_profiles:
        fail("profile manifest contains no profiles")

    tiers = manifest.get("tiers")
    if not isinstance(tiers, dict) or set(tiers) != KNOWN_EXECUTION_TIERS:
        fail("tiers must define exactly pr, nightly, and release")

    gates = manifest.get("gates")
    if not isinstance(gates, list) or not gates:
        fail("manifest must define a non-empty gates list")

    known_gates = registered_gates()
    dependencies = tier_dependencies()
    seen: set[str] = set()
    owners: set[str] = set()

    for gate in gates:
        if not isinstance(gate, dict):
            fail("each gate must be an object")
        missing = sorted(REQUIRED_FIELDS - set(gate))
        gate_id = gate.get("id")
        if not isinstance(gate_id, str) or not gate_id:
            fail("each gate must define a non-empty id")
        if missing:
            fail(f"gate {gate_id} missing fields: {', '.join(missing)}")
        if gate_id in seen:
            fail(f"duplicate gate id {gate_id}")
        seen.add(gate_id)

        for scalar in ("owner", "category", "tier", "skip_policy"):
            if not isinstance(gate.get(scalar), str) or not gate[scalar]:
                fail(f"gate {gate_id} must define non-empty {scalar}")
        owners.add(gate["owner"])

        if gate["tier"] not in KNOWN_EXECUTION_TIERS:
            fail(f"gate {gate_id} uses unknown execution tier {gate['tier']}")
        if gate["skip_policy"] not in KNOWN_SKIP_POLICIES:
            fail(f"gate {gate_id} uses unknown skip policy {gate['skip_policy']}")
        if gate_id not in known_gates:
            fail(f"gate {gate_id} is not registered in build/*.zig")

        unknown_profiles = sorted(set(string_list(gate_id, gate, "blocking_profiles")) - known_profiles)
        if unknown_profiles:
            fail(f"gate {gate_id} references unknown profiles: {', '.join(unknown_profiles)}")
        string_list(gate_id, gate, "required_tools")
        build_tiers = string_list(gate_id, gate, "build_tiers")
        unknown_build_tiers = sorted(set(build_tiers) - KNOWN_BUILD_TIERS)
        if unknown_build_tiers:
            fail(f"gate {gate_id} references unknown build tiers: {', '.join(unknown_build_tiers)}")

        for build_tier in build_tiers:
            if gate_id not in dependencies[build_tier]:
                fail(f"gate {gate_id} is missing from {build_tier}_step dependencies")

    if len(gates) < 10:
        fail("pilot manifest must cover at least 10 existing compiler-core gates")
    if len(owners) < 5:
        fail("pilot manifest should cover multiple ownership domains")

    print(
        "PASS: gate-manifest-test - "
        f"{len(gates)} pilot gates, {len(owners)} owners, {len(known_profiles)} profiles"
    )


if __name__ == "__main__":
    main()
