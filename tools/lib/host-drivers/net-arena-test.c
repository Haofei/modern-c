#include <stdint.h>
extern uint32_t net_arena_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(net_arena_run() == 0x102); // 2 packets demuxed on arena scratch + stale handle caught
    return 0;
}
