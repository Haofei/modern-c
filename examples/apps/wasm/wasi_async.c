// examples/apps/wasm/wasi_async.c — Phase-5 async overlap + back-pressure, the WASM mirror of
// examples/agents/agent_async.js. Submits 12 overlapping TOOL_OP_SUM ops past the kernel's 8-deep
// in-flight queue: the first 8 are accepted and complete (result = arg+2), the last 4 are denied
// with -E_AGAIN at submit. Drains completions by id via mc.tool_poll. Expect ok=8, rejected=4.
#include <stdio.h>
#include <stdint.h>

#define TOOL_OP_SUM 1u

__attribute__((import_module("mc"), import_name("tool_submit")))
extern int64_t tool_submit(int op, int arg, int flags);
__attribute__((import_module("mc"), import_name("tool_poll")))
extern int tool_poll(void *out);

int main(void) {
    int rejected = 0, submitted = 0;
    for (int i = 0; i < 12; i++) {
        int64_t r = tool_submit(TOOL_OP_SUM, 100 + i, 0); // delay 0: all 8 queued are ready at once
        if (r < 0) rejected++; else submitted++;
    }
    int ok = 0;
    unsigned char ev[16];
    for (int spin = 0; spin < 100000 && ok < submitted; spin++) {
        if (tool_poll(ev) == 1) {
            int32_t status = *(int32_t *)(ev + 8);
            if (status == 0) ok++;
        }
    }
    printf("async-agent: backpressure ok=%d rejected=%d\n", ok, rejected);
    if (ok == 8 && rejected == 4) printf("async: ok\n");
    else printf("async: FAIL ok=%d rejected=%d\n", ok, rejected);
    return 0;
}
