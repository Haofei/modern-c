#!/usr/bin/env bash
# Runtime test for the MC printf family (user/libc/stdio.mc) on riscv64. Lowers stdio.mc (+
# cstr.mc, which supplies the memset/memcpy the struct copies need) through the selected backend,
# links a C runtime that provides the mc_console_write hook and checks snprintf output against
# expected strings, and runs under QEMU. Linked WITHOUT freestanding.c — the MC libc is the only
# mem/str/stdio.
#
# Usage: tools/lang/stdio-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
# Compile the WHOLE aggregated libc (one unit) — the artifact QuickJS links: snprintf/printf +
# the memset/memcpy the struct copies need, with no cross-object std/* duplication.
LIBC="$HERE/user/libc/libc.mc"
# The boot seam + driver is now PURE MC (no .c runtime): `_start` is `#[naked]` MC, the
# console is mmio_console over the bare 16550, this runtime DEFINES the `mc_console_write`
# hook the formatter streams through, and snprintf/printf are bound via fixed C-ABI
# prototypes (see the runtime's header). Linked as a SECOND MC object beside the libc.
RUNTIME="$HERE/tests/qemu/arch/stdio_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="STDIO-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-stdio-test" || echo "stdio-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$LIBC" "$WORK/libc.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null
kernel_boot_link_run "$TEST_NAME" "$EXPECT" \
    "$BACKEND backend ran the all-MC printf family (snprintf/printf, integer/string/char/pointer specifiers, flags/width/precision/length, truncation) under QEMU" \
    "$WORK/runtime.o" "$WORK/libc.o" $SUPPORT_OBJ "$WORK/libm.a"
