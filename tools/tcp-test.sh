#!/usr/bin/env bash
# TCP test: build a TCP segment, parse its fields, validate the checksum (over the
# IPv4 pseudo-header), and confirm corruption is detected.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: tcp-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/tcp_demo.mc" -o "$WORK/tcp.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern void     tcp_build(uintptr_t buf, uintptr_t buflen, uintptr_t off, uint32_t s, uint32_t d, uint16_t sp, uint16_t dp, uint32_t seq, uint32_t ack, uint16_t flags, uint16_t win, uintptr_t plen);
extern uint32_t tcp_get_sport(uintptr_t b, uintptr_t l, uintptr_t o);
extern uint32_t tcp_get_dport(uintptr_t b, uintptr_t l, uintptr_t o);
extern uint64_t tcp_get_seq(uintptr_t b, uintptr_t l, uintptr_t o);
extern uint64_t tcp_get_ack(uintptr_t b, uintptr_t l, uintptr_t o);
extern uint32_t tcp_get_flags(uintptr_t b, uintptr_t l, uintptr_t o);
extern uint32_t tcp_get_window(uintptr_t b, uintptr_t l, uintptr_t o);
extern uint32_t tcp_valid(uintptr_t b, uintptr_t l, uintptr_t o, uint32_t s, uint32_t d, uint16_t seg);
#define SYN 0x02
#define ACK 0x10
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    uint8_t pkt[40]; for (int i=0;i<40;i++) pkt[i]=0;
    uint32_t s=0x0A00020F, d=0x0A000202;
    tcp_build((uintptr_t)pkt, 40, 0, s, d, 1234, 80, 1000, 2000, SYN|ACK, 8192, 0); // 20-byte header, no payload
    CHECK(tcp_get_sport((uintptr_t)pkt,40,0) == 1234);
    CHECK(tcp_get_dport((uintptr_t)pkt,40,0) == 80);
    CHECK(tcp_get_seq((uintptr_t)pkt,40,0) == 1000);
    CHECK(tcp_get_ack((uintptr_t)pkt,40,0) == 2000);
    CHECK((tcp_get_flags((uintptr_t)pkt,40,0) & SYN) != 0);
    CHECK((tcp_get_flags((uintptr_t)pkt,40,0) & ACK) != 0);
    CHECK(tcp_get_window((uintptr_t)pkt,40,0) == 8192);
    CHECK(tcp_valid((uintptr_t)pkt,40,0,s,d,20) == 1);
    pkt[4] ^= 0xFF; // corrupt the seq field
    CHECK(tcp_valid((uintptr_t)pkt,40,0,s,d,20) == 0);
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/tcp.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: tcp-test — TCP segment build/parse (ports/seq/ack/flags/window) + pseudo-header checksum + corruption detection"; exit 0; fi
echo "FAIL: tcp-test — driver returned non-zero (failing CHECK line)"; exit 1
