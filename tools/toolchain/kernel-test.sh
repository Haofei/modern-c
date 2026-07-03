#!/usr/bin/env bash
# Kernel-suite gate: lower every kernel/ module to C, compile-check it for the
# riscv64 freestanding target, and verify the kernel/bad/ typestate misuses are
# rejected. (The runnable net path is gated separately by `net-test`.)
#
# Each module is an independent compile-check, so both phases fan out across the
# available cores (override with JOBS=N). Parallelism only changes output
# ordering; a single failing module still fails the whole gate.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-env.sh"
HERE="$(mc_repo_root)"
CLANG="${CLANG:-clang}"
JOBS="${JOBS:-$(mc_host_jobs)}"

# A missing toolchain/target normally SKIPs (so host dev without a riscv64 clang stays
# green), but a CONFORMANCE tier (c1) requires the riscv64 compile to actually run — there
# a skip is a FAILURE, not a pass. `MC_REQUIRE_TARGET=1` (set by the conformance tiers in
# build.zig) flips skip into a hard failure so the tier cannot pass vacuously.
unavailable() { # $1 = reason
    if [ -n "${MC_REQUIRE_TARGET:-}" ]; then
        echo "FAIL: kernel-test — $1 (required by this conformance tier; set MC_REQUIRE_TARGET only where the riscv64 toolchain is present)"
        exit 1
    fi
    echo "SKIP: kernel-test ($1)"
    exit 0
}
command -v "$CLANG" >/dev/null 2>&1 || unavailable "clang not found"
"$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || unavailable "no riscv64 target"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Each module compiles for ITS OWN target. Modules under kernel/arch/<arch>/ carry
# that ISA's inline asm, so compiling them for the wrong triple is a guaranteed
# (and meaningless) failure — the same per-arch split llvm-kernel-test already uses
# on the LLVM path. Everything else is portable kernel logic, built for riscv64.
COMMON_CFLAGS="-nostdlib -ffreestanding -fno-pic -O1 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function"
RISCV_CFLAGS="--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -mcmodel=medany $COMMON_CFLAGS"
X86_CFLAGS="--target=x86_64-unknown-none -mcmodel=kernel -mno-red-zone $COMMON_CFLAGS"

export MCC CLANG WORK HERE RISCV_CFLAGS X86_CFLAGS

# Map a module's path to the CFLAGS for its target ISA.
kt_cflags_for() {
    case "$1" in
        kernel/arch/x86_64/*) printf '%s' "$X86_CFLAGS" ;;
        *) printf '%s' "$RISCV_CFLAGS" ;;
    esac
}
export -f kt_cflags_for

# 1. Every kernel module must lower to C that compiles for its target ISA. Each worker
# lowers + compiles one module into a per-module scratch file (named from the
# source path so parallel workers never collide) and returns non-zero on the
# first problem; xargs then fails the gate.
kt_compile_one() {
    local src="$1"
    local name="${src#"$HERE"/}"
    local id; id="$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')"
    local c="$WORK/$id.c"
    local e="$WORK/$id.err"
    local cflags; cflags="$(kt_cflags_for "$name")"
    local triple="${cflags#--target=}"; triple="${triple%% *}"
    if ! "$MCC" emit-c "$src" >"$c" 2>"$e"; then
        echo "FAIL: kernel-test — $name did not lower to C"; cat "$e"; return 1
    fi
    if ! "$CLANG" $cflags -c "$c" -o /dev/null 2>"$e"; then
        echo "FAIL: kernel-test — $name produced C that does not compile for $triple"; head "$e"; return 1
    fi
}
export -f kt_compile_one

modules_file="$WORK/modules.list"
find "$HERE/kernel" -name '*.mc' ! -path '*/kernel/bad/*' | sort >"$modules_file"
count="$(mc_count_lines "$modules_file")"
tr '\n' '\0' <"$modules_file" | xargs -0 -P "$JOBS" -I{} bash -c 'kt_compile_one "$@"' _ {}

# 2. Typestate misuses must be rejected with the error their EXPECT: line names (parallel).
kt_reject_one() {
    local src="$1"
    local name="bad/$(basename "$src")"
    local want; want="$(grep -o 'EXPECT: [A-Z_]*' "$src" | awk '{print $2}')"
    # A reject fixture must FAIL `check` (nonzero exit) AND name its diagnostic — asserting
    # only on the message lets a fixture that actually COMPILES pass. Capture status, not `|| true`.
    local out rc
    set +e
    out="$("$MCC" check "$src" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: kernel-test — $name should have been REJECTED ($want) but check succeeded (rc=0)"; return 1
    fi
    if ! printf '%s' "$out" | grep -q "$want"; then
        echo "FAIL: kernel-test — $name rejected, but not with $want"; printf '%s\n' "$out" | head; return 1
    fi
}
export -f kt_reject_one

rejects=0
if compgen -G "$HERE/kernel/bad/*.mc" >/dev/null; then
    bads_file="$WORK/bads.list"
    find "$HERE/kernel/bad" -name '*.mc' | sort >"$bads_file"
    rejects="$(mc_count_lines "$bads_file")"
    tr '\n' '\0' <"$bads_file" | xargs -0 -P "$JOBS" -I{} bash -c 'kt_reject_one "$@"' _ {}
fi

echo "PASS: kernel-test — $count kernel modules compile for their target ISA; $rejects typestate misuses rejected"
exit 0
