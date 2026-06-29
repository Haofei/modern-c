// examples/apps/wamr_full_host.c — confined WAMR host for the real broker AGENTS: registers BOTH the
// WASI Preview-1 stdout/startup surface (module "wasi_snapshot_preview1") AND the mc tool ABI (module
// "mc": net_fetch + tool_submit/tool_poll), then runs a stock wasm32-wasi guest's _start. This is the
// WAMR analogue of wasi_shim.c's combined WASI+mc surface for the async/net agents (printf via WASI +
// brokered effects via mc). FS broker imports come next; this covers the printf+mc.* agents.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "wasm_export.h"
#include "wasm_blob.h"
#include "tool_abi.h"

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern long sys_submit(unsigned long req_ptr);
extern long sys_poll(unsigned long events_ptr, unsigned long max, unsigned long timeout);

#define WASI_ESUCCESS 0
#define WASI_EBADF    8
#define WASI_ESPIPE   29

// ---- WASI P1 (stdout + startup stubs + proc_exit) ----
static uint32_t w_fd_write(wasm_exec_env_t e, uint32_t fd, uint32_t iovs_off, uint32_t iovs_len, uint32_t nwritten_off) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (!wasm_runtime_validate_app_addr(m, iovs_off, (uint64_t)iovs_len * 8)) return WASI_EBADF;
    uint32_t *iovs = (uint32_t *)wasm_runtime_addr_app_to_native(m, iovs_off);
    uint32_t total = 0;
    for (uint32_t i = 0; i < iovs_len; i++) {
        uint32_t bo = iovs[i*2], ln = iovs[i*2+1];
        if (!ln) continue;
        if (!wasm_runtime_validate_app_addr(m, bo, ln)) return WASI_EBADF;
        sys_write(fd, wasm_runtime_addr_app_to_native(m, bo), ln);
        total += ln;
    }
    if (nwritten_off && wasm_runtime_validate_app_addr(m, nwritten_off, 4))
        *(uint32_t *)wasm_runtime_addr_app_to_native(m, nwritten_off) = total;
    return WASI_ESUCCESS;
}
static uint32_t w_zero2(wasm_exec_env_t e, uint32_t a, uint32_t b) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (a && wasm_runtime_validate_app_addr(m, a, 4)) *(uint32_t *)wasm_runtime_addr_app_to_native(m, a) = 0;
    if (b && wasm_runtime_validate_app_addr(m, b, 4)) *(uint32_t *)wasm_runtime_addr_app_to_native(m, b) = 0;
    return WASI_ESUCCESS;
}
static uint32_t w_ok2(wasm_exec_env_t e, uint32_t a, uint32_t b) { (void)e;(void)a;(void)b; return WASI_ESUCCESS; }
static uint32_t w_fdstat(wasm_exec_env_t e, uint32_t fd, uint32_t off) {
    (void)fd; wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (off && wasm_runtime_validate_app_addr(m, off, 24)) { uint8_t *p = wasm_runtime_addr_app_to_native(m, off); memset(p,0,24); p[0]=2; }
    return WASI_ESUCCESS;
}
static uint32_t w_fd_close(wasm_exec_env_t e, uint32_t fd) { (void)e;(void)fd; return WASI_ESUCCESS; }
static uint32_t w_fd_seek(wasm_exec_env_t e, uint32_t fd, uint64_t o, uint32_t wh, uint32_t np) { (void)e;(void)fd;(void)o;(void)wh;(void)np; return WASI_ESPIPE; }
static uint32_t w_prestat_get(wasm_exec_env_t e, uint32_t fd, uint32_t b) { (void)e;(void)fd;(void)b; return WASI_EBADF; }
static uint32_t w_prestat_dir(wasm_exec_env_t e, uint32_t fd, uint32_t p, uint32_t l) { (void)e;(void)fd;(void)p;(void)l; return WASI_EBADF; }
static uint32_t w_clock(wasm_exec_env_t e, uint32_t id, uint64_t pr, uint32_t off) {
    (void)id;(void)pr; wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (off && wasm_runtime_validate_app_addr(m, off, 8)) *(uint64_t *)wasm_runtime_addr_app_to_native(m, off) = 0;
    return WASI_ESUCCESS;
}
static uint32_t w_random(wasm_exec_env_t e, uint32_t off, uint32_t len) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (off && wasm_runtime_validate_app_addr(m, off, len)) memset(wasm_runtime_addr_app_to_native(m, off), 0, len);
    return WASI_ESUCCESS;
}
static void w_proc_exit(wasm_exec_env_t e, uint32_t code) { (void)code; wasm_runtime_set_exception(wasm_runtime_get_module_inst(e), "wasi proc exit"); }

