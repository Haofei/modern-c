// examples/apps/wamr_wasi_host.c — confined WAMR host for STOCK wasm32-wasi guests: the WAMR analogue
// of wasm_host.c + wasi_shim.c's WASI Preview-1 surface. Registers the minimal WASI imports a wasi
// command needs (fd_write -> SYS_WRITE, the startup stubs, proc_exit) as WAMR native symbols, then
// runs the guest's _start. Proves WAMR runs real WASI agents confined. (FS/net/tool brokered imports
// come next — this is the hello/stdout slice.) WAMR converts app offsets via addr_app_to_native.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "wasm_export.h"
#include "wasm_blob.h"

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);

#define WASI_ESUCCESS 0
#define WASI_EBADF    8
#define WASI_ESPIPE   29
#define WASI_ENOSYS   52

static int g_exit_code = 0;

// --- WASI Preview 1 native imports (module "wasi_snapshot_preview1") ---

static uint32_t w_fd_write(wasm_exec_env_t e, uint32_t fd, uint32_t iovs_off, uint32_t iovs_len, uint32_t nwritten_off) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (!wasm_runtime_validate_app_addr(m, iovs_off, (uint64_t)iovs_len * 8)) return WASI_EBADF;
    uint32_t *iovs = (uint32_t *)wasm_runtime_addr_app_to_native(m, iovs_off);
    uint32_t total = 0;
    for (uint32_t i = 0; i < iovs_len; i++) {
        uint32_t buf_off = iovs[i * 2 + 0];
        uint32_t len     = iovs[i * 2 + 1];
        if (!len) continue;
        if (!wasm_runtime_validate_app_addr(m, buf_off, len)) return WASI_EBADF;
        void *buf = wasm_runtime_addr_app_to_native(m, buf_off);
        sys_write(fd, buf, len);   // fd 1/2 -> kernel console via the syscall ABI
        total += len;
    }
    if (nwritten_off && wasm_runtime_validate_app_addr(m, nwritten_off, 4))
        *(uint32_t *)wasm_runtime_addr_app_to_native(m, nwritten_off) = total;
    return WASI_ESUCCESS;
}

static uint32_t w_zero2(wasm_exec_env_t e, uint32_t a_off, uint32_t b_off) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (a_off && wasm_runtime_validate_app_addr(m, a_off, 4)) *(uint32_t *)wasm_runtime_addr_app_to_native(m, a_off) = 0;
    if (b_off && wasm_runtime_validate_app_addr(m, b_off, 4)) *(uint32_t *)wasm_runtime_addr_app_to_native(m, b_off) = 0;
    return WASI_ESUCCESS;   // environ_sizes_get / args_sizes_get -> 0 entries, 0 bytes
}
static uint32_t w_okay2(wasm_exec_env_t e, uint32_t a, uint32_t b) { (void)e; (void)a; (void)b; return WASI_ESUCCESS; } // environ_get / args_get
static uint32_t w_fd_fdstat_get(wasm_exec_env_t e, uint32_t fd, uint32_t buf_off) {
    (void)fd;
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (buf_off && wasm_runtime_validate_app_addr(m, buf_off, 24)) {
        uint8_t *p = (uint8_t *)wasm_runtime_addr_app_to_native(m, buf_off);
        memset(p, 0, 24);
        p[0] = 2;   // fs_filetype = character_device (a tty-like stdio)
    }
    return WASI_ESUCCESS;
}
static uint32_t w_fd_close(wasm_exec_env_t e, uint32_t fd) { (void)e; (void)fd; return WASI_ESUCCESS; }
static uint32_t w_fd_seek(wasm_exec_env_t e, uint32_t fd, uint64_t off, uint32_t whence, uint32_t np) {
    (void)e; (void)fd; (void)off; (void)whence; (void)np; return WASI_ESPIPE;   // stdio is not seekable
}
static uint32_t w_fd_prestat_get(wasm_exec_env_t e, uint32_t fd, uint32_t buf) { (void)e; (void)fd; (void)buf; return WASI_EBADF; } // no preopens
static uint32_t w_fd_prestat_dir_name(wasm_exec_env_t e, uint32_t fd, uint32_t p, uint32_t l) { (void)e; (void)fd; (void)p; (void)l; return WASI_EBADF; }
static uint32_t w_clock_time_get(wasm_exec_env_t e, uint32_t id, uint64_t prec, uint32_t out_off) {
    (void)id; (void)prec;
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (out_off && wasm_runtime_validate_app_addr(m, out_off, 8)) *(uint64_t *)wasm_runtime_addr_app_to_native(m, out_off) = 0;
    return WASI_ESUCCESS;
}
static uint32_t w_random_get(wasm_exec_env_t e, uint32_t buf_off, uint32_t len) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (buf_off && wasm_runtime_validate_app_addr(m, buf_off, len))
        memset(wasm_runtime_addr_app_to_native(m, buf_off), 0, len);  // deterministic test stub
    return WASI_ESUCCESS;
}
static void w_proc_exit(wasm_exec_env_t e, uint32_t code) {
    g_exit_code = (int)code;
    wasm_runtime_set_exception(wasm_runtime_get_module_inst(e), "wasi proc exit");
}

