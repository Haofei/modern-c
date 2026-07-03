#!/usr/bin/env bash
set -euo pipefail

# mcc-llvm-cc: compile an MC module to a linkable object through LLVM IR.
#
# Usage: tools/toolchain/mcc-llvm-cc.sh <input.mc> [-o output.o] [llc args...]
# Defaults the object name to the input stem + ".o". Additional arguments are
# passed through to llc, so callers can provide target/relocation options.

MCC="${MCC_UNDER_TEST:-${MCC:-mcc}}"
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
# resolves to. When callers pass only llc's -mtriple, infer the same MC arch so LLVM lowering
# gets target ABI details such as va_list storage right for user-libc/QuickJS objects too.
EFFECTIVE_MC_ARCH="${MC_ARCH:-}"
HAVE_MTRIPLE=0
for arg in ${LLC_ARGS[@]+"${LLC_ARGS[@]}"}; do
    case "$arg" in
        -mtriple=*)
            HAVE_MTRIPLE=1
            if [ -z "$EFFECTIVE_MC_ARCH" ]; then
                case "$arg" in
                    -mtriple=riscv64*) EFFECTIVE_MC_ARCH="riscv64" ;;
                    -mtriple=x86_64*) EFFECTIVE_MC_ARCH="x86_64" ;;
                    -mtriple=aarch64*|-mtriple=arm64*) EFFECTIVE_MC_ARCH="aarch64" ;;
                esac
            fi
            ;;
    esac
done
if [ "$HAVE_MTRIPLE" -eq 0 ]; then
    HOST_TRIPLE="${MC_HOST_TRIPLE:-}"
    if [ -z "$HOST_TRIPLE" ]; then
        HOST_TRIPLE="$("$LLC" --version | awk -F: '/Default target:/ { gsub(/^[ \t]+/, "", $2); print $2; exit }')"
    fi
    if [ -n "$HOST_TRIPLE" ]; then
        LLC_ARGS+=("-mtriple=$HOST_TRIPLE")
        if [ -z "$EFFECTIVE_MC_ARCH" ]; then
            case "$HOST_TRIPLE" in
                riscv64*) EFFECTIVE_MC_ARCH="riscv64" ;;
                x86_64*) EFFECTIVE_MC_ARCH="x86_64" ;;
                aarch64*|arm64*) EFFECTIVE_MC_ARCH="aarch64" ;;
            esac
        fi
    fi
fi
ARCH_FLAG=()
[ -n "$EFFECTIVE_MC_ARCH" ] && ARCH_FLAG=(--arch="$EFFECTIVE_MC_ARCH")
# Host-native logic tests of arch modules set MC_STUB_ASM=1 so inline asm lowers to a
# host-neutral stub (the target ISA's mnemonics can't be assembled on the host).
STUB_FLAG=()
[ -n "${MC_STUB_ASM:-}" ] && STUB_FLAG=(--stub-asm)
"$MCC" emit-llvm "$INPUT" ${CHECKS_FLAG[@]+"${CHECKS_FLAG[@]}"} ${ARCH_FLAG[@]+"${ARCH_FLAG[@]}"} ${STUB_FLAG[@]+"${STUB_FLAG[@]}"} > "$LL"
"$LLC" -filetype=obj "$LL" -o "$OUT" ${LLC_ARGS[@]+"${LLC_ARGS[@]}"}
