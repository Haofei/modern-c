#!/usr/bin/env bash
# UDP test: compile the UDP layer (kernel/net/udp.mc via the test wrappers, with
# std/bytes + std/addr) to an object, link a C driver that builds a datagram and
# checks its fields + checksum, including detecting corruption.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: udp-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/net/udp_demo.mc" -o "$WORK/udp.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>

extern void     udp_build(uintptr_t buf, uintptr_t buflen, uintptr_t off, uint32_t src_ip, uint32_t dst_ip, uint16_t sport, uint16_t dport, uintptr_t payload_len);
extern uint32_t udp_sport(uintptr_t buf, uintptr_t buflen, uintptr_t off);
extern uint32_t udp_dport(uintptr_t buf, uintptr_t buflen, uintptr_t off);
extern uint32_t udp_len(uintptr_t buf, uintptr_t buflen, uintptr_t off);
extern uint32_t udp_valid(uintptr_t buf, uintptr_t buflen, uintptr_t off, uint32_t src_ip, uint32_t dst_ip);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    uint8_t pkt[64];
    for (int i = 0; i < 64; i++) pkt[i] = 0;

    uint32_t src = 0x0A00020F; // 10.0.2.15
    uint32_t dst = 0x0A000202; // 10.0.2.2
    const char payload[] = "hello";
    for (int i = 0; i < 5; i++) pkt[8 + i] = (uint8_t)payload[i]; // payload after the 8-byte header

    udp_build((uintptr_t)pkt, 64, 0, src, dst, 1234, 53, 5);

    CHECK(udp_sport((uintptr_t)pkt, 64, 0) == 1234);
    CHECK(udp_dport((uintptr_t)pkt, 64, 0) == 53);
    CHECK(udp_len((uintptr_t)pkt, 64, 0) == 13);        // 8 header + 5 payload
    CHECK(udp_valid((uintptr_t)pkt, 64, 0, src, dst) == 1);

    // Corrupting a payload byte must break the checksum.
    pkt[8] ^= 0xFF;
    CHECK(udp_valid((uintptr_t)pkt, 64, 0, src, dst) == 0);

    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/udp.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: udp-test — UDP datagram build/parse + pseudo-header checksum (incl. corruption detection) correct"
    exit 0
fi
echo "FAIL: udp-test — driver returned non-zero (failing CHECK line)"
exit 1
