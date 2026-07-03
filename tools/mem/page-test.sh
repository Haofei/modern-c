#!/usr/bin/env bash
# Page/frame allocator logic test — thin wrapper over the shared host-MC-driver runner.
# Every assertion lives in tests/mem/page_host_driver.mc (no C struct mirror of
# PageAllocator/Page/MemoryMap); the harness only supplies trap stubs + a pool. See
# tools/lib/host-mc-logic-test.sh and docs/test-architecture.md.
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
exec "$HERE/tools/lib/host-mc-logic-test.sh" "$MCC" "$BACKEND" \
    "$HERE/tests/mem/page_host_driver.mc" "$HERE/tests/mem/page_host_harness.c" \
    "page-test" "$BACKEND backend frame allocator bump + free-list reclaim + LIFO reuse compute correctly"
