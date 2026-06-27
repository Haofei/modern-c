// examples/apps/wasm/wasi_quota.c — Phase-5 structured back-pressure errno, the WASM mirror of
// examples/agents/agent_quota.js. Fills the 8-deep in-flight queue, then asserts the next submit
// returns exactly -E_AGAIN (-11) — the tool-ABI back-pressure errno, surfaced to the agent.
#include <stdio.h>
#include <stdint.h>

#define TOOL_OP_SUM 1u
#define E_AGAIN     (-11)

__attribute__((import_module("mc"), import_name("tool_submit")))
extern int64_t tool_submit(int op, int arg, int flags);

int main(void) {
    for (int i = 0; i < 8; i++) tool_submit(TOOL_OP_SUM, i, 8); // delay 8: keep all 8 in flight
    int64_t r = tool_submit(TOOL_OP_SUM, 99, 8);                // 9th: queue full -> -E_AGAIN
    printf("quota-agent: rc=%lld\n", (long long)r);
    if (r == E_AGAIN) printf("quota: ok\n");
    else printf("quota: FAIL rc=%lld\n", (long long)r);
    return 0;
}
