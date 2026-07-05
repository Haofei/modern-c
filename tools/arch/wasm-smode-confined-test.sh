#!/usr/bin/env bash
# WASM-agent Phase 6 (docs/wasm-migration-plan.md §5): run a WASM agent CONFINED under REAL OpenSBI
# in S-mode. Same confined U-mode WASM agent ELF as wasm-confined-test.sh (WAMR + the comprehensive
# wamr_full_host + all-MC libc running an embedded stock wasm32-wasi guest), but the KERNEL runs
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
AR="${AR:-llvm-ar}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
WAMR="$HERE/third_party/wamr"
WC="$WAMR/core"
WASMDIR="$HERE/examples/apps/wasm"
HOST="$HERE/examples/apps/wamr_full_host.c"             # the comprehensive WAMR host (WASI + FS + mc)
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
WASI_MCPU="none"  # no feature-pin: WAMR is built WASM_ENABLE_CALL_INDIRECT_OVERLONG=1
                  # (WDEF below), so its loader reads stock wasi-libc's overlong call_indirect
                  # table-index LEB directly — no `-mcpu=` rebuild needed
if [ "$GUEST_KIND" = qjs ]; then
    QCACHE="$HERE/.wamr-cache/qjs-wasm"; mkdir -p "$QCACHE"
    QWANT="$(printf '%s ' "$WASI_MCPU"; ls -la "$QJS"/dtoa.c "$QJS"/libunicode.c "$QJS"/libregexp.c "$QJS"/quickjs.c "$QJS"/*.h 2>/dev/null | md5sum)"
    kernel_boot_lock 8 "$QCACHE/.lock"
    if [ "$(cat "$QCACHE/stamp" 2>/dev/null)" != "$QWANT" ]; then
        for f in dtoa libunicode libregexp quickjs; do
            "$ZIG" cc -target wasm32-wasi -O2 -I"$QJS" -D__wasi__ -c "$QJS/$f.c" -o "$QCACHE/$f.o"
        done
        printf '%s' "$QWANT" > "$QCACHE/stamp"
    fi
    kernel_boot_unlock 8 "$QCACHE/.lock"
    "$ZIG" cc -target wasm32-wasi -O2 -s -I"$QJS" -D__wasi__ -Wl,-z,stack-size=524288 \
        "$HERE/$GUEST_REL" "$QCACHE"/dtoa.o "$QCACHE"/libunicode.o "$QCACHE"/libregexp.o "$QCACHE"/quickjs.o \
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

# ---- 1. The confined U-mode host ELF: WAMR (cached) + wamr_full_host + all-MC libc (hardware FP) ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2
            -fno-builtin -Wno-implicit-function-declaration -I"$HERE/user/libc/include")
WINC=(-I"$WC/shared/platform/include" -I"$WC/shared/platform/mc" -I"$WC/shared/utils"
      -I"$WC/shared/utils/uncommon" -I"$WC/shared/mem-alloc" -I"$WC/shared/mem-alloc/ems"
      -I"$WC/iwasm/include" -I"$WC/iwasm/common" -I"$WC/iwasm/interpreter" -I"$WC")
WDEF=(-DBH_PLATFORM_MC -DBUILD_TARGET_RISCV64_LP64D -DWASM_ENABLE_INTERP=1
      -DWASM_ENABLE_INSTRUCTION_METERING=1 -DWASM_ENABLE_BULK_MEMORY=1
      -DWASM_ENABLE_BULK_MEMORY_OPT=1 -DWASM_ENABLE_REF_TYPES=1
      -DWASM_ENABLE_CALL_INDIRECT_OVERLONG=1
      -DBH_MALLOC=wasm_runtime_malloc -DBH_FREE=wasm_runtime_free)
# Phase 1.2 (perf plan): default to WAMR's FAST interpreter (direct-threaded / label-as-values
# dispatch); set WAMR_FAST_INTERP=0 to fall back to the classic interpreter. The flag is part of the
# cache key (WANT below) so toggling it rebuilds libwamr.a.
if [ "${WAMR_FAST_INTERP:-1}" = 1 ]; then WDEF+=(-DWASM_ENABLE_FAST_INTERP=1); WAMR_INTERP_TU=wasm_interp_fast.c; else WDEF+=(-DWASM_ENABLE_FAST_INTERP=0); WAMR_INTERP_TU=wasm_interp_classic.c; fi

