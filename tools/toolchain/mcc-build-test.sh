#!/usr/bin/env bash
# Smoke test for the installed `mcc build <file.mc> -o <exe>` launcher path.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
CLANG="${CLANG:-clang}"

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: mcc-build-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/ok.mc" <<'MC'
export fn main() -> u32 {
    return 7;
}
MC

"$MCC" build "$WORK/ok.mc" -o "$WORK/ok" >"$WORK/build.out" 2>"$WORK/build.err"

set +e
"$WORK/ok" >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -ne 7 ]; then
    echo "FAIL: mcc-build-test - built executable exited $RC, want 7"
    cat "$WORK/build.out"
    cat "$WORK/build.err"
    exit 1
fi

if ! grep -Fq "mcc build: wrote $WORK/ok" "$WORK/build.out"; then
    echo "FAIL: mcc-build-test - build output did not report the executable path"
    cat "$WORK/build.out"
    exit 1
fi

set +e
"$MCC" build "$WORK/ok.mc" >"$WORK/missing-out.out" 2>"$WORK/missing-out.err"
RC=$?
set -e
if [ "$RC" -ne 2 ] || ! grep -Fq "missing -o <exe>" "$WORK/missing-out.err"; then
    echo "FAIL: mcc-build-test - missing -o did not fail with a usage diagnostic"
    cat "$WORK/missing-out.out"
    cat "$WORK/missing-out.err"
    exit 1
fi

echo "PASS: mcc-build-test - installed mcc build compiled and ran a hosted program"
