#!/usr/bin/env bash
# WASM-agent Phase 6 (docs/wasm-migration-plan.md §5): a confined WASM guest's brokered net_fetch
# reaches a LIVE HTTP server through the kernel's REAL TCP transport (net_fetch_tcp) over virtio-net
# — the WASM peer of qjs-net-realtool-test.sh. Same confined WASM agent ELF (WAMR +
# wamr_full_host + all-MC libc running a stock wasm32-wasi guest), with the M-mode TCP-backed net runtime.
# PASS requires the guest's success marker + an HTTP access-log GET 200 + a non-empty pcap, proving a
# real datagram round-trip (not the mock broker).
#
# Usage: tools/lang/wasm-net-realtool-test.sh <mcc> [c|llvm] [guest.c] [expect] [name-base]
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
GUEST_REL="${3:-examples/apps/wasm/wasi_net_real.c}"
EXPECT="${4:-net-real: ok}"
NAME_BASE="${5:-wasm-net-realtool}"
GUEST_KIND="${6:-wasi}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
ZIG="${ZIG:-zig}"
QEMU="${QEMU:-qemu-system-riscv64}"
AR="${AR:-llvm-ar}"
PORT=8080
TOKEN="MC-WASM-NET-REALTOOL-OK"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
WAMR="$HERE/third_party/wamr"
WC="$WAMR/core"
WASMDIR="$HERE/examples/apps/wasm"
HOST="$HERE/examples/apps/wamr_full_host.c"
QJS="$HERE/third_party/quickjs"
SRC="$HERE/tests/qemu/proc/app_run_demo.mc"
NETTCP="$HERE/tests/qemu/proc/app_run_net_tcp.mc"             # TCP-backed net provider (agent-agnostic)
RUNTIME="$HERE/tests/qemu/proc/qjs_net_real_runtime.mc"      # M-mode TCP net runtime
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
USERMODE="$HERE/tests/qemu/proc/usermode_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: $TEST_NAME — python3 unavailable for the test HTTP server"
    exit 0
fi

