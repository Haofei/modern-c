#!/usr/bin/env python3
"""Validate the product-profile manifest against risk and build-gate sources."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "profile-manifest.json"
TCB_COMPONENTS = ROOT / "docs" / "tcb-components.json"
RISK_REGISTER = ROOT / "docs" / "review-risk-register.yaml"
BUILD_DIR = ROOT / "build"

REQUIRED_PROFILES = {
    "compiler-subset",
    "llvm-experimental",
    "selfhost-experimental",
    "developer-tools",
    "kernel-qemu",
}


def fail(message: str) -> None:
    print(f"FAIL: profile-manifest-test - {message}", file=sys.stderr)
    sys.exit(1)


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        fail(f"missing {path.relative_to(ROOT)}")
    except json.JSONDecodeError as exc:
        fail(f"{path.relative_to(ROOT)} is not valid JSON: {exc}")


def risk_ids() -> set[str]:
    try:
        text = RISK_REGISTER.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing {RISK_REGISTER.relative_to(ROOT)}")
    return set(re.findall(r"(?m)^\s+- id:\s*([A-Z0-9-]+)\s*$", text))


def registered_gates() -> set[str]:
    gates: set[str] = set()
    for path in BUILD_DIR.glob("*.zig"):
        text = path.read_text(encoding="utf-8")
        gates.update(re.findall(r'addScriptTest(?:Opts)?\(\s*ctx,\s*"([^"]+)"', text))
        gates.update(re.findall(r'addRawCmd\(\s*ctx,\s*"([^"]+)"', text))
        gates.update(re.findall(r'(?:ctx\.)?b\.step\(\s*"([^"]+)"', text))
    return gates


def require_string_list(profile_id: str, profile: dict[str, Any], field: str) -> list[str]:
    value = profile.get(field)
    if not isinstance(value, list) or not value:
        fail(f"profile {profile_id} must define non-empty {field}")
    for item in value:
        if not isinstance(item, str) or not item:
            fail(f"profile {profile_id} has invalid {field} item {item!r}")
    return value


def require_scope(profile_id: str, profile: dict[str, Any]) -> None:
    scope = profile.get("scope")
    if not isinstance(scope, dict):
        fail(f"profile {profile_id} must define scope object")
    for field in ("blocking", "experimental_or_excluded"):
        value = scope.get(field)
        if not isinstance(value, list) or not value:
            fail(f"profile {profile_id} must define non-empty scope.{field}")
        for item in value:
            if not isinstance(item, str) or not item:
                fail(f"profile {profile_id} has invalid scope.{field} item {item!r}")


def main() -> None:
    manifest = load_json(MANIFEST)
    if manifest.get("schema_version") != 1:
        fail("schema_version must be 1")
    if manifest.get("risk_register") != "docs/review-risk-register.yaml":
        fail("risk_register must point at docs/review-risk-register.yaml")
    if manifest.get("tcb_component_manifest") != "docs/tcb-components.json":
        fail("tcb_component_manifest must point at docs/tcb-components.json")

    component_manifest = load_json(TCB_COMPONENTS)
    if component_manifest.get("schema_version") != 1:
        fail("docs/tcb-components.json schema_version must be 1")
    if component_manifest.get("source_of_truth") != "docs/tcb-components.json":
        fail("docs/tcb-components.json source_of_truth must point at itself")
    components = component_manifest.get("components")
    if not isinstance(components, list) or not components:
        fail("docs/tcb-components.json must define a non-empty components list")

    component_by_id: dict[str, dict[str, Any]] = {}
    for component in components:
        if not isinstance(component, dict):
            fail("each TCB component must be an object")
        component_id = component.get("id")
        if not isinstance(component_id, str) or not component_id:
            fail("each TCB component must define a non-empty id")
        if component_id in component_by_id:
            fail(f"duplicate TCB component id {component_id}")
        component_by_id[component_id] = component
        for field in ("category", "owner", "summary", "advisory_status", "review_after"):
            if not isinstance(component.get(field), str) or not component[field]:
                fail(f"TCB component {component_id} must define {field}")
        component_profiles = component.get("profiles")
        if not isinstance(component_profiles, list) or not component_profiles:
            fail(f"TCB component {component_id} must list owning profiles")
        for profile_id in component_profiles:
            if not isinstance(profile_id, str) or not profile_id:
                fail(f"TCB component {component_id} has invalid profile reference {profile_id!r}")

    profiles = manifest.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        fail("manifest must define a non-empty profiles list")

    seen: set[str] = set()
    known_risks = risk_ids()
    known_gates = registered_gates()

    for profile in profiles:
        if not isinstance(profile, dict):
            fail("each profile must be an object")
        profile_id = profile.get("id")
        if not isinstance(profile_id, str) or not profile_id:
            fail("each profile must define a non-empty id")
        if profile_id in seen:
            fail(f"duplicate profile id {profile_id}")
        seen.add(profile_id)

        if not isinstance(profile.get("status"), str) or not profile["status"]:
            fail(f"profile {profile_id} must define status")
        if not isinstance(profile.get("production_claim"), bool):
            fail(f"profile {profile_id} must define boolean production_claim")
        if not isinstance(profile.get("summary"), str) or not profile["summary"]:
            fail(f"profile {profile_id} must define summary")

        require_scope(profile_id, profile)
        profile_risks = require_string_list(profile_id, profile, "blocking_risks")
        profile_gates = require_string_list(profile_id, profile, "blocking_gates")
        profile_components = require_string_list(profile_id, profile, "tcb_components")

        unknown_risks = sorted(set(profile_risks) - known_risks)
        if unknown_risks:
            fail(f"profile {profile_id} references unknown risks: {', '.join(unknown_risks)}")

        unknown_gates = sorted(set(profile_gates) - known_gates)
        if unknown_gates:
            fail(f"profile {profile_id} references unregistered gates: {', '.join(unknown_gates)}")

        unknown_components = sorted(set(profile_components) - set(component_by_id))
        if unknown_components:
            fail(f"profile {profile_id} references unknown TCB components: {', '.join(unknown_components)}")
        for component_id in profile_components:
            component_profiles = component_by_id[component_id]["profiles"]
            if profile_id not in component_profiles:
                fail(f"TCB component {component_id} does not list owning profile {profile_id}")

    missing_profiles = sorted(REQUIRED_PROFILES - seen)
    if missing_profiles:
        fail(f"missing required profiles: {', '.join(missing_profiles)}")
    for component_id, component in component_by_id.items():
        unknown_component_profiles = sorted(set(component["profiles"]) - seen)
        if unknown_component_profiles:
            fail(f"TCB component {component_id} references unknown profiles: {', '.join(unknown_component_profiles)}")

    profile_by_id = {profile["id"]: profile for profile in profiles}
    if profile_by_id["compiler-subset"]["production_claim"]:
        fail("compiler-subset must not claim unrestricted production support")
    for experimental_id in ("llvm-experimental", "selfhost-experimental", "developer-tools", "kernel-qemu"):
        if profile_by_id[experimental_id]["production_claim"]:
            fail(f"{experimental_id} must not claim production support")

    if "BACKEND-LLVM-PROFILE" not in profile_by_id["llvm-experimental"]["blocking_risks"]:
        fail("llvm-experimental must reference BACKEND-LLVM-PROFILE")
    if "SELFHOST-PROFILE" not in profile_by_id["selfhost-experimental"]["blocking_risks"]:
        fail("selfhost-experimental must reference SELFHOST-PROFILE")

    print(
        "PASS: profile-manifest-test - "
        f"{len(profiles)} profiles, {len(component_by_id)} TCB components, "
        f"{len(known_risks)} risk IDs, {len(known_gates)} registered gates"
    )


if __name__ == "__main__":
    main()
