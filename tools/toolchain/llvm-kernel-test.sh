#!/usr/bin/env bash
# Kernel LLVM gate: lower every non-bad kernel/ module to LLVM IR, verify the IR
# with llvm-as, and compile it to a non-empty target object with llc.
#
# Each module is independent, so the suite fans out across the available cores
# (override with JOBS=N). Parallelism only changes output ordering; a single
# failing module still fails the gate.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-env.sh"
HERE="$(mc_repo_root)"
LLVM_AS="${LLVM_AS:-llvm-as}"
LLC="${LLC:-llc}"
JOBS="${JOBS:-$(mc_host_jobs)}"

command -v "$LLVM_AS" >/dev/null 2>&1 || { echo "SKIP: llvm-kernel-test (llvm-as not found)"; exit 0; }
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: llvm-kernel-test (llc not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export MCC LLVM_AS LLC WORK HERE

# Lower one module to LLVM IR, verify it with llvm-as, and compile it to a non-empty
# target object. Per-module scratch files are named from the source path so parallel
# workers never collide; any failure returns non-zero and xargs fails the gate.
llk_one() {
    local src="$1"
    local rel="${src#"$HERE"/}"
    local stem="${rel//\//_}"
    local ll="$WORK/$stem.ll"
    local bc="$WORK/$stem.bc"
    local obj="$WORK/$stem.o"
    local err="$WORK/$stem.err"

    if ! "$MCC" emit-llvm "$src" >"$ll" 2>"$err"; then
        echo "FAIL: llvm-kernel-test - $rel did not lower to LLVM"; cat "$err"; return 1
    fi
    if ! "$LLVM_AS" "$ll" -o "$bc" 2>"$err"; then
        echo "FAIL: llvm-kernel-test - $rel emitted invalid LLVM IR"; cat "$err"; return 1
    fi
    local triple
    case "$rel" in
        kernel/arch/x86_64/*) triple="x86_64-unknown-none" ;;
        *) triple="riscv64-unknown-elf" ;;
    esac
    if ! "$LLC" -mtriple="$triple" -filetype=obj "$ll" -o "$obj" 2>"$err"; then
        echo "FAIL: llvm-kernel-test - $rel did not compile to a $triple LLVM object"; cat "$err"; return 1
    fi
    if [ ! -s "$obj" ]; then
        echo "FAIL: llvm-kernel-test - $rel produced an empty LLVM object"; return 1
    fi
}
export -f llk_one

modules_file="$WORK/modules.list"
find "$HERE/kernel" -name '*.mc' ! -path '*/kernel/bad/*' | sort >"$modules_file"
count="$(mc_count_lines "$modules_file")"
tr '\n' '\0' <"$modules_file" | xargs -0 -P "$JOBS" -I{} bash -c 'llk_one "$@"' _ {}

echo "PASS: llvm-kernel-test - $count kernel modules emit assemblable LLVM IR and non-empty target objects"