WORK="$(mktemp -d)"
[ "${KEEP_WORK:-0}" = 1 ] && echo "KEEP_WORK: $WORK" >&2
HTTP_PID=""
cleanup() {
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    [ "${KEEP_WORK:-0}" != 1 ] && rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/docroot"
printf '<html><body>%s</body></html>\n' "$TOKEN" > "$WORK/docroot/index.html"
python3 -u -m http.server "$PORT" --bind 0.0.0.0 --directory "$WORK/docroot" >"$WORK/httpd.log" 2>&1 &
HTTP_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then break; fi
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then break; fi
    sleep 0.3
done
: >"$WORK/httpd.log"

# ---- 0. The guest: a wasm32-wasi binary (off-the-shelf zig + wasi-libc), stock; no feature-pin (WAMR reads overlong call_indirect) ----
WASI_MCPU="none"  # no feature-pin: WAMR is built WASM_ENABLE_CALL_INDIRECT_OVERLONG=1
                  # (WDEF below), so its loader reads stock wasi-libc's overlong call_indirect
                  # table-index LEB directly — no `-mcpu=` rebuild needed
if [ "$GUEST_KIND" = qjs ]; then
    # Reuse the shared QuickJS-to-wasm object cache (see wasm-confined-test.sh): compile the 4 heavy
    # QuickJS TUs once, then per-gate only compile the small guest .c and link against the cached objects.
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

# ---- 1. The confined U-mode host ELF (hardware FP) ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
            -fno-builtin -I"$HERE/user/libc/include")
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
WAMR_CFLAGS=("${APP_CFLAGS[@]}" -Wno-implicit-function-declaration)
# Build/reuse the cached WAMR engine archive (flock-guarded, stamped) — shared with the other gates.
CACHE="$HERE/.wamr-cache"; mkdir -p "$CACHE"; WAMR_LIB="$CACHE/libwamr.a"
WANT="$(printf '%s ' "${WDEF[@]}"; find "$WC/shared/platform/mc" "$WC/shared/utils" "$WC/shared/mem-alloc" "$WC/iwasm/common" "$WC/iwasm/interpreter" \( -name '*.c' -o -name '*.h' -o -name '*.S' \) 2>/dev/null | sort | xargs ls -la 2>/dev/null | md5sum)"
kernel_boot_lock 9 "$CACHE/.lock"
if [ ! -f "$WAMR_LIB" ] || [ "$(cat "$CACHE/stamp" 2>/dev/null)" != "$WANT" ]; then
    CB="$CACHE/obj"; rm -rf "$CB"; mkdir -p "$CB"; OBJS=(); j=0
    cwamr() { "$CLANG" "${WAMR_CFLAGS[@]}" "${WINC[@]}" "${WDEF[@]}" -c "$1" -o "$2"; OBJS+=("$2"); }
    cwamr "$WC/shared/platform/mc/mc_platform.c" "$CB/w_mc.o"
    for f in "$WC"/shared/utils/*.c; do cwamr "$f" "$CB/wu_$((j++)).o"; done
    cwamr "$WC/shared/mem-alloc/mem_alloc.c" "$CB/w_ma.o"
    for f in "$WC"/shared/mem-alloc/ems/ems_alloc.c "$WC"/shared/mem-alloc/ems/ems_hmu.c "$WC"/shared/mem-alloc/ems/ems_kfc.c; do cwamr "$f" "$CB/we_$((j++)).o"; done
    for f in "$WC"/iwasm/common/*.c; do case "$f" in *wasm_application.c) continue;; esac; cwamr "$f" "$CB/wc_$((j++)).o"; done
    cwamr "$WC/iwasm/interpreter/wasm_runtime.c" "$CB/w_rt.o"
    cwamr "$WC/iwasm/interpreter/$WAMR_INTERP_TU" "$CB/w_interp.o"
    cwamr "$WC/iwasm/interpreter/wasm_loader.c" "$CB/w_loader.o"
    "$CLANG" "${WAMR_CFLAGS[@]}" -c "$WC/iwasm/common/arch/invokeNative_riscv.S" -o "$CB/w_tramp.o"; OBJS+=("$CB/w_tramp.o")
    "$AR" rcs "$WAMR_LIB" "${OBJS[@]}"
    printf '%s' "$WANT" > "$CACHE/stamp"
fi
kernel_boot_unlock 9 "$CACHE/.lock"
"$CLANG" "${APP_CFLAGS[@]}" -I"$WC/iwasm/include" -I"$WASMDIR" -I"$WORK" -c "$HOST" -o "$WORK/host.o"

"$MCC" emit-c "$HERE/user/runtime/crt0.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"

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
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
    printf 'unsigned long mc_app_image(void) { return (unsigned long)app_image; }\n'
    printf 'unsigned long mc_app_image_len(void) { return (unsigned long)app_image_len; }\n'
} >"$WORK/app_image.c"

# ---- 3. Kernel image (M-mode) with app_run_demo + the TCP-backed net tool ----
KERNEL_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
               -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
               -Wno-unused-parameter -Wno-unused-function -fno-builtin)
CFLAGS=("${KERNEL_CFLAGS[@]}")
mkdir -p "$WORK/app" "$WORK/nettcp" "$WORK/runtime" "$WORK/platform"
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/app.o" "$WORK/app"
kernel_boot_compile_mc_object "$BACKEND" "$NETTCP" "$WORK/nettcp.o" "$WORK/nettcp"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/runtime"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK/platform"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
kernel_boot_compile_c_object "$USERMODE" "$WORK/usermode.o"
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/app_image.c" -o "$WORK/app_image.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" --allow-multiple-definition -T "$LDSCRIPT" \
    "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/app.o" "$WORK/nettcp.o" "$WORK/platform.o" \
    "$WORK/app_image.o" $K_SUPPORT -o "$WORK/kernel.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -bios none -nographic -m 256M \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/wasm-net-real.pcap" \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"
echo "--- python access log ---"
tr -d '\000' <"$WORK/httpd.log" 2>/dev/null || true
echo "-------------------------"

UART_OK=0; LOG_OK=0; PCAP_OK=0; ACCESS_LINE=""; PCAP_BYTES=0
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    UART_OK=1
fi
if ACCESS_LINE="$(grep -aE '"GET / HTTP/1\.[01]" 200' "$WORK/httpd.log" 2>/dev/null | head -1)"; then
    [ -n "$ACCESS_LINE" ] && LOG_OK=1
fi
if [ -s "$WORK/wasm-net-real.pcap" ]; then
    PCAP_BYTES="$(wc -c <"$WORK/wasm-net-real.pcap" | tr -d ' ')"; PCAP_OK=1
fi

if [ "$UART_OK" = 1 ] && [ "$LOG_OK" = 1 ] && [ "$PCAP_OK" = 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: a confined WASM guest's net_fetch reached a live HTTP server through the real TCP-backed broker transport over virtio-net."
    echo "  access: $ACCESS_LINE"
    echo "  pcap:   $PCAP_BYTES bytes"
    exit 0
fi
echo "FAIL: $TEST_NAME — expected '$EXPECT', USER-EXIT, a real HTTP GET 200, and a non-empty pcap"
exit 1
