#!/usr/bin/env bash
set -euo pipefail

# mcc-llvm-cc: compile an MC module to a linkable object through LLVM IR.
#
# Usage: tools/toolchain/mcc-llvm-cc.sh <input.mc> [-o output.o] [llc args...]
# Defaults the object name to the input stem + ".o". Additional arguments are
# passed through to llc, so callers can provide target/relocation options.

MCC="${MCC:-mcc}"
LLC="${LLC:-llc}"

if [ "$#" -lt 1 ]; then
    echo "usage: mcc-llvm-cc.sh <input.mc> [-o output.o] [llc args...]" >&2
    exit 2
fi

INPUT="$1"
shift
OUT="${INPUT%.*}.o"
LLC_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            [ "$#" -ge 2 ] || { echo "mcc-llvm-cc: -o requires an argument" >&2; exit 2; }
            OUT="$2"
            shift 2
            ;;
        *)
            LLC_ARGS+=("$1")
            shift
            ;;
    esac
done

command -v "$LLC" >/dev/null 2>&1 || { echo "mcc-llvm-cc: llc not found" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
LL="$TMP_DIR/module.ll"

# Build-safety profile (D2.5): MC_CHECKS=all (default, SAFE) keeps every trap check;
# MC_CHECKS=elide-proven (RELEASE) elides only the optimizer-proven-dead ones (annex E.4).
CHECKS_FLAG=()
[ "${MC_CHECKS:-all}" != "all" ] && CHECKS_FLAG=(--checks="${MC_CHECKS}")
# Arch-selection seam (R0b): MC_ARCH picks which arch a `kernel/arch/active/...` import
# resolves to (default riscv64 in the compiler). Mirrors MC_CHECKS.
ARCH_FLAG=()
[ -n "${MC_ARCH:-}" ] && ARCH_FLAG=(--arch="${MC_ARCH}")
# Host-native logic tests of arch modules set MC_STUB_ASM=1 so inline asm lowers to a
# host-neutral stub (the target ISA's mnemonics can't be assembled on the host).
STUB_FLAG=()
[ -n "${MC_STUB_ASM:-}" ] && STUB_FLAG=(--stub-asm)
"$MCC" emit-llvm "$INPUT" ${CHECKS_FLAG[@]+"${CHECKS_FLAG[@]}"} ${ARCH_FLAG[@]+"${ARCH_FLAG[@]}"} ${STUB_FLAG[@]+"${STUB_FLAG[@]}"} > "$LL"
"$LLC" -filetype=obj "$LL" -o "$OUT" "${LLC_ARGS[@]}"
