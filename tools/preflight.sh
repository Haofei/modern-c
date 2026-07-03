#!/usr/bin/env bash
# Preflight: verify the toolchain the QEMU milestone gates need, with a clear per-tool report.
# Exits non-zero if anything required is missing. Run via `zig build preflight`.
#
# The project's Docker dev image ships all of these — `COMPOSE_PROJECT_NAME=modern-c docker compose
# run --rm dev` — so on the host you typically run the gates inside the container. Milestone gates
# invoked with MC_REQUIRE_TOOLS=1 (or CI=1) FAIL rather than skip when a tool is absent, so a green
# run cannot hide a missing toolchain; this preflight is the fast, explicit check for that setup.
set -uo pipefail

CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
LLVM_AS="${LLVM_AS:-llvm-as}"
OPT="${OPT:-opt}"
QEMU="${QEMU:-qemu-system-riscv64}"
LLVM_MAJOR="${MC_LLVM_MAJOR:-}"

missing=0
check() {
    local tool="$1" why="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        printf '  ok    %-26s %s\n' "$tool" "$why"
    else
        printf '  MISS  %-26s %s\n' "$tool" "$why"
        missing=1
    fi
}

check_llvm_major() {
    local tool="$1"
    [ -n "$LLVM_MAJOR" ] || return 0
    if ! command -v "$tool" >/dev/null 2>&1; then
        return 0
    fi
    if "$tool" --version 2>/dev/null | grep -Eq "(version |LLD )${LLVM_MAJOR}\\."; then
        printf '  ok    %-26s %s\n' "$tool major" "LLVM $LLVM_MAJOR"
    else
        printf '  MISS  %-26s expected LLVM %s.x\n' "$tool major" "$LLVM_MAJOR"
        "$tool" --version 2>/dev/null | head -n 1
        missing=1
    fi
}

echo "Preflight: toolchain required by the QEMU milestone gates"
check "$CLANG" "compile MC->C/LLVM + freestanding C (riscv64)"
check "$LLD" "link the kernel / app ELFs"
check "$LLC" "emit-llvm backend object lowering"
check "$LLVM_AS" "validate emitted LLVM IR"
check "$OPT" "run LLVM optimizer verification"
check "$QEMU" "run the kernel under riscv64 virt"
check_llvm_major "$CLANG"
check_llvm_major "$LLD"
check_llvm_major "$LLC"
check_llvm_major "$LLVM_AS"
check_llvm_major "$OPT"

# clang must actually carry the riscv64 target, not just exist.
if command -v "$CLANG" >/dev/null 2>&1; then
    if "$CLANG" --print-targets 2>/dev/null | grep -q riscv64; then
        printf '  ok    %-26s %s\n' "riscv64 target" "clang can target riscv64"
    else
        printf '  MISS  %-26s %s\n' "riscv64 target" "clang lacks the riscv64 target"
        missing=1
    fi
fi

if [ "$missing" -ne 0 ]; then
    echo "PREFLIGHT: FAIL — install the missing tools (the Docker dev image has them all:"
    echo "  COMPOSE_PROJECT_NAME=modern-c docker compose run --rm dev). With MC_REQUIRE_TOOLS=1/CI=1"
    echo "  the milestone gates FAIL (not skip) without these."
    exit 1
fi
echo "PREFLIGHT: OK — all required tools present"
