#include <stdint.h>
extern void     ra_init(uint32_t irs);
extern uint32_t ra_accept(uint32_t seq, uint32_t len);
extern uint32_t ra_rcv_nxt(void);
extern uint32_t ra_buffered(void);
extern void     rtx_init(uint32_t iss, uint32_t wnd);
extern void     rtx_send(uint32_t len);
extern uint32_t rtx_ack(uint32_t ack);
extern uint32_t rtx_reset(void);
extern uint32_t rtx_snd_nxt(void);
extern uint32_t rtx_snd_una(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    // Reassembly: in-order, then two future segments, then the gap-filler coalesces.
    ra_init(1000);
    CHECK(ra_accept(1000, 100) == 100 && ra_rcv_nxt() == 1100 && ra_buffered() == 0);
    CHECK(ra_accept(1200, 100) == 0   && ra_buffered() == 1 && ra_rcv_nxt() == 1100);
    CHECK(ra_accept(1300, 50)  == 0   && ra_buffered() == 2);
    // 1100..1200 fills the gap: delivers 100 + coalesces the buffered 100 + 50.
    CHECK(ra_accept(1100, 100) == 250 && ra_rcv_nxt() == 1350 && ra_buffered() == 0);
    CHECK(ra_accept(1000, 100) == 0   && ra_rcv_nxt() == 1350); // old data dropped

    // Go-back-N retransmit.
    rtx_init(5000, 8000);
    rtx_send(1000);
    rtx_send(500);
    CHECK(rtx_snd_nxt() == 6500 && rtx_snd_una() == 5000);
    CHECK(rtx_ack(5500) == 500 && rtx_snd_una() == 5500); // first 1000 acked? no — 500
    // Timeout: rewind snd_nxt to snd_una and resend the remaining unacked bytes.
    CHECK(rtx_reset() == 1000 && rtx_snd_nxt() == 5500);   // 6500-5500 unacked
    rtx_send(1000);
    CHECK(rtx_snd_nxt() == 6500);                          // retransmitted
    return 0;
}
