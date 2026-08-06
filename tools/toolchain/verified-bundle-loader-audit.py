#!/usr/bin/env python3
"""Audit raw ELF loader entry points against the VerifiedBundle admission boundary.

`elf_load_image_for` is still a valid low-level loader primitive and direct loader
demo target. It must not silently reappear in app/agent admission paths that are
supposed to consume `VerifiedBundle` via `elf_load_verified_bundle_for`.
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CALL = "elf_load_image_for("

SCAN_ROOTS = (
    "kernel",
    "std",
    "user",
    "tests",
    "examples",
    "demo",
)

ALLOWLIST = {
    # The primitive and the VerifiedBundle-consuming wrapper live here.
    "kernel/core/elf_loader.mc": "low-level loader primitive and verified wrapper",
    # These fixtures intentionally exercise the raw loader/arch boundary itself.
    "tests/qemu/mem/elf_loader_demo.mc": "raw ELF loader regression fixture",
    "tests/arm/qjs_arm_demo.mc": "AArch64 arch-loader smoke fixture",
    "tests/x86/qjs_x86_demo.mc": "x86_64 arch-loader smoke fixture",
}


@dataclass(frozen=True)
class Finding:
    path: Path
    line: int
    text: str


def strip_comments_and_strings(line: str) -> str:
    out: list[str] = []
    in_string = False
    in_char = False
    escaped = False
    i = 0
    while i < len(line):
        ch = line[i]
        nxt = line[i + 1] if i + 1 < len(line) else ""
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if in_char:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "'":
                in_char = False
            i += 1
            continue
        if ch == "/" and nxt == "/":
            break
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == "'":
            in_char = True
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def iter_mc_files(root: Path, roots: tuple[str, ...]) -> list[Path]:
    files: list[Path] = []
    for rel in roots:
        scan_root = root / rel
        if scan_root.exists():
            files.extend(path for path in scan_root.rglob("*.mc") if path.is_file())
    return sorted(files)


def scan(root: Path, roots: tuple[str, ...]) -> list[Finding]:
    findings: list[Finding] = []
    for path in iter_mc_files(root, roots):
        rel = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError as exc:
            raise SystemExit(f"FAIL: verified-bundle-loader-audit - cannot decode {rel}: {exc}") from exc
        for line_no, line in enumerate(text.splitlines(), start=1):
            if CALL not in strip_comments_and_strings(line):
                continue
            if rel in ALLOWLIST:
                continue
            findings.append(Finding(path.relative_to(root), line_no, line.strip()))
    return findings


def emit_findings(findings: list[Finding]) -> None:
    for finding in findings:
        print(
            f"RAW-ELF-LOAD {finding.path}:{finding.line}: "
            f"{finding.text}",
            file=sys.stderr,
        )


def run_self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="verified-bundle-loader-audit-") as tmp:
        root = Path(tmp)
        (root / "kernel/core").mkdir(parents=True)
        (root / "tests/qemu/proc").mkdir(parents=True)
        (root / "kernel/core/elf_loader.mc").write_text(
            "export fn elf_load_image_for() -> void {}\n"
            "export fn elf_load_verified_bundle_for() -> void {\n"
            "    elf_load_image_for();\n"
            "}\n",
            encoding="utf-8",
        )
        (root / "tests/qemu/proc/raw_agent_loader.mc").write_text(
            "export fn bad_agent_load() -> void {\n"
            "    elf_load_image_for();\n"
            "}\n",
            encoding="utf-8",
        )
        findings = scan(root, ("kernel", "tests"))
        emit_findings(findings)
        if len(findings) != 1:
            print(
                f"FAIL: verified-bundle-loader-audit self-test expected 1 finding, got {len(findings)}",
                file=sys.stderr,
            )
            return 1
        print("PASS: verified-bundle-loader-audit self-test flagged raw app-loader bypass")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true", help="run the built-in negative fixture")
    parser.add_argument("roots", nargs="*", help="optional repo-relative roots to scan")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    roots = tuple(args.roots) if args.roots else SCAN_ROOTS
    findings = scan(ROOT, roots)
    if findings:
        emit_findings(findings)
        print(
            "FAIL: verified-bundle-loader-audit - raw elf_load_image_for call outside approved loader/demo files",
            file=sys.stderr,
        )
        return 1
    print(
        "PASS: verified-bundle-loader-audit - "
        f"raw elf_load_image_for calls confined to {len(ALLOWLIST)} approved loader/demo file(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
