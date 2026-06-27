// examples/apps/wasm/wasi_cancel.c — Phase-5 cancellation, the WASM mirror of
// examples/agents/agent_cancel.js. A fast op (delay 0) resolves; a slow op (delay 8) is cancelled
// before it completes via TOOL_OP_CANCEL(arg=its id) and completes with -E_CANCELED instead.
#include <stdio.h>
#include <stdint.h>

#define TOOL_OP_SUM    1u
#define TOOL_OP_CANCEL 3u
#define E_CANCELED     (-125)

__attribute__((import_module("mc"), import_name("tool_submit")))
extern int64_t tool_submit(int op, int arg, int flags);
__attribute__((import_module("mc"), import_name("tool_poll")))
extern int tool_poll(void *out);

int main(void) {
    int64_t win   = tool_submit(TOOL_OP_SUM, 7, 0);  // ready now -> result 9
    int64_t loser = tool_submit(TOOL_OP_SUM, 9, 8);  // delay 8 -> not ready yet
    if (win < 0 || loser < 0) { printf("cancel: FAIL submit win=%lld loser=%lld\n", (long long)win, (long long)loser); return 1; }
    int64_t crc = tool_submit(TOOL_OP_CANCEL, (int)loser, 0); // cancel the slow one -> ready now, -E_CANCELED

    int win_ok = 0, loser_cancelled = 0;
    unsigned char ev[16];
    for (int spin = 0; spin < 100000 && (!win_ok || !loser_cancelled); spin++) {
        if (tool_poll(ev) == 1) {
            int64_t id   = (int64_t)(*(uint64_t *)ev);
            int32_t st   = *(int32_t *)(ev + 8);
            int32_t res  = *(int32_t *)(ev + 12);
            if (id == win && st == 0 && res == 9) win_ok = 1;
            if (id == loser && st == E_CANCELED) loser_cancelled = 1;
        }
    }
    printf("cancel-agent: winner=%d loser_cancelled=%d crc=%d\n", win_ok, loser_cancelled, (int)crc);
    if (win_ok && loser_cancelled) printf("cancel: ok\n");
    else printf("cancel: FAIL\n");
    return 0;
}
