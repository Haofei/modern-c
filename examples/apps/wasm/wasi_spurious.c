// examples/apps/wasm/wasi_spurious.c — Phase-5 spurious-completion handling, the WASM mirror of
// examples/agents/agent_spurious.js. The TEST-ONLY spurious op returns a real id at submit but its
// completion carries a BOGUS id; the agent must detect the unknown completion id (never silently
// accept it). Here the guest detects the mismatch and reports it.
#include <stdio.h>
#include <stdint.h>

#define TOOL_OP_SPURIOUS 5u

__attribute__((import_module("mc"), import_name("tool_submit")))
extern int64_t tool_submit(int op, int arg, int flags);
__attribute__((import_module("mc"), import_name("tool_poll")))
extern int tool_poll(void *out);

int main(void) {
    int64_t id = tool_submit(TOOL_OP_SPURIOUS, 0, 0);
    if (id < 0) { printf("spurious: FAIL submit rc=%lld\n", (long long)id); return 1; }
    int detected = 0;
    unsigned char ev[16];
    for (int spin = 0; spin < 100000 && !detected; spin++) {
        if (tool_poll(ev) == 1) {
            int64_t cid = (int64_t)(*(uint64_t *)ev);
            if (cid != id) detected = 1;  // unknown completion id — the host never registered it
        }
    }
    printf("spurious-agent: detected_unknown=%d (real id=%lld)\n", detected, (long long)id);
    if (detected) printf("spurious: ok\n");
    else printf("spurious: FAIL\n");
    return 0;
}
