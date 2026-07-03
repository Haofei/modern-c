#!/usr/bin/env bash
# arch-emit gate (pure host check — emit-c only, no ld.lld/QEMU, never skips).
#
# The arch-selection seam (R0b) lets the genuinely arch-NEUTRAL core modules compile against any
# arch's paging via `--arch`. The x86/ARM QEMU gates exercise this end-to-end but skip locally
# without a cross toolchain. This gate type-checks + emits C for each portable core module under
# EVERY arch, so an `active`-import regression (or a paging backend that drops a uniform hook,
# e.g. mapping_is_readable) is caught cheaply on any host.
#
# Scope: only modules that import `kernel/arch/active/...` AND use exclusively the uniform paging
# interface. RISC-V-specific demos (cow.mc, demand.mc — Sv39 gigapage + satp) import riscv paging
# directly and are intentionally NOT covered here.
set -euo pipefail
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
MCC="${1:-${MCC_UNDER_TEST:-$HERE/zig-out/bin/mcc}}"
TEST_NAME="arch-emit-test"

MODULES=(
    kernel/core/elf_loader.mc
    kernel/core/uaccess_pt.mc
    kernel/core/uaccess.mc
    kernel/core/mmap.mc
)
ARCHES=(riscv64 x86_64 aarch64)

fail=0
n=0
for m in "${MODULES[@]}"; do
    for a in "${ARCHES[@]}"; do
        n=$((n + 1))
        if ! "$MCC" emit-c "$HERE/$m" --arch="$a" >/dev/null 2>"$HERE/.arch-emit-err"; then
            echo "FAIL: $TEST_NAME — emit-c $m --arch=$a did not compile:"
            sed 's/^/    /' "$HERE/.arch-emit-err" | head -8
            fail=1
        fi
    done
done
rm -f "$HERE/.arch-emit-err"

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "PASS: $TEST_NAME — ${#MODULES[@]} portable core modules emit-c clean under all ${#ARCHES[@]} arches ($n combinations)"
