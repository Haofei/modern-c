#!/usr/bin/env bash
# WASM-agent Phase 6 (docs/wasm-migration-plan.md §5): run a WASM agent CONFINED under REAL OpenSBI
# in S-mode. Same confined U-mode WASM agent ELF as wasm-confined-test.sh (wasm3 + WASI P1 shim +
# all-MC libc + generic wasm_host running an embedded stock wasm32-wasi guest), but the KERNEL runs
# in S-mode under the real OpenSBI firmware (no `-bios none`) instead of M-mode. The agent runs in an
# ISOLATED Sv39 space (kernel mapped SUPERVISOR-ONLY, unreachable from U), reaching the kernel ONLY
# through the syscall ABI (ecall). PASS requires the OpenSBI banner + confinement + the guest marker
# + a clean U-mode exit. The S-mode peer of wasm-confined-test.sh; mirrors qjs-smode-confined-test.sh.
#
# Usage: tools/arch/wasm-smode-confined-test.sh <mcc> [c|llvm] [guest.c] [expect] [name-base] [wasi|qjs]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
GUEST_REL="${3:-examples/apps/wasm/wasi_hello.c}"  # a stock wasm32-wasi program
EXPECT="${4:-WASI-HELLO=ok}"                       # the guest's printf marker
NAME_BASE="${5:-wasm-smode-confined}"
GUEST_KIND="${6:-wasi}"                            # "wasi" (single .c) | "qjs" (QuickJS-on-wasm)
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
ZIG="${ZIG:-zig}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
W3="$HERE/third_party/wasm3/source"
WASMDIR="$HERE/examples/apps/wasm"
HOST="$HERE/examples/apps/wasm_host.c"
SHIM="$WASMDIR/wasi_shim.c"
QJS="$HERE/third_party/quickjs"
# Kernel side (S-mode): the same loader/ABI/confinement the qjs S-mode peer uses (agent-agnostic).
SRC="$HERE/tests/qemu/arch/qjs_smode_demo.mc"                  # ELF load + ABI + supervisor gigapage
RUNTIME="$HERE/tests/qemu/arch/qjs_smode_confined_runtime.mc"  # S-mode bring-up under OpenSBI (PURE MC)
USERMODE="$HERE/tests/qemu/arch/smode_usermode_runtime.mc"     # S-mode trap vector + syscall dispatch
CTX_STUBS="$HERE/tests/qemu/mem/proc_ctx_stubs.mc"             # link-only process context externs
LDSCRIPT="$HERE/tests/qemu/sbi.ld"                             # OpenSBI payload @ 0x80200000
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
if [ "${KEEP_WORK:-0}" = 1 ]; then echo "KEEP_WORK: $WORK" >&2; else trap 'rm -rf "$WORK"' EXIT; fi

# ---- 0. The guest: a wasm32-wasi binary, built by the off-the-shelf toolchain (zig + wasi-libc) ----
if [ "$GUEST_KIND" = qjs ]; then
    "$ZIG" cc -target wasm32-wasi -O2 -s -I"$QJS" -D__wasi__ -Wl,-z,stack-size=524288 \
        "$HERE/$GUEST_REL" "$QJS"/dtoa.c "$QJS"/libunicode.c "$QJS"/libregexp.c "$QJS"/quickjs.c \
        -o "$WORK/guest.wasm"
else
    "$ZIG" cc -target wasm32-wasi -O2 -s -Wl,-z,stack-size=262144 "$HERE/$GUEST_REL" -o "$WORK/guest.wasm"
fi
{
    echo "const unsigned char wasm_blob[] = {"
    od -An -v -tu1 "$WORK/guest.wasm" | awk '{ for (i = 1; i <= NF; i++) printf "%s,", $i }'
    echo "};"
    echo "const unsigned int wasm_blob_len = sizeof(wasm_blob);"
} > "$WORK/wasm_blob.h"

# ---- 1. The confined U-mode host ELF (hardware FP; wasm float ops compute on doubles) ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
            -fno-builtin -I"$HERE/user/libc/include")
W3FLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
         -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2
         -fno-strict-aliasing -fno-builtin -I"$HERE/user/libc/include" -I"$W3")

for f in m3_bind m3_code m3_compile m3_core m3_env m3_exec m3_function m3_module m3_parse; do
    "$CLANG" "${W3FLAGS[@]}" -c "$W3/$f.c" -o "$WORK/$f.o"
done
"$CLANG" "${APP_CFLAGS[@]}" -I"$W3" -I"$WASMDIR" -c "$SHIM" -o "$WORK/wasi_shim.o"
"$CLANG" "${APP_CFLAGS[@]}" -I"$W3" -I"$WASMDIR" -I"$WORK" -c "$HOST" -o "$WORK/host.o"

# crt0 + app_traps are PURE MC: emit-c then compile with the app CFLAGS.
"$MCC" emit-c "$HERE/user/runtime/crt0.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"

# The all-MC libc + the U-mode syscall shim, through the selected backend with hardware FP.
CFLAGS=("${APP_CFLAGS[@]}")   # kernel_boot_compile_mc_object reads CFLAGS for the target ABI (lp64d)
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/libc.mc" "$WORK/libc.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/syscall_user.mc" "$WORK/sys.o" "$WORK"
APP_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/app-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null

"$LLD" -T "$HERE/user/runtime/user_qjs.ld" \
    "$WORK/crt0.o" "$WORK/host.o" "$WORK/wasi_shim.o" \
    "$WORK/m3_bind.o" "$WORK/m3_code.o" "$WORK/m3_compile.o" "$WORK/m3_core.o" \
    "$WORK/m3_env.o" "$WORK/m3_exec.o" "$WORK/m3_function.o" "$WORK/m3_module.o" "$WORK/m3_parse.o" \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed the host ELF for the kernel to load ----
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
} >"$WORK/app_image.c"

# ---- 3. The kernel image (integer-only), linked at the OpenSBI payload address. The S-mode runtime
#         owns _start and routes console + power through SBI; no context_runtime.c / -bios none. ----
KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")   # switch the MC-object ABI to the integer-only kernel target (lp64)
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/thread.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$CTX_STUBS" "$WORK/ctx_stubs.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$USERMODE" "$WORK/usermode.o" "$WORK"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/ctx_stubs.o" "$WORK/app_image.o" $K_SUPPORT -o "$WORK/kernel.elf"

# Real OpenSBI (the default firmware): NO `-bios none`. OpenSBI boots our kernel in S-mode.
OUT="$(timeout 120 "$QEMU" -machine virt -nographic -m 256M \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- OpenSBI + kernel UART output ---"
printf '%s\n' "$OUT"
echo "------------------------------------"

# PASS requires: OpenSBI ran (banner = S-mode under real firmware); the kernel is mapped
# supervisor-only (CONFINED) in the agent's space; the stock wasm32-wasi guest ran on wasm3 and
# printed its marker (copied out by SYS_WRITE); and the host left U-mode via SYS_EXIT.
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "CONFINED: kernel not user-accessible in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: wasm3 + WASI P1 shim, built freestanding against the all-MC libc, ran a STOCK wasm32-wasi guest CONFINED in an isolated U-mode Sv39 space under REAL OpenSBI in S-mode; the kernel is mapped supervisor-only (unreachable from U) and the agent reached the kernel only via the syscall ABI"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + 'CONFINED...' + '$EXPECT' + 'USER-EXIT from U'"
exit 1
