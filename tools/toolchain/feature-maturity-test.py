#!/usr/bin/env python3
"""Validate the machine-readable feature maturity matrix."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "feature-maturity.json"
SPEC = ROOT / "docs" / "spec" / "MC_0.7_Final_Design.md"
README = ROOT / "README.md"

KNOWN_STATUSES = {
    "core-qualified",
    "experimental",
    "validation-only",
    "reserved-or-unsupported",
}

REQUIRED_FEATURES = {
    "checked-arithmetic",
    "address-spaces",
    "mmio-dma-contracts",
    "move-linear-drop-v0",
    "traits",
    "closures",
    "broad-generics",
    "async-await",
    "advanced-ownership-views",
    "freestanding-qemu-fixtures",
}

FROZEN_EXPERIMENTAL = {
    "traits",
    "closures",
    "broad-generics",
    "async-await",
    "advanced-ownership-views",
}


def fail(message: str) -> int:
    print(f"FAIL: feature-maturity-test - {message}", file=sys.stderr)
    return 1


def require(cond: bool, message: str) -> None:
    if not cond:
        raise AssertionError(message)


def load_manifest() -> dict[str, Any]:
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except Exception as exc:
        raise AssertionError(f"cannot parse {MANIFEST.relative_to(ROOT)}: {exc}") from exc
    require(data.get("schema_version") == 1, "schema_version must be 1")
    require(data.get("source_of_truth") == "docs/feature-maturity.json", "source_of_truth mismatch")
    require(set(data.get("statuses", [])) == KNOWN_STATUSES, "statuses must exactly match known status set")
    features = data.get("features")
    require(isinstance(features, list) and features, "features must be a non-empty list")
    return data


def main() -> int:
    try:
        data = load_manifest()
        spec_text = SPEC.read_text(encoding="utf-8")
        readme_text = README.read_text(encoding="utf-8")

        seen: set[str] = set()
        for item in data["features"]:
            require(isinstance(item, dict), "feature entries must be objects")
            feature_id = item.get("id")
            require(isinstance(feature_id, str) and feature_id, "feature id must be a string")
            require(feature_id not in seen, f"duplicate feature id {feature_id!r}")
            seen.add(feature_id)

            status = item.get("status")
            require(status in KNOWN_STATUSES, f"{feature_id}: unknown status {status!r}")
            require(isinstance(item.get("area"), str) and item["area"], f"{feature_id}: area required")

            anchor = item.get("spec_anchor")
            require(isinstance(anchor, str) and anchor, f"{feature_id}: spec_anchor required")
            require(anchor in spec_text or anchor in readme_text, f"{feature_id}: spec_anchor {anchor!r} not found")

            evidence = item.get("evidence")
            require(isinstance(evidence, list) and evidence, f"{feature_id}: evidence list required")
            for rel in evidence:
                require(isinstance(rel, str) and rel, f"{feature_id}: evidence path must be string")
                require((ROOT / rel).exists(), f"{feature_id}: evidence path missing: {rel}")

        missing = REQUIRED_FEATURES - seen
        require(not missing, "missing required features: " + ", ".join(sorted(missing)))

        for feature_id in FROZEN_EXPERIMENTAL:
            status = next(item["status"] for item in data["features"] if item["id"] == feature_id)
            require(status == "experimental", f"{feature_id} must stay experimental while backend authority boundary is open")

        qemu_status = next(item["status"] for item in data["features"] if item["id"] == "freestanding-qemu-fixtures")
        require(qemu_status == "validation-only", "freestanding-qemu-fixtures must stay validation-only")

        require(
            "Traits, closures, broad generics, async/await" in readme_text,
            "README must state advanced language forms are experimental/frozen",
        )
    except AssertionError as exc:
        return fail(str(exc))

    print(f"PASS: feature-maturity-test - {len(data['features'])} features classified; advanced surface remains frozen")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
