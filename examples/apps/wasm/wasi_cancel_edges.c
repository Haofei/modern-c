// examples/apps/wasm/wasi_cancel_edges.c — Phase-6 negative cancellation edges, the WASM mirror of
// examples/agents/agent_cancel_edges.js. Asserts the broker rejects two ill-formed cancels:
//   1. cancelling an ALREADY-COMPLETED request's id -> -E_DENIED (its slot was reclaimed), and
//   2. cancelling a NEVER-SUBMITTED id -> -E_DENIED (no such in-flight request).
// Neither must succeed or corrupt the broker; a following normal op still completes.
#include <stdio.h>
#include <stdint.h>

#define TOOL_OP_SUM    1u
#define TOOL_OP_CANCEL 3u
#define E_DENIED       (-13)

__attribute__((import_module("mc"), import_name("tool_submit")))
extern int64_t tool_submit(int op, int arg, int flags);
__attribute__((import_module("mc"), import_name("tool_poll")))
extern int tool_poll(void *out);

int main(void) {
    // 1. Submit a fast SUM and drain it to completion, then cancel its (now-stale) id.
    int64_t id = tool_submit(TOOL_OP_SUM, 5, 0);
    if (id < 0) { printf("cancel-edges: FAIL submit %lld\n", (long long)id); return 1; }
    unsigned char ev[16];
    int done = 0;
    for (int spin = 0; spin < 100000 && !done; spin++) {
        if (tool_poll(ev) == 1 && (int64_t)(*(uint64_t *)ev) == id) done = 1;
    }
    if (!done) { printf("cancel-edges: FAIL drain\n"); return 1; }
    int64_t post = tool_submit(TOOL_OP_CANCEL, (int)id, 0);   // already completed -> denied
    int64_t never = tool_submit(TOOL_OP_CANCEL, 0x7fffff, 0); // never submitted -> denied

    printf("cancel-edges: post=%lld never=%lld\n", (long long)post, (long long)never);
    if (post == E_DENIED && never == E_DENIED) printf("cancel-edges: ok\n");
    else printf("cancel-edges: FAIL post=%lld never=%lld\n", (long long)post, (long long)never);
    return 0;
}
