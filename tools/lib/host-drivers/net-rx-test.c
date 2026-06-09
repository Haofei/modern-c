#include <stdint.h>
extern uintptr_t build_frame(uint32_t s, uint32_t d, uint16_t sp, uint16_t dp);
extern void      sk_init(void);
extern uint32_t  sk_bind(uintptr_t idx, uint16_t port);
extern uint32_t  rx_deliver(uintptr_t len);
extern uint64_t  sk_recv(uintptr_t idx, uintptr_t dst, uintptr_t max);
extern uint32_t  sk_last_port(uintptr_t idx);
#define ERR ((uint64_t)-1)
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    sk_init();
    CHECK(sk_bind(0, 53) == 1);

    // A UDP frame from 10.0.2.2:4321 to us:53 arrives at the NIC.
    uintptr_t len = build_frame(0x0A000202u, 0x0A00020Fu, 4321, 53);
    CHECK(rx_deliver(len) == 1);

    char buf[8];
    for (int i = 0; i < 8; i++) buf[i] = 0;
    CHECK(sk_recv(0, (uintptr_t)buf, 8) == 3);            // "RX!" reached the socket
    CHECK(buf[0] == 'R' && buf[1] == 'X' && buf[2] == '!');
    CHECK(sk_last_port(0) == 4321);                       // sender port recorded

    // A frame to an unbound port is dropped (no listener).
    uintptr_t len2 = build_frame(0x0A000202u, 0x0A00020Fu, 4321, 9999);
    CHECK(rx_deliver(len2) == 0);
    return 0;
}
