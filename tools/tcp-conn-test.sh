#!/usr/bin/env bash
# TCP state-machine test: drive a connection through passive open (3-way handshake),
# active close (4-way), and an active open, checking states + emitted actions.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: tcp-conn-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/net/tcp_conn_demo.mc" -o "$WORK/conn.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern void     c_init(uint32_t iss);
extern void     c_listen(void);
extern uint32_t c_connect(void);
extern uint32_t c_segment(uint16_t flags, uint32_t seq);
extern uint32_t c_close(void);
extern uint32_t c_state(void);
// flags
#define FIN 0x01
#define SYN 0x02
#define ACK 0x10
// states
enum { CLOSED, LISTEN, SYN_SENT, SYN_RCVD, ESTAB, FINW1, FINW2, CLOSEW, LASTACK, TIMEW };
// actions
enum { A_NONE, A_SYN, A_SYNACK, A_ACK, A_FIN };
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    // Passive open: LISTEN -> recv SYN -> SYN_RCVD (send SYN+ACK) -> recv ACK -> ESTAB.
    c_init(100);
    c_listen();
    CHECK(c_state() == LISTEN);
    CHECK(c_segment(SYN, 500) == A_SYNACK);
    CHECK(c_state() == SYN_RCVD);
    CHECK(c_segment(ACK, 501) == A_NONE);
    CHECK(c_state() == ESTAB);
    // Peer closes first: recv FIN -> CLOSE_WAIT (send ACK); we close -> LAST_ACK
    // (send FIN); recv ACK -> CLOSED.
    CHECK(c_segment(FIN, 501) == A_ACK);
    CHECK(c_state() == CLOSEW);
    CHECK(c_close() == A_FIN);
    CHECK(c_state() == LASTACK);
    CHECK(c_segment(ACK, 502) == A_NONE);
    CHECK(c_state() == CLOSED);

    // Active open: connect (send SYN) -> recv SYN+ACK (send ACK) -> ESTAB.
    c_init(200);
    CHECK(c_connect() == A_SYN);
    CHECK(c_state() == SYN_SENT);
    CHECK(c_segment(SYN | ACK, 900) == A_ACK);
    CHECK(c_state() == ESTAB);
    // We close first: FIN_WAIT1 (send FIN) -> recv ACK -> FIN_WAIT2 -> recv FIN ->
    // TIME_WAIT (send ACK).
    CHECK(c_close() == A_FIN);
    CHECK(c_state() == FINW1);
    CHECK(c_segment(ACK, 901) == A_NONE);
    CHECK(c_state() == FINW2);
    CHECK(c_segment(FIN, 901) == A_ACK);
    CHECK(c_state() == TIMEW);
    return 0;
}
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/conn.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: tcp-conn-test — TCP state machine: passive + active open handshakes and both close paths transition correctly"; exit 0; fi
echo "FAIL: tcp-conn-test — driver returned non-zero (failing CHECK line)"; exit 1
