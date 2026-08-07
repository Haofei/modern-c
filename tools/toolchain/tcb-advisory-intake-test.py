#!/usr/bin/env python3
"""Check profile-facing TCB advisory-intake metadata is complete and gated."""

from __future__ import annotations

import json
import sys
from datetime import date
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
TCB_COMPONENTS = ROOT / "docs" / "tcb-components.json"
INTAKE = ROOT / "docs" / "tcb-advisory-intake.json"

ALLOWED_STATUSES = {
    "advisory-intake-manifest-gated",
    "open-before-production",
    "tracked-by-platform-image",
}
INTAKE_REQUIRED_CATEGORIES = {"vendored", "firmware", "profile-slot"}
INTAKE_REQUIRED_PROFILES = {"kernel-qemu"}
ALLOWED_SOURCE_KINDS = {
    "upstream",
    "security-advisory",
    "cve-database",
    "distro-tracker",
    "release-notes",
}
REQUIRED_WAIVER_FIELDS = {
    "component_id",
    "advisory_id",
    "source_url",
    "affected_versions",
    "retained_subset_analysis",
    "local_build_flags",
    "owner",
    "approval",
    "expires_on",
}


def fail(message: str) -> None:
    print(f"FAIL: tcb-advisory-intake-test - {message}", file=sys.stderr)
    sys.exit(1)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing {path.relative_to(ROOT)}")
    except json.JSONDecodeError as exc:
        fail(f"{path.relative_to(ROOT)} is not valid JSON: {exc}")


def parse_date(field: str, value: object, context: str) -> date:
    if not isinstance(value, str) or not value:
        fail(f"{context} must define non-empty {field}")
    try:
        return date.fromisoformat(value)
    except ValueError:
        fail(f"{context} has invalid ISO date {field}={value!r}")


