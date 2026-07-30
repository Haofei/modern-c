#!/usr/bin/env python3
"""Verify an MC source-map artifact bundle.

The `.mcmap` header records the generated artifact digest and the digest of the
source-map payload (`# columns:` plus `entry` rows). This tool is the consumer
side of that contract: it rejects a map whose body was substituted and rejects a
map paired with the wrong generated artifact.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path


HEX64_RE = re.compile(r"^[0-9a-f]{64}$")


class VerifyError(Exception):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_file(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise VerifyError(f"cannot read {path}: {exc}") from exc


def parse_mcmap(data: bytes) -> tuple[dict[str, str], bytes]:
    headers: dict[str, str] = {}
    lines = data.splitlines(keepends=True)
    payload_start: int | None = None

    for index, line in enumerate(lines):
        if line.startswith(b"# columns:"):
            payload_start = index
            break

        if not line.startswith(b"# "):
            continue

        body = line[2:].rstrip(b"\r\n")
        if b"=" not in body:
            continue

        key, value = body.split(b"=", 1)
        try:
            headers[key.decode("ascii")] = value.decode("ascii")
        except UnicodeDecodeError as exc:
            raise VerifyError("mcmap header contains non-ASCII key or value") from exc

    if payload_start is None:
        raise VerifyError("missing source-map payload marker '# columns:'")

    payload = b"".join(lines[payload_start:])
    return headers, payload


def require_header(headers: dict[str, str], name: str) -> str:
    value = headers.get(name)
    if value is None:
        raise VerifyError(f"missing required header '{name}'")
    return value


def require_sha256_header(headers: dict[str, str], name: str) -> str:
    value = require_header(headers, name)
    if not HEX64_RE.fullmatch(value):
        raise VerifyError(f"header '{name}' is not a lowercase SHA-256 digest")
    return value


def verify(args: argparse.Namespace) -> None:
    map_data = read_file(args.map)
    headers, payload = parse_mcmap(map_data)

    expected_payload_digest = require_sha256_header(headers, "source_map_payload_sha256")
    actual_payload_digest = sha256_bytes(payload)
    if actual_payload_digest != expected_payload_digest:
        raise VerifyError(
            "source-map payload digest mismatch: "
            f"header={expected_payload_digest} actual={actual_payload_digest}"
        )

    require_sha256_header(headers, "mir_facts_sha256")

    if args.artifact is not None:
        expected_artifact_digest = require_sha256_header(headers, "generated_artifact_sha256")
        actual_artifact_digest = sha256_bytes(read_file(args.artifact))
        if actual_artifact_digest != expected_artifact_digest:
            raise VerifyError(
                "generated artifact digest mismatch: "
                f"header={expected_artifact_digest} actual={actual_artifact_digest}"
            )

    if args.source is not None:
        expected_source_digest = require_sha256_header(headers, "source_sha256")
        actual_source_digest = sha256_bytes(read_file(args.source))
        if actual_source_digest != expected_source_digest:
            raise VerifyError(
                "source digest mismatch: "
                f"header={expected_source_digest} actual={actual_source_digest}"
            )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify an MC .mcmap bundle header against its payload and optional paired files.",
    )
    parser.add_argument("--map", required=True, type=Path, help="Path to the .mcmap file")
    parser.add_argument(
        "--artifact",
        type=Path,
        help="Generated artifact that must match generated_artifact_sha256",
    )
    parser.add_argument(
        "--source",
        type=Path,
        help="Exact loaded source object that must match source_sha256",
    )
    args = parser.parse_args()

    try:
        verify(args)
    except VerifyError as exc:
        print(f"FAIL: mcmap-verify — {exc}", file=sys.stderr)
        return 1

    print("PASS: mcmap-verify")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
