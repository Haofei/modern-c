#!/usr/bin/env bash
# Demand-grown guest heap (Increment 1): run a confined U-mode agent whose libc heap GROWS ON DEMAND
# past the fixed static arena via SYS_SBRK. Build a tiny native agent (examples/apps/sbrk_grow.c) +
# the all-MC libc + the U-mode syscall shim into a U-mode ELF, load it with the real elf_loader into
# an ISOLATED Sv39 space (kernel UNMAPPED), drop to U-mode, and let it malloc() 40 MiB in chunks —
# forcing the kernel (app_run_demo.mc sys_sbrk) to map fresh frames at the running break. PASS requires
# confinement + the agent's SBRK-GROW-OK marker (it wrote+read every page of the grown region) + a
# clean U-mode exit. Reaches the kernel ONLY through ecall (sys_write + SYS_SBRK). Mirrors qjs-confined.
#
# Usage: tools/lang/sbrk-grow-test.sh <mcc> [c|llvm]
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
AGENT_REL="${3:-examples/apps/sbrk_grow.c}"
EXPECT="${4:-SBRK-GROW-OK}"
NAME_BASE="${5:-sbrk-grow}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/proc/app_run_demo.mc"             # kernel side: ELF load + SYS_WRITE/SYS_SBRK + confine
RUNTIME="$HERE/tests/qemu/lang/qjs_confined_runtime.mc" # kernel-side loader (generic; PURE MC)
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
USERMODE="$HERE/tests/qemu/proc/usermode_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 1. The confined U-mode agent ELF: the native malloc agent + the all-MC libc ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
            -fno-builtin -I"$HERE/user/libc/include")
"$CLANG" "${APP_CFLAGS[@]}" -I"$HERE" -c "$HERE/$AGENT_REL" -o "$WORK/agent.o"
# crt0 + app_traps are PURE MC: emit-c then compile with the app CFLAGS.
"$MCC" emit-c "$HERE/user/runtime/crt0.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"

# The all-MC libc + the U-mode syscall shim (provides the strong __sbrk over libc's weak default).
CFLAGS=("${APP_CFLAGS[@]}")
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/libc.mc" "$WORK/libc.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/syscall_user.mc" "$WORK/sys.o" "$WORK"
APP_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/app-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null

"$LLD" -T "$HERE/user/runtime/user_qjs.ld" \
    "$WORK/crt0.o" "$WORK/agent.o" \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed the agent ELF for the kernel to load ----
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
} >"$WORK/app_image.c"

# ---- 3. The kernel image (integer-only; the loader/ABI/confinement) ----
KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$USERMODE" "$WORK/usermode.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/app_image.o" $K_SUPPORT -o "$WORK/kernel.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -bios none -nographic -m 256 \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# PASS requires: the kernel is unmapped in the agent's space (CONFINED); the agent grew its heap far
# past the static arena and wrote+read every page (SBRK-GROW-OK); and it left U-mode via SYS_EXIT.
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: a confined U-mode agent grew its libc heap on demand past the fixed static arena via SYS_SBRK (40 MiB in chunks, every page written+read) in an isolated Sv39 space under QEMU; the kernel is unmapped in the agent and it reached the kernel only via ecall"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'CONFINED...', '$EXPECT', and 'USER-EXIT from U'"
exit 1
