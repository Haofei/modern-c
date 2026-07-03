#!/usr/bin/env python3
"""Generate/check docs/std-api.md from exported stdlib declarations."""

from __future__ import annotations

import argparse
import difflib
import html
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


EXPORT_RE = re.compile(r"^\s*export\s+")
EXPORT_FN_RE = re.compile(r"^\s*export\s+(?:const\s+)?fn\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b")
EXPORT_CONST_RE = re.compile(r"^\s*export\s+const\s+(?!fn\b)(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b")
EXPORT_TYPE_RE = re.compile(
    r"^\s*export\s+(?:(?:opaque|move|extern|mmio)\s+){0,4}(?P<kind>struct|enum|trait|type)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)
TYPE_RE = re.compile(
    r"^\s*(?P<prefix>(?:(?:opaque|move|extern|mmio)\s+){0,4})(?P<kind>struct|enum|trait|type)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
)
IDENT_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")

KEYWORDS_AND_BUILTINS = {
    "as",
    "bool",
    "closure",
    "comptime",
    "const",
    "dyn",
    "export",
    "f32",
    "f64",
    "false",
    "fn",
    "i16",
    "i32",
    "i64",
    "i8",
    "move",
    "mut",
    "opaque",
    "struct",
    "trait",
    "true",
    "type",
    "u16",
    "u32",
    "u64",
    "u8",
    "usize",
    "void",
}


@dataclass
class Decl:
    name: str
    signature: str
    path: str
    line: int
    kind: str


@dataclass
class ModuleApi:
    path: str
    functions: list[Decl] = field(default_factory=list)
    constants: list[Decl] = field(default_factory=list)
    exported_types: list[Decl] = field(default_factory=list)
    local_types: dict[str, Decl] = field(default_factory=dict)

    def referenced_local_types(self) -> list[Decl]:
        names: set[str] = set()
        for decl in [*self.functions, *self.constants, *self.exported_types]:
            for ident in IDENT_RE.findall(decl.signature):
                if ident not in KEYWORDS_AND_BUILTINS:
                    names.add(ident)
        return [decl for name, decl in self.local_types.items() if name in names]


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


def source_files(root: Path) -> list[Path]:
    return sorted((root / "std").glob("**/*.mc"))


def normalize_signature(signature: str) -> str:
    return re.sub(r"\s+", " ", signature).strip()


def decl_end(text: str, kind: str) -> tuple[int, bool]:
    terminators = ";" if kind == "const" else "{;"
    in_string = False
    escaped = False
    for idx, ch in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch in terminators:
            include = kind == "const" and ch == ";"
            return idx + 1 if include else idx, True
    return len(text), False


def classify_export(line: str) -> tuple[str, str] | None:
    if match := EXPORT_FN_RE.match(line):
        return "fn", match.group("name")
    if match := EXPORT_CONST_RE.match(line):
        return "const", match.group("name")
    if match := EXPORT_TYPE_RE.match(line):
        return match.group("kind"), match.group("name")
    return None


def parse_module(root: Path, path: Path) -> ModuleApi:
    rel = path.relative_to(root).as_posix()
    module = ModuleApi(rel)
    lines = path.read_text(encoding="utf-8").splitlines()

    idx = 0
    while idx < len(lines):
        raw = lines[idx]
        line = strip_line_comment(raw)
        stripped = line.strip()

        if not EXPORT_RE.match(line):
            if match := TYPE_RE.match(line):
                kind = match.group("kind")
                name = match.group("name")
                end, _ = decl_end(line, "const" if kind == "type" else "type")
                module.local_types.setdefault(
                    name,
                    Decl(
                        name=name,
                        signature=normalize_signature(line[:end]),
                        path=rel,
                        line=idx + 1,
                        kind=kind,
                    ),
                )
            idx += 1
            continue

        classified = classify_export(line)
        if classified is None:
            idx += 1
            continue

        kind, name = classified
        start_line = idx + 1
        pieces = [stripped]
        search_text = stripped
        end, done = decl_end(search_text, "const" if kind in {"const", "type"} else "type")
        while not done and idx + 1 < len(lines):
            idx += 1
            next_line = strip_line_comment(lines[idx]).strip()
            pieces.append(next_line)
            search_text = " ".join(pieces)
            end, done = decl_end(search_text, "const" if kind in {"const", "type"} else "type")

        signature = normalize_signature(search_text[:end])
        decl = Decl(name=name, signature=signature, path=rel, line=start_line, kind=kind)
        if kind == "fn":
            module.functions.append(decl)
        elif kind == "const":
            module.constants.append(decl)
        else:
            module.exported_types.append(decl)
            module.local_types.setdefault(name, decl)
        idx += 1

    return module


def collect(root: Path) -> list[ModuleApi]:
    modules = [parse_module(root, path) for path in source_files(root)]
    return [
        module
        for module in modules
        if module.functions or module.constants or module.exported_types
    ]


def code_cell(value: str) -> str:
    return f"<code>{html.escape(value, quote=False)}</code>"


def source_cell(decl: Decl) -> str:
    return f"`{decl.path}:{decl.line}`"


def table(lines: list[str], heading: str, decls: list[Decl]) -> None:
    if not decls:
        return
    lines.extend(
        [
            "",
            f"### {heading}",
            "",
            "| Signature | Source |",
            "|---|---|",
        ]
    )
    for decl in decls:
        lines.append(f"| {code_cell(decl.signature)} | {source_cell(decl)} |")


def render(root: Path) -> str:
    modules = collect(root)
    fn_count = sum(len(module.functions) for module in modules)
    const_count = sum(len(module.constants) for module in modules)
    exported_type_count = sum(len(module.exported_types) for module in modules)
    referenced_type_count = sum(len(module.referenced_local_types()) for module in modules)

    lines: list[str] = [
        "# MC standard library API",
        "",
        "This file is generated from exported declarations in `std/**/*.mc`.",
        "Regenerate it with:",
        "",
        "```sh",
        "python3 tools/toolchain/std-api-docs.py --write",
        "```",
        "",
        "The extractor is static: it records `export fn` signatures, exported constants,",
        "exported type declarations, and local types named by exported declarations.",
        "",
        f"Total modules: **{len(modules)}**.",
        f"Total exported functions: **{fn_count}**.",
        f"Total exported constants: **{const_count}**.",
        f"Total exported type declarations: **{exported_type_count}**.",
        f"Total referenced local types: **{referenced_type_count}**.",
        "",
        "## Modules",
    ]

    for module in modules:
        module_name = module.path.removesuffix(".mc")
        lines.extend(["", f"## `{module_name}`", "", f"Source: `{module.path}`"])
        table(lines, "Referenced local types", module.referenced_local_types())
        table(lines, "Exported types", module.exported_types)
        table(lines, "Exported constants", module.constants)
        table(lines, "Exported functions", module.functions)

    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="rewrite docs/std-api.md")
    parser.add_argument("--check", action="store_true", help="fail if docs/std-api.md is stale")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[2]
    target = root / "docs" / "std-api.md"
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
            print("FAIL: std API docs are stale; run python3 tools/toolchain/std-api-docs.py --write", file=sys.stderr)
            return 1
        print("PASS: std-api-docs - docs/std-api.md covers exported stdlib declarations")
        return 0
    print(generated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
