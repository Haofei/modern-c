#!/usr/bin/env bash
# M3a: run QuickJS CONFINED under REAL OpenSBI in S-mode. Same confined U-mode QuickJS agent as
# qjs-confined-test.sh (Phase 6), but the KERNEL runs in S-mode under the real OpenSBI firmware
# (no `-bios none`) instead of M-mode. The agent evaluates JS in an ISOLATED Sv39 space (kernel
# mapped SUPERVISOR-ONLY, unreachable from U), reaching the kernel ONLY through SYS_WRITE/SYS_EXIT
# (ecall). PASS requires the OpenSBI banner + confinement + the JS result + U-mode exit.
#
# Usage: tools/arch/qjs-smode-confined-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
AGENT_REL="${3:-examples/apps/qjs_agent.c}"  # the confined agent front-end
EXPECT_JS="${4:-JS=7}"                        # the JS-result marker proving evaluation
NAME_BASE="${5:-qjs-smode-confined}"          # gate name base
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
QJS="$HERE/third_party/quickjs"
SRC="$HERE/tests/qemu/arch/qjs_smode_demo.mc"            # kernel side (S-mode): ELF load + ABI + supervisor gigapage
RUNTIME="$HERE/tests/qemu/arch/qjs_smode_confined_runtime.mc"  # S-mode bring-up under OpenSBI, now PURE MC
USERMODE="$HERE/kernel/arch/riscv64/smode_usermode_runtime.c"     # S-mode trap vector + syscall dispatch
LDSCRIPT="$HERE/tests/qemu/sbi.ld"                       # OpenSBI payload @ 0x80200000
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. The confined U-mode agent ELF (hardware FP; QuickJS computes on doubles) ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
            -fno-builtin -D__wasi__ -I"$HERE/user/libc/include" -I"$QJS")
for f in dtoa libunicode libregexp quickjs; do
    "$CLANG" "${APP_CFLAGS[@]}" -c "$QJS/$f.c" -o "$WORK/$f.o"
done
"$CLANG" "${APP_CFLAGS[@]}" -I"$HERE" -c "$HERE/$AGENT_REL" -o "$WORK/agent.o"
"$CLANG" "${APP_CFLAGS[@]}" -c "$HERE/user/runtime/crt0.c" -o "$WORK/crt0.o"
"$CLANG" "${APP_CFLAGS[@]}" -c "$HERE/user/runtime/app_traps.c" -o "$WORK/traps.o"

# The all-MC libc + the U-mode syscall shim, through the selected backend with hardware FP.
CFLAGS=("${APP_CFLAGS[@]}")
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/libc.mc" "$WORK/libc.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/syscall_user.mc" "$WORK/sys.o" "$WORK"
APP_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/app-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null

"$LLD" -T "$HERE/user/runtime/user_qjs.ld" \
    "$WORK/crt0.o" "$WORK/agent.o" \
    "$WORK/dtoa.o" "$WORK/libunicode.o" "$WORK/libregexp.o" "$WORK/quickjs.o" \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed the agent ELF for the kernel to load ----
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
} >"$WORK/app_image.c"

# ---- 3. The kernel image (integer-only; the loader/ABI/confinement), linked at the OpenSBI
#         payload address. No context_runtime.c/-bios none: the S-mode runtime owns _start and
#         routes console + power through SBI. ----
KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_c_object "$USERMODE" "$WORK/usermode.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/app_image.o" $K_SUPPORT -o "$WORK/kernel.elf"

# Real OpenSBI (the default firmware): NO `-bios none`. OpenSBI boots our kernel in S-mode.
OUT="$(timeout 120 "$QEMU" -machine virt -nographic -m 256M \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- OpenSBI + kernel UART output ---"
printf '%s\n' "$OUT"
echo "------------------------------------"

# PASS requires: OpenSBI actually ran (banner) — proves S-mode under the real firmware; the
# kernel is mapped supervisor-only (CONFINED) in the agent's space; QuickJS evaluated the script
# (JS=7), its output copied in through the agent page table by SYS_WRITE; and the agent left
# U-mode via SYS_EXIT (reaching the kernel only through ecall).
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "CONFINED: kernel not user-accessible in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT_JS" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: QuickJS, built freestanding against the all-MC libc, evaluated JavaScript (1 + 2*3 == 7) CONFINED in an isolated U-mode Sv39 space under REAL OpenSBI in S-mode; the kernel is mapped supervisor-only (unreachable from U) and the agent reached the kernel only via SYS_WRITE/SYS_EXIT"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + 'CONFINED...' + '$EXPECT_JS' + 'USER-EXIT from U'"
exit 1
