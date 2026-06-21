#!/usr/bin/env bash
# Phase-1 confined-APP test: build a real MC app (examples/apps/hello.mc) into a multi-segment
# U-mode ELF via the userspace SDK, load it with the real elf_loader into an ISOLATED Sv39
# space (kernel UNMAPPED), and run it under QEMU. The app prints via SYS_WRITE (its user buffer
# copied in through the agent's page table) and exits via SYS_EXIT — reaching the kernel only
# through ecall. This is the end-to-end Phase-1 spine of the QuickJS-agent plan.
#
# Usage: tools/proc/app-run-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
APP_REL="${3:-examples/apps/hello.mc}"   # the app source (.mc or .c)
MARKER="${4:-hello}"                      # output substring proving the app ran
NAME_BASE="${5:-app-run}"                 # gate name base
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/proc/app_run_demo.mc"
RUNTIME="$HERE/tests/qemu/proc/app_runtime.mc"
SHARED="$HERE/kernel/arch/riscv64/context_runtime.c"
APP="$HERE/$APP_REL"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-parameter -Wno-unused-function -fno-builtin)

# 1. Build the confined app into its own multi-segment U-mode ELF (same backend).
MCC="$MCC" CLANG="$CLANG" LLC="$LLC" LLD="$LLD" \
    bash "$HERE/tools/user/build-app.sh" "$APP" "$BACKEND" "$WORK/app.elf" >/dev/null

# 2. Embed the app ELF bytes as a generated C data array, with accessors the pure-MC
#    app_runtime.mc reads (MC has no `extern` data-symbol form, only `extern fn`). These
#    apps embed NO agent source, so a default mc_agent_source (returns nothing) lets the
#    MC loader's SYS_READ ingress link and read 0/EOF (fault-probe links its own strong one).
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/app.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/app.elf")"
    printf 'unsigned long mc_app_image(void) { return (unsigned long)app_image; }\n'
    printf 'unsigned long mc_app_image_len(void) { return (unsigned long)app_image_len; }\n'
    printf 'unsigned long mc_agent_source(unsigned long *out_len) { *out_len = 0; return 0; }\n'
} >"$WORK/app_image.c"

# 3. Build the kernel image: MC loader/ABI + app_runtime + shared/usermode runtimes + the
#    embedded app + freestanding boot.
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
mkdir -p "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$HERE/kernel/arch/riscv64/usermode_runtime.c" "$WORK/usermode.o"
"$CLANG" "${CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/app_image.o" $SUPPORT_OBJ -o "$WORK/kernel.elf"

OUT="$(timeout 30 "$QEMU" -machine virt -bios none -nographic \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# PASS requires ALL of:
#   - the kernel is unmapped in the app's space (CONFINED);
#   - the app actually ran and printed "hello" via SYS_WRITE (its buffer copied in through the
#     agent page table) — it could only do so at a VA valid through its isolated page table;
#   - it exited from U-mode (SYS_EXIT), proving it reached the kernel only via ecall.
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in app space" \
   && printf '%s' "$OUT" | grep -q "$MARKER" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend built an MC app into a multi-segment ELF, loaded it into an isolated Sv39 space (kernel unmapped), and ran it confined in U-mode; it printed via SYS_WRITE (buffer copied through the agent page table) and exited via syscall"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'CONFINED: kernel unmapped in app space', the app's 'hello', and 'USER-EXIT from U'"
exit 1
