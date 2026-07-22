#!/usr/bin/env bash
# Real outbound HTTP GET test.
#
# Starts a REAL HTTP server (python3 -m http.server) in the container, lowers the MC
# TCP/HTTP client demo through the selected backend, links it into a bare-metal
# riscv64 image with the platform runtime, and boots it under qemu-system-riscv64
# -machine virt with virtio-net user networking. The guest actively opens a TCP
# connection to the slirp gateway (10.0.2.2:PORT), which slirp redirects to the host
# loopback where python listens, sends "GET / HTTP/1.0", and verifies the real 200
# response body. PASS requires ALL THREE: UART HTTP-GET-OK, a real GET line in the
# python access log, and a non-empty pcap of the genuine frames.
#
# Usage: tools/net/http-get-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

PORT=8080                       # must match HTTP_PORT in http_get_runtime.c
TOKEN="MC-KERNEL-HTTP-OK"       # the unique body token we verify

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
# The boot seam is now PURE MC (http_get_mmode_demo.mc imports http_get_demo.mc for
# http_get_drive + the shared MMIO probe). The std/dma + std/time platform primitives
# (CLINT mtime + 8 MiB bump pool) are the separate mmode_dma_time.mc object.
SRC="$HERE/tests/qemu/net/http_get_mmode_demo.mc"
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="HTTP-GET-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-http-get-test" || echo "http-get-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: $TEST_NAME — python3 unavailable for the test HTTP server"
    exit 0
fi

WORK="$(mktemp -d)"
HTTP_PID=""
cleanup() {
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Doc root with index.html carrying the unique token.
mkdir -p "$WORK/docroot"
printf '<html><body>%s</body></html>\n' "$TOKEN" > "$WORK/docroot/index.html"

# 2. Start the REAL HTTP server, access log captured. Bind 0.0.0.0 so the slirp
#    gateway redirect (10.0.2.2 -> host loopback) reaches it.
python3 -u -m http.server "$PORT" --bind 0.0.0.0 --directory "$WORK/docroot" \
    >"$WORK/httpd.log" 2>&1 &
HTTP_PID=$!
# Give it a moment to bind, and confirm it actually came up.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then break; fi
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then break; fi
    sleep 0.3
done

# 3. Build the kernel image.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/http.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/http.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/http.elf"

# 4. Boot under QEMU with virtio-net user networking + pcap capture. The guest
#    connects to the slirp gateway 10.0.2.2:PORT, redirected to the host loopback.
OUT="$(timeout 40 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/http.pcap" \
        -kernel "$WORK/http.elf" 2>/dev/null || true)"

echo "--- driver UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"
echo "--- python access log ---"
cat "$WORK/httpd.log" 2>/dev/null || true
echo "-------------------------"

# 5. PASS requires all three independent proofs.
UART_OK=0; LOG_OK=0; PCAP_OK=0
ACCESS_LINE=""
PCAP_BYTES=0

if printf '%s' "$OUT" | grep -q "$EXPECT"; then UART_OK=1; fi
# Also require the body token actually arrived over UART (the response text).
TOKEN_OK=0
if printf '%s' "$OUT" | grep -q "$TOKEN"; then TOKEN_OK=1; fi

if ACCESS_LINE="$(grep -E '"GET / HTTP/1\.[01]" 200' "$WORK/httpd.log" 2>/dev/null | head -1)"; then
    [ -n "$ACCESS_LINE" ] && LOG_OK=1
fi

if [ -s "$WORK/http.pcap" ]; then
    PCAP_BYTES="$(wc -c <"$WORK/http.pcap" | tr -d ' ')"
    PCAP_OK=1
fi

if [ "$UART_OK" = 1 ] && [ "$TOKEN_OK" = 1 ] && [ "$LOG_OK" = 1 ] && [ "$PCAP_OK" = 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: real outbound TCP active-open + HTTP GET against a live python http.server under QEMU."
    echo "  UART:   $EXPECT printed and body token '$TOKEN' received over UART"
    echo "  access: $ACCESS_LINE"
    echo "  pcap:   $PCAP_BYTES bytes of real frames captured at $WORK/http.pcap"
    exit 0
fi

echo "FAIL: $TEST_NAME — not all proofs present:"
echo "  UART HTTP-GET-OK: $UART_OK   body token over UART: $TOKEN_OK   access-log GET 200: $LOG_OK   pcap non-empty: $PCAP_OK ($PCAP_BYTES bytes)"
exit 1
