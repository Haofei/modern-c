#!/usr/bin/env python3
"""Keep the kernel scoped as a language-validation workload, not a product roadmap."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOTS = [ROOT / "docs", ROOT / "kernel"]
INCLUDED_SUFFIXES = {".md", ".mc"}
EXCLUDED_DOCS = {
    ROOT / "docs" / "compiler-production-readiness.md",
}

FORBIDDEN = [
    ("kernel product target", re.compile(r"\bproduction target\b", re.IGNORECASE)),
    ("appliance kernel product claim", re.compile(r"\bappliance[- ]kernel\b", re.IGNORECASE)),
    ("hardware pilot claim", re.compile(r"\bfield pilot\b", re.IGNORECASE)),
    ("fixed-device product claim", re.compile(r"\bfixed-device production\b", re.IGNORECASE)),
    ("production-candidate board profile", re.compile(r"\bproduction-candidate\b", re.IGNORECASE)),
    ("production-shaped kernel path", re.compile(r"\bproduction-shaped\b", re.IGNORECASE)),
    ("production JS fixture claim", re.compile(r"\bproduction JS\b", re.IGNORECASE)),
    ("agent production surface roadmap", re.compile(r"\bAgent production surface\b", re.IGNORECASE)),
    ("kernel production checklist", re.compile(r"\bMinimum production checklist\b", re.IGNORECASE)),
    ("product runtime roadmap", re.compile(r"\bproduct runtime roadmap\b", re.IGNORECASE)),
    ("kernel secure-update claim", re.compile(r"\b(secure boot|verified boot|signed bundle|anti-rollback|OTA/live-update|Kernel OTA|live-update gate)\b", re.IGNORECASE)),
]

ALLOWED_CONTEXT = (
    "out of scope",
    "outside",
    "removed",
    "not part",
    "not treated",
    "no kernel",
    "future",
    "external product scope",
)


def fail(message: str) -> int:
    print(f"FAIL: kernel-scope-inventory-test - {message}", file=sys.stderr)
    return 1


def iter_files() -> list[Path]:
    files: list[Path] = []
    for root in SCAN_ROOTS:
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in INCLUDED_SUFFIXES:
                continue
            if path in EXCLUDED_DOCS:
                continue
            files.append(path)
    return sorted(files)


def allowed_context(line: str) -> bool:
    lower = line.lower()
    return any(marker in lower for marker in ALLOWED_CONTEXT)


def main() -> int:
    violations: list[str] = []
    scanned = 0
    for path in iter_files():
        scanned += 1
        rel = path.relative_to(ROOT)
        text = path.read_text(encoding="utf-8")
        for line_no, line in enumerate(text.splitlines(), 1):
            for label, pattern in FORBIDDEN:
                if not pattern.search(line):
                    continue
                if allowed_context(line):
                    continue
                violations.append(f"{rel}:{line_no}: {label}: {line.strip()}")

    if violations:
        return fail("kernel product-scope wording is not explicitly out of scope:\n" + "\n".join(violations))

    print(f"PASS: kernel-scope-inventory-test - scanned {scanned} docs/kernel files; kernel product-scope wording stays out of current scope")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
