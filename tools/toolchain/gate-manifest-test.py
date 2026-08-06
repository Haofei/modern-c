#!/usr/bin/env python3
"""Validate the gate manifest against build registration and tiers."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "gate-manifest.json"
PROFILE_MANIFEST = ROOT / "docs" / "profile-manifest.json"
RISK_REGISTER = ROOT / "docs" / "review-risk-register.yaml"
REFACTORING_PLAN = ROOT / "docs" / "refactoring-plan.md"
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
KNOWN_CI_PASS_ASSERTIONS = {"ci-m0-pass"}
REQUIRED_GOVERNANCE_GATES = {
    "gate-manifest-test",
    "profile-manifest-test",
    "vendoring-test",
    "third-party-licenses-test",
    "release-metadata-test",
    "package-release-test",
    "ci-pass-gates-test",
}
ARTIFACT_METADATA_ANCHORS: dict[str, list[str]] = {
    "src/backend.zig": [
        "pub const ArtifactBundle = struct",
        "pub fn forArtifact(",
        "pub fn forSourceMap(",
        "pub const ArtifactBundleFormat = enum",
        "pub fn appendArtifactBundle(",
        "pub fn appendArtifactMetadata(",
        "generated_artifact_sha256",
        "source_map_payload_sha256",
    ],
    "src/main.zig": [
        "fn writeArtifactMetadataSidecar(",
        "fn writeArtifactWithMetadata(",
        '.artifact_kind = "c"',
        '.artifact_kind = "llvm-ir"',
        '.artifact_kind = "host-executable"',
    ],
    "src/lower_c_map.zig": [
        "const bundle = backend.ArtifactBundle.forSourceMap(",
        "try backend.appendArtifactBundle(allocator, out, bundle, .source_map)",
    ],
    "tools/toolchain/mcmap-verify.py": [
        'expected_magic=b"# mcmap v1" if args.map is not None else b"# mcmeta v1"',
        "wrong metadata bundle magic",
        "require_header_value(headers, \"artifact_kind\", \"c-source-map\")",
        "require_header_value(headers, \"backend\", \"c\")",
        "if args.artifact_kind is not None:",
        "if args.backend is not None:",
        "expected_artifact_digest = require_sha256_header(headers, \"generated_artifact_sha256\")",
        "expected_map_artifact_digest = require_sha256_header(headers, \"source_map_generated_artifact_sha256\")",
        "expected_payload_digest = require_sha256_header(headers, \"source_map_payload_sha256\")",
        "require_sha256_header(headers, \"mir_facts_sha256\")",
        "if args.source_map_artifact is not None:",
    ],
    "tools/toolchain/mcc-cli-test.sh": [
        "ok.c.mcmeta",
        "ok.ll.mcmeta",
        "ok.c.no-magic.mcmeta",
        "ok.c.no-artifact-digest.mcmeta",
        "ok.c.no-source-map-payload.mcmeta",
        "metadata verifier accepted a sidecar without the mcmeta magic",
        "metadata verifier accepted a sidecar without generated_artifact_sha256",
        "metadata verifier accepted an incomplete source-map digest binding",
        "metadata verifier accepted C sidecar as LLVM IR",
        "metadata verifier accepted LLVM sidecar as C",
        "# artifact_kind=c",
        "# artifact_kind=llvm-ir",
    ],
    "tools/toolchain/mcc-build-test.sh": [
        "ok.mcmeta",
        "# artifact_kind=host-executable",
        "metadata verifier accepted executable sidecar as C source",
        "sha256=[0-9a-f]{64}",
        "directory output target did not fail closed",
        "directory output failure leaked temporary build artifacts",
        "directory output failure created metadata sidecar",
    ],
    "tools/toolchain/mcmap-test.sh": [
        "no-magic.mcmap",
        "no-artifact-digest.mcmap",
        "no-artifact-kind.mcmap",
        "wrong-backend.mcmap",
        "verifier accepted a map without the mcmap magic",
        "verifier accepted a map without generated_artifact_sha256",
        "verifier accepted a map without artifact_kind",
        "verifier accepted a map with the wrong backend header",
        "require_sha_header generated_artifact_sha256",
        "require_sha_header source_map_payload_sha256",
    ],
}
RISK_ID_RE = re.compile(r"^\s*-\s+id:\s+([A-Z0-9][A-Z0-9-]+)\s*$", re.MULTILINE)
REFACTOR_RISK_REF_RE = re.compile(r"`([A-Z0-9][A-Z0-9-]+)`")
REFACTOR_ZIG_BUILD_RE = re.compile(r"\bzig\s+build\s+([A-Za-z0-9_.<>-]+)")


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


def risk_register_ids() -> set[str]:
    try:
        text = RISK_REGISTER.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing {RISK_REGISTER.relative_to(ROOT)}")
    ids = set(RISK_ID_RE.findall(text))
    if not ids:
        fail(f"{RISK_REGISTER.relative_to(ROOT)} contains no risk ids")
    return ids


def refactoring_plan_risk_refs() -> set[str]:
    try:
        text = REFACTORING_PLAN.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing {REFACTORING_PLAN.relative_to(ROOT)}")
    refs = {
        ref
        for ref in REFACTOR_RISK_REF_RE.findall(text)
        if "-" in ref and not ref.endswith("-GATE")
    }
    if not refs:
        fail(f"{REFACTORING_PLAN.relative_to(ROOT)} contains no risk references")
    return refs


def refactoring_plan_build_refs() -> set[str]:
    try:
        text = REFACTORING_PLAN.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing {REFACTORING_PLAN.relative_to(ROOT)}")
    refs = {
        ref
        for ref in REFACTOR_ZIG_BUILD_RE.findall(text)
        if not (ref.startswith("<") and ref.endswith(">"))
    }
    if not refs:
        fail(f"{REFACTORING_PLAN.relative_to(ROOT)} contains no zig build references")
    return refs


def validate_anchor_inventory(name: str, anchors: dict[str, list[str]]) -> None:
    for rel_path, needles in anchors.items():
        path = ROOT / rel_path
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            fail(f"{name} references missing file {rel_path}")
        for needle in needles:
            if needle not in text:
                fail(f"{name} missing anchor in {rel_path}: {needle!r}")


def anchor_count(anchors: dict[str, list[str]]) -> int:
    return sum(len(needles) for needles in anchors.values())


def string_list(gate_id: str, gate: dict[str, Any], field: str) -> list[str]:
    value = gate.get(field)
    if not isinstance(value, list) or not value:
        fail(f"gate {gate_id} must define non-empty {field}")
    for item in value:
        if not isinstance(item, str) or not item:
            fail(f"gate {gate_id} has invalid {field} item {item!r}")
    return value


def validate_ci_pass_assertions(
    manifest: dict[str, Any],
    known_gates: set[str],
    dependencies: dict[str, set[str]],
) -> int:
    assertions = manifest.get("ci_pass_assertions")
    if not isinstance(assertions, dict) or set(assertions) != KNOWN_CI_PASS_ASSERTIONS:
        fail("ci_pass_assertions must define exactly ci-m0-pass")

    total = 0
    for assertion_id, spec in assertions.items():
        if not isinstance(spec, dict):
            fail(f"ci_pass_assertions.{assertion_id} must be an object")
        build_tier = spec.get("build_tier")
        if build_tier not in KNOWN_BUILD_TIERS:
            fail(f"ci_pass_assertions.{assertion_id} uses unknown build_tier {build_tier!r}")
        gates = spec.get("gates")
        if not isinstance(gates, list) or not gates:
            fail(f"ci_pass_assertions.{assertion_id}.gates must be a non-empty list")
        minimum = spec.get("min_count")
        if not isinstance(minimum, int) or minimum < 1:
            fail(f"ci_pass_assertions.{assertion_id}.min_count must be a positive integer")
        if len(gates) < minimum:
            fail(
                f"ci_pass_assertions.{assertion_id} has {len(gates)} gate(s), "
                f"below required floor {minimum}"
            )
        seen: set[str] = set()
        for gate in gates:
            if not isinstance(gate, str) or not gate:
                fail(f"ci_pass_assertions.{assertion_id}.gates contains a non-string gate")
            if gate in seen:
                fail(f"ci_pass_assertions.{assertion_id}.gates duplicates {gate}")
            seen.add(gate)
            if gate not in known_gates:
                fail(f"ci_pass_assertions.{assertion_id} references unregistered gate {gate}")
            if gate not in dependencies[build_tier]:
                fail(f"ci_pass_assertions.{assertion_id} references gate {gate} outside {build_tier}")
        total += len(gates)
    return total


def main() -> None:
    manifest = load_json(MANIFEST)
    if manifest.get("schema_version") != 1:
        fail("schema_version must be 1")
    if manifest.get("profiles") != "docs/profile-manifest.json":
        fail("profiles must point at docs/profile-manifest.json")
    if manifest.get("scope") != "compiler-core-and-governance":
        fail("scope must be compiler-core-and-governance")

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
    known_risks = risk_register_ids()
    refactor_risk_refs = refactoring_plan_risk_refs()
    refactor_build_refs = refactoring_plan_build_refs()
    validate_anchor_inventory("artifact metadata inventory", ARTIFACT_METADATA_ANCHORS)
    ci_pass_assertion_count = validate_ci_pass_assertions(manifest, known_gates, dependencies)
    unknown_refactor_risks = sorted(refactor_risk_refs - known_risks)
    if unknown_refactor_risks:
        fail(
            "refactoring plan references unknown risk ids: "
            + ", ".join(unknown_refactor_risks)
        )
    unknown_refactor_build_refs = sorted(refactor_build_refs - known_gates)
    if unknown_refactor_build_refs:
        fail(
            "refactoring plan references unknown zig build steps: "
            + ", ".join(unknown_refactor_build_refs)
        )
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

    if len(gates) < 20:
        fail("gate manifest must cover at least 20 compiler-core/governance gates")
    if len(owners) < 5:
        fail("gate manifest should cover multiple ownership domains")
    missing_governance = sorted(REQUIRED_GOVERNANCE_GATES - seen)
    if missing_governance:
        fail(f"manifest missing governance/provenance gates: {', '.join(missing_governance)}")

    print(
        "PASS: gate-manifest-test - "
        f"{len(gates)} manifest gates, {len(owners)} owners, "
        f"{len(known_profiles)} profiles, {len(refactor_risk_refs)} refactor risk refs, "
        f"{len(refactor_build_refs)} refactor build refs, "
        f"{anchor_count(ARTIFACT_METADATA_ANCHORS)} artifact metadata anchors, "
        f"{ci_pass_assertion_count} CI PASS assertion gates"
    )


if __name__ == "__main__":
    main()
