#!/usr/bin/env bash
# Direct syscall-ABI fault test: build a confined MC app (examples/apps/fault_probe.mc) that
# deliberately hands the kernel BAD user pointers for SYS_WRITE, SYS_READ, and SYS_POLL, and run
# it under QEMU. The app asserts each returns -E_FAULT (the page-table-aware uaccess path fails
# closed) and prints FAULT-PROBE: PASS only if all three did. This proves the confinement
# guarantee at runtime, not by static review.
#
# SYS_READ returns 0/EOF unless the kernel holds an agent source, so we link a STRONG
# mc_agent_source (a few bytes) into the kernel — only then does sys_read reach its copy-out and
# fault on the bad pointer.
#
# Usage: tools/proc/fault-probe-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/proc/app_run_demo.mc"
RUNTIME="$HERE/kernel/arch/riscv64/app_runtime.c"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
APP="$HERE/examples/apps/fault_probe.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-fault-probe-test" || echo "fault-probe-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# 1. Build the confined fault-probe app into its own U-mode ELF.
MCC="$MCC" CLANG="$CLANG" LLC="$LLC" LLD="$LLD" \
    bash "$HERE/tools/user/build-app.sh" "$APP" "$BACKEND" "$WORK/app.elf" >/dev/null

# 2. Embed the app ELF bytes for the kernel to load.
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/app.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/app.elf")"
} >"$WORK/app_image.c"

# 3. A STRONG mc_agent_source so SYS_READ reaches its copy-out (and then faults on the bad ptr).
{
    printf 'static const char agent_js[] = "probe-source";\n'
    printf 'unsigned long mc_agent_source(unsigned long *out_len) {\n'
    printf '    *out_len = sizeof agent_js - 1;\n'
    printf '    return (unsigned long)agent_js;\n}\n'
} >"$WORK/agent_src.c"

# 4. Build the kernel image: MC loader/ABI + app_runtime + shared/usermode + embedded app +
#    strong agent source + freestanding boot.
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$HERE/kernel/arch/riscv64/usermode_runtime.c" "$WORK/usermode.o"
"$CLANG" "${CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
"$CLANG" "${CFLAGS[@]}" -c "$WORK/agent_src.c" -o "$WORK/agent_src.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/app_image.o" "$WORK/agent_src.o" $SUPPORT_OBJ -o "$WORK/kernel.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# PASS requires the app to be confined AND to observe -E_FAULT from all three syscalls.
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in app space" \
   && printf '%s' "$OUT" | grep -q "FAULT-PROBE: PASS" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: a confined U-mode app got -E_FAULT from SYS_WRITE/SYS_READ/SYS_POLL on bad user pointers under QEMU (uaccess fails closed)"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'CONFINED...', 'FAULT-PROBE: PASS', and 'USER-EXIT from U'"
exit 1
