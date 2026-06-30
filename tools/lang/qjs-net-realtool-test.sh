#!/usr/bin/env bash
# QuickJS production network tool over REAL TCP transport.
#
# Builds the fixed QuickJS host + a pure JS agent, configures app_run_demo's SYS_SUBMIT/SYS_POLL
# runtime for TCP-backed net_fetch, starts a live python http.server, and boots under QEMU with
# virtio-net. PASS requires the JS agent's success marker, an HTTP access-log GET, and a non-empty
# pcap, proving host_net_fetch reached the server through net_fetch_tcp.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
AGENT_JS_REL="${3:-examples/agents/agent_net_real_tool.js}"
EXPECT="${4:-net-real: ok}"
NAME_BASE="${5:-qjs-net-realtool}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"
PORT=8080
TOKEN="MC-QJS-NET-REALTOOL-OK"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
QJS="$HERE/third_party/quickjs"
SRC="$HERE/tests/qemu/proc/app_run_demo.mc"
NETTCP="$HERE/tests/qemu/proc/app_run_net_tcp.mc"
RUNTIME="$HERE/tests/qemu/proc/qjs_net_real_runtime.mc"
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
USERMODE="$HERE/tests/qemu/proc/usermode_runtime.mc"
HOST="$HERE/examples/apps/qjs_host.c"
AGENT_JS="$HERE/$AGENT_JS_REL"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-$NAME_BASE-test" || echo "$NAME_BASE-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: $TEST_NAME — python3 unavailable for the test HTTP server"
    exit 0
fi

WORK="$(mktemp -d)"
if [ "${KEEP_WORK:-0}" = 1 ]; then
    echo "KEEP_WORK: $WORK" >&2
fi
HTTP_PID=""
cleanup() {
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    if [ "${KEEP_WORK:-0}" != 1 ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

mkdir -p "$WORK/docroot"
printf '<html><body>%s</body></html>\n' "$TOKEN" > "$WORK/docroot/index.html"
python3 -u -m http.server "$PORT" --bind 0.0.0.0 --directory "$WORK/docroot" \
    >"$WORK/httpd.log" 2>&1 &
HTTP_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then break; fi
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then break; fi
    sleep 0.3
done
: >"$WORK/httpd.log"

# ---- 1. Confined U-mode QuickJS agent ELF ----
APP_CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
            -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1
            -fno-builtin -D__wasi__ -I"$HERE/user/libc/include" -I"$QJS")
# QuickJS engine objects: build once per (compiler+flags), cached + cp'd in (build-qjs.sh).
bash "$HERE/tools/user/build-qjs.sh" "$WORK" "$CLANG" "${APP_CFLAGS[@]}"
"$CLANG" "${APP_CFLAGS[@]}" -I"$HERE" -c "$HOST" -o "$WORK/host.o"
"$MCC" emit-c "$HERE/user/runtime/crt0.mc" > "$WORK/crt0_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/crt0_gen.c" -o "$WORK/crt0.o"
"$MCC" emit-c "$HERE/user/runtime/app_traps.mc" > "$WORK/traps_gen.c"
"$CLANG" "${APP_CFLAGS[@]}" -c "$WORK/traps_gen.c" -o "$WORK/traps.o"

CFLAGS=("${APP_CFLAGS[@]}")
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/libc.mc" "$WORK/libc.o" "$WORK"
MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$HERE/user/libc/syscall_user.mc" "$WORK/sys.o" "$WORK"
APP_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/app-support.o")"
bash "$HERE/tools/user/build-openlibm.sh" "$WORK/libm.a" >/dev/null

"$LLD" -T "$HERE/user/runtime/user_qjs.ld" \
    "$WORK/crt0.o" "$WORK/host.o" \
    "$WORK/dtoa.o" "$WORK/libunicode.o" "$WORK/libregexp.o" "$WORK/quickjs.o" \
    "$WORK/libc.o" "$WORK/sys.o" "$WORK/traps.o" $APP_SUPPORT "$WORK/libm.a" \
    -o "$WORK/agent.elf"

# ---- 2. Embed app ELF + JS source ----
{
    printf 'const unsigned char app_image[] = {'
    od -An -v -tx1 "$WORK/agent.elf" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\nconst unsigned int app_image_len = %s;\n' "$(wc -c < "$WORK/agent.elf")"
    printf 'unsigned long mc_app_image(void) { return (unsigned long)app_image; }\n'
    printf 'unsigned long mc_app_image_len(void) { return (unsigned long)app_image_len; }\n'
} >"$WORK/app_image.c"

{
    printf 'static const char agent_js[] = {'
    od -An -v -tx1 "$AGENT_JS" | tr -s ' ' '\n' | grep -v '^$' | sed 's/^/0x/; s/$/,/' | tr '\n' ' '
    printf '};\n'
    printf 'unsigned long mc_agent_source(unsigned long *out_len) {\n'
    printf '    *out_len = sizeof agent_js;\n'
    printf '    return (unsigned long)agent_js;\n}\n'
} >"$WORK/agent_src.c"

# ---- 3. Kernel image with app_run_demo + TCP-backed net tool ----
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
"$CLANG" "${KERNEL_CFLAGS[@]}" -c "$WORK/agent_src.c" -o "$WORK/agent_src.o"
K_SUPPORT="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/k-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" --allow-multiple-definition -T "$LDSCRIPT" \
    "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/usermode.o" \
    "$WORK/runtime.o" "$WORK/app.o" "$WORK/nettcp.o" "$WORK/platform.o" \
    "$WORK/app_image.o" "$WORK/agent_src.o" $K_SUPPORT -o "$WORK/kernel.elf"

OUT="$(timeout 120 "$QEMU" -machine virt -bios none -nographic -m 256M \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/qjs-net-real.pcap" \
        -kernel "$WORK/kernel.elf" 2>/dev/null || true)"

echo "--- kernel UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"
echo "--- python access log ---"
tr -d '\000' <"$WORK/httpd.log" 2>/dev/null || true
echo "-------------------------"

UART_OK=0; LOG_OK=0; PCAP_OK=0
ACCESS_LINE=""
PCAP_BYTES=0
if printf '%s' "$OUT" | grep -q "CONFINED: kernel unmapped in agent space" \
   && printf '%s' "$OUT" | grep -q "$EXPECT" \
   && printf '%s' "$OUT" | grep -q "USER-EXIT from U"; then
    UART_OK=1
fi
if ACCESS_LINE="$(grep -aE '"GET / HTTP/1\.[01]" 200' "$WORK/httpd.log" 2>/dev/null | head -1)"; then
    [ -n "$ACCESS_LINE" ] && LOG_OK=1
fi
if [ -s "$WORK/qjs-net-real.pcap" ]; then
    PCAP_BYTES="$(wc -c <"$WORK/qjs-net-real.pcap" | tr -d ' ')"
    PCAP_OK=1
fi

if [ "$UART_OK" = 1 ] && [ "$LOG_OK" = 1 ] && [ "$PCAP_OK" = 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend pure-JS host_net_fetch reached a live HTTP server through the real TCP-backed broker transport over virtio-net."
    echo "  access: $ACCESS_LINE"
    echo "  pcap:   $PCAP_BYTES bytes"
    exit 0
fi

echo "FAIL: $TEST_NAME — expected '$EXPECT', USER-EXIT, a real HTTP GET 200, and a non-empty pcap"
exit 1
