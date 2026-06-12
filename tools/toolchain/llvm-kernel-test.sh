#!/usr/bin/env bash
# Kernel LLVM gate: lower every non-bad kernel/ module to LLVM IR, verify the IR
# with llvm-as, and compile it to a non-empty target object with llc.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
LLVM_AS="${LLVM_AS:-llvm-as}"
LLC="${LLC:-llc}"

command -v "$LLVM_AS" >/dev/null 2>&1 || { echo "SKIP: llvm-kernel-test (llvm-as not found)"; exit 0; }
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: llvm-kernel-test (llc not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

count=0
for src in $(find "$HERE/kernel" -name '*.mc' | sort); do
    case "$src" in */kernel/bad/*) continue ;; esac
    rel="${src#"$HERE"/}"
    stem="${rel//\//_}"
    ll="$WORK/$stem.ll"
    bc="$WORK/$stem.bc"
    obj="$WORK/$stem.o"

    if ! "$MCC" emit-llvm "$src" >"$ll" 2>"$WORK/err"; then
        echo "FAIL: llvm-kernel-test - $rel did not lower to LLVM"
        cat "$WORK/err"
        exit 1
    fi
    if ! "$LLVM_AS" "$ll" -o "$bc" 2>"$WORK/err"; then
        echo "FAIL: llvm-kernel-test - $rel emitted invalid LLVM IR"
        cat "$WORK/err"
        exit 1
    fi

    case "$rel" in
        kernel/arch/x86_64/*) triple="x86_64-unknown-none" ;;
        *) triple="riscv64-unknown-elf" ;;
    esac
    if ! "$LLC" -mtriple="$triple" -filetype=obj "$ll" -o "$obj" 2>"$WORK/err"; then
        echo "FAIL: llvm-kernel-test - $rel did not compile to a $triple LLVM object"
        cat "$WORK/err"
        exit 1
    fi
    if [ ! -s "$obj" ]; then
        echo "FAIL: llvm-kernel-test - $rel produced an empty LLVM object"
        exit 1
    fi
    count=$((count + 1))
done

echo "PASS: llvm-kernel-test - $count kernel modules emit assemblable LLVM IR and non-empty target objects"
