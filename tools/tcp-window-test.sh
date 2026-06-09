#!/usr/bin/env bash
# TCP window/data-plane test: track the send window (space, in-flight), process ACKs
# (advance, reject duplicate + unsent-data acks), accept in-order receive (reject
# out-of-order), and handle 32-bit sequence wraparound.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: tcp-window-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/net/tcp_window_demo.mc" -o "$WORK/win.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern void     tw_init(uint32_t iss, uint32_t irs, uint32_t wnd);
extern uint32_t tw_send_space(void);
extern void     tw_on_send(uint32_t len);
extern uint32_t tw_on_ack(uint32_t ack);
extern void     tw_update_wnd(uint32_t wnd);
extern uint32_t tw_on_recv(uint32_t seq, uint32_t len);
extern uint32_t tw_snd_una(void);
extern uint32_t tw_snd_nxt(void);
extern uint32_t tw_rcv_nxt(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    tw_init(1000, 5000, 4000);
    CHECK(tw_send_space() == 4000);

    tw_on_send(1500); CHECK(tw_snd_nxt() == 2500 && tw_send_space() == 2500);
    tw_on_send(2500); CHECK(tw_snd_nxt() == 5000 && tw_send_space() == 0); // window full

    CHECK(tw_on_ack(2500) == 1500);                 // acks the first 1500
    CHECK(tw_snd_una() == 2500 && tw_send_space() == 1500);
    CHECK(tw_on_ack(2500) == 0);                    // duplicate ack
    CHECK(tw_on_ack(9999) == 0 && tw_snd_una() == 2500); // acks unsent data -> rejected

    CHECK(tw_on_recv(5000, 100) == 100 && tw_rcv_nxt() == 5100);
    CHECK(tw_on_recv(5000, 100) == 0);              // out of order / retransmit -> dropped
    CHECK(tw_on_recv(5100, 50) == 50 && tw_rcv_nxt() == 5150);

    tw_update_wnd(8000);
    CHECK(tw_send_space() == 8000 - 2500);          // window grew; 2500 still in flight

    // 32-bit sequence wraparound.
    tw_init(0xFFFFFF00u, 0, 1000);
    tw_on_send(0x200);
    CHECK(tw_snd_nxt() == 0x100u);                  // wrapped past 2^32
    CHECK(tw_on_ack(0x100u) == 0x200u);             // 512 bytes acked across the wrap
    CHECK(tw_snd_una() == 0x100u);
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/win.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: tcp-window-test — TCP send window + ACK processing (dup/unsent rejected) + in-order receive + sequence wraparound"; exit 0; fi
echo "FAIL: tcp-window-test — driver returned non-zero (failing CHECK line)"; exit 1
