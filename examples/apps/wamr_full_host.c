// examples/apps/wamr_full_host.c — confined WAMR host for the real broker AGENTS: the WAMR analogue
// of wasi_shim.c. Registers the full WASI Preview-1 surface (stdout + startup stubs + a "/ws" preopen
// filesystem brokered through TOOL_OP_FS_*) AND the mc tool ABI (net_fetch + tool_submit/tool_poll)
// as WAMR native symbols, then runs a stock wasm32-wasi guest's _start. Effects route through the SAME
// six-syscall ABI + capability broker as the old wasm3 shim; the engine is the only thing swapped. The FS
// model mirrors the shim: whole-file (FS_WRITE buffers + flushes on close, FS_READ caches), one "/ws"
// preopen (fd 3). Guest offsets are converted via wasm_runtime_addr_app_to_native (bounds-validated).
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include "wasm_export.h"
#include "wasm_blob.h"
#include "tool_abi.h"
#include "wasi.h"   // WASI_E*, FILETYPE/RIGHTS/WHENCE/PREOPENTYPE, wasi_errno_from_kernel

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern long sys_read(void *buf, unsigned long max);
extern long sys_submit(unsigned long req_ptr);
extern long sys_poll(unsigned long events_ptr, unsigned long max, unsigned long timeout);

// ---- guest-memory access (offset -> validated native pointer) ----
static void *app_ptr(wasm_exec_env_t e, uint32_t off, uint64_t len) {
    wasm_module_inst_t m = wasm_runtime_get_module_inst(e);
    if (!off || !wasm_runtime_validate_app_addr(m, off, len)) return 0;
    return wasm_runtime_addr_app_to_native(m, off);
}

// ---- the filesystem fd table (mirrors wasi_shim.c) ----
#define WASM_FD_MAX   16
#define WASM_PATH_MAX 128
#define WASM_PREOPEN_FD 3
static const char WASM_PREOPEN_NAME[] = "/ws";
typedef struct {
    int used, is_preopen, can_read, can_write;
    unsigned char path[WASM_PATH_MAX]; uint32_t path_len;
    int read_loaded; unsigned char rbuf[TOOL_MAX_RES_BYTES]; uint32_t rlen, rpos;
    unsigned char wbuf[TOOL_MAX_RES_BYTES]; uint32_t wlen; int dirty;
} wasm_fd_t;
static wasm_fd_t g_fds[WASM_FD_MAX];

static void fds_init(void) {
    wasm_fd_t *pre = &g_fds[WASM_PREOPEN_FD];
    pre->used = 1; pre->is_preopen = 1;
    uint32_t i = 0; for (; WASM_PREOPEN_NAME[i] && i < WASM_PATH_MAX; i++) pre->path[i] = (unsigned char)WASM_PREOPEN_NAME[i];
    pre->path_len = i;
}
static int fd_is_file(uint32_t fd) { return fd < WASM_FD_MAX && g_fds[fd].used && !g_fds[fd].is_preopen; }
static int fd_is_preopen(uint32_t fd) { return fd < WASM_FD_MAX && g_fds[fd].used && g_fds[fd].is_preopen; }
static uint32_t join_path(unsigned char *dst, const wasm_fd_t *base, const char *rel, uint32_t rel_len) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < base->path_len && n < WASM_PATH_MAX; i++) dst[n++] = base->path[i];
    if (n < WASM_PATH_MAX) dst[n++] = '/';
    for (uint32_t i = 0; i < rel_len && n < WASM_PATH_MAX; i++) dst[n++] = (unsigned char)rel[i];
    return n;
}

