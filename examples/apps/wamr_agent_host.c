// examples/apps/wamr_agent_host.c — confined WAMR host for brokered AGENT guests. Registers the mc
// tool ABI (tool_submit/tool_poll over SYS_SUBMIT/SYS_POLL + a print->SYS_WRITE) as WAMR native
// symbols, then runs the guest's exported agent_main(). The WAMR analogue of wasi_shim's host tool
// path — proving WAMR drives the real kernel broker from a confined agent. Engine is WAMR; the
// kernel/broker/ABI are unchanged (this is a U-mode payload swap, exactly like wasm3).
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "wasm_export.h"
#include "wasm_blob.h"
#include "tool_abi.h"   // ToolReq / ToolEvent (mirrors user/abi.mc)

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern long sys_submit(unsigned long req_ptr);
extern long sys_poll(unsigned long events_ptr, unsigned long max, unsigned long timeout);

static int64_t mc_tool_submit(wasm_exec_env_t e, uint32_t op, uint32_t arg, uint32_t flags) {
    (void)e;
    ToolReq req;
    memset(&req, 0, sizeof req);
    req.op = op; req.arg = arg; req.flags = flags;
    return (int64_t)sys_submit((unsigned long)(uintptr_t)&req);
}
static int32_t mc_tool_poll(wasm_exec_env_t e, uint32_t out_off) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    ToolEvent ev;
    long n = sys_poll((unsigned long)(uintptr_t)&ev, 1, 1);
    if (n <= 0) return (int32_t)n;
    if (!wasm_runtime_validate_app_addr(m, out_off, 16)) return -14; // E_FAULT
    uint8_t *o = (uint8_t *)wasm_runtime_addr_app_to_native(m, out_off);
    *(uint64_t *)(o + 0) = ev.id;
    *(int32_t  *)(o + 8) = ev.status;
    *(int32_t  *)(o + 12) = ev.result;
    return 1;
}
static void mc_print(wasm_exec_env_t e, uint32_t ptr_off, uint32_t len) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (wasm_runtime_validate_app_addr(m, ptr_off, len))
        sys_write(1, wasm_runtime_addr_app_to_native(m, ptr_off), len);
}

static NativeSymbol g_mc[] = {
    { "tool_submit", mc_tool_submit, "(iii)I", NULL },
    { "tool_poll",   mc_tool_poll,   "(i)i",   NULL },
    { "print",       mc_print,       "(ii)",   NULL },
};

static unsigned char g_wbuf[262144];

int main(void) {
    RuntimeInitArgs ia; memset(&ia, 0, sizeof ia);
    ia.mem_alloc_type = Alloc_With_System_Allocator;
    ia.native_module_name = "mc";
    ia.native_symbols = g_mc;
    ia.n_native_symbols = sizeof(g_mc) / sizeof(g_mc[0]);
    if (!wasm_runtime_full_init(&ia)) { printf("WAMR-AGENT: init fail\n"); return 1; }
    if (wasm_blob_len > sizeof g_wbuf) { printf("WAMR-AGENT: module too big\n"); return 1; }
    memcpy(g_wbuf, wasm_blob, wasm_blob_len);
    char err[192];
    wasm_module_t module = wasm_runtime_load(g_wbuf, wasm_blob_len, err, sizeof err);
    if (!module) { printf("WAMR-AGENT: load fail: %s\n", err); return 1; }
    wasm_module_inst_t inst = wasm_runtime_instantiate(module, 65536, 131072, err, sizeof err);
    if (!inst) { printf("WAMR-AGENT: instantiate fail: %s\n", err); return 1; }
    wasm_exec_env_t env = wasm_runtime_create_exec_env(inst, 65536);
    wasm_function_inst_t fn = wasm_runtime_lookup_function(inst, "agent_main");
    if (!fn) { printf("WAMR-AGENT: no agent_main\n"); return 1; }
    uint32_t argv[1] = { 0 };
    if (!wasm_runtime_call_wasm(env, fn, 0, argv)) { printf("WAMR-AGENT: trap: %s\n", wasm_runtime_get_exception(inst)); return 1; }
    return 0;
}
