#!/usr/bin/env bash
# QuickJS agent bring-up: build the vendored QuickJS engine (third_party/quickjs) freestanding
# against the all-MC libc (user/libc/libc.mc) + the vendored openlibm, link the confined
# qjs_agent front-end (examples/apps/qjs_agent.c) with the platform runtime, and run under QEMU.
# The agent evaluates a fixed script and prints the result; PASS requires the expected value.
#
# Usage: tools/lang/qjs-run-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
QJS="$HERE/third_party/quickjs"
LIBC="$HERE/user/libc/libc.mc"
AGENT="$HERE/examples/apps/qjs_agent.c"
RUNTIME="$HERE/tests/qemu/lang/qjs_runtime.mc"  # platform glue is now PURE MC
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="JS=7"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-qjs-run-test" || echo "qjs-run-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Hardware-FP freestanding target (QuickJS computes on doubles), single-threaded (-D__wasi__
# selects QuickJS's no-threads path).
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
        -fno-builtin -D__wasi__ -I"$HERE/user/libc/include" -I"$QJS")

# 1. QuickJS engine core (4 TUs) + the confined front-end.
# QuickJS engine objects: build once per (compiler+flags), cached + cp'd in (build-qjs.sh).
bash "$HERE/tools/user/build-qjs.sh" "$WORK" "$CLANG" "${CFLAGS[@]}"
"$CLANG" "${CFLAGS[@]}" -I"$HERE" -c "$AGENT" -o "$WORK/agent.o"

# 2. The all-MC libc, as one unit, through the selected backend (hardware FP: JS = doubles).
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$LIBC" "$WORK/libc.o" "$WORK"

# 3. openlibm (the transcendentals) + the platform runtime.
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null
# Platform runtime is pure MC; build it with the same hardware-FP ABI (lp64d) as the libc
# so it links with the FP objects (it does no FP itself but must share the ABI).
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"

# 4. Link the bare-metal image.
"$LLD" -T "$LDSCRIPT" "$WORK/runtime.o" "$WORK/agent.o" \
    "$WORK/dtoa.o" "$WORK/libunicode.o" "$WORK/libregexp.o" "$WORK/quickjs.o" \
    "$WORK/libc.o" $SUPPORT_OBJ "$WORK/libm.a" -o "$WORK/qjs.elf"

OUT="$(timeout 60 "$QEMU" -machine virt -bios none -nographic -m 256 \
        -kernel "$WORK/qjs.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: QuickJS, built freestanding against the all-MC libc, evaluated JavaScript (1 + 2*3 == 7) confined under QEMU"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT' (QuickJS eval result) in output"
exit 1