// ---- synchronous bridge over the async Tool ABI ----
static long submit_and_wait(ToolReq *req, uint32_t *out_len) {
    long id = sys_submit((unsigned long)(uintptr_t)req);
    if (id < 0) return id;
    ToolEvent ev[4];
    for (int spin = 0; spin < 1024; spin++) {
        long c = sys_poll((unsigned long)(uintptr_t)ev, 4, 0);
        if (c < 0) return c;
        for (long i = 0; i < c; i++)
            if (ev[i].id == (uint64_t)id) { if (out_len) *out_len = ev[i].out_len; return ev[i].status < 0 ? ev[i].status : ev[i].result; }
    }
    return -110; // E_TIMEDOUT
}
// A capability-checked FS op: stage [path][data] in a HOST buffer, submit, wait.
static long tool_call(uint32_t op, const unsigned char *path, uint32_t plen,
                      const unsigned char *data, uint32_t dlen,
                      unsigned char *out, uint32_t out_cap, uint32_t *out_len) {
    static unsigned char payload[TOOL_MAX_REQ_BYTES];
    if ((uint64_t)plen + (uint64_t)dlen > sizeof payload) return -105; // E_NOCAP
    for (uint32_t i = 0; i < plen; i++) payload[i] = path[i];
    for (uint32_t i = 0; i < dlen; i++) payload[plen + i] = data[i];
    ToolReq req; memset(&req, 0, sizeof req);
    req.op = op; req.arg = plen;
    req.in_ptr = (uint64_t)(uintptr_t)payload; req.in_len = plen + dlen;
    if (out_cap) { req.out_cap = out_cap; req.out_ptr = (uint64_t)(uintptr_t)out; }
    return submit_and_wait(&req, out_len);
}

