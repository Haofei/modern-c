#!/usr/bin/env bash
# Hosted-argv test: compile an MC program that reads its command-line arguments
# (via the opt-in `std/hosted_args`), link it with the C runtime shim
# `hosted_args_rt.c` (which owns `main(argc,argv)` and calls the MC entry
# `mc_main`), run the resulting BINARY with known arguments, and assert the exit
# code. Unlike vec-test/stack-test, the linked C file supplies `main`, so this
# runs a full program end-to-end with a real argv.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/argv_user.mc"
RT="$HERE/tools/toolchain/hosted_args_rt.c"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: argv-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/argv.o" >/dev/null

# The shim provides main(); link it with the MC object. libc supplies strlen.
"$CLANG" -std=c11 -Wall -Wextra -Werror "$RT" "$WORK/argv.o" -o "$WORK/prog"

# Run with the known arguments the gate program expects: "hello" (len 5) + "wo"
# (len 2). mc_main returns 5 + 2 = 7 as the process exit code on full success.
set +e
"$WORK/prog" hello wo
rc=$?
set -e

if [ "$rc" -ne 7 ]; then
    echo "FAIL: argv-test — program exited $rc (expected 7 = len(\"hello\") + len(\"wo\"))"
    exit 1
fi

# Negative check: with the wrong argument the gate rejects it (exit 102), proving
# the bytes really flow from the process argv into MC (not a constant).
set +e
"$WORK/prog" nope wo
rc2=$?
set -e
if [ "$rc2" -ne 102 ]; then
    echo "FAIL: argv-test — wrong-arg run exited $rc2 (expected 102 rejection)"
    exit 1
fi

echo "PASS: argv-test — hosted MC program read its real argv via std/hosted_args + hosted_args_rt.c shim (exit 7; wrong-arg rejected 102)"
exit 0
