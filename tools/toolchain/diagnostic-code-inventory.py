#!/usr/bin/env python3
"""Ensure every emitted E_* diagnostic has fixture or allowlist ownership."""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path


EXPECT_RE = re.compile(r"EXPECT(?:_ERROR)?:\s+(E_[A-Z0-9_]+)")
ALLOWLIST_ROW_RE = re.compile(r"^\|\s*`?(E_[A-Z0-9_]+)`?\s*\|\s*(.*?)\s*\|")
FIXTURE_GLOBS = (
    "tests/spec/*.mc",
    "tests/c_emit/bad/*.mc",
    "kernel/bad/*.mc",
    "demo/bad/*.mc",
)


def load_diagnostics_reference(root: Path):
    path = root / "tools" / "toolchain" / "diagnostics-reference.py"
    spec = importlib.util.spec_from_file_location("diagnostics_reference", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def collect_fixture_codes(root: Path) -> dict[str, list[str]]:
    codes: dict[str, list[str]] = {}
    for pattern in FIXTURE_GLOBS:
        for path in sorted(root.glob(pattern)):
            rel = path.relative_to(root).as_posix()
            text = path.read_text(encoding="utf-8")
            for match in EXPECT_RE.finditer(text):
                codes.setdefault(match.group(1), []).append(rel)
    return codes


def collect_allowlist(root: Path) -> dict[str, str]:
    path = root / "docs" / "diagnostic-code-inventory.md"
    if not path.exists():
        return {}

    allowlist: dict[str, str] = {}
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = ALLOWLIST_ROW_RE.match(line)
        if not match:
            continue
        code = match.group(1)
        reason = re.sub(r"<[^>]+>", "", match.group(2)).strip()
        reason = reason.replace("`", "").strip()
        if not reason or set(reason) <= {"-"}:
            raise RuntimeError(f"{path.relative_to(root)}:{line_no}: allowlist row for {code} needs a reason")
        allowlist[code] = reason
    return allowlist


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if any diagnostic code lacks ownership")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    diag_ref = load_diagnostics_reference(root)
    source_info = diag_ref.collect(root)
    source_codes = set(source_info)
    fixture_codes = collect_fixture_codes(root)
    fixture_owned = set(fixture_codes)
    allowlist = collect_allowlist(root)
    allowlisted = set(allowlist)

    missing = sorted(source_codes - fixture_owned - allowlisted)
    stale_allowlist = sorted(allowlisted - source_codes)
    redundant_allowlist = sorted(allowlisted & fixture_owned)
    stale_fixtures = sorted(fixture_owned - source_codes)

    if missing or stale_allowlist or redundant_allowlist or stale_fixtures:
        for code in missing:
            refs = ", ".join(source_info[code].refs[:4])
            print(
                f"FAIL: diagnostic-code-inventory - {code} has no negative fixture or allowlist entry ({refs})",
                file=sys.stderr,
            )
        for code in stale_allowlist:
            print(f"FAIL: diagnostic-code-inventory - allowlist entry for non-emitted code {code}", file=sys.stderr)
        for code in redundant_allowlist:
            examples = ", ".join(fixture_codes[code][:3])
            print(
                f"FAIL: diagnostic-code-inventory - {code} has fixture coverage; remove the allowlist entry ({examples})",
                file=sys.stderr,
            )
        for code in stale_fixtures:
            examples = ", ".join(fixture_codes[code][:3])
            print(f"FAIL: diagnostic-code-inventory - fixture expects non-emitted code {code} ({examples})", file=sys.stderr)
        print(
            "FAIL: diagnostic-code-inventory - update tests/spec or bad/ EXPECT fixtures, "
            "or document an intentional allowlist entry in docs/diagnostic-code-inventory.md",
            file=sys.stderr,
        )
        return 1

    print(
        "PASS: diagnostic-code-inventory - "
        f"{len(source_codes)} emitted codes, {len(fixture_owned)} fixture-owned, {len(allowlisted)} allowlisted"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
