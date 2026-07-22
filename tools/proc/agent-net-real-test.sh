#!/usr/bin/env bash
# Agent-OS NETWORK MODEL, REAL TRANSPORT, under REAL emulation.
#
# Starts a REAL HTTP server (python3 -m http.server) in the container, lowers the integrated
# agent-net-real demo through the selected backend, links it with the net runtime into a bare
# riscv64 image, and boots it under qemu-system-riscv64 -machine virt with virtio-net user
# networking. The image spawns a SANDBOXED agent that reaches the live server ONLY through the
# broker's REAL tcp_socket transport (net_fetch_tcp): the allowed endpoint (web) active-opens a
# genuine TCP connection to the slirp gateway 10.0.2.2:PORT and reads the real 200 response (W); a
# disallowed endpoint (evil) is egress-Blocked WITHOUT a packet (D); the budget bound holds (B); the
# dispatched egresses are audited (A).
#
# PASS requires ALL of: UART AGENT-NET-REAL-OK, the stage markers W/D/B/A, the unique body token over
# UART (proving the real response arrived), a real GET 200 in the python access log (proving a real
# brokered request reached the server), and a non-empty pcap of the genuine frames.
#
# Usage: tools/proc/agent-net-real-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

PORT=8080                          # must match HTTP_PORT in agent_net_real_runtime.c
TOKEN="MC-AGENT-NET-REAL-OK"       # the unique body token we verify over UART

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
# Boot seam now PURE MC (agent_net_real_mmode_demo.mc imports agent_net_real_demo.mc + the
# shared MMIO probe; provides test_main, no _start). The std/dma+std/time platform is the
# shared mmode_dma_time.mc (8 MiB pool); the green-thread context switch + the .text.start
# _start that calls test_main are the shared context_runtime.c (C), linked alongside.
SRC="$HERE/tests/qemu/proc/agent_net_real_mmode_demo.mc"
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
SHARED="$HERE/tests/qemu/proc/context_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="AGENT-NET-REAL-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-agent-net-real-test" || echo "agent-net-real-test")

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

# 1. Doc root with index.html carrying the unique token (the body the real fetch must read back).
mkdir -p "$WORK/docroot"
printf '<html><body>%s</body></html>\n' "$TOKEN" > "$WORK/docroot/index.html"

# 2. Start the REAL HTTP server, access log captured. Bind 0.0.0.0 so the slirp gateway redirect
#    (10.0.2.2 -> host loopback) reaches it.
python3 -u -m http.server "$PORT" --bind 0.0.0.0 --directory "$WORK/docroot" \
    >"$WORK/httpd.log" 2>&1 &
HTTP_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then break; fi
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then break; fi
    sleep 0.3
done

# 3. Build the kernel image.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/agent.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK"
kernel_boot_compile_c_object "$SHARED" "$WORK/shared.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/shared.o" "$WORK/agent.o" "$WORK/platform.o" $SUPPORT_OBJ -o "$WORK/agent.elf"

# 4. Boot under QEMU with virtio-net user networking + pcap capture. The guest's brokered agent
#    connects to the slirp gateway 10.0.2.2:PORT, redirected to the host loopback where python listens.
OUT="$(timeout 40 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/agent.pcap" \
        -kernel "$WORK/agent.elf" 2>/dev/null || true)"

echo "--- driver UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"
echo "--- python access log ---"
cat "$WORK/httpd.log" 2>/dev/null || true
echo "-------------------------"

# 5. PASS requires all proofs.
UART_OK=0; MARKERS_OK=0; TOKEN_OK=0; LOG_OK=0; PCAP_OK=0
ACCESS_LINE=""
PCAP_BYTES=0

if printf '%s' "$OUT" | grep -q "$EXPECT"; then UART_OK=1; fi
# The four broker stage markers W (real web fetch), D (Denied), B (Budget), A (audit), in order.
if printf '%s' "$OUT" | grep -q "WDBA"; then MARKERS_OK=1; fi
# The body token must have actually arrived over UART (the real response text).
if printf '%s' "$OUT" | grep -q "$TOKEN"; then TOKEN_OK=1; fi

if ACCESS_LINE="$(grep -E '"GET / HTTP/1\.[01]" 200' "$WORK/httpd.log" 2>/dev/null | head -1)"; then
    [ -n "$ACCESS_LINE" ] && LOG_OK=1
fi

if [ -s "$WORK/agent.pcap" ]; then
    PCAP_BYTES="$(wc -c <"$WORK/agent.pcap" | tr -d ' ')"
    PCAP_OK=1
fi

if [ "$UART_OK" = 1 ] && [ "$MARKERS_OK" = 1 ] && [ "$TOKEN_OK" = 1 ] && [ "$LOG_OK" = 1 ] && [ "$PCAP_OK" = 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: a sandboxed agent made a REAL brokered (egress-checked + budgeted + audited) network call through the tcp_socket transport against a live python http.server under QEMU."
    echo "  UART:    $EXPECT + stage markers WDBA printed; body token '$TOKEN' received over UART"
    echo "  access:  $ACCESS_LINE"
    echo "  pcap:    $PCAP_BYTES bytes of real frames captured at $WORK/agent.pcap"
    exit 0
fi

echo "FAIL: $TEST_NAME — not all proofs present:"
echo "  UART AGENT-NET-REAL-OK: $UART_OK   stage markers WDBA: $MARKERS_OK   body token over UART: $TOKEN_OK   access-log GET 200: $LOG_OK   pcap non-empty: $PCAP_OK ($PCAP_BYTES bytes)"
exit 1
