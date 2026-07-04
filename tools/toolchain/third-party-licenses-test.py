#!/usr/bin/env python3
"""Check the aggregated third-party license manifest."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "THIRD-PARTY-LICENSES.md"
LICENSE_FILENAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING")

DEPENDENCIES = {
    "bearssl": {
        "heading": "BearSSL",
        "license": "third_party/bearssl/LICENSE.txt",
        "readme": "third_party/bearssl/README.vendored.md",
        "needles": (
            "Component: BearSSL",
            "https://www.bearssl.org/git/BearSSL",
            "7bea48e5e850ab4cafbe68d3765cdaba13a86d6f",
            "MIT",
            "Redistribution note:",
            "copyright notice",
            "permission notice",
            "warranty disclaimer",
        ),
    },
    "quickjs": {
        "heading": "QuickJS-NG",
        "license": "third_party/quickjs/LICENSE",
        "readme": "third_party/quickjs/README.vendored.md",
        "needles": (
            "Component: QuickJS-NG",
            "https://github.com/quickjs-ng/quickjs",
            "0.15.1",
            "v0.15.1",
            "fd0a0210b7be00957751871e7e01b8291268fc29",
            "c4e813951b7c46845096a948e978c620b11ab4cf5fd622ca09c727ec31f42623",
            "MIT",
            "Redistribution note:",
            "copyright notices",
            "permission notice",
            "warranty disclaimer",
        ),
        "forbidden": (
            "exact recorded commit is currently unknown",
            "exact upstream commit is unknown",
            "next QuickJS re-vendor",
        ),
    },
    "wamr": {
        "heading": "WAMR",
        "license": "third_party/wamr/LICENSE",
        "readme": "third_party/wamr/README.vendored.md",
        "needles": (
            "Component: WAMR",
            "https://github.com/bytecodealliance/wasm-micro-runtime",
            "2.4.3",
            "0e65961d8e560b3d8a125045a29336ce6a0b16ad",
            "dc27b60a1aff64b89d2ca51f036e0f1baee000e156ed7e9283e4f97b660e6e65",
            "Apache-2.0 WITH LLVM-exception",
            "Apache License, Version 2.0",
            "Redistribution note:",
            "NOTICE text",
            "this vendored subset currently has no separate NOTICE file",
            "If a future re-vendor imports one, preserve",
            "LLVM exception",
            "Apache-2.0 Sections",
            "4(a), 4(b), and 4(d)",
        ),
        "forbidden": (
            "exact recorded commit is currently unknown",
            "exact upstream commit is unknown",
            "next WAMR re-vendor",
        ),
    },
    "openlibm": {
        "heading": "openlibm",
        "license": "third_party/openlibm/LICENSE.md",
        "readme": "third_party/openlibm/README.vendored.md",
        "needles": (
            "Component: openlibm",
            "https://github.com/JuliaMath/openlibm",
            "exact recorded version and commit currently unknown",
            "mixed permissive",
            "MIT",
            "ISC",
            "FreeBSD/2-clause BSD",
            "FDLIBM",
            "Redistribution note:",
            "LICENSE.md",
        ),
    },
}


def fail(message: str) -> None:
    print(f"FAIL: third-party-licenses-test - {message}", file=sys.stderr)


def license_bearing_dirs() -> set[str]:
    third_party = ROOT / "third_party"
    if not third_party.is_dir():
        return set()

    found: set[str] = set()
    for child in third_party.iterdir():
        if not child.is_dir():
            continue
        if any((child / name).is_file() for name in LICENSE_FILENAMES):
            found.add(child.name)
    return found


def section_for(text: str, heading: str) -> str | None:
    pattern = re.compile(rf"^## {re.escape(heading)}\s*$", re.MULTILINE)
    match = pattern.search(text)
    if match is None:
        return None
    next_heading = re.search(r"^## .*$", text[match.end() :], re.MULTILINE)
    if next_heading is None:
        return text[match.start() :]
    return text[match.start() : match.end() + next_heading.start()]


def contains_text(haystack: str, needle: str) -> bool:
    return " ".join(needle.split()) in " ".join(haystack.split())


def check_dependency(name: str, cfg: dict[str, object], manifest: str) -> list[str]:
    errors: list[str] = []

    license_rel = cfg["license"]
    readme_rel = cfg["readme"]
    heading = cfg["heading"]
    needles = cfg["needles"]
    forbidden = cfg.get("forbidden", ())
    assert isinstance(license_rel, str)
    assert isinstance(readme_rel, str)
    assert isinstance(heading, str)
    assert isinstance(needles, tuple)
    assert isinstance(forbidden, tuple)

    if not (ROOT / license_rel).is_file():
        errors.append(f"missing license file {license_rel}")
    if not (ROOT / readme_rel).is_file():
        errors.append(f"missing provenance file {readme_rel}")

    section = section_for(manifest, heading)
    if section is None:
        return [*errors, f"manifest missing section ## {heading}"]

    for required_path in (license_rel, readme_rel):
        if f"`{required_path}`" not in section:
            errors.append(f"manifest section ## {heading} does not reference {required_path}")

    for needle in needles:
        assert isinstance(needle, str)
        if not contains_text(section, needle):
            errors.append(f"manifest section ## {heading} missing {needle!r}")

    for needle in forbidden:
        assert isinstance(needle, str)
        if contains_text(section, needle):
            errors.append(f"manifest section ## {heading} still contains {needle!r}")

    if name not in section.lower() and heading.lower() not in section.lower():
        errors.append(f"manifest section ## {heading} does not identify {name}")

    return errors


def check_manifest_paths(manifest: str) -> list[str]:
    errors: list[str] = []
    for rel in sorted(set(re.findall(r"`(third_party/[^`]+)`", manifest))):
        if rel.endswith("/README.vendored.md") or Path(rel).name in LICENSE_FILENAMES:
            if not (ROOT / rel).is_file():
                errors.append(f"manifest references missing path {rel}")
    return errors


def main() -> int:
    errors: list[str] = []
    if not MANIFEST.is_file():
        fail("missing THIRD-PARTY-LICENSES.md")
        return 1

    manifest = MANIFEST.read_text(encoding="utf-8")

    listed = set(DEPENDENCIES)
    discovered = license_bearing_dirs()
    for extra in sorted(discovered - listed):
        errors.append(f"license-bearing dependency third_party/{extra} is not listed")
    for missing in sorted(listed - discovered):
        errors.append(f"listed dependency third_party/{missing} has no top-level license file")

    for name, cfg in DEPENDENCIES.items():
        errors.extend(check_dependency(name, cfg, manifest))
    errors.extend(check_manifest_paths(manifest))

    if errors:
        for error in errors:
            fail(error)
        return 1

    print(
        "PASS: third-party-licenses-test - aggregated third-party license manifest is complete"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
