// examples/apps/wasm/wasi_broker.c — Phase-6 out-of-order broker completion, the WASM mirror of
// examples/agents/agent_broker.js. Submits a SLOW async SUM (delay 5 ticks) FIRST, then a FAST one
// (delay 1) SECOND; the mock broker reads tool_submit's `flags` as a completion delay, so the fast
// request completes BEFORE the slow one despite being submitted later. Recording completion order by
// id yields "FS" (fast-then-slow) — proving the broker delivers completions out of submit order and
// the agent demultiplexes them by id over the SYS_SUBMIT/SYS_POLL ABI.
#include <stdio.h>
#include <stdint.h>

#define TOOL_OP_SUM 1u

__attribute__((import_module("mc"), import_name("tool_submit")))
extern int64_t tool_submit(int op, int arg, int flags); // flags = mock-broker completion delay (ticks)
__attribute__((import_module("mc"), import_name("tool_poll")))
extern int tool_poll(void *out);

int main(void) {
    printf("broker-agent: start\n");
    int64_t slow = tool_submit(TOOL_OP_SUM, 10, 5); // submitted first, delay 5
    int64_t fast = tool_submit(TOOL_OP_SUM, 20, 1); // submitted second, delay 1 -> completes first
    if (slow < 0 || fast < 0) { printf("broker-agent: FAIL submit slow=%lld fast=%lld\n", (long long)slow, (long long)fast); return 1; }

    char order[4];
    int n = 0;
    unsigned char ev[16];
    for (int spin = 0; spin < 200000 && n < 2; spin++) {
        if (tool_poll(ev) == 1) {
            uint64_t id = *(uint64_t *)ev;
            if (id == (uint64_t)slow) order[n++] = 'S';
            else if (id == (uint64_t)fast) order[n++] = 'F';
        }
    }
    order[n] = 0;
    printf("broker-agent: order=%s\n", order);
    printf("broker-agent: done\n");
    return 0;
}
