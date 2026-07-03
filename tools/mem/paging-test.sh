#!/usr/bin/env bash
# Sv39 page-table logic test — thin wrapper over the shared host-MC-driver runner. Every
# assertion lives in tests/mem/paging_host_driver.mc (no C struct mirror of PageTable/Heap).
# paging.mc's `sfence_vma_page` carries riscv `sfence.vma` the host assembler can't encode,
# so MC_STUB_ASM=1 lowers it to a host-neutral stub (a TLB fence is a no-op for this
# single-threaded host test). See tools/lib/host-mc-logic-test.sh and docs/test-architecture.md.
set -euo pipefail
MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
exec env MC_STUB_ASM=1 "$HERE/tools/lib/host-mc-logic-test.sh" "$MCC" "$BACKEND" \
    "$HERE/tests/mem/paging_host_driver.mc" "$HERE/tests/mem/paging_host_harness.c" \
    "paging-test" "$BACKEND backend Sv39 map + translate (multi-level, shared interior tables, page offsets) computes correctly"
