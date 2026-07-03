#!/usr/bin/env python3
"""Static gate for release/version/process metadata."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
EXPECTED_VERSION = "0.7.0-dev"


def fail(message: str) -> None:
    print(f"FAIL: release-metadata-test - {message}")
    sys.exit(1)


def read(path: str) -> str:
    full = ROOT / path
    if not full.is_file():
        fail(f"missing {path}")
    return full.read_text(encoding="utf-8")


def require_contains(path: str, needle: str) -> None:
    if needle not in read(path):
        fail(f"{path} does not contain {needle!r}")


def zon_field(text: str, name: str) -> str:
    match = re.search(rf"\.{re.escape(name)}\s*=\s*\"([^\"]+)\"", text)
    if not match:
        fail(f"build.zig.zon missing .{name}")
    return match.group(1)


def main() -> None:
    zon = read("build.zig.zon")
    version = zon_field(zon, "version")
    if version != EXPECTED_VERSION:
        fail(f"build.zig.zon version is {version!r}, want {EXPECTED_VERSION!r}")

    minimum_zig = zon_field(zon, "minimum_zig_version")
    zigversion = read(".zigversion").strip()
    if minimum_zig != zigversion:
        fail(f"minimum_zig_version {minimum_zig!r} does not match .zigversion {zigversion!r}")

    compiler_build = read("build/compiler.zig")
    require_contains("build/compiler.zig", 'b.option([]const u8, "version"')
    require_contains("build/compiler.zig", f'orelse "{EXPECTED_VERSION}"')
    require_contains("src/main.zig", "@import(\"build_options\")")
    require_contains("src/main.zig", "build_options.version")

    for path in ("SECURITY.md", "STABILITY.md", "CHANGELOG.md", "docs/release-process.md"):
        require_contains(path, EXPECTED_VERSION)

    if "root_module.addOptions(\"build_options\"" not in compiler_build:
        fail("build/compiler.zig does not expose build_options to src/main.zig")

    print("PASS: release-metadata-test - version, Zig pin, and process docs are in sync")


if __name__ == "__main__":
    main()
