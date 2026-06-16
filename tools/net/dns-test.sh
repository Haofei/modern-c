#!/usr/bin/env bash
# Deterministic live DNS + HTTP test (no internet dependency).
#
# Starts a tiny LOCAL DNS responder and a REAL HTTP server in the container, lowers the
# MC DNS-resolver + HTTP-client demo through the selected backend, links it into a
# bare-metal riscv64 image, and boots it under qemu-system-riscv64 -machine virt with
# virtio-net user networking. The guest sends a REAL DNS A-query for "host.test" to the
# slirp gateway 10.0.2.2:PORT_D (redirected by slirp to the host loopback where the
# python DNS responder listens), parses the A record (answered as 10.0.2.2 — itself the
# gateway, redirected to the host HTTP server), then active-opens a TCP connection to
# the resolved IP:PORT_H and GETs it, verifying the body token.
#
# PASS requires ALL: UART DNS-HTTP-OK, the resolved IP printed == 10.0.2.2, the DNS
# server log shows the A-query, the HTTP access log shows GET 200, and a non-empty pcap.
#
# Usage: tools/net/dns-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain / QEMU / python3 is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

PORT_H=18080                       # local HTTP server port
HOSTNAME="host.test"               # the name the guest resolves
RESOLVE_TO="10.0.2.2"              # the A record we answer with (gateway -> host HTTP)
TOKEN="MC-DNS-HTTP-OK"             # the unique HTTP body token we verify
DNS_FWD_IP="10.0.2.3"              # slirp's built-in DNS forwarder (relays to resolv.conf)
DNS_FWD_HEX="0x0A000203u"          # 10.0.2.3 as a host-order u32

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/tests/qemu/net/dns_http_demo.mc"
RUNTIME="$HERE/kernel/drivers/virtio/dns_runtime.c"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
EXPECT="DNS-HTTP-OK"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-dns-test" || echo "dns-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: $TEST_NAME — python3 unavailable for the test DNS/HTTP servers"
    exit 0
fi

WORK="$(mktemp -d)"
HTTP_PID=""
DNS_PID=""
RESOLV="/etc/resolv.conf"
RESOLV_BAK="$WORK/resolv.conf.bak"
RESOLV_SAVED=0
cleanup() {
    [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true
    [ -n "$DNS_PID" ] && kill "$DNS_PID" 2>/dev/null || true
    [ "$RESOLV_SAVED" = 1 ] && cp "$RESOLV_BAK" "$RESOLV" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Doc root with index.html carrying the unique token.
mkdir -p "$WORK/docroot"
printf '<html><body>%s</body></html>\n' "$TOKEN" > "$WORK/docroot/index.html"

# 2. A tiny LOCAL authoritative DNS responder bound to 127.0.0.1:53. We point the
#    container's resolv.conf at it so QEMU slirp's built-in DNS forwarder (10.0.2.3,
#    which relays the guest's query to the host's configured nameserver) lands the
#    guest's REAL DNS A-query here. The responder answers HOSTNAME with RESOLVE_TO and
#    logs every query it receives (the wire proof). Real UDP packets end to end.
cat > "$WORK/dns_server.py" <<PYEOF
import socket, struct, sys
ANSWER = bytes(int(x) for x in "$RESOLVE_TO".split("."))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 53))
log = open("$WORK/dns.log", "w", buffering=1)
while True:
    data, addr = s.recvfrom(2048)
    if len(data) < 12:
        continue
    i = 12
    labels = []
    while i < len(data):
        n = data[i]
        if n == 0:
            i += 1
            break
        labels.append(data[i+1:i+1+n])
        i += n + 1
    qname = b".".join(labels)
    qtype = struct.unpack(">H", data[i:i+2])[0] if i+2 <= len(data) else 0
    log.write("QUERY name=%s type=%d len=%d\n" % (qname.decode("ascii","replace"), qtype, len(data)))
    txn = data[0:2]
    header = txn + b"\x81\x80" + b"\x00\x01\x00\x01\x00\x00\x00\x00"
    question = data[12:i+4]  # QNAME + QTYPE + QCLASS
    answer = b"\xc0\x0c" + b"\x00\x01\x00\x01" + b"\x00\x00\x00\x3c" + b"\x00\x04" + ANSWER
    s.sendto(header + question + answer, addr)
    log.write("ANSWER %s -> %s\n" % (qname.decode("ascii","replace"), "$RESOLVE_TO"))
PYEOF
python3 -u "$WORK/dns_server.py" >"$WORK/dns_stderr.log" 2>&1 &
DNS_PID=$!
# Wait for the responder to bind :53.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    # Probe with a DISTINCT name ("probe.test") so the only "$HOSTNAME" query logged is
    # the guest's — the proof grep then can't be satisfied by this readiness probe.
    if python3 -c 'import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(0.5)
