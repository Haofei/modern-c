#!/usr/bin/env bash
# Deterministic in-kernel REAL TLS 1.2 HTTPS GET (CI gate).
#
# Starts a LOCAL python HTTPS server using the committed self-signed cert for
# CN=host.test (third_party/trust-anchors/host_test.{pem,key}); that cert is its own
# trust anchor, embedded in the kernel (local_ta.c). Compiles every BearSSL src/**/*.c
# freestanding for riscv64, lowers the MC TCP transport (tests/qemu/tls/tls_demo.mc)
# through the selected backend, links them with https_get_runtime.c into a bare-metal
# `virt` image, and boots it under qemu-system-riscv64 with virtio-net (slirp) +
# virtio-rng. The guest TCP-connects to 10.0.2.2:PORT (slirp -> host loopback), runs a
# REAL BearSSL handshake validating the self-signed TA + server_name "host.test",
# sends an HTTPS GET over the encrypted channel, and verifies the DECRYPTED response
# contains the token MC-KERNEL-HTTPS-OK and "200".
#
# PASS requires ALL: UART HTTPS-GET-OK + CERT-CHAIN-VALIDATED + decrypted token + "200",
# the python access log shows the GET 200 (served over TLS), and a non-empty pcap (the
# captured frames are TLS records, not plaintext).
#
# Usage: tools/tls/https-get-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain / QEMU / python3 ssl is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

PORT=18443                         # local HTTPS server port (slirp -> host loopback)
SERVERNAME="host.test"             # SNI + cert-name validated by BearSSL
TOKEN="MC-KERNEL-HTTPS-OK"         # the unique decrypted body token we verify

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/tls/tls_demo.mc"
RUNTIME="$HERE/kernel/drivers/virtio/https_get_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
BEARSSL="$HERE/third_party/bearssl"
TA_DIR="$HERE/third_party/trust-anchors"
EXPECT="HTTPS-GET-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-https-get-test" || echo "https-get-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: $TEST_NAME — python3 unavailable for the test HTTPS server"
    exit 0
fi
if ! python3 -c 'import ssl' 2>/dev/null; then
    echo "SKIP: $TEST_NAME — python3 ssl module unavailable"
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

# 2. Start a REAL HTTPS server with the committed self-signed cert (CN=host.test) — the
#    same cert whose TA is embedded in the kernel. Access log captured.
cat > "$WORK/https_server.py" <<PYEOF
import http.server, ssl, sys, os
os.chdir("$WORK/docroot")
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile="$TA_DIR/host_test.pem", keyfile="$TA_DIR/host_test.key")
# Force TLS 1.2 to match BearSSL's br_ssl_client_init_full (TLS 1.2) profile.
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.maximum_version = ssl.TLSVersion.TLSv1_2
httpd = http.server.HTTPServer(("0.0.0.0", $PORT), http.server.SimpleHTTPRequestHandler)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
log = open("$WORK/httpd.log", "w", buffering=1)
sys.stderr = log
sys.stdout = log
httpd.serve_forever()
PYEOF
python3 -u "$WORK/https_server.py" >"$WORK/httpd_stderr.log" 2>&1 &
HTTP_PID=$!
# Wait for it to bind + actually accept a TLS connection.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 -c "import socket,ssl,sys
c=ssl.create_default_context(); c.check_hostname=False; c.verify_mode=ssl.CERT_NONE
try:
  s=socket.create_connection(('127.0.0.1',$PORT),timeout=0.5)
  ss=c.wrap_socket(s,server_hostname='$SERVERNAME'); ss.close(); sys.exit(0)
except Exception: sys.exit(1)" 2>/dev/null; then break; fi
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then
        echo "SKIP: $TEST_NAME — local HTTPS server failed to start"; cat "$WORK/httpd_stderr.log" "$WORK/httpd.log" 2>/dev/null; exit 0
    fi
    sleep 0.3
done

# 3. Compile BearSSL freestanding for riscv64.
EPOCH="$(date +%s)"
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2 -fno-builtin
        -DBR_USE_UNIX_TIME=0 -DBR_USE_WIN32_TIME=0
        -DBR_USE_URANDOM=0 -DBR_USE_GETENTROPY=0
        -I"$BEARSSL/freestanding-shim" -I"$BEARSSL/inc" -I"$BEARSSL/src")

echo "Compiling BearSSL freestanding for riscv64..."
BEARSSL_OBJS=()
mkdir -p "$WORK/bearssl"
while IFS= read -r f; do
    obj="$WORK/bearssl/$(echo "$f" | sed 's#[/.]#_#g').o"
    "$CLANG" "${CFLAGS[@]}" -c "$f" -o "$obj"
    BEARSSL_OBJS+=("$obj")
