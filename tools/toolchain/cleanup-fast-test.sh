#!/usr/bin/env bash
# Fast local regression gate for MIR/backend cleanup authority work.
#
# This is intentionally narrower than `zig build test c-test llvm-test ...`.
# It covers the cleanup/defer/auto-drop unit tests plus the structural
# architecture-boundary check that keeps backends off the syntax front end.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

zig build architecture-boundary-test
zig test src/main.zig \
  --test-filter "defer" \
  --test-filter "auto-drop" \
  --test-filter "explicit drop glue"

echo "PASS: cleanup-fast-test — MIR/backend defer and auto-drop cleanup authority checks passed"