// ================= WASI Preview 1 =================
static uint32_t w_fd_write(wasm_exec_env_t e, uint32_t fd, uint32_t iovs_off, uint32_t iovs_len, uint32_t nwritten_off) {
    uint32_t *iovs = app_ptr(e, iovs_off, (uint64_t)iovs_len * 8);
    if (!iovs) return WASI_EBADF;
    int file = fd_is_file(fd); wasm_fd_t *f = file ? &g_fds[fd] : 0;
    if (file && !f->can_write) return WASI_EACCES;
    uint32_t total = 0;
    for (uint32_t i = 0; i < iovs_len; i++) {
        uint32_t bo = iovs[i*2], ln = iovs[i*2+1];
        if (!ln) continue;
        unsigned char *p = app_ptr(e, bo, ln);
        if (!p) return WASI_EBADF;
        if (file) {
            if (f->wlen + ln > sizeof f->wbuf) return WASI_ENOBUFS;
            for (uint32_t k = 0; k < ln; k++) f->wbuf[f->wlen + k] = p[k];
            f->wlen += ln; f->dirty = 1;
        } else sys_write(fd, p, ln);
        total += ln;
    }
    uint32_t *nw = app_ptr(e, nwritten_off, 4); if (nw) *nw = total;
    return WASI_ESUCCESS;
}
static uint32_t w_fd_read(wasm_exec_env_t e, uint32_t fd, uint32_t iovs_off, uint32_t iovs_len, uint32_t nread_off) {
    uint32_t *iovs = app_ptr(e, iovs_off, (uint64_t)iovs_len * 8);
    if (!iovs) return WASI_EBADF;
    int file = fd_is_file(fd); wasm_fd_t *f = file ? &g_fds[fd] : 0;
    if (file) {
        if (!f->can_read) return WASI_EACCES;
        if (!f->read_loaded) {
            uint32_t olen = 0;
            long r = tool_call(TOOL_OP_FS_READ, f->path, f->path_len, 0, 0, f->rbuf, sizeof f->rbuf, &olen);
            if (r < 0) return wasi_errno_from_kernel(r);
            f->rlen = olen; f->rpos = 0; f->read_loaded = 1;
        }
    }
    uint32_t total = 0;
    for (uint32_t i = 0; i < iovs_len; i++) {
        uint32_t bo = iovs[i*2], ln = iovs[i*2+1];
        if (!ln) continue;
        unsigned char *p = app_ptr(e, bo, ln);
        if (!p) return WASI_EBADF;
        if (file) {
            uint32_t avail = f->rlen - f->rpos, take = ln < avail ? ln : avail;
            for (uint32_t k = 0; k < take; k++) p[k] = f->rbuf[f->rpos + k];
            f->rpos += take; total += take;
            if (take < ln) break;
        } else {
            long n = sys_read(p, ln);
            if (n < 0) return wasi_errno_from_kernel(n);
            total += (uint32_t)n; if ((uint32_t)n < ln) break;
        }
    }
    uint32_t *nr = app_ptr(e, nread_off, 4); if (nr) *nr = total;
    return WASI_ESUCCESS;
}
static uint32_t w_fd_close(wasm_exec_env_t e, uint32_t fd) {
    (void)e;
    if (fd_is_file(fd)) {
        wasm_fd_t *f = &g_fds[fd]; uint32_t res = WASI_ESUCCESS;
        if (f->dirty) { long r = tool_call(TOOL_OP_FS_WRITE, f->path, f->path_len, f->wbuf, f->wlen, 0, 0, 0); if (r < 0) res = wasi_errno_from_kernel(r); }
        f->used = 0; f->dirty = 0; f->wlen = 0; f->read_loaded = 0; f->rlen = 0; f->rpos = 0;
        return res;
    }
    return WASI_ESUCCESS;
}
static uint32_t w_fd_seek(wasm_exec_env_t e, uint32_t fd, uint64_t offset, uint32_t whence, uint32_t newoff_off) {
    if (fd_is_file(fd)) {
        wasm_fd_t *f = &g_fds[fd];
        int64_t base = (whence == WASI_WHENCE_CUR) ? (int64_t)f->rpos : (whence == WASI_WHENCE_END) ? (int64_t)f->rlen : 0;
        int64_t no = base + (int64_t)offset; if (no < 0) no = 0;
        f->rpos = (uint32_t)no;
        uint64_t *p = app_ptr(e, newoff_off, 8); if (p) *p = f->rpos;
        return WASI_ESUCCESS;
    }
    return WASI_ESPIPE;
}
static uint32_t w_fd_fdstat_get(wasm_exec_env_t e, uint32_t fd, uint32_t off) {
    uint8_t *p = app_ptr(e, off, 24); if (!p) return WASI_EBADF;
    uint8_t ft;
    if (fd_is_preopen(fd)) ft = WASI_FILETYPE_DIRECTORY;
    else if (fd_is_file(fd)) ft = WASI_FILETYPE_REGULAR_FILE;
    else if (fd <= 2) ft = WASI_FILETYPE_CHARACTER_DEVICE;
    else return WASI_EBADF;
    memset(p, 0, 24); p[0] = ft;
    *(uint64_t *)(p + 8) = (uint64_t)-1; *(uint64_t *)(p + 16) = (uint64_t)-1; // rights_base / inheriting
    return WASI_ESUCCESS;
}
static uint32_t w_fd_prestat_get(wasm_exec_env_t e, uint32_t fd, uint32_t off) {
    if (!fd_is_preopen(fd)) return WASI_EBADF;
    uint8_t *p = app_ptr(e, off, 8); if (!p) return WASI_EBADF;
    p[0] = WASI_PREOPENTYPE_DIR; p[1] = p[2] = p[3] = 0;
    *(uint32_t *)(p + 4) = g_fds[fd].path_len;
    return WASI_ESUCCESS;
}
static uint32_t w_fd_prestat_dir_name(wasm_exec_env_t e, uint32_t fd, uint32_t path_off, uint32_t path_len) {
    if (!fd_is_preopen(fd)) return WASI_EBADF;
    wasm_fd_t *f = &g_fds[fd];
    uint32_t n = path_len < f->path_len ? path_len : f->path_len;
    uint8_t *p = app_ptr(e, path_off, n); if (!p) return WASI_EBADF;
    for (uint32_t i = 0; i < n; i++) p[i] = f->path[i];
    return WASI_ESUCCESS;
}
static uint32_t w_path_open(wasm_exec_env_t e, uint32_t dirfd, uint32_t dirflags, uint32_t path_off, uint32_t path_len,
                            uint32_t oflags, uint64_t rights_base, uint64_t rights_inh, uint32_t fdflags, uint32_t opened_off) {
    (void)dirflags; (void)oflags; (void)rights_inh; (void)fdflags;
    const char *path = app_ptr(e, path_off, path_len); if (!path) return WASI_EBADF;
    if (!fd_is_preopen(dirfd)) return WASI_EBADF;
    int slot = -1; for (int i = WASM_PREOPEN_FD + 1; i < WASM_FD_MAX; i++) if (!g_fds[i].used) { slot = i; break; }
    if (slot < 0) return WASI_EMFILE;
    wasm_fd_t *f = &g_fds[slot]; memset(f, 0, sizeof *f);
    f->used = 1;
    f->can_read = (rights_base & WASI_RIGHTS_FD_READ) != 0;
    f->can_write = (rights_base & WASI_RIGHTS_FD_WRITE) != 0;
    if (!f->can_read && !f->can_write) f->can_read = 1;
    f->path_len = join_path(f->path, &g_fds[dirfd], path, path_len);
    uint32_t *op = app_ptr(e, opened_off, 4); if (!op) return WASI_EBADF;
    *op = (uint32_t)slot;
    return WASI_ESUCCESS;
}
static uint32_t w_path_create_directory(wasm_exec_env_t e, uint32_t dirfd, uint32_t path_off, uint32_t path_len) {
    const char *path = app_ptr(e, path_off, path_len); if (!path) return WASI_EBADF;
    if (!fd_is_preopen(dirfd)) return WASI_EBADF;
    unsigned char full[WASM_PATH_MAX];
    uint32_t n = join_path(full, &g_fds[dirfd], path, path_len);
    long r = tool_call(TOOL_OP_FS_MKDIR, full, n, 0, 0, 0, 0, 0);
    return r < 0 ? wasi_errno_from_kernel(r) : WASI_ESUCCESS;
}
static uint32_t w_zero2(wasm_exec_env_t e, uint32_t a, uint32_t b) {
    uint32_t *pa = app_ptr(e, a, 4), *pb = app_ptr(e, b, 4); if (pa) *pa = 0; if (pb) *pb = 0; return WASI_ESUCCESS;
}
static uint32_t w_ok2(wasm_exec_env_t e, uint32_t a, uint32_t b) { (void)e;(void)a;(void)b; return WASI_ESUCCESS; }
static uint32_t w_clock(wasm_exec_env_t e, uint32_t id, uint64_t pr, uint32_t off) {
    (void)id;(void)pr; uint64_t *p = app_ptr(e, off, 8); if (p) *p = 0; return WASI_ESUCCESS;
}
static uint32_t w_random(wasm_exec_env_t e, uint32_t off, uint32_t len) {
    unsigned char *p = app_ptr(e, off, len); if (p) memset(p, 0, len); return WASI_ESUCCESS;
}
static void w_proc_exit(wasm_exec_env_t e, uint32_t code) { (void)code; wasm_runtime_set_exception(wasm_runtime_get_module_inst(e), "wasi proc exit"); }

