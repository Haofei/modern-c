#!/usr/bin/env python3
"""Generate/check docs/diagnostics.md from compiler-emitted E_* codes."""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


CODE_RE = re.compile(r"(?<![A-Z0-9_])E_[A-Z0-9_]+(?![A-Z0-9_])")
CODE_MESSAGE_RE = re.compile(
    r'"(?P<code>E_[A-Z0-9_]+)"\s*,\s*"(?P<message>(?:[^"\\]|\\.)*)"'
)
INLINE_MESSAGE_RE = re.compile(
    r"(?<![A-Z0-9_])(?P<code>E_[A-Z0-9_]+):\s*(?P<message>.*)"
)


@dataclass
class CodeInfo:
    refs: list[str] = field(default_factory=list)
    messages: set[str] = field(default_factory=set)


def strip_line_comment(line: str) -> str:
    in_string = False
    escaped = False
    i = 0
    while i + 1 < len(line):
        ch = line[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == "/" and line[i + 1] == "/":
            return line[:i]
        i += 1
    return line


def string_literals(line: str) -> list[str]:
    out: list[str] = []
    i = 0
    while i < len(line):
        if line[i] != '"':
            i += 1
            continue
        i += 1
        chars: list[str] = []
        escaped = False
        while i < len(line):
            ch = line[i]
            if escaped:
                chars.append("\\" + ch)
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                break
            else:
                chars.append(ch)
            i += 1
        out.append("".join(chars))
        i += 1
    return out


def unescape_for_doc(s: str) -> str:
    return (
        s.replace(r"\\", "\\")
        .replace(r"\"", '"')
        .replace(r"\n", " ")
        .replace(r"\t", " ")
    )


def normalize_message(s: str) -> str:
    msg = unescape_for_doc(s).strip()
    msg = re.sub(r"\s+", " ", msg)
    return msg.rstrip(".")


def source_files(root: Path) -> list[Path]:
    src = root / "src"
    return sorted(
        p
        for p in src.glob("*.zig")
        if not p.name.endswith("_tests.zig")
    )


def collect(root: Path) -> dict[str, CodeInfo]:
    codes: dict[str, CodeInfo] = {}
    for path in source_files(root):
        rel = path.relative_to(root).as_posix()
        lines = path.read_text(encoding="utf-8").splitlines()
        for idx, raw in enumerate(lines, 1):
            line = strip_line_comment(raw)
            for literal in string_literals(line):
                for code in CODE_RE.findall(literal):
                    if code == "E_TEST":
                        continue
                    info = codes.setdefault(code, CodeInfo())
                    ref = f"{rel}:{idx}"
                    if ref not in info.refs:
                        info.refs.append(ref)
                    inline = INLINE_MESSAGE_RE.search(literal)
                    if inline and inline.group("code") == code:
                        info.messages.add(normalize_message(inline.group("message")))
            for match in CODE_MESSAGE_RE.finditer(line):
                code = match.group("code")
                if code == "E_TEST":
                    continue
                info = codes.setdefault(code, CodeInfo())
                info.messages.add(normalize_message(match.group("message")))
    return codes


def render(root: Path) -> str:
    codes = collect(root)
    lines: list[str] = [
        "# MC compiler diagnostics",
        "",
        "This file is generated from `E_*` diagnostic codes emitted by production Zig sources under `src/`.",
        "Regenerate it with:",
        "",
        "```sh",
        "python3 tools/toolchain/diagnostics-reference.py --write",
        "```",
        "",
        f"Total codes: **{len(codes)}**.",
        "",
        "| Code | Message examples | Source references |",
        "|---|---|---|",
    ]
    for code in sorted(codes):
        info = codes[code]
        messages = sorted(m for m in info.messages if m)
        msg_cell = "<br>".join(markdown_escape(m) for m in messages[:3]) if messages else "_see source_"
        if len(messages) > 3:
            msg_cell += f"<br>_+{len(messages) - 3} more_"
        ref_cell = "<br>".join(f"`{ref}`" for ref in info.refs[:6])
        if len(info.refs) > 6:
            ref_cell += f"<br>_+{len(info.refs) - 6} more_"
        lines.append(f"| `{code}` | {msg_cell} | {ref_cell} |")
    lines.append("")
    return "\n".join(lines)


def markdown_escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("|", "\\|")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("`", "\\`")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="rewrite docs/diagnostics.md")
    parser.add_argument("--check", action="store_true", help="fail if docs/diagnostics.md is stale")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    target = root / "docs" / "diagnostics.md"
    generated = render(root)

    if args.write:
        target.write_text(generated, encoding="utf-8")
        return 0
    if args.check:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != generated:
            diff = difflib.unified_diff(
                current.splitlines(),
                generated.splitlines(),
                fromfile=str(target),
                tofile="generated",
                lineterm="",
            )
            print("\n".join(diff), file=sys.stderr)
            print("FAIL: diagnostics reference is stale; run python3 tools/toolchain/diagnostics-reference.py --write", file=sys.stderr)
            return 1
        print("PASS: diagnostics reference covers all compiler E_* codes")
        return 0
    print(generated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
