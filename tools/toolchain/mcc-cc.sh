#!/usr/bin/env bash
# mcc-cc: compile an MC module to a linkable object file (toolchain driver).
#
# Lowers MC -> C with `mcc emit-c`, then compiles the C with clang. This is the
# minimal "toolchain" step that turns a verified MC module into something a host
# or bare-metal linker can consume.
#
# Usage: tools/toolchain/mcc-cc.sh <input.mc> [-o output.o] [--profile=P] [clang args...]
#
# Defaults the object name to the input stem + ".o". `--profile=kernel`
# (default, freestanding) or `--profile=hosted` selects the target conformance
# profile; it is forwarded to `mcc emit-c`. (Linking libc + `-lm` for the hosted
# profile is the final link step's job — see tools/lib/host-harness.sh — not this
# compile-to-object step.) Other arguments are passed through to clang, so
# cross-compilation works, e.g.:
#   tools/toolchain/mcc-cc.sh dev.mc -o dev.o --target=riscv64-unknown-elf -march=rv64imac \
#       -mabi=lp64 -ffreestanding -nostdlib -mcmodel=medany
set -euo pipefail

MCC="${MCC:-zig-out/bin/mcc}"
CLANG="${CLANG:-clang}"

if [ "$#" -lt 1 ]; then
    echo "usage: mcc-cc.sh <input.mc> [-o output.o] [clang args...]" >&2
    exit 2
fi

INPUT="$1"
shift

# Pull an explicit -o and any --profile out of the args; the rest go to clang.
OUT=""
PROFILE_ARGS=()
PASS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            OUT="$2"
            shift 2
            ;;
        --profile=*)
            PROFILE_ARGS+=("$1")
            shift
            ;;
        *)
            PASS+=("$1")
            shift
            ;;
    esac
done
if [ -z "$OUT" ]; then
    stem="$(basename "$INPUT")"
    OUT="${stem%.mc}.o"
fi

command -v "$CLANG" >/dev/null 2>&1 || { echo "mcc-cc: clang not found" >&2; exit 1; }

# Default to a conservative, warnings-as-errors C compile; callers can override
# the standard/flags through the passthrough args.
"$MCC" emit-c "$INPUT" "${PROFILE_ARGS[@]}" | "$CLANG" -std=c11 -Wall -Wextra -Werror "${PASS[@]}" -c -x c - -o "$OUT"

echo "mcc-cc: wrote $OUT"