// ================= mc tool ABI (brokered effects) =================
static int32_t mc_net_fetch(wasm_exec_env_t e, uint32_t endpoint, uint32_t token) {
    (void)e; ToolReq req; memset(&req, 0, sizeof req);
    req.op = TOOL_OP_NET_FETCH; req.arg = endpoint; req.flags = token;
    return (int32_t)submit_and_wait(&req, 0);
}
static int64_t mc_tool_submit(wasm_exec_env_t e, uint32_t op, uint32_t arg, uint32_t flags) {
    (void)e; ToolReq req; memset(&req, 0, sizeof req);
    req.op = op; req.arg = arg; req.flags = flags;
    return (int64_t)sys_submit((unsigned long)(uintptr_t)&req);
}
static int32_t mc_tool_poll(wasm_exec_env_t e, uint32_t out_off) {
    ToolEvent ev; long n = sys_poll((unsigned long)(uintptr_t)&ev, 1, 1);
    if (n <= 0) return (int32_t)n;
    uint8_t *o = app_ptr(e, out_off, 16); if (!o) return -14;
    *(uint64_t *)(o+0) = ev.id; *(int32_t *)(o+8) = ev.status; *(int32_t *)(o+12) = ev.result;
    return 1;
}

static NativeSymbol g_wasi[] = {
    { "fd_write", w_fd_write, "(iiii)i", NULL }, { "fd_read", w_fd_read, "(iiii)i", NULL },
    { "fd_close", w_fd_close, "(i)i", NULL }, { "fd_seek", w_fd_seek, "(iIii)i", NULL },
    { "fd_fdstat_get", w_fd_fdstat_get, "(ii)i", NULL },
    { "fd_prestat_get", w_fd_prestat_get, "(ii)i", NULL }, { "fd_prestat_dir_name", w_fd_prestat_dir_name, "(iii)i", NULL },
    { "path_open", w_path_open, "(iiiiiIIii)i", NULL }, { "path_create_directory", w_path_create_directory, "(iii)i", NULL },
    { "environ_sizes_get", w_zero2, "(ii)i", NULL }, { "environ_get", w_ok2, "(ii)i", NULL },
    { "args_sizes_get", w_zero2, "(ii)i", NULL }, { "args_get", w_ok2, "(ii)i", NULL },
    { "clock_time_get", w_clock, "(iIi)i", NULL }, { "random_get", w_random, "(ii)i", NULL },
    { "proc_exit", w_proc_exit, "(i)", NULL },
};
static NativeSymbol g_mc[] = {
    { "net_fetch", mc_net_fetch, "(ii)i", NULL },
    { "tool_submit", mc_tool_submit, "(iii)I", NULL },
    { "tool_poll", mc_tool_poll, "(i)i", NULL },
};

