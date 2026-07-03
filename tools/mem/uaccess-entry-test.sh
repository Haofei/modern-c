#!/usr/bin/env bash
# QEMU gate for the uaccess entry-mode demos (page-table / snapshot / taint).
#
# Lowers an entry-mode uaccess fixture through the selected backend, links it with the
# generic M-mode uaccess runtime into a riscv64 image, and boots it under QEMU. The
# fixture's `u32 <entry>(void)` returns 1 iff every case passed; the runtime prints
# UACCESS-OK on 1, UACCESS-BAD on 0, UACCESS-TRAP on an unexpected fault.
#
# These fixtures cannot run on the host driver suite: they exercise kernel/core/uaccess.mc,
# which imports the riscv paging module (paging.mc), whose sfence_vma_page emits the
# `sfence.vma` instruction — not assemblable for the host target. Hence the QEMU gate.
#
# Usage: tools/mem/uaccess-entry-test.sh <path-to-mcc> <c|llvm> <fixture.mc> <entry-fn> <base-name>
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
FIXTURE="${3:?usage: uaccess-entry-test.sh <mcc> <backend> <fixture.mc> <entry-fn> <base-name>}"
ENTRY="${4:?missing entry function name}"
BASE="${5:?missing base test name}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/$FIXTURE"
RUNTIME="$HERE/tests/qemu/mem/uaccess_entry_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$BASE" || echo "$BASE")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/demo.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"

# The generic MC runtime calls the fixed-name `rt_uaccess_entry`. MC has no -D, so a
# tiny generated shim forwards rt_uaccess_entry -> this gate's fixture entry ($ENTRY)
# — the all-MC analogue of the C runtime's -DMC_ENTRY=<fn>.
SHIM="$WORK/uaccess_shim.mc"
cat >"$SHIM" <<EOF
// Generated per-gate shim: forward rt_uaccess_entry -> $ENTRY (the fixture entry).
extern fn $ENTRY() -> u32;
export fn rt_uaccess_entry() -> u32 {
    return $ENTRY();
}
EOF

mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
mkdir -p "$WORK/shim"
kernel_boot_compile_mc_object "$BACKEND" "$SHIM" "$WORK/shim.o" "$WORK/shim"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/shim.o" "$WORK/demo.o" \
    $SUPPORT_OBJ -o "$WORK/uaccess.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
    -kernel "$WORK/uaccess.elf" 2>/dev/null || true)"

echo "--- $BASE UART ---"
printf '%s\n' "$OUT"
echo "------------------"

if printf '%s' "$OUT" | grep -q "UACCESS-OK" \
    && ! printf '%s' "$OUT" | grep -qE "UACCESS-(BAD|TRAP)"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: $ENTRY returned all-pass under QEMU (riscv entry fixture (imports paging/uaccess; sfence-bearing), so QEMU-only)"
    exit 0
fi
echo "FAIL: $TEST_NAME — missing UACCESS-OK or saw UACCESS-BAD/TRAP"
exit 1
