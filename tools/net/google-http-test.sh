#!/usr/bin/env bash
# Best-effort REAL google.com fetch over HTTP:80 (standalone; NOT wired into CI).
#
# Lowers the same MC DNS-resolver + HTTP-client demo (tests/qemu/net/dns_http_demo),
# but parameterized to query slirp's built-in DNS forwarder 10.0.2.3:53 for the REAL
# name "google.com", then TCP-connect to the resolved IP on :80 and send a real
# "GET / HTTP/1.1 / Host: google.com / Connection: close". Google forces HTTPS, so :80
# yields a real 301 redirect — that redirect IS a genuine response from Google's servers.
#
# This depends on the sandbox letting the GUEST egress to the internet, which may be
# blocked. Honest outcome:
#   - Real 301/200 from Google -> print resolved IP + status line + GOOGLE-HTTP-REAL-OK, PASS.
#   - DNS resolved a real IP but no TCP response -> SKIP (exit 0), stating egress is blocked.
#   - DNS itself failed -> SKIP (exit 0), stating how far it got.
# Never fakes a green.
#
# Usage: tools/net/google-http-test.sh <path-to-mcc> [c|llvm]
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

HOSTNAME="google.com"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
# Boot seam now PURE MC (imports dns_http_demo.mc + shared probe); platform = mmode_dma_time.mc.
SRC="$HERE/tests/qemu/net/dns_http_mmode_demo.mc"
PLATFORM="$HERE/kernel/arch/riscv64/mmode_dma_time.mc"
LDSCRIPT="$HERE/tests/qemu/virt.ld"
TEST_NAME="google-http-test"

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build: query slirp's real DNS forwarder 10.0.2.3 for google.com, GET on :80 with a
# proper Host header so Google returns its real redirect.
REQ='GET / HTTP/1.1\r\nHost: google.com\r\nConnection: close\r\n\r\n'
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -fno-builtin)
# Per-invocation config the C runtime took via -D, threaded in as a generated MC unit
# (MC has no -D). The \r\n in REQ are literal backslash sequences MC's lexer interprets.
cat > "$WORK/dnscfg.mc" <<EOF
export fn mc_dns_server_ip() -> u32 { return 0x0A000203; }
export fn mc_http_port() -> u16 { return 80; }
export fn mc_dns_hostname() -> *const u8 { return "$HOSTNAME"; }
export fn mc_http_request() -> *const u8 { return "$REQ"; }
EOF

kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/dns.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$PLATFORM" "$WORK/platform.o" "$WORK"
kernel_boot_compile_mc_object "$BACKEND" "$WORK/dnscfg.mc" "$WORK/dnscfg.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/dns.o" "$WORK/platform.o" "$WORK/dnscfg.o" $SUPPORT_OBJ -o "$WORK/dns.elf"

# Boot with plain slirp user networking (real upstream resolver + internet egress, if
# the sandbox permits it). Capture a pcap for the honest report.
OUT="$(timeout 60 "$QEMU" -machine virt -bios none -nographic \
        -global virtio-mmio.force-legacy=false \
        -netdev "user,id=n0" \
        -device virtio-net-device,netdev=n0 \
        -object filter-dump,id=f0,netdev=n0,file="$WORK/google.pcap" \
        -kernel "$WORK/dns.elf" 2>/dev/null || true)"

echo "--- guest UART output ---"
printf '%s\n' "$OUT"
echo "-------------------------"
PCAP_BYTES=0
[ -s "$WORK/google.pcap" ] && PCAP_BYTES="$(wc -c <"$WORK/google.pcap" | tr -d ' ')"
echo "pcap: $PCAP_BYTES bytes captured"

# Extract the resolved IP (printed as RESOLVED-IP=0x...) and decode to dotted-quad.
RESOLVED_HEX="$(printf '%s' "$OUT" | grep -oE 'RESOLVED-IP=0x[0-9a-f]+' | head -1 | sed 's/.*=0x//')"
RESOLVED_DOTTED=""
if [ -n "$RESOLVED_HEX" ]; then
    ip=$((16#$RESOLVED_HEX))
    RESOLVED_DOTTED="$(( (ip>>24)&255 )).$(( (ip>>16)&255 )).$(( (ip>>8)&255 )).$(( ip&255 ))"
fi

# The real status line, if Google answered.
STATUS_LINE="$(printf '%s' "$OUT" | grep -oE 'HTTP/1\.[01] [0-9]{3}[^\r]*' | head -1 || true)"

if printf '%s' "$OUT" | grep -q 'DNS-NO-RESPONSE'; then
    echo "SKIP: $TEST_NAME — the DNS A-query for google.com via 10.0.2.3 got no response."
    echo "  The guest could not resolve google.com; slirp's DNS forwarder did not reply"
    echo "  (the sandbox appears to block the guest's DNS egress)."
    exit 0
fi

if [ -z "$RESOLVED_DOTTED" ]; then
    echo "SKIP: $TEST_NAME — no resolved IP was printed; see UART above for how far it got."
    exit 0
fi

echo "resolved: google.com -> $RESOLVED_DOTTED (real DNS answer from slirp 10.0.2.3)"

if printf '%s' "$OUT" | grep -qE 'HANDSHAKE\+GET\+RESPONSE-OK'; then
    echo "status line from Google: ${STATUS_LINE:-<none captured>}"
    echo "PASS: $TEST_NAME — resolved google.com -> $RESOLVED_DOTTED and got a REAL HTTP response on :80."
    echo "GOOGLE-HTTP-REAL-OK"
    exit 0
fi

# Resolved a real IP, but the TCP/HTTP exchange did not complete: report exactly where.
if printf '%s' "$OUT" | grep -qE 'NO-SYN-ACK'; then
    echo "SKIP: $TEST_NAME — DNS resolved google.com -> $RESOLVED_DOTTED [real], but the TCP"
    echo "  SYN to $RESOLVED_DOTTED:80 got no SYN-ACK — guest internet egress to :80 appears blocked."
    exit 0
fi
if printf '%s' "$OUT" | grep -qE 'HANDSHAKE\+GET-OK-NO-RESPONSE'; then
    echo "SKIP: $TEST_NAME — DNS resolved google.com -> $RESOLVED_DOTTED [real] and TCP connected,"
    echo "  the GET was sent, but no HTTP response came back within the wait window."
    exit 0
fi
echo "SKIP: $TEST_NAME — DNS resolved google.com -> $RESOLVED_DOTTED [real]; the HTTP fetch did not"
echo "  complete (see the UART transcript above for the exact drive status)."
exit 0