static NativeSymbol g_wasi[] = {
    { "fd_write",            w_fd_write,            "(iiii)i", NULL },
    { "environ_sizes_get",   w_zero2,               "(ii)i",   NULL },
    { "environ_get",         w_okay2,               "(ii)i",   NULL },
    { "args_sizes_get",      w_zero2,               "(ii)i",   NULL },
    { "args_get",            w_okay2,               "(ii)i",   NULL },
    { "fd_fdstat_get",       w_fd_fdstat_get,       "(ii)i",   NULL },
    { "fd_close",            w_fd_close,            "(i)i",    NULL },
    { "fd_seek",             w_fd_seek,             "(iIii)i", NULL },
    { "fd_prestat_get",      w_fd_prestat_get,      "(ii)i",   NULL },
    { "fd_prestat_dir_name", w_fd_prestat_dir_name, "(iii)i",  NULL },
    { "clock_time_get",      w_clock_time_get,      "(iIi)i",  NULL },
    { "random_get",          w_random_get,          "(ii)i",   NULL },
    { "proc_exit",           w_proc_exit,           "(i)",     NULL },
};

static unsigned char g_wbuf[1u << 20];

int main(void) {
    RuntimeInitArgs ia; memset(&ia, 0, sizeof ia);
    ia.mem_alloc_type = Alloc_With_System_Allocator;
    ia.native_module_name = "wasi_snapshot_preview1";
    ia.native_symbols = g_wasi;
    ia.n_native_symbols = sizeof(g_wasi) / sizeof(g_wasi[0]);
    if (!wasm_runtime_full_init(&ia)) { printf("WAMR-WASI: init fail\n"); return 1; }

    if (wasm_blob_len > sizeof g_wbuf) { printf("WAMR-WASI: module too big\n"); return 1; }
    memcpy(g_wbuf, wasm_blob, wasm_blob_len);
    char err[192];
    wasm_module_t module = wasm_runtime_load(g_wbuf, wasm_blob_len, err, sizeof err);
    if (!module) { printf("WAMR-WASI: load fail: %s\n", err); return 1; }
    wasm_module_inst_t inst = wasm_runtime_instantiate(module, 65536, 262144, err, sizeof err);
    if (!inst) { printf("WAMR-WASI: instantiate fail: %s\n", err); return 1; }
    wasm_exec_env_t env = wasm_runtime_create_exec_env(inst, 65536);
    wasm_function_inst_t start = wasm_runtime_lookup_function(inst, "_start");
    if (!start) { printf("WAMR-WASI: no _start\n"); return 1; }
    if (!wasm_runtime_call_wasm(env, start, 0, NULL)) {
        const char *ex = wasm_runtime_get_exception(inst);
        if (!(ex && strstr(ex, "wasi proc exit"))) { printf("WAMR-WASI: trap: %s\n", ex ? ex : "?"); return 1; }
    }
    return 0;   // the guest's fd_write output is the gate marker
}
