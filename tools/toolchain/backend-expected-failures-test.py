#!/usr/bin/env python3
"""Validate the backend expected-failure manifest.

`c-test` holds the fixtures in docs/backend-expected-failures.json out of its
must-compile phase and instead asserts that each one still fails, for the
reason recorded there. That keeps the gate green with known debt while a NEW
failure, or a fixture that quietly starts passing, still fails it.

This check is the cheap half: it runs no compiler, so it can sit in every
tier, including the `m0` tier CI runs. It proves the manifest is well formed
and still points at real fixtures, so the list cannot rot into a blanket
exemption. The expensive half -- actually running emit-c -- stays in c-test.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from backend_gap_lib import STRUCTURED_REASON, cause_problem  # shared E_BACKEND_UNSUPPORTED cause shape

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "backend-expected-failures.json"
HARNESS = ROOT / "tools" / "toolchain" / "check-generated-c.sh"
SWEEP_HARNESS = ROOT / "tools" / "toolchain" / "spec-emit-sweep.py"

# A reason is either a diagnostic code the user sees, or the name of a
# fail-closed admission error. Both are stable identifiers; free text is not.
DIAGNOSTIC_RE = re.compile(r"^E_[A-Z0-9_]+$")
INTERNAL_RE = re.compile(r"^[A-Z][A-Za-z0-9]+$")


def fail(message: str) -> None:
    print(f"FAIL: backend-expected-failures-test - {message}", file=sys.stderr)
    sys.exit(1)


def require_cause(fixture: str, entry: dict) -> None:
    """Every `E_BACKEND_UNSUPPORTED` entry must record a structured cause.

    The reason code is the backend's *only* refusal code, so an entry carrying
    it says no more than "the backend said no somewhere". That is too weak to
    hold a fixture to: the gap can move to a different phase, construct or
    function and the entry still matches. A `cause` pins the refusal the entry
    was written for, and the harnesses compare it. An entry failing for any
    other reason names its own gap already, so it records no cause.
    """
    cause = entry.get("cause")
    if entry["reason"] != STRUCTURED_REASON:
        if cause is not None:
            fail(f"{fixture} records a cause but fails with {entry['reason']!r}, "
                 f"which is not {STRUCTURED_REASON}; the reason already names its gap")
        return
    if cause is None:
        fail(f"{fixture} fails with {STRUCTURED_REASON}, which names no gap on its own; "
             f"record a cause with the refusing phase, category, construct and function "
             f"the diagnostic spells")
    problem = cause_problem(cause)
    if problem is not None:
        fail(f"{fixture}: {problem}")


def main() -> None:
    if not MANIFEST.is_file():
        fail(f"missing {MANIFEST.relative_to(ROOT)}")
    try:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{MANIFEST.relative_to(ROOT)} is not valid JSON: {exc}")

    if manifest.get("schema_version") != 1:
        fail("schema_version must be 1")
    if manifest.get("source_of_truth") != "docs/backend-expected-failures.json":
        fail("source_of_truth mismatch")
    if not isinstance(manifest.get("purpose"), str) or not manifest["purpose"].strip():
        fail("purpose must explain what the list is for")

    entries = manifest.get("emit_c")
    if not isinstance(entries, list):
        fail("emit_c must be a list")

    sweep_entries = manifest.get("sweep")
    if not isinstance(sweep_entries, list):
        fail("sweep must be a list")

    seen: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            fail("each emit_c entry must be an object")
        fixture = entry.get("fixture")
        reason = entry.get("reason")
        if not isinstance(fixture, str) or not fixture:
            fail("each entry must name a fixture")
        if fixture in seen:
            fail(f"duplicate entry for {fixture}")
        seen.add(fixture)
        if not (ROOT / fixture).is_file():
            fail(f"{fixture} is listed but does not exist; delete the entry")
        if not fixture.startswith("tests/c_emit/"):
            fail(f"{fixture} is outside the c-test corpus")
        if fixture.startswith("tests/c_emit/bad/"):
            fail(f"{fixture} is a reject fixture and is already asserted by c-test")
        if not isinstance(reason, str) or not reason:
            fail(f"{fixture} must record the reason it fails")
        if not (DIAGNOSTIC_RE.match(reason) or INTERNAL_RE.match(reason)):
            fail(f"{fixture} reason {reason!r} is neither an E_* code nor an error name")
        require_cause(fixture, entry)
        note = entry.get("note")
        if not isinstance(note, str) or not note.strip():
            fail(f"{fixture} must carry a note saying why it cannot compile today")

    sweep_seen: set[str] = set()
    for entry in sweep_entries:
        if not isinstance(entry, dict):
            fail("each sweep entry must be an object")
        fixture = entry.get("fixture")
        stage = entry.get("stage")
        reason = entry.get("reason")
        note = entry.get("note")
        if not isinstance(fixture, str) or not fixture:
            fail("each sweep entry must name a fixture")
        if fixture in sweep_seen:
            fail(f"duplicate sweep entry for {fixture}")
        sweep_seen.add(fixture)
        # The sweep keys on the fixture's basename inside tests/spec.
        if not (ROOT / "tests" / "spec" / fixture).is_file():
            fail(f"sweep entry {fixture} does not exist under tests/spec; delete the entry")
        if stage not in ("EMIT", "CLANG"):
            fail(f"sweep entry {fixture} has unknown stage {stage!r}")
        if not isinstance(reason, str) or not reason:
            fail(f"sweep entry {fixture} must record the reason it fails")
        if stage == "EMIT" and not (DIAGNOSTIC_RE.match(reason) or INTERNAL_RE.match(reason)):
            fail(f"sweep entry {fixture} reason {reason!r} is neither an E_* code nor an error name")
        require_cause(f"sweep entry {fixture}", entry)
        if not isinstance(note, str) or not note.strip():
            fail(f"sweep entry {fixture} must carry a note saying why it cannot compile today")

    # A manifest is only meaningful if the harnesses actually consult it.
    harness = HARNESS.read_text(encoding="utf-8")
    for needle in ("docs/backend-expected-failures.json", "run_known_fixture", "render_cause"):
        if needle not in harness:
            fail(f"{HARNESS.relative_to(ROOT)} no longer consults the manifest ({needle!r} missing)")
    sweep_harness = SWEEP_HARNESS.read_text(encoding="utf-8")
    for needle in ("backend-expected-failures.json", "load_expected_failures", "failure_matches", "parse_cause"):
        if needle not in sweep_harness:
            fail(f"{SWEEP_HARNESS.relative_to(ROOT)} no longer consults the manifest ({needle!r} missing)")

    reasons: dict[str, int] = {}
    for entry in entries:
        reasons[entry["reason"]] = reasons.get(entry["reason"], 0) + 1
    summary = ", ".join(f"{count} {reason}" for reason, count in sorted(reasons.items()))
    sweep_reasons: dict[str, int] = {}
    for entry in sweep_entries:
        key = entry["reason"] if entry["stage"] == "EMIT" else "clang-compile"
        sweep_reasons[key] = sweep_reasons.get(key, 0) + 1
    sweep_summary = ", ".join(f"{count} {reason}" for reason, count in sorted(sweep_reasons.items()))
    caused = sum(1 for entry in entries + sweep_entries if entry.get("cause") is not None)
    print(
        f"PASS: backend-expected-failures-test - {len(entries)} known-failing c_emit fixtures ({summary}); "
        f"{len(sweep_entries)} known-failing spec sweep fixtures ({sweep_summary}); "
        f"{caused} entries pinned to a structured {STRUCTURED_REASON} cause"
    )


if __name__ == "__main__":
    main()