# Build the WAMR engine ONCE into a cached archive (flock-guarded, stamped on WDEF + source mtimes) —
# reused across every WASM gate so the ~25-TU engine doesn't recompile per gate. See tools/wamr/README.
CACHE="$HERE/.wamr-cache"; mkdir -p "$CACHE"
WAMR_LIB="$CACHE/libwamr.a"
WANT="$(printf '%s ' "${WDEF[@]}"; find "$WC/shared/platform/mc" "$WC/shared/utils" "$WC/shared/mem-alloc" "$WC/iwasm/common" "$WC/iwasm/interpreter" \( -name '*.c' -o -name '*.h' -o -name '*.S' \) 2>/dev/null | sort | xargs ls -la 2>/dev/null | md5sum)"
kernel_boot_lock 9 "$CACHE/.lock"
if [ ! -f "$WAMR_LIB" ] || [ "$(cat "$CACHE/stamp" 2>/dev/null)" != "$WANT" ]; then
    CB="$CACHE/obj"; rm -rf "$CB"; mkdir -p "$CB"; OBJS=(); j=0
    cwamr() { "$CLANG" "${APP_CFLAGS[@]}" "${WINC[@]}" "${WDEF[@]}" -c "$1" -o "$2"; OBJS+=("$2"); }
    cwamr "$WC/shared/platform/mc/mc_platform.c" "$CB/w_mc.o"
    for f in "$WC"/shared/utils/*.c; do cwamr "$f" "$CB/wu_$((j++)).o"; done
    cwamr "$WC/shared/mem-alloc/mem_alloc.c" "$CB/w_ma.o"
    for f in "$WC"/shared/mem-alloc/ems/ems_alloc.c "$WC"/shared/mem-alloc/ems/ems_hmu.c "$WC"/shared/mem-alloc/ems/ems_kfc.c; do cwamr "$f" "$CB/we_$((j++)).o"; done
    for f in "$WC"/iwasm/common/*.c; do case "$f" in *wasm_application.c) continue;; esac; cwamr "$f" "$CB/wc_$((j++)).o"; done
    cwamr "$WC/iwasm/interpreter/wasm_runtime.c" "$CB/w_rt.o"
    cwamr "$WC/iwasm/interpreter/$WAMR_INTERP_TU" "$CB/w_interp.o"
    cwamr "$WC/iwasm/interpreter/wasm_loader.c" "$CB/w_loader.o"
    "$CLANG" "${APP_CFLAGS[@]}" -c "$WC/iwasm/common/arch/invokeNative_riscv.S" -o "$CB/w_tramp.o"; OBJS+=("$CB/w_tramp.o")
    "$AR" rcs "$WAMR_LIB" "${OBJS[@]}"
    printf '%s' "$WANT" > "$CACHE/stamp"
fi
kernel_boot_unlock 9 "$CACHE/.lock"

# The confined host front-end (sees wasm_blob.h + WAMR's public header + tool_abi.h/wasi.h).
"$CLANG" "${APP_CFLAGS[@]}" -I"$WC/iwasm/include" -I"$WASMDIR" -I"$WORK" -c "$HOST" -o "$WORK/host.o"

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
    "$WORK/crt0.o" "$WORK/host.o" --whole-archive "$WAMR_LIB" --no-whole-archive \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed the host ELF for the kernel to load ----
APP_HASH="$(python3 - "$WORK/agent.elf" <<'PY'
import pathlib
import sys
h = 0x811c9dc5
for b in pathlib.Path(sys.argv[1]).read_bytes():
    h = ((h ^ b) * 0x01000193) & 0xffffffff
print(h)
PY
)"
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
    printf 'const unsigned long long app_image_hash = %sULL;\n' "$APP_HASH"
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
# supervisor-only (CONFINED) in the agent's space; the stock wasm32-wasi guest ran on WAMR and
# printed its marker (copied out by SYS_WRITE); and the host left U-mode via SYS_EXIT.
if printf '%s' "$OUT" | grep -qi "OpenSBI" \
   && printf '%s' "$OUT" | grep -q "CONFINED: kernel not user-accessible in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: WAMR + the comprehensive WASI/FS/mc host, built freestanding against the all-MC libc, ran a STOCK wasm32-wasi guest CONFINED in an isolated U-mode Sv39 space under REAL OpenSBI in S-mode; the kernel is mapped supervisor-only (unreachable from U) and the agent reached the kernel only via the syscall ABI"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected OpenSBI banner + 'CONFINED...' + '$EXPECT' + 'USER-EXIT from U'"
exit 1
