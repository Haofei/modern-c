#!/usr/bin/env bash
# Kernel heap logic test — thin wrapper over the shared host-MC-driver runner. Every
# assertion lives in tests/mem/heap_host_driver.mc (no C struct mirror of Heap); the
# harness only supplies trap/ksan stubs + a pool. See tools/lib/host-mc-logic-test.sh
# and docs/test-architecture.md.
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
exec "$HERE/tools/lib/host-mc-logic-test.sh" "$MCC" "$BACKEND" \
    "$HERE/tests/mem/heap_host_driver.mc" "$HERE/tests/mem/heap_host_harness.c" \
    "heap-test" "$BACKEND backend kernel heap aligned bump allocation over a PhysRange computes correctly (MC-side asserts, no struct mirror)"
