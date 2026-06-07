#!/usr/bin/env bash
# mcc-cc: compile an MC module to a linkable object file (toolchain driver).
#
# Lowers MC -> C with `mcc emit-c`, then compiles the C with clang. This is the
# minimal "toolchain" step that turns a verified MC module into something a host
# or bare-metal linker can consume.
#
# Usage: tools/mcc-cc.sh <input.mc> [-o output.o] [extra clang args...]
#
# Defaults the object name to the input stem + ".o". Extra arguments are passed
# through to clang, so cross-compilation works, e.g.:
#   tools/mcc-cc.sh dev.mc -o dev.o --target=riscv64-unknown-elf -march=rv64imac \
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

# Pull an explicit -o out of the passthrough args; otherwise derive from input.
OUT=""
PASS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            OUT="$2"
            shift 2
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
"$MCC" emit-c "$INPUT" | "$CLANG" -std=c11 -Wall -Wextra -Werror "${PASS[@]}" -c -x c - -o "$OUT"

echo "mcc-cc: wrote $OUT"
