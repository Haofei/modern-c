#include <stdint.h>
extern void     sk_init(void);
extern uint32_t sk_bind(uintptr_t idx, uint16_t port);
extern uint32_t sk_deliver(uint16_t dport, uint32_t sip, uint16_t sport, uintptr_t addr, uintptr_t len);
extern uint64_t sk_recv(uintptr_t idx, uintptr_t addr, uintptr_t max);
extern uint32_t sk_last_ip(uintptr_t idx);
extern uint32_t sk_last_port(uintptr_t idx);
#define ERR ((uint64_t)-1)
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    sk_init();
    CHECK(sk_bind(0, 53) == 1);
    CHECK(sk_bind(1, 80) == 1);
    CHECK(sk_bind(2, 53) == 0); // port 53 already bound

    // Deliver to each bound port + one with no listener.
    CHECK(sk_deliver(53, 0x0A000202, 1000, (uintptr_t)"DNS", 3) == 1);
    CHECK(sk_deliver(80, 0x0A000203, 2000, (uintptr_t)"GET", 3) == 1);
    CHECK(sk_deliver(9999, 0x0A000204, 3000, (uintptr_t)"X", 1) == 0); // no listener

    char buf[16];
    for (int i = 0; i < 16; i++) buf[i] = 0;
    // socket 0 (port 53) gets "DNS" from 10.0.2.2:1000
    CHECK(sk_recv(0, (uintptr_t)buf, 16) == 3);
    CHECK(buf[0] == 'D' && buf[1] == 'N' && buf[2] == 'S');
    CHECK(sk_last_ip(0) == 0x0A000202 && sk_last_port(0) == 1000);
    // socket 1 (port 80) gets "GET" from 10.0.2.3:2000 — demuxed correctly
    for (int i = 0; i < 16; i++) buf[i] = 0;
    CHECK(sk_recv(1, (uintptr_t)buf, 16) == 3);
    CHECK(buf[0] == 'G' && buf[1] == 'E' && buf[2] == 'T');
    CHECK(sk_last_port(1) == 2000);
    // socket 0's queue is now empty
    CHECK(sk_recv(0, (uintptr_t)buf, 16) == ERR);
    return 0;
}
