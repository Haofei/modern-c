#!/usr/bin/env bash
# Data-driven host-driver test harness.
#
# A "host-driver" test lowers an MC fixture to a C object (via mcc-cc), links it
# with a tiny C driver, and runs it on the host; the driver returning 0 is PASS.
# Every such test used to be its own ~18-line script that differed only in the
# fixture, the driver, and one description string — so they were cloned and
# hand-edited, which bred mislabel bugs. The per-test data now lives in one
# manifest (tools/lib/host-tests.tsv) and this is the single shared runner.
#
#   row: name <tab> fixture <tab> mode <tab> spec <tab> mcc_flags <tab> description
#   mode=entry  -> spec is a `uint32_t <fn>(void)`; PASS iff it returns 1
#   mode=driver -> the driver is tools/lib/host-drivers/<name>.c (bespoke C)
#
# Adding a host test = one manifest row (+ a driver file only if bespoke).
#
# Usage: tools/lib/host-harness.sh <path-to-mcc> <test-name>
# Skips (exit 0) when clang is unavailable, like the scripts it replaces.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
NAME="${2:?usage: host-harness.sh <mcc> <test-name>}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
MANIFEST="$HERE/tools/lib/host-tests.tsv"

# Pull each field by column with awk (-F'\t' preserves empty fields; a bash `read`
# with IFS=tab would collapse them, since tab is IFS-whitespace, and shift the row).
awk -F'\t' -v n="$NAME" '$1==n{hit=1} END{exit hit?0:3}' "$MANIFEST" \
  || { echo "FAIL: $NAME — no row for '$NAME' in tools/lib/host-tests.tsv"; exit 1; }
field() { awk -F'\t' -v n="$NAME" -v c="$1" '$1==n{print $c; exit}' "$MANIFEST"; }
fixture="$(field 2)"; mode="$(field 3)"; spec="$(field 4)"
mcc_flags="$(field 5)"; desc="$(field 6)"

CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $NAME (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Optional sanitizer instrumentation: when SANITIZE is set, build the fixture object and the
# linked app with ASan + UBSan and abort on the first report, so undefined behavior or a bad
# access in the emitted C fails the test. (-fno-sanitize-recover makes UBSan trap rather than
# print-and-continue.) Driven by tools/toolchain/sanitize-test.sh.
# `function` is excluded: the closure / Allocator vtable ABI deliberately calls a concrete
# function through a type-erased `RET (*)(void *, …)` pointer (env passed as void*). That is
# representation-identical and ABI-correct on every target — and identical across both backends
# — but -fsanitize=function flags the pointer-type mismatch. The valuable checks (signed
# overflow, OOB, null, alignment, shifts, …) stay on.
SAN_FLAGS=()
if [ -n "${SANITIZE:-}" ]; then
    SAN_FLAGS=(-fsanitize=address,undefined -fno-sanitize=function -fno-sanitize-recover=all)
fi

# 1. MC fixture -> object. mcc_flags (e.g. -Wno-switch-bool) flow to the fixture's C compile.
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/$fixture" -o "$WORK/mod.o" $mcc_flags ${SAN_FLAGS[@]+"${SAN_FLAGS[@]}"} >/dev/null

# 2. the C driver: generated for the trivial single-call case, or a bespoke file.
case "$mode" in
    entry)
        printf '#include <stdint.h>\nextern uint32_t %s(void);\nint main(void){ return %s()==1 ? 0 : 1; }\n' \
            "$spec" "$spec" >"$WORK/driver.c" ;;
    driver)
        cp "$HERE/tools/lib/host-drivers/$NAME.c" "$WORK/driver.c" ;;
    *)
        echo "FAIL: $NAME — unknown manifest mode '$mode'"; exit 1 ;;
esac

# 3. link the driver with the fixture object and run it; PASS iff it exits 0.
# (No -Werror on the driver: it is test glue, and the fixture's emitted C was already
# compiled -Werror by mcc-cc; driver warnings can't change the app's pass/fail exit.)
"$CLANG" -std=c11 -Wall -Wextra ${SAN_FLAGS[@]+"${SAN_FLAGS[@]}"} "$WORK/driver.c" "$WORK/mod.o" -o "$WORK/app"
if OUT="$("$WORK/app")"; then
    [ -n "$OUT" ] && printf '%s\n' "$OUT"
    echo "PASS: $NAME — $desc"
    exit 0
fi
echo "FAIL: $NAME — driver returned nonzero"
exit 1
