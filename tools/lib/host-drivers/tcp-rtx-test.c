#include <stdint.h>
extern void     t_init(uint64_t rto, uint32_t iss, uint32_t wnd);
extern void     t_send(uint32_t len, uint64_t now);
extern uint32_t t_tick(uint64_t now);
extern uint32_t t_ack(uint32_t ack);
extern uint32_t t_snd_nxt(void);
extern uint32_t t_armed(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    t_init(100, 1000, 8000);
    t_send(500, 0);                  // snd_nxt=1500, timer armed (deadline 100)
    CHECK(t_snd_nxt() == 1500 && t_armed() == 1);

    CHECK(t_tick(50) == 0);          // before RTO: nothing
    CHECK(t_snd_nxt() == 1500);

    CHECK(t_tick(100) == 500);       // RTO elapsed: go-back-N resends the 500 unacked
    CHECK(t_snd_nxt() == 1000);      // snd_nxt rewound to snd_una
    CHECK(t_armed() == 1);           // re-armed (deadline 200)

    t_send(500, 100);                // retransmit the data
    CHECK(t_snd_nxt() == 1500);

    CHECK(t_ack(1500) == 500);       // everything acked
    CHECK(t_armed() == 0);           // timer disarmed
    CHECK(t_tick(1000) == 0);        // disarmed: no spurious retransmit
    return 0;
}
