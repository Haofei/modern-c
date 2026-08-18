#!/usr/bin/env python3
"""Validate the active review goal status manifest.

This gate is deliberately scoped to the current language/compiler review goals.
It does not claim completion.  It prevents accidental drift where the manifest
marks a goal complete while the old AST body fallback, inspection-only HIR, or
textual module inclusion evidence is still present.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "review-goal-status.json"


def fail(message: str) -> int:
    print(f"FAIL: review-goal-status-test - {message}", file=sys.stderr)
    return 1


def require(cond: bool, message: str) -> None:
    if not cond:
        raise AssertionError(message)


def count_literal(rel: str, needle: str) -> int:
    path = ROOT / rel
    require(path.exists(), f"missing evidence file {rel}")
    return path.read_text(encoding="utf-8").count(needle)


def validate_evidence(goal: dict[str, Any], failures: list[str]) -> int:
    checked = 0
    evidence = goal.get("current_evidence")
    require(isinstance(evidence, list) and evidence, f"{goal.get('id')}: current_evidence must be a non-empty list")
    for item in evidence:
        require(isinstance(item, dict), f"{goal.get('id')}: evidence item must be an object")
        rel = item.get("file")
        needle = item.get("needle")
        require(isinstance(rel, str) and rel, f"{goal.get('id')}: evidence file must be a string")
        require(isinstance(needle, str) and needle, f"{goal.get('id')}: evidence needle must be a string")
        actual = count_literal(rel, needle)
        checked += 1
        if "expected_count_while_incomplete" in item:
            expected = item["expected_count_while_incomplete"]
            require(isinstance(expected, int) and expected >= 0, f"{goal.get('id')}: expected count must be a non-negative int")
            if goal.get("status") == "incomplete" and actual != expected:
                failures.append(f"{goal.get('id')}: {rel}: expected {expected} occurrences of {needle!r}, found {actual}")
        if "expected_min_count_while_incomplete" in item:
            expected = item["expected_min_count_while_incomplete"]
            require(isinstance(expected, int) and expected >= 0, f"{goal.get('id')}: expected min count must be a non-negative int")
            if goal.get("status") == "incomplete" and actual < expected:
                failures.append(f"{goal.get('id')}: {rel}: expected at least {expected} occurrences of {needle!r}, found {actual}")
        if goal.get("status") == "complete" and actual != 0:
            failures.append(f"{goal.get('id')}: status is complete but {rel} still has {actual} occurrences of {needle!r}")
    return checked


def main() -> int:
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        require(data.get("schema_version") == 1, "schema_version must be 1")
        require(data.get("source_of_truth") == "docs/review-goal-status.json", "source_of_truth mismatch")
        goals = data.get("goals")
        require(isinstance(goals, list) and len(goals) == 3, "goals must contain exactly the three active review goals")
        expected_ids = ["function-body-fallback", "typed-hir-checked-program", "real-module-graph"]
        actual_ids = [goal.get("id") for goal in goals]
        require(actual_ids == expected_ids, f"goal order mismatch: expected {expected_ids}, got {actual_ids}")
        failures: list[str] = []
        checked = 0
        for goal in goals:
            require(goal.get("priority") in {"P0", "P1"}, f"{goal.get('id')}: priority must be P0 or P1")
            require(goal.get("status") in {"incomplete", "complete"}, f"{goal.get('id')}: unsupported status")
            require(isinstance(goal.get("requested_end_state"), str) and goal["requested_end_state"], f"{goal.get('id')}: missing requested_end_state")
            checked += validate_evidence(goal, failures)
        if failures:
            return fail("\n  - " + "\n  - ".join(failures))
    except Exception as exc:
        return fail(str(exc))

    print(f"PASS: review-goal-status-test - {checked} evidence anchors checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