// ---- mc tool ABI (brokered effects) ----
static int32_t mc_net_fetch(wasm_exec_env_t e, uint32_t endpoint, uint32_t token) {
    (void)e;
    ToolReq req; memset(&req, 0, sizeof req);
    req.op = TOOL_OP_NET_FETCH; req.arg = endpoint; req.flags = token;
    long id = sys_submit((unsigned long)(uintptr_t)&req);
    if (id < 0) return (int32_t)id;
    ToolEvent ev;
    for (int spin = 0; spin < 100000; spin++) {
        long n = sys_poll((unsigned long)(uintptr_t)&ev, 1, 1);
        if (n < 0) return (int32_t)n;
        if (n == 1 && ev.id == (uint64_t)id) return ev.status == 0 ? ev.result : ev.status;
    }
    return -11; // E_AGAIN (timeout)
}
static int64_t mc_tool_submit(wasm_exec_env_t e, uint32_t op, uint32_t arg, uint32_t flags) {
    (void)e; ToolReq req; memset(&req, 0, sizeof req);
    req.op = op; req.arg = arg; req.flags = flags;
    return (int64_t)sys_submit((unsigned long)(uintptr_t)&req);
}
static int32_t mc_tool_poll(wasm_exec_env_t e, uint32_t out_off) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    ToolEvent ev; long n = sys_poll((unsigned long)(uintptr_t)&ev, 1, 1);
    if (n <= 0) return (int32_t)n;
    if (!wasm_runtime_validate_app_addr(m, out_off, 16)) return -14;
    uint8_t *o = wasm_runtime_addr_app_to_native(m, out_off);
    *(uint64_t *)(o+0) = ev.id; *(int32_t *)(o+8) = ev.status; *(int32_t *)(o+12) = ev.result;
    return 1;
}

static NativeSymbol g_wasi[] = {
    { "fd_write", w_fd_write, "(iiii)i", NULL }, { "environ_sizes_get", w_zero2, "(ii)i", NULL },
    { "environ_get", w_ok2, "(ii)i", NULL }, { "args_sizes_get", w_zero2, "(ii)i", NULL },
    { "args_get", w_ok2, "(ii)i", NULL }, { "fd_fdstat_get", w_fdstat, "(ii)i", NULL },
    { "fd_close", w_fd_close, "(i)i", NULL }, { "fd_seek", w_fd_seek, "(iIii)i", NULL },
    { "fd_prestat_get", w_prestat_get, "(ii)i", NULL }, { "fd_prestat_dir_name", w_prestat_dir, "(iii)i", NULL },
    { "clock_time_get", w_clock, "(iIi)i", NULL }, { "random_get", w_random, "(ii)i", NULL },
    { "proc_exit", w_proc_exit, "(i)", NULL },
};
static NativeSymbol g_mc[] = {
    { "net_fetch", mc_net_fetch, "(ii)i", NULL },
    { "tool_submit", mc_tool_submit, "(iii)I", NULL },
    { "tool_poll", mc_tool_poll, "(i)i", NULL },
};

static unsigned char g_wbuf[1u << 20];

int main(void) {
    RuntimeInitArgs ia; memset(&ia, 0, sizeof ia);
    ia.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&ia)) { printf("WAMR-FULL: init fail\n"); return 1; }
    wasm_runtime_register_natives("wasi_snapshot_preview1", g_wasi, sizeof(g_wasi)/sizeof(g_wasi[0]));
    wasm_runtime_register_natives("mc", g_mc, sizeof(g_mc)/sizeof(g_mc[0]));
    if (wasm_blob_len > sizeof g_wbuf) { printf("WAMR-FULL: module too big\n"); return 1; }
    memcpy(g_wbuf, wasm_blob, wasm_blob_len);
    char err[192];
    wasm_module_t module = wasm_runtime_load(g_wbuf, wasm_blob_len, err, sizeof err);
    if (!module) { printf("WAMR-FULL: load fail: %s\n", err); return 1; }
    wasm_module_inst_t inst = wasm_runtime_instantiate(module, 65536, 262144, err, sizeof err);
    if (!inst) { printf("WAMR-FULL: instantiate fail: %s\n", err); return 1; }
    wasm_exec_env_t env = wasm_runtime_create_exec_env(inst, 65536);
    wasm_function_inst_t start = wasm_runtime_lookup_function(inst, "_start");
    if (!start) { printf("WAMR-FULL: no _start\n"); return 1; }
    if (!wasm_runtime_call_wasm(env, start, 0, NULL)) {
        const char *ex = wasm_runtime_get_exception(inst);
        if (!(ex && strstr(ex, "wasi proc exit"))) { printf("WAMR-FULL: trap: %s\n", ex ? ex : "?"); return 1; }
    }
    return 0;
}
