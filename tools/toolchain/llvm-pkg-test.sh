#!/usr/bin/env bash
# Package-build test through the LLVM backend: reuse the manifest/dependency
# assertions from pkg-test, but compile the package object through emit-llvm/llc.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: llvm-pkg-test (clang not found)"; exit 0; }
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: llvm-pkg-test (llc not found)"; exit 0; }

MCC_UNDER_TEST="$MCC" MCC="$MCC" MCC_PKG_CC="$HERE/tools/toolchain/mcc-llvm-cc.sh" "$HERE/tools/toolchain/pkg-test.sh" "$MCC"
echo "PASS: llvm-pkg-test — package manifest built through LLVM, linked, and ran"