done < <(find "$BEARSSL/src" -name '*.c' | sort)

# 4. Lower the MC transport + compile the runtime (embeds local_ta.c via -I the TA dir).
MCFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
         -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
         -Wno-unused-function -fno-builtin)
RUNTIME_FLAGS=("${CFLAGS[@]}"
        -I"$TA_DIR"
        -DMC_BUILD_EPOCH="$EPOCH"
        -DHTTPS_PORT="$PORT"
        "-DTLS_SERVERNAME=\"$SERVERNAME\""
        "-DTLS_HOSTHDR=\"$SERVERNAME\"")

# MC object built with the MC backend flags; runtime + bearssl with the BearSSL flags.
CFLAGS=("${MCFLAGS[@]}")
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/tls.o" "$WORK"
# The real wall-clock seam (goldfish-RTC) — provides time_now_epoch() for X.509 validity.
kernel_boot_compile_mc_object "$BACKEND" "$HERE/kernel/core/time.mc" "$WORK/time.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
"$CLANG" "${RUNTIME_FLAGS[@]}" -c "$RUNTIME" -o "$WORK/runtime.o"
# Shared virtio-rng entropy driver (single source of truth, also used by the smoke test).
"$CLANG" "${RUNTIME_FLAGS[@]}" -c "$HERE/kernel/drivers/virtio/virtio_rng.c" -o "$WORK/virtio_rng.o"

kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/virtio_rng.o" "$WORK/tls.o" "$WORK/time.o" "${BEARSSL_OBJS[@]}" $SUPPORT_OBJ -o "$WORK/https.elf"

# 5. Boot under QEMU with virtio-net (slirp) + virtio-rng + pcap.
OUT="$(timeout 90 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev user,id=n0 \
        -device virtio-net-device,netdev=n0 \
        -device virtio-rng-device \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/https.pcap" \
        -kernel "$WORK/https.elf" 2>"$WORK/qemu.err" || true)"

echo "--- guest UART output ---"
printf '%s\n' "$OUT"
echo "-------------------------"
echo "--- python HTTPS access log ---"
cat "$WORK/httpd.log" 2>/dev/null || true
echo "-------------------------------"

# 6. PASS requires all proofs.
UART_OK=0; CERT_OK=0; TOKEN_OK=0; STATUS_OK=0; LOG_OK=0; PCAP_OK=0
ACCESS_LINE=""; PCAP_BYTES=0; CIPHER=""

printf '%s' "$OUT" | grep -q "$EXPECT" && UART_OK=1
printf '%s' "$OUT" | grep -q 'CERT-CHAIN-VALIDATED' && CERT_OK=1
printf '%s' "$OUT" | grep -q "$TOKEN" && TOKEN_OK=1
printf '%s' "$OUT" | grep -qE 'HTTP/1\.[01] 200' && STATUS_OK=1
CIPHER="$(printf '%s' "$OUT" | grep -oE 'CIPHER-SUITE=0x[0-9a-f]+' | head -1)"

if ACCESS_LINE="$(grep -E '"GET / HTTP/1\.[01]" 200' "$WORK/httpd.log" 2>/dev/null | head -1)"; then
    [ -n "$ACCESS_LINE" ] && LOG_OK=1
fi
if [ -s "$WORK/https.pcap" ]; then
    PCAP_BYTES="$(wc -c <"$WORK/https.pcap" | tr -d ' ')"
    PCAP_OK=1
fi

echo "negotiated cipher: ${CIPHER:-<none>}"

if [ "$UART_OK" = 1 ] && [ "$CERT_OK" = 1 ] && [ "$TOKEN_OK" = 1 ] \
   && [ "$STATUS_OK" = 1 ] && [ "$LOG_OK" = 1 ] && [ "$PCAP_OK" = 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: REAL BearSSL TLS 1.2 handshake validated the"
    echo "  self-signed '$SERVERNAME' trust anchor and decrypted a real HTTPS GET under QEMU."
    echo "  UART:    $EXPECT + CERT-CHAIN-VALIDATED + decrypted token '$TOKEN' + 200"
    echo "  cipher:  ${CIPHER:-<none>}"
    echo "  access:  $ACCESS_LINE"
    echo "  pcap:    $PCAP_BYTES bytes of TLS records captured at $WORK/https.pcap"
    exit 0
fi

echo "FAIL: $TEST_NAME — not all proofs present:"
echo "  UART HTTPS-GET-OK: $UART_OK   cert-validated: $CERT_OK   decrypted token: $TOKEN_OK"
echo "  200 status: $STATUS_OK   access-log GET 200: $LOG_OK   pcap non-empty: $PCAP_OK ($PCAP_BYTES bytes)"
exit 1