int main(void) {
    fds_init();
    RuntimeInitArgs ia; memset(&ia, 0, sizeof ia);
    ia.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&ia)) { printf("WAMR-FULL: init fail\n"); return 1; }
    wasm_runtime_register_natives("wasi_snapshot_preview1", g_wasi, sizeof(g_wasi)/sizeof(g_wasi[0]));
    wasm_runtime_register_natives("mc", g_mc, sizeof(g_mc)/sizeof(g_mc[0]));
    // WAMR edits the module buffer in place -> a WRITABLE copy. malloc from the libc arena (not a
    // static BSS buffer) so the big QuickJS guest fits the confined region.
    unsigned char *wbuf = malloc(wasm_blob_len);
    if (!wbuf) { printf("WAMR-FULL: oom\n"); return 1; }
    memcpy(wbuf, wasm_blob, wasm_blob_len);
    char err[192];
    wasm_module_t module = wasm_runtime_load(wbuf, wasm_blob_len, err, sizeof err);
    if (!module) { printf("WAMR-FULL: load fail: %s\n", err); return 1; }
    // Large WAMR operand stack: QuickJS's wasm call chains are deep (the JS eval recursion).
    wasm_module_inst_t inst = wasm_runtime_instantiate(module, 1048576, 262144, err, sizeof err);
    if (!inst) { printf("WAMR-FULL: instantiate fail: %s\n", err); return 1; }
    wasm_exec_env_t env = wasm_runtime_create_exec_env(inst, 1048576);
    wasm_function_inst_t start = wasm_runtime_lookup_function(inst, "_start");
    if (!start) { printf("WAMR-FULL: no _start\n"); return 1; }
    if (!wasm_runtime_call_wasm(env, start, 0, NULL)) {
        const char *ex = wasm_runtime_get_exception(inst);
        if (!(ex && strstr(ex, "wasi proc exit"))) { printf("WAMR-FULL: trap: %s\n", ex ? ex : "?"); return 1; }
    }
    return 0;
}
