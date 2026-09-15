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

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs" / "backend-expected-failures.json"
HARNESS = ROOT / "tools" / "toolchain" / "check-generated-c.sh"

# A reason is either a diagnostic code the user sees, or the name of a
# fail-closed admission error. Both are stable identifiers; free text is not.
DIAGNOSTIC_RE = re.compile(r"^E_[A-Z0-9_]+$")
INTERNAL_RE = re.compile(r"^[A-Z][A-Za-z0-9]+$")


def fail(message: str) -> None:
    print(f"FAIL: backend-expected-failures-test - {message}", file=sys.stderr)
    sys.exit(1)


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
        note = entry.get("note")
        if not isinstance(note, str) or not note.strip():
            fail(f"{fixture} must carry a note saying why it cannot compile today")

    # The manifest is only meaningful if the harness actually consults it.
    harness = HARNESS.read_text(encoding="utf-8")
    for needle in ("docs/backend-expected-failures.json", "run_known_fixture"):
        if needle not in harness:
            fail(f"{HARNESS.relative_to(ROOT)} no longer consults the manifest ({needle!r} missing)")

    reasons: dict[str, int] = {}
    for entry in entries:
        reasons[entry["reason"]] = reasons.get(entry["reason"], 0) + 1
    summary = ", ".join(f"{count} {reason}" for reason, count in sorted(reasons.items()))
    print(f"PASS: backend-expected-failures-test - {len(entries)} known-failing c_emit fixtures ({summary})")


if __name__ == "__main__":
    main()
