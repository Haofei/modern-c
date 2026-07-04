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
            "Recorded tag",
            "v0.15.1",
            "Recorded commit",
            "fd0a0210b7be00957751871e7e01b8291268fc29",
            "Archive SHA-256",
            "c4e813951b7c46845096a948e978c620b11ab4cf5fd622ca09c727ec31f42623",
            "License",
            "What is kept",
            "dropped",
            "Local modifications",
            "quickjs.h",
            "BUILDING_QJS_SHARED",
            "QUICKJS_NG_MODULE_BUILD",
            "How it is built and used",
        ],
        "forbidden": [
            "Recorded commit:** unknown",
            "exact upstream commit is unknown",
            "exact recorded commit is currently unknown",
            "next QuickJS re-vendor",
        ],
    },
    "wamr": {
        "license": "LICENSE",
        "needles": [
            "Upstream",
            "Recorded version",
            "Recorded commit",
            "0e65961d8e560b3d8a125045a29336ce6a0b16ad",
            "Archive SHA-256",
            "dc27b60a1aff64b89d2ca51f036e0f1baee000e156ed7e9283e4f97b660e6e65",
            "License",
            "What is kept",
            "dropped",
            "Local modifications",
            "core/shared/platform/mc",
            "How it is built and used",
        ],
        "forbidden": [
            "Recorded commit:** unknown",
            "exact upstream commit is unknown",
            "exact recorded commit is currently unknown",
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

    forbidden = cfg.get("forbidden", [])
    assert isinstance(forbidden, list)
    for needle in forbidden:
        assert isinstance(needle, str)
        if needle.lower() in lower_text:
            errors.append(f"{readme.relative_to(ROOT)} still contains forbidden '{needle}'")

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


def check_wamr_loader_guard() -> list[str]:
    path = ROOT / "third_party" / "wamr" / "core" / "iwasm" / "interpreter" / "wasm_loader.c"
    if not path.is_file():
        return [f"missing {path.relative_to(ROOT)}"]
    text = path.read_text(encoding="utf-8")
    guarded_read = "CHECK_BUF(buf, buf_end, 1);\n            uint8 data = *buf++;"
    if guarded_read not in text:
        return [
            f"{path.relative_to(ROOT)} must bounds-check branch-hint payload bytes before reading them"
        ]
    return []


def main() -> int:
    errors: list[str] = []
    for name, cfg in DEPENDENCIES.items():
        errors.extend(check_dependency(name, cfg))
    errors.extend(check_no_extra_license_deps())
    errors.extend(check_doc())
    errors.extend(check_wamr_loader_guard())

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
