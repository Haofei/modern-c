#!/usr/bin/env python3
"""Validate the codegen ingress migration budget.

This gate is a framework for the remaining VerifiedProgram/codegen boundary
migration.  It does not claim the boundary is closed; it makes the remaining
AST-shaped declaration payload explicit and ratcheted so large migration slices
can safely delete whole payload families without reintroducing them later.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "codegen-ingress-migration.json"


def fail(message: str) -> int:
    print(f"FAIL: codegen-ingress-migration-test - {message}", file=sys.stderr)
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
    require(data.get("source_of_truth") == "docs/codegen-ingress-migration.json", "source_of_truth mismatch")
    return data


def count_literal(rel: str, needle: str) -> int:
    path = ROOT / rel
    require(path.exists(), f"missing source file {rel}")
    return path.read_text(encoding="utf-8").count(needle)


def validate_count_table(table_name: str, table: Any, failures: list[str]) -> int:
    require(isinstance(table, dict), f"{table_name} must be an object")
    checked = 0
    for rel, counts in table.items():
        require(isinstance(rel, str) and rel, f"{table_name}: file key must be a string")
        require(isinstance(counts, dict), f"{table_name}.{rel} must be an object")
        for needle, expected in counts.items():
            require(isinstance(needle, str) and needle, f"{table_name}.{rel}: needle must be a string")
            require(isinstance(expected, int) and expected >= 0, f"{table_name}.{rel}.{needle!r}: expected count must be non-negative int")
            actual = count_literal(rel, needle)
            checked += 1
            if actual != expected:
                failures.append(f"{table_name}: {rel}: expected {expected} occurrences of {needle!r}, found {actual}")
    return checked


def validate_fallback_census_ratchet(spec: Any) -> int:
    require(isinstance(spec, dict), "fallback_census_ratchet must be an object")
    required = ("gate", "script", "report", "ratchet", "baseline", "roots", "default_check_corpus", "policy")
    checked = 0
    for key in required:
        value = spec.get(key)
        require(isinstance(value, str) and value, f"fallback_census_ratchet.{key} must be a non-empty string")
        checked += 1

    for key in ("script", "report", "ratchet", "baseline", "roots"):
        rel = spec[key]
        require((ROOT / rel).is_file(), f"fallback_census_ratchet.{key} references missing file {rel}")
        checked += 1

    require(spec["roots"] == spec["default_check_corpus"], "fallback census roots/default_check_corpus mismatch")
    checked += 1

    baseline = ROOT / spec["baseline"]
    roots = [
        line
        for line in (ROOT / spec["roots"]).read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]
    require(roots, "fallback census roots must list at least one checked root")
    checked += 1

    lines = [
        line.strip()
        for line in baseline.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]
    require(lines, "fallback census baseline must contain a header and backend rows")
    require(
        lines[0].split("\t") == [
            "backend",
            "total_min",
            "admitted_min",
            "fallback_max",
            "unsupported_max",
            "admission_bps_min",
            "canonical_min",
            "specialized_max",
            "specialized_plan_defs_max",
        ],
        "fallback census baseline header mismatch",
    )
    backends = {line.split("\t")[0] for line in lines[1:]}
    require(backends == {"c", "llvm"}, "fallback census baseline must pin exactly c and llvm rows")
    checked += 3
    return checked


def main() -> int:
    try:
        data = load_manifest()
        failures: list[str] = []
        checked = 0
        for key in (
            "ast_shaped_payload_budget",
            "normalized_fact_anchors",
            "mir_body_fast_path_ratchet",
            "backend_artifact_consumers",
            "forbidden_regressions",
        ):
            checked += validate_count_table(key, data.get(key), failures)

        policy = data.get("policy")
        require(isinstance(policy, dict), "policy must be an object")
        require(policy.get("direction") and policy.get("stable_goal"), "policy must document direction and stable_goal")
        checked += validate_fallback_census_ratchet(data.get("fallback_census_ratchet"))

        if failures:
            return fail("\n  - " + "\n  - ".join(failures))
    except AssertionError as exc:
        return fail(str(exc))

    print(f"PASS: codegen-ingress-migration-test - {checked} codegen ingress anchors checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
