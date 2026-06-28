// examples/apps/wasm/wasi_agent.c — Phase-6 basic syscall-driven agent, the WASM mirror of
// examples/agents/agent.js (qjs-agent-test). The minimal agent loop: submit a brokered tool op over
// the frozen SYS_SUBMIT/SYS_POLL ABI, then drive it to completion by polling for its id and reading
// the result. SUM(arg) completes with arg+2. Prints "agent: ok" only on the correct round-trip —
// the foundational "an agent reaches the broker and demultiplexes a completion by id" proof.
#include <stdio.h>
#include <stdint.h>

#define TOOL_OP_SUM 1u

__attribute__((import_module("mc"), import_name("tool_submit")))
extern int64_t tool_submit(int op, int arg, int flags);
__attribute__((import_module("mc"), import_name("tool_poll")))
extern int tool_poll(void *out);

int main(void) {
    int64_t id = tool_submit(TOOL_OP_SUM, 40, 0);
    if (id < 0) { printf("agent: FAIL submit %lld\n", (long long)id); return 1; }

    int32_t status = -1, result = -1;
    unsigned char ev[16];
    for (int spin = 0; spin < 100000; spin++) {
        if (tool_poll(ev) == 1 && (int64_t)(*(uint64_t *)ev) == id) {
            status = *(int32_t *)(ev + 8);
            result = *(int32_t *)(ev + 12);
            break;
        }
    }
    if (status != 0 || result != 42) { printf("agent: FAIL status=%d result=%d\n", status, result); return 1; }

    printf("agent: ok\n");
    return 0;
}
