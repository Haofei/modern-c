#!/usr/bin/env bash
# Shared runner for host-native MC-driver "logic tests".
#
# Compile an MC driver module (which `import`s the kernel/std module under test, so the
# whole reachable graph is pulled into one object) through the selected backend, link a
# minimal C harness (trap stubs + main calling the MC entry point), and run it on the host.
#
# All test assertions live in the MC driver, so the C harness mirrors NO MC struct layout
# (see docs/test-architecture.md) — a module growing a field can never silently corrupt
# memory past a hand-written C mirror, because there is no mirror. This runner is the single
# place the compile -> link -> run -> report flow lives, so each per-test script is a
# one-line wrapper that just names its driver, harness, gate name, and PASS detail.
#
# Usage:
#   host-mc-logic-test.sh <mcc> <backend:c|llvm> <driver.mc> <harness.c> <base-name> <pass-detail>
# The gate name is "<base-name>" for the C backend and "llvm-<base-name>" for LLVM. The
# PASS line is `PASS: <gate> — <pass-detail>` (the caller composes the detail verbatim, e.g.
# embedding its own "$BACKEND backend ..." wording). MC_STUB_ASM=1 in the environment is
# honored by mcc-cc.sh / mcc-llvm-cc.sh (for arch modules whose inline asm the host
# assembler cannot encode); modules without inline asm leave it unset.
set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: host-mc-logic-test.sh <mcc> <backend> <driver.mc> <harness.c> <base-name> <pass-detail>" >&2
    exit 2
fi

MCC="$1"
BACKEND="$2"
DRIVER="$3"
HARNESS="$4"
BASE="$5"
PASS_DETAIL="$6"

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$BASE" || echo "$BASE")

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (clang not found)"; exit 0; }
if [ "$BACKEND" = llvm ]; then
    command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: $TEST_NAME (llc not found)"; exit 0; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$BACKEND" in
    c)
        MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$DRIVER" -o "$WORK/mod.o" >/dev/null
        ;;
    llvm)
        MCC_UNDER_TEST="$MCC" MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$DRIVER" -o "$WORK/mod.o" >/dev/null
        ;;
    *)
        echo "unknown backend: $BACKEND" >&2
        exit 2
        ;;
esac

"$CLANG" -std=c11 -Wall -Wextra -Werror "$HARNESS" "$WORK/mod.o" -o "$WORK/app"
set +e
"$WORK/app"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    echo "PASS: $TEST_NAME — $PASS_DETAIL"
    exit 0
fi
echo "FAIL: $TEST_NAME — driver returned non-zero (failing check id or signal, rc=$rc)"
exit 1
