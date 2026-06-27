// examples/apps/wasm/wasi_smoke.c — Phase-6 canonical agent smoke, the WASM mirror of
// examples/agents/agent_smoke.js / qjs-agent-smoke-test. ONE guest walks the whole agent path in a
// single confined run: an async SUM tool call resolves (result = arg+2), a real capability-checked
// FS write+read round-trips through the broker, and an async TIMEOUT op is CANCELLED (completing
// -E_CANCELED). Prints "smoke: ok" only if every stage is correct.
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

#define TOOL_OP_SUM     1u
#define TOOL_OP_TIMEOUT 4u
#define TOOL_OP_CANCEL  3u
#define E_CANCELED      (-125)

__attribute__((import_module("mc"), import_name("tool_submit")))
extern int64_t tool_submit(int op, int arg, int flags);
__attribute__((import_module("mc"), import_name("tool_poll")))
extern int tool_poll(void *out);

static int drain_for(int64_t id, int32_t *status, int32_t *result) {
    unsigned char ev[16];
    for (int spin = 0; spin < 200000; spin++) {
        if (tool_poll(ev) == 1 && (int64_t)(*(uint64_t *)ev) == id) {
            *status = *(int32_t *)(ev + 8);
            *result = *(int32_t *)(ev + 12);
            return 1;
        }
    }
    return 0;
}

int main(void) {
    int32_t st = 0, rs = 0;

    // (1) async SUM tool call -> result 7
    int64_t s = tool_submit(TOOL_OP_SUM, 5, 0);
    if (s < 0 || !drain_for(s, &st, &rs) || st != 0 || rs != 7) { printf("smoke: FAIL sum st=%d rs=%d\n", st, rs); return 1; }

    // (2) capability-checked FS write+read round-trip under /ws
    int fd = open("/ws/smoke.txt", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0 || write(fd, "hi", 2) != 2) { printf("smoke: FAIL fs-write\n"); return 1; }
    close(fd);
    fd = open("/ws/smoke.txt", O_RDONLY);
    char buf[8]; memset(buf, 0, sizeof buf);
    ssize_t n = (fd >= 0) ? read(fd, buf, sizeof buf) : -1;
    if (fd >= 0) close(fd);
    if (!(n == 2 && buf[0] == 'h' && buf[1] == 'i')) { printf("smoke: FAIL fs-read n=%d\n", (int)n); return 1; }

    // (3) async TIMEOUT op cancelled before it fires -> -E_CANCELED
    int64_t t = tool_submit(TOOL_OP_TIMEOUT, 0, 8);
    if (t < 0) { printf("smoke: FAIL timeout-submit\n"); return 1; }
    tool_submit(TOOL_OP_CANCEL, (int)t, 0);
    if (!drain_for(t, &st, &rs) || st != E_CANCELED) { printf("smoke: FAIL cancel st=%d\n", st); return 1; }

    printf("smoke: ok\n");
    return 0;
}
