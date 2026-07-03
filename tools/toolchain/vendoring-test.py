#!/usr/bin/env python3
"""Check vendored dependency provenance metadata."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

DEPENDENCIES = {
    "bearssl": {
        "license": "LICENSE.txt",
        "needles": [
            "Upstream",
            "Commit",
            "License",
            "What is kept",
            "dropped",
            "added by us",
            "How it is built",
        ],
    },
    "quickjs": {
        "license": "LICENSE",
        "needles": [
            "Upstream",
            "Recorded version",
            "Recorded commit",
            "License",
            "What is kept",
            "dropped",
            "Local modifications",
            "How it is built and used",
            "next QuickJS re-vendor",
        ],
    },
    "wamr": {
        "license": "LICENSE",
        "needles": [
            "Upstream",
            "Recorded version",
            "Recorded commit",
            "License",
            "What is kept",
            "dropped",
            "Local modifications",
            "How it is built and used",
            "next WAMR re-vendor",
        ],
    },
    "openlibm": {
        "license": "LICENSE.md",
        "needles": [
            "Upstream",
            "Recorded version",
            "Source evidence",
            "License",
            "What is kept",
            "dropped",
            "Local modifications",
            "How it is built and used",
            "next openlibm",
            "re-vendor",
        ],
    },
}

DOC_NEEDLES = [
    "bearssl",
    "quickjs",
    "wamr",
    "openlibm",
    "CVE",
    "advisory",
    "GitHub Security Advisories",
    "security-driven",
    "archive checksum",
]


def fail(message: str) -> None:
    print(f"FAIL: vendoring-test - {message}", file=sys.stderr)


def check_dependency(name: str, cfg: dict[str, object]) -> list[str]:
    errors: list[str] = []
    dep_dir = ROOT / "third_party" / name
    if not dep_dir.is_dir():
        return [f"missing third_party/{name}"]

    readme = dep_dir / "README.vendored.md"
    if not readme.is_file():
        errors.append(f"missing {readme.relative_to(ROOT)}")
        text = ""
    else:
        text = readme.read_text(encoding="utf-8")

    license_rel = cfg["license"]
    assert isinstance(license_rel, str)
    license_path = dep_dir / license_rel
    if not license_path.is_file():
        errors.append(f"missing license file {license_path.relative_to(ROOT)}")
    if text and license_rel not in text:
        errors.append(f"{readme.relative_to(ROOT)} does not mention {license_rel}")

    lower_text = text.lower()
    needles = cfg["needles"]
    assert isinstance(needles, list)
    for needle in needles:
        assert isinstance(needle, str)
        if needle.lower() not in lower_text:
            errors.append(f"{readme.relative_to(ROOT)} missing '{needle}'")

    return errors


def check_no_extra_license_deps() -> list[str]:
    errors: list[str] = []
    third_party = ROOT / "third_party"
    for child in sorted(p for p in third_party.iterdir() if p.is_dir()):
        has_license = any(
            (child / name).is_file()
            for name in ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING")
        )
        if has_license and child.name not in DEPENDENCIES:
            errors.append(f"license-bearing dependency {child.name} is not listed")
    return errors


def check_doc() -> list[str]:
    doc = ROOT / "docs" / "vendoring.md"
    if not doc.is_file():
        return ["missing docs/vendoring.md"]
    text = doc.read_text(encoding="utf-8")
    return [
        f"docs/vendoring.md missing '{needle}'"
        for needle in DOC_NEEDLES
        if needle.lower() not in text.lower()
    ]


def main() -> int:
    errors: list[str] = []
    for name, cfg in DEPENDENCIES.items():
        errors.extend(check_dependency(name, cfg))
    errors.extend(check_no_extra_license_deps())
    errors.extend(check_doc())

    if errors:
        for error in errors:
            fail(error)
        return 1

    print(
        "PASS: vendoring-test - vendored dependency provenance and CVE process are documented"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
