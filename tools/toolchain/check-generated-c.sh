#!/bin/sh
set -eu

exe="${1:-zig-out/bin/mcc}"
fixture_glob="${2:-tests/c_emit_*.mc}"
out_dir="${3:-zig-out/c-test}"

mkdir -p "$out_dir"
for fixture in $fixture_glob; do
    base=$(basename "$fixture" .mc)
    out="$out_dir/$base.c"
    if ! "$exe" emit-c "$fixture" > "$out"; then
        echo "emit-c failed for $fixture" >&2
        exit 1
    fi
    clang -std=c11 -Wall -Wextra -Werror -fsyntax-only "$out"
done
