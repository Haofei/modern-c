#!/usr/bin/env bash
# Per-architecture precise-asm register vocabularies (§23.2), split by target.
#
# The positive fixture uses each ISA's own mnemonics/registers (x86-64, RISC-V,
# AArch64, plus the shared x-registers), which cannot be host-assembled through the
# C emit sweep — so this is a `mcc check`-only gate: it asserts the fixture compiles
# with ZERO diagnostics, i.e. sema recognizes every architecture's register names
# and the arch-unification accepts each consistent block. The negative side (unknown
# register / mixed architectures / register & clobber conflicts) is covered by the
# inline-EXPECT_ERROR cases in tests/spec/inline_asm.mc. Needs only mcc.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/asm_targets.mc"

errors="$("$MCC" check "$SRC" 2>&1 | grep -c 'error:' || true)"
if [ "$errors" -ne 0 ]; then
    echo "FAIL: asm-targets-test — per-architecture register vocabulary should check clean, got $errors error(s)"
    "$MCC" check "$SRC" 2>&1 | grep 'error:' | head
    exit 1
fi
echo "PASS: asm-targets-test — x86-64 / RISC-V / AArch64 precise-asm register vocabularies all recognized and accepted"
