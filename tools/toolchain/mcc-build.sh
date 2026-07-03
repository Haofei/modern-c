#!/usr/bin/env bash
# mcc-build: one-shot hosted build driver for `mcc build <file.mc> -o <exe>`.
set -euo pipefail

usage() {
    echo "usage: mcc build <file.mc> -o <exe>" >&2
}

fail_usage() {
    echo "mcc build: $1" >&2
    usage
    exit 2
}

TOOL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${TOOL_DIR%/tools/toolchain}"

MCC_BIN="${MCC_REAL:-${MCC:-}}"
if [ -z "$MCC_BIN" ]; then
    if [ -x "$PREFIX/bin/mcc-real" ]; then
        MCC_BIN="$PREFIX/bin/mcc-real"
    elif [ -x "$PREFIX/zig-out/bin/mcc-real" ]; then
        MCC_BIN="$PREFIX/zig-out/bin/mcc-real"
    elif [ -x "$PREFIX/zig-out/bin/mcc" ]; then
        MCC_BIN="$PREFIX/zig-out/bin/mcc"
    else
        MCC_BIN="mcc"
    fi
fi

CLANG_BIN="${CLANG:-clang}"

INPUT=""
OUT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -o)
            [ "$#" -ge 2 ] || fail_usage "-o requires an output path"
            OUT="$2"
            shift 2
            ;;
        -*)
            fail_usage "unknown option '$1'"
            ;;
        *)
            [ -z "$INPUT" ] || fail_usage "multiple input files are not supported"
            INPUT="$1"
            shift
            ;;
    esac
done

[ -n "$INPUT" ] || fail_usage "missing input file"
[ -n "$OUT" ] || fail_usage "missing -o <exe>"
[ -f "$INPUT" ] || { echo "mcc build: input file not found: $INPUT" >&2; exit 1; }
[ -x "$MCC_BIN" ] || { echo "mcc build: compiler not found or not executable: $MCC_BIN" >&2; exit 1; }
command -v "$CLANG_BIN" >/dev/null 2>&1 || { echo "mcc build: clang not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM
RAW_C="$WORK/main.raw.c"
HOSTED_C="$WORK/main.hosted.c"

if [ -d "$PREFIX/std" ]; then
    MC_PATH="${MC_PATH:+$MC_PATH:}$PREFIX" "$MCC_BIN" emit-c "$INPUT" --profile=hosted >"$RAW_C"
else
    "$MCC_BIN" emit-c "$INPUT" --profile=hosted >"$RAW_C"
fi
ENTRY_RET="$(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*) main\(void\);$/\1/p' "$RAW_C" | head -n 1)"
[ -n "$ENTRY_RET" ] || { echo "mcc build: expected exported no-argument main() entry point in $INPUT" >&2; exit 1; }

sed -E 's/^([A-Za-z_][A-Za-z0-9_]*) main\(void\)[[:space:]]*([;{])$/\1 mc_user_main(void)\2/' "$RAW_C" >"$HOSTED_C"
{
    printf '\n'
    printf 'int main(void) {\n'
    if [ "$ENTRY_RET" = "void" ]; then
        printf '    mc_user_main();\n'
        printf '    return 0;\n'
    else
        printf '    return (int)mc_user_main();\n'
    fi
    printf '}\n'
} >>"$HOSTED_C"

"$CLANG_BIN" -std=c11 -Wall -Wextra -Werror \
    -fno-strict-aliasing -fno-delete-null-pointer-checks -fwrapv \
    "$HOSTED_C" -lm -o "$OUT"
echo "mcc build: wrote $OUT"
