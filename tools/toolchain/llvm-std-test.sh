#!/usr/bin/env bash
# Standard-library logic test (LLVM backend) — thin wrapper over the shared host-MC-driver
# runner. Same driver as std-test (tests/std/std_host_driver.mc), compiled through llc.
# See tools/lib/host-mc-logic-test.sh and docs/test-architecture.md.
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
MCC_UNDER_TEST="$MCC" exec "$HERE/tools/lib/host-mc-logic-test.sh" "$MCC" "llvm" \
    "$HERE/tests/std/std_host_driver.mc" "$HERE/tests/std/std_host_harness.c" \
    "std-test" "std/{core,bits,math,ascii,fmt,addr} LLVM object linked and ran"
