#!/usr/bin/env bash
# Fast local regression gate for MIR/backend cleanup authority work.
#
# This is intentionally narrower than `zig build test c-test llvm-test ...`.
# It covers the cleanup/defer/auto-drop unit tests plus the two inventory gates
# that prevent backend-local ownership authority from regressing.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 tools/toolchain/semantic-facts-inventory.py
python3 tools/toolchain/mir-identity-inventory.py
zig test src/main.zig \
  --test-filter "defer" \
  --test-filter "auto-drop" \
  --test-filter "explicit drop glue"

echo "PASS: cleanup-fast-test — MIR/backend defer and auto-drop cleanup authority checks passed"
