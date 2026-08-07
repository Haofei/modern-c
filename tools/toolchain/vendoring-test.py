#!/usr/bin/env python3
"""Check vendored dependency provenance metadata."""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TCB_COMPONENTS = ROOT / "docs" / "tcb-components.json"

DEPENDENCIES = {
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
            "Retained-subset comparison commit",
            "b8b7bec46076bbe5fee43ffe8f9b2a4c8352a9c8",
            "Archive SHA-256",
            "b387919068d5ec49929cc012119375b889724175918e851851d3eacab92a665a",
            "Source evidence",
            "Provenance limit",
            "not uniquely provable",
            "License",
            "What is kept",
            "dropped",
            "Local modifications",
            "tools/user/build-openlibm.sh",
            "How it is built and used",
            "re-vendor",
        ],
        "forbidden": [
            "exact recorded version and commit currently unknown",
            "No upstream version macro, commit, tag file, or archive checksum is present",
        ],
    },
}

DOC_NEEDLES = [
    "quickjs",
    "wamr",
    "openlibm",
    "README.vendored.md",
    "tcb-components.json",
    "THIRD-PARTY-LICENSES.md",
    "CVE",
    "advisory",
    "GitHub Security Advisories",
    "security-driven",
    "archive checksum",
]


def fail(message: str) -> None:
    print(f"FAIL: vendoring-test - {message}", file=sys.stderr)


def load_tcb_components() -> tuple[dict[str, dict[str, object]], list[str]]:
    errors: list[str] = []
    try:
        data = json.loads(TCB_COMPONENTS.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}, [f"missing {TCB_COMPONENTS.relative_to(ROOT)}"]
    except json.JSONDecodeError as exc:
        return {}, [f"{TCB_COMPONENTS.relative_to(ROOT)} is not valid JSON: {exc}"]

    if data.get("schema_version") != 1:
        errors.append("docs/tcb-components.json schema_version must be 1")
    components = data.get("components")
    if not isinstance(components, list) or not components:
        errors.append("docs/tcb-components.json must define a non-empty components list")
        return {}, errors

    by_id: dict[str, dict[str, object]] = {}
    for component in components:
        if not isinstance(component, dict):
            errors.append("each TCB component must be an object")
            continue
        component_id = component.get("id")
        if not isinstance(component_id, str) or not component_id:
            errors.append("each TCB component must define a non-empty id")
            continue
        if component_id in by_id:
            errors.append(f"duplicate TCB component id {component_id}")
            continue
        by_id[component_id] = component
    return by_id, errors


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


def check_tcb_component_metadata(components: dict[str, dict[str, object]]) -> list[str]:
    errors: list[str] = []
    vendored_ids = {
        component_id
        for component_id, component in components.items()
        if component.get("category") == "vendored"
    }
    expected_ids = set(DEPENDENCIES)
    missing_vendored = sorted(expected_ids - vendored_ids)
    if missing_vendored:
        errors.append(f"docs/tcb-components.json missing vendored components: {', '.join(missing_vendored)}")
    extra_vendored = sorted(vendored_ids - expected_ids)
    if extra_vendored:
        errors.append(f"docs/tcb-components.json has untracked vendored components: {', '.join(extra_vendored)}")

    for name, cfg in DEPENDENCIES.items():
        component = components.get(name)
        if not component:
            continue
        for field in (
            "owner",
            "summary",
            "upstream",
            "revision",
            "license",
            "license_file",
            "provenance_file",
            "advisory_status",
            "review_after",
        ):
            if not isinstance(component.get(field), str) or not component[field]:
                errors.append(f"TCB component {name} must define {field}")
        if component.get("advisory_status") == "unknown":
            errors.append(f"TCB component {name} must not have unknown advisory_status")
        profiles = component.get("profiles")
        if not isinstance(profiles, list) or not profiles:
            errors.append(f"TCB component {name} must list owning profiles")
        else:
            for profile in profiles:
                if not isinstance(profile, str) or not profile:
                    errors.append(f"TCB component {name} has invalid profile entry {profile!r}")
        local_modifications = component.get("local_modifications")
        if not isinstance(local_modifications, list) or not local_modifications:
            errors.append(f"TCB component {name} must list local_modifications")
        license_rel = cfg["license"]
        assert isinstance(license_rel, str)
        expected_license = f"third_party/{name}/{license_rel}"
        if component.get("license_file") != expected_license:
            errors.append(f"TCB component {name} license_file must be {expected_license}")
        expected_readme = f"third_party/{name}/README.vendored.md"
        if component.get("provenance_file") != expected_readme:
            errors.append(f"TCB component {name} provenance_file must be {expected_readme}")
        if not (ROOT / expected_license).is_file():
            errors.append(f"TCB component {name} license_file path is missing")
        if not (ROOT / expected_readme).is_file():
            errors.append(f"TCB component {name} provenance_file path is missing")
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


def check_manifest_links() -> list[str]:
    manifest = ROOT / "THIRD-PARTY-LICENSES.md"
    if not manifest.is_file():
        return ["missing THIRD-PARTY-LICENSES.md"]
    text = manifest.read_text(encoding="utf-8")
    errors: list[str] = []
    for name, cfg in DEPENDENCIES.items():
        readme = f"third_party/{name}/README.vendored.md"
        if f"`{readme}`" not in text:
            errors.append(f"THIRD-PARTY-LICENSES.md does not reference {readme}")
        license_rel = cfg["license"]
        assert isinstance(license_rel, str)
        license_path = f"third_party/{name}/{license_rel}"
        if f"`{license_path}`" not in text:
            errors.append(f"THIRD-PARTY-LICENSES.md does not reference {license_path}")
    return errors


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
    components, component_errors = load_tcb_components()
    errors.extend(component_errors)
    for name, cfg in DEPENDENCIES.items():
        errors.extend(check_dependency(name, cfg))
    if components:
        errors.extend(check_tcb_component_metadata(components))
    errors.extend(check_no_extra_license_deps())
    errors.extend(check_doc())
    errors.extend(check_manifest_links())
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
