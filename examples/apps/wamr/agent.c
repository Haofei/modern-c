// examples/apps/wamr/agent.c — a brokered async AGENT guest for WAMR, freestanding wasm32 (no
// wasi-libc, so MVP features WAMR loads cleanly). It uses the mc tool ABI directly — tool_submit /
// tool_poll over the kernel's SYS_SUBMIT/SYS_POLL broker, plus a print import — exactly the surface
// the MC agents need. Submits an async SUM(5) op and drives it to completion by id (result = arg+2 =
// 7), then prints "agent: ok". Proves WAMR runs a real confined broker agent, not just compute.
__attribute__((import_module("mc"), import_name("tool_submit")))
extern long long tool_submit(int op, int arg, int flags);
__attribute__((import_module("mc"), import_name("tool_poll")))
extern int tool_poll(void *out);
__attribute__((import_module("mc"), import_name("print")))
extern void mc_print(const void *p, int len);

#define TOOL_OP_SUM 1

__attribute__((export_name("agent_main"))) int agent_main(void) {
    long long id = tool_submit(TOOL_OP_SUM, 5, 0);
    if (id < 0) { mc_print("agent: FAIL submit\n", 19); return 1; }
    unsigned char ev[16];
    for (int spin = 0; spin < 100000; spin++) {
        if (tool_poll(ev) == 1) {
            long long eid = *(long long *)(ev + 0);
            int st = *(int *)(ev + 8);
            int rs = *(int *)(ev + 12);
            if (eid == id) {
                if (st == 0 && rs == 7) mc_print("agent: ok\n", 10);
                else mc_print("agent: FAIL result\n", 19);
                return 0;
            }
        }
    }
    mc_print("agent: FAIL timeout\n", 20);
    return 1;
}