s.sendto(b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x05probe\x04test\x00\x00\x01\x00\x01",("127.0.0.1",53))
try: s.recvfrom(512); sys.exit(0)
except Exception: sys.exit(1)' 2>/dev/null; then break; fi
    if ! kill -0 "$DNS_PID" 2>/dev/null; then echo "SKIP: $TEST_NAME — could not start local DNS responder on :53"; cat "$WORK/dns_stderr.log"; exit 0; fi
    sleep 0.3
done

# Point the resolver at our responder so slirp's 10.0.2.3 forwarder relays here.
cp "$RESOLV" "$RESOLV_BAK" 2>/dev/null && RESOLV_SAVED=1 || true
printf 'nameserver 127.0.0.1\noptions ndots:0\n' > "$RESOLV"

# 3. The REAL HTTP server, access log captured. Bind 0.0.0.0 so the gateway redirect
#    (10.0.2.2 -> host loopback) reaches it.
python3 -u -m http.server "$PORT_H" --bind 0.0.0.0 --directory "$WORK/docroot" \
    >"$WORK/httpd.log" 2>&1 &
HTTP_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT_H/" 2>/dev/null; then break; fi
    if ! kill -0 "$HTTP_PID" 2>/dev/null; then break; fi
    sleep 0.3
done

# 4. Build the kernel image. The runtime is parameterized via -D: the kernel sends its
#    DNS A-query to 10.0.2.3:53 (slirp's built-in DNS forwarder), which relays it to the
#    host nameserver we configured above (our local responder); then it GETs the resolved
#    IP (10.0.2.2 -> host HTTP server) on PORT_H.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin
        -DDNS_SERVER_IP=$DNS_FWD_HEX
        -DHTTP_PORT=$PORT_H
        '-DDNS_HOSTNAME="'"$HOSTNAME"'"')

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/dns.o" "$WORK"
kernel_boot_compile_c_object "$RUNTIME" "$WORK/runtime.o"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/dns.o" $SUPPORT_OBJ -o "$WORK/dns.elf"

# 5. Boot under QEMU with virtio-net user networking + pcap. The guest's DNS A-query to
#    10.0.2.3:53 hits slirp's built-in forwarder, which relays it to our local responder
#    via the host resolver; the gateway 10.0.2.2 TCP:PORT_H reaches the host HTTP server
#    on the loopback as usual (the slirp gateway proxies to host services).
OUT="$(timeout 50 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev "user,id=n0" \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/dns.pcap" \
        -kernel "$WORK/dns.elf" 2>"$WORK/qemu.err" || true)"

echo "--- driver UART output ---"
printf '%s\n' "$OUT"
echo "--------------------------"
echo "--- DNS server log ---"
cat "$WORK/dns.log" 2>/dev/null || true
echo "----------------------"
echo "--- python HTTP access log ---"
cat "$WORK/httpd.log" 2>/dev/null || true
echo "------------------------------"

# 6. PASS requires all five independent proofs.
UART_OK=0; TOKEN_OK=0; IP_OK=0; DNSLOG_OK=0; HTTPLOG_OK=0; PCAP_OK=0
ACCESS_LINE=""; DNS_LINE=""; PCAP_BYTES=0

printf '%s' "$OUT" | grep -q "$EXPECT" && UART_OK=1
printf '%s' "$OUT" | grep -q "$TOKEN" && TOKEN_OK=1
# The resolved IP must be 10.0.2.2 == 0x0A000202.
printf '%s' "$OUT" | grep -q "RESOLVED-IP=0x000000000a000202" && IP_OK=1

if DNS_LINE="$(grep -E "QUERY name=$HOSTNAME type=1" "$WORK/dns.log" 2>/dev/null | head -1)"; then
    [ -n "$DNS_LINE" ] && DNSLOG_OK=1
fi
if ACCESS_LINE="$(grep -E '"GET / HTTP/1\.[01]" 200' "$WORK/httpd.log" 2>/dev/null | head -1)"; then
    [ -n "$ACCESS_LINE" ] && HTTPLOG_OK=1
fi
if [ -s "$WORK/dns.pcap" ]; then
    PCAP_BYTES="$(wc -c <"$WORK/dns.pcap" | tr -d ' ')"
    PCAP_OK=1
fi

if [ "$UART_OK" = 1 ] && [ "$TOKEN_OK" = 1 ] && [ "$IP_OK" = 1 ] \
   && [ "$DNSLOG_OK" = 1 ] && [ "$HTTPLOG_OK" = 1 ] && [ "$PCAP_OK" = 1 ]; then
    echo "PASS: $TEST_NAME — $BACKEND backend: real DNS A-query resolved '$HOSTNAME' -> $RESOLVE_TO and HTTP GET that host under QEMU."
    echo "  UART:    $EXPECT printed and body token '$TOKEN' received over UART"
    echo "  resolved: $HOSTNAME -> 10.0.2.2 (RESOLVED-IP=0x0a000202)"
    echo "  dns log: $DNS_LINE"
    echo "  access:  $ACCESS_LINE"
    echo "  pcap:    $PCAP_BYTES bytes of real frames captured at $WORK/dns.pcap"
    exit 0
fi

echo "FAIL: $TEST_NAME — not all proofs present:"
echo "  UART DNS-HTTP-OK: $UART_OK   body token: $TOKEN_OK   resolved-IP==10.0.2.2: $IP_OK"
echo "  DNS-query logged: $DNSLOG_OK   access-log GET 200: $HTTPLOG_OK   pcap non-empty: $PCAP_OK ($PCAP_BYTES bytes)"
exit 1
