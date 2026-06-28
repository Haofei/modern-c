#!/usr/bin/env bash
# WASM-agent Phase 1 (docs/wasm-migration-plan.md §5): run a WASM agent CONFINED. Build the wasm3
# engine + the WASI Preview 1 shim + the all-MC libc + the generic wasm_host front-end into a U-mode
# ELF, load it with the real elf_loader into an ISOLATED Sv39 space (kernel UNMAPPED), drop to
# U-mode, and let the host run an embedded STOCK wasm32-wasi guest (built by `zig cc -target
# wasm32-wasi`, linking zig's wasi-libc) — reaching the kernel ONLY through SYS_WRITE/SYS_EXIT
# (ecall), exactly as the confined QuickJS agent does. PASS requires confinement + the guest's
# printf marker + a clean U-mode exit. Mirrors qjs-confined-test.
#
# Usage: tools/lang/wasm-confined-test.sh <mcc> [c|llvm] [guest.c] [expect] [name-base]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
GUEST_REL="${3:-examples/apps/wasm/wasi_hello.c}"  # a stock wasm32-wasi program
EXPECT="${4:-WASI-HELLO=ok}"                       # the guest's printf marker
NAME_BASE="${5:-wasm-wasi-hello}"
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
SRC="$HERE/tests/qemu/proc/app_run_demo.mc"             # kernel side: ELF load + SYS_WRITE + confine
RUNTIME="$HERE/tests/qemu/lang/qjs_confined_runtime.mc" # kernel-side loader (generic; PURE MC)
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
USERMODE="$HERE/tests/qemu/proc/usermode_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
if [ "${KEEP_WORK:-0}" = 1 ]; then echo "KEEP_WORK: $WORK" >&2; else trap 'rm -rf "$WORK"' EXIT; fi

# ---- 0. The guest: a wasm32-wasi binary, built by the off-the-shelf toolchain (zig + wasi-libc) ----
# The SOURCE is unmodified; we only cap the wasm stack (zig defaults it to ~16 MB of initial linear
# memory, which would exceed the confined agent's 8 MiB libc arena). The guest's initial memory is
# then allocated by the wasm3 engine from that arena; QuickJS-on-wasm grows it via memory.grow.
if [ "$GUEST_KIND" = qjs ]; then
    # KEYSTONE: JavaScript on the WASM path — the repo's vendored QuickJS compiled to wasm32-wasi
    # (the Javy approach, built with the toolchain we have). The guest .c + the 4 QuickJS TUs.
    QJS="$HERE/third_party/quickjs"
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
# wasm3 needs reliable tail-call optimization + aliasing-heavy slot punning (see Phase 0 / VENDOR.md).
W3FLAGS=("${APP_CFLAGS[@]}")
W3FLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
         -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2
         -fno-strict-aliasing -fno-builtin -I"$HERE/user/libc/include" -I"$W3")

for f in m3_bind m3_code m3_compile m3_core m3_env m3_exec m3_function m3_module m3_parse; do
    "$CLANG" "${W3FLAGS[@]}" -c "$W3/$f.c" -o "$WORK/$f.o"
done
"$CLANG" "${APP_CFLAGS[@]}" -I"$W3" -I"$WASMDIR" -c "$SHIM" -o "$WORK/wasi_shim.o"
"$CLANG" "${APP_CFLAGS[@]}" -I"$W3" -I"$WASMDIR" -I"$WORK" -c "$HOST" -o "$WORK/host.o"

# crt0 + app_traps are PURE MC: emit-c then compile with the app CFLAGS.
CFLAGS=("${APP_CFLAGS[@]}")
"$MCC" emit-c "$HERE/user/runtime/crt0.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"

# The all-MC libc + the U-mode syscall shim, through the selected backend with hardware FP.
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
# Phase-5 CPU-runaway watchdog (only when WD_TICKS is set): link a STRONG mc_watchdog_ticks override
# (budget = WD_TICKS timer preemptions) over the weak default in usermode_runtime.mc, arming the
# machine-timer watchdog. Otherwise no object is added and the watchdog stays disarmed.
WD_OBJ=""
if [ -n "${WD_TICKS:-}" ]; then
    printf 'unsigned long mc_watchdog_ticks(void){ return %sUL; }\n' "$WD_TICKS" > "$WORK/wd_cfg.c"
    "$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/wd_cfg.c" -o "$WORK/wd_cfg.o"
    WD_OBJ="$WORK/wd_cfg.o"
fi
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/thread.o" "$WORK/app_image.o" $WD_OBJ $K_SUPPORT -o "$WORK/kernel.elf"

_bt0=$(date +%s%N 2>/dev/null || echo 0)
OUT="$(timeout 120 "$QEMU" -machine virt -bios none -nographic -m 256 \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"
_bt1=$(date +%s%N 2>/dev/null || echo 0)
# Phase-7 benchmark hooks (only when BENCH is set; otherwise no output change): the QEMU wall time
# of the agent run + the confined U-mode image size, consumed by tools/lang/wasm-js-bench-test.sh.
if [ -n "${BENCH:-}" ]; then
    echo "BENCH-QEMU-MS: $(( (_bt1 - _bt0) / 1000000 ))"
    [ -f "$WORK/agent.elf" ] && echo "BENCH-AGENT-ELF-BYTES: $(wc -c < "$WORK/agent.elf" | tr -d ' ')"
fi

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"

# Watchdog mode (WD_TICKS set): success is a CONFINED agent that the watchdog KILLED — the runaway
# never reaches SYS_EXIT, so we require CONFINED + the kill marker ($EXPECT) and explicitly do NOT
# require USER-EXIT (a clean exit here would mean the watchdog failed to fire).
if [ -n "${WD_TICKS:-}" ]; then
    if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
       && printf '%s' "$OUT" | grep -q "$EXPECT"; then
        echo "PASS: $TEST_NAME — $BACKEND backend: a confined runaway WASM agent (infinite CPU loop, no syscalls) was preempted by the machine-timer watchdog and KILLED after its CPU budget; the system failed closed instead of hanging"
        exit 0
    fi
    echo "FAIL: $TEST_NAME — expected 'CONFINED...' and the watchdog kill marker '$EXPECT'"
    exit 1
fi

# PASS requires: the kernel is unmapped in the host's space (CONFINED); the stock wasm32-wasi guest
# ran on the wasm3 engine and printed its marker — copied out through the agent page table by
# SYS_WRITE; and the host left U-mode via SYS_EXIT (reaching the kernel only through ecall).
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    echo "PASS: $TEST_NAME — $BACKEND backend: wasm3 + WASI P1 shim, built freestanding against the all-MC libc, ran a STOCK wasm32-wasi guest CONFINED in an isolated U-mode Sv39 space under QEMU; the kernel is unmapped in the host and it reached the kernel only via SYS_WRITE/SYS_EXIT"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected 'CONFINED...', '$EXPECT', and 'USER-EXIT from U'"
exit 1