def require_string(value: object, field: str, context: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{context} must define non-empty {field}")
    return value


def require_string_list(value: object, field: str, context: str, *, minimum: int = 1) -> list[str]:
    if not isinstance(value, list) or len(value) < minimum:
        fail(f"{context} must define {field} with at least {minimum} item(s)")
    result: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item:
            fail(f"{context} has invalid {field} item {item!r}")
        result.append(item)
    return result


def main() -> None:
    components_doc = load_json(TCB_COMPONENTS)
    intake_doc = load_json(INTAKE)

    if components_doc.get("schema_version") != 1:
        fail("docs/tcb-components.json schema_version must be 1")
    if intake_doc.get("schema_version") != 1:
        fail("docs/tcb-advisory-intake.json schema_version must be 1")
    if intake_doc.get("source_of_truth") != "docs/tcb-advisory-intake.json":
        fail("docs/tcb-advisory-intake.json source_of_truth must point at itself")
    if intake_doc.get("tcb_components") != "docs/tcb-components.json":
        fail("docs/tcb-advisory-intake.json must reference docs/tcb-components.json")

    policy = intake_doc.get("policy")
    if not isinstance(policy, dict):
        fail("docs/tcb-advisory-intake.json must define policy")
    require_string(policy.get("release_rule"), "policy.release_rule", "manifest")
    require_string(policy.get("non_goal"), "policy.non_goal", "manifest")
    waiver_fields = set(require_string_list(policy.get("waiver_required_fields"), "policy.waiver_required_fields", "manifest"))
    missing_waiver_fields = sorted(REQUIRED_WAIVER_FIELDS - waiver_fields)
    if missing_waiver_fields:
        fail(f"manifest policy is missing required waiver field(s): {', '.join(missing_waiver_fields)}")

    components = components_doc.get("components")
    if not isinstance(components, list) or not components:
        fail("docs/tcb-components.json must define components")

    component_by_id: dict[str, dict[str, object]] = {}
    required_component_ids: set[str] = set()
    vendored_ids: set[str] = set()
    for component in components:
        if not isinstance(component, dict):
            fail("each TCB component must be an object")
        component_id = require_string(component.get("id"), "id", "TCB component")
        if component_id in component_by_id:
            fail(f"duplicate TCB component id {component_id}")
        component_by_id[component_id] = component
        category = component.get("category")
        profiles = component.get("profiles")
        if not isinstance(profiles, list):
            fail(f"TCB component {component_id} must list profiles")
        if category in INTAKE_REQUIRED_CATEGORIES and INTAKE_REQUIRED_PROFILES.intersection(profiles):
            required_component_ids.add(component_id)
        if category == "vendored":
            vendored_ids.add(component_id)
            if component.get("advisory_status") != "advisory-intake-manifest-gated":
                fail(f"vendored TCB component {component_id} must use advisory-intake-manifest-gated")
            for path_field in ("license_file", "provenance_file"):
                path = require_string(component.get(path_field), path_field, f"TCB component {component_id}")
                if not (ROOT / path).is_file():
                    fail(f"TCB component {component_id} references missing {path_field} {path}")

    rows = intake_doc.get("components")
    if not isinstance(rows, list) or not rows:
        fail("docs/tcb-advisory-intake.json must define components")

    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            fail("each advisory-intake row must be an object")
        component_id = require_string(row.get("component_id"), "component_id", "advisory-intake row")
        context = f"advisory-intake row {component_id}"
        if component_id in seen:
            fail(f"duplicate advisory-intake row for {component_id}")
        seen.add(component_id)
        if component_id not in component_by_id:
            fail(f"{context} references unknown TCB component")
        if component_id not in required_component_ids:
            fail(f"{context} is not required for a kernel profile-facing vendored/firmware/profile-slot TCB component")

        component = component_by_id[component_id]
        owner = require_string(row.get("owner"), "owner", context)
        if owner != component.get("owner"):
            fail(f"{context} owner {owner!r} does not match docs/tcb-components.json owner {component.get('owner')!r}")
        status = require_string(row.get("status"), "status", context)
        if status not in ALLOWED_STATUSES:
            fail(f"{context} has unsupported status {status!r}")
        if status != component.get("advisory_status"):
            fail(f"{context} status must match docs/tcb-components.json advisory_status")

        reviewed_on = parse_date("reviewed_on", row.get("reviewed_on"), context)
        review_after = parse_date("review_after", row.get("review_after"), context)
        component_review_after = parse_date("review_after", component.get("review_after"), f"TCB component {component_id}")
        if review_after < reviewed_on:
            fail(f"{context} review_after must not be before reviewed_on")
        if review_after != component_review_after:
            fail(f"{context} review_after must match docs/tcb-components.json")

        require_string_list(row.get("queries"), "queries", context, minimum=2)
        require_string(row.get("retained_subset_policy"), "retained_subset_policy", context)
        require_string_list(row.get("release_blocker_if"), "release_blocker_if", context, minimum=2)

        sources = row.get("advisory_sources")
        if not isinstance(sources, list) or len(sources) < 2:
            fail(f"{context} must define at least two advisory_sources")
        kinds: set[str] = set()
        for source in sources:
            if not isinstance(source, dict):
                fail(f"{context} advisory_sources entries must be objects")
            require_string(source.get("name"), "advisory_sources.name", context)
            kind = require_string(source.get("kind"), "advisory_sources.kind", context)
            if kind not in ALLOWED_SOURCE_KINDS:
                fail(f"{context} has unsupported advisory source kind {kind!r}")
            kinds.add(kind)
            url = require_string(source.get("url"), "advisory_sources.url", context)
            if not (url.startswith("https://") or url.startswith("http://")):
                fail(f"{context} advisory source URL must be absolute HTTP(S): {url!r}")
        if "cve-database" not in kinds:
            fail(f"{context} must include a CVE database source")
        if not ({"security-advisory", "upstream", "release-notes"} & kinds):
            fail(f"{context} must include an upstream, release, or security-advisory source")

    missing = sorted(required_component_ids - seen)
    if missing:
        fail(f"missing advisory-intake rows for required TCB component(s): {', '.join(missing)}")
    stale = sorted(seen - required_component_ids)
    if stale:
        fail(f"stale advisory-intake rows for non-required component(s): {', '.join(stale)}")

    print(
        "PASS: tcb-advisory-intake-test - "
        f"{len(seen)} profile-facing TCB component(s) have advisory intake metadata"
    )


if __name__ == "__main__":
    main()
