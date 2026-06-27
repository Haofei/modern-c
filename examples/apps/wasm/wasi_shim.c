// examples/apps/wasm/wasi_shim — the freestanding WASI Preview 1 shim (docs/wasm-migration-plan.md
// Phase 1). Each WASI import is an m3 raw function that reads/writes the guest's linear memory and
// routes effects through the kernel's narrow syscall ABI. This is the standard, reusable boundary
// the migration replaces qjs_host.c's bespoke JS glue with: the same shim serves any wasm32-wasi
// guest (C/Rust/Zig/Go/AssemblyScript/JS-via-Javy).
//
// Phase 1 scope: enough P1 to run a stock `wasm32-wasi` hello unmodified — console I/O, process
// exit, clocks, randomness, and empty environ/args. Filesystem preopens (Phase 2) and network
// (Phase 3) layer on top through the FS/net brokers; this file deliberately reports "no preopens"
// (fd_prestat_get -> EBADF) and routes only stdio for now.

#include "wasm3.h"
#include "wasi.h"
#include "wasi_shim.h"

#include <stdint.h>
#include <stddef.h>

// The confined platform shim (user/libc/syscall_user.mc) — the only path to the kernel.
extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern long sys_read(void *buf, unsigned long max);

// m3_info.c (the printf disassembler) is excluded from the freestanding build; provide the one
// symbol m3_FreeRuntime references. See third_party/wasm3/VENDOR.md.
void m3_PrintProfilerInfo(void) {}

const char *const wasm_wasi_proc_exit_result = "wasm3-host: guest called proc_exit";
int wasm_wasi_exit_code = 0;

// No host wall-clock yet: a monotonic counter (advances per call). Real time will route through
// the broker (TOOL_OP_TIMEOUT/SYS_POLL) in a later phase; until then this keeps clock_time_get
// monotonic, which is all wasi-libc's stdio/buffering logic requires.
static uint64_t g_clock_ns = 0;

// random_get placeholder: a deterministic xorshift, NOT cryptographic. docs/wasm-migration-plan.md
// Phase 1 calls for a TOOL_OP_RANDOM over the kernel rng once a guest needs real entropy; the
// hello path never calls random_get, so this stays a documented stub until that op lands.
static uint32_t g_rng = 0x9E3779B9u;

// --- console / process ------------------------------------------------------------------------

// fd_write(fd, *iovs, iovs_len, *nwritten) -> errno
m3ApiRawFunction(wasi_fd_write) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArgMem (const uint32_t *, iovs)
    m3ApiGetArg    (uint32_t, iovs_len)
    m3ApiGetArgMem (uint32_t *, nwritten)

    m3ApiCheckMem(iovs, (uint64_t)iovs_len * 8);
    uint32_t total = 0;
    for (uint32_t i = 0; i < iovs_len; i++) {
        uint32_t off = m3ApiReadMem32(&iovs[i * 2 + 0]);
        uint32_t len = m3ApiReadMem32(&iovs[i * 2 + 1]);
        void *p = m3ApiOffsetToPtr(off);
        m3ApiCheckMem(p, len);
        if (len) sys_write(fd, p, len);
        total += len;
    }
    if (nwritten) { m3ApiCheckMem(nwritten, 4); m3ApiWriteMem32(nwritten, total); }
    m3ApiReturn(WASI_ESUCCESS);
}

// fd_read(fd, *iovs, iovs_len, *nread) -> errno  (stdin via the §0 ingress channel: SYS_READ)
m3ApiRawFunction(wasi_fd_read) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArgMem (const uint32_t *, iovs)
    m3ApiGetArg    (uint32_t, iovs_len)
    m3ApiGetArgMem (uint32_t *, nread)
    (void)fd;

    m3ApiCheckMem(iovs, (uint64_t)iovs_len * 8);
    uint32_t total = 0;
    for (uint32_t i = 0; i < iovs_len; i++) {
        uint32_t off = m3ApiReadMem32(&iovs[i * 2 + 0]);
        uint32_t len = m3ApiReadMem32(&iovs[i * 2 + 1]);
        if (!len) continue;
        void *p = m3ApiOffsetToPtr(off);
        m3ApiCheckMem(p, len);
        long n = sys_read(p, len);
        if (n < 0) m3ApiReturn(wasi_errno_from_kernel(n));
        total += (uint32_t)n;
        if ((uint32_t)n < len) break;  // short read == no more input for now
    }
    if (nread) { m3ApiCheckMem(nread, 4); m3ApiWriteMem32(nread, total); }
    m3ApiReturn(WASI_ESUCCESS);
}

// fd_close(fd) -> errno  (stdio fds are virtual; closing is a no-op success)
m3ApiRawFunction(wasi_fd_close) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, fd)
    (void)fd;
    m3ApiReturn(WASI_ESUCCESS);
}

// fd_seek(fd, offset, whence, *newoffset) -> errno  (the console is a pipe: not seekable)
m3ApiRawFunction(wasi_fd_seek) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArg    (uint64_t, offset)
    m3ApiGetArg    (uint32_t, whence)
    m3ApiGetArgMem (uint64_t *, newoffset)
    (void)fd; (void)offset; (void)whence; (void)newoffset;
    m3ApiReturn(WASI_ESPIPE);
}

// fd_fdstat_get(fd, *stat) -> errno  (fds 0/1/2 are character devices, others regular files)
m3ApiRawFunction(wasi_fd_fdstat_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArgMem (wasi_fdstat_t *, st)
    m3ApiCheckMem(st, sizeof(wasi_fdstat_t));

    st->fs_filetype        = (fd <= 2) ? WASI_FILETYPE_CHARACTER_DEVICE : WASI_FILETYPE_REGULAR_FILE;
    st->_pad0              = 0;
    st->fs_flags           = 0;
    st->_pad1[0] = st->_pad1[1] = st->_pad1[2] = st->_pad1[3] = 0;
    st->fs_rights_base       = (uint64_t)-1;  // all rights
    st->fs_rights_inheriting = (uint64_t)-1;
    m3ApiReturn(WASI_ESUCCESS);
}

// proc_exit(code) -> noreturn
m3ApiRawFunction(wasi_proc_exit) {
    m3ApiGetArg(uint32_t, code)
    wasm_wasi_exit_code = (int)code;
    m3ApiTrap(wasm_wasi_proc_exit_result);
}

// --- clocks / randomness ----------------------------------------------------------------------

m3ApiRawFunction(wasi_clock_time_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, clk_id)
    m3ApiGetArg    (uint64_t, precision)
    m3ApiGetArgMem (uint64_t *, time)
    (void)clk_id; (void)precision;
    m3ApiCheckMem(time, 8);
    g_clock_ns += 1000000;  // advance ~1ms (ns) per query; monotonic
    m3ApiWriteMem64(time, g_clock_ns);
    m3ApiReturn(WASI_ESUCCESS);
}

m3ApiRawFunction(wasi_clock_res_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, clk_id)
    m3ApiGetArgMem (uint64_t *, res)
    (void)clk_id;
    m3ApiCheckMem(res, 8);
    m3ApiWriteMem64(res, 1);  // 1 ns
    m3ApiReturn(WASI_ESUCCESS);
}

m3ApiRawFunction(wasi_random_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArgMem (uint8_t *, buf)
    m3ApiGetArg    (uint32_t, len)
    m3ApiCheckMem(buf, len);
    for (uint32_t i = 0; i < len; i++) {
        g_rng ^= g_rng << 13; g_rng ^= g_rng >> 17; g_rng ^= g_rng << 5;
        buf[i] = (uint8_t)g_rng;
    }
    m3ApiReturn(WASI_ESUCCESS);
}

// --- environment / args (empty) ---------------------------------------------------------------

m3ApiRawFunction(wasi_environ_sizes_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArgMem (uint32_t *, count)
    m3ApiGetArgMem (uint32_t *, bufsize)
    m3ApiCheckMem(count, 4); m3ApiCheckMem(bufsize, 4);
    m3ApiWriteMem32(count, 0); m3ApiWriteMem32(bufsize, 0);
    m3ApiReturn(WASI_ESUCCESS);
}

m3ApiRawFunction(wasi_environ_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, environ_ptr)
    m3ApiGetArg(uint32_t, buf)
    (void)environ_ptr; (void)buf;
    m3ApiReturn(WASI_ESUCCESS);
}

m3ApiRawFunction(wasi_args_sizes_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArgMem (uint32_t *, argc)
    m3ApiGetArgMem (uint32_t *, bufsize)
    m3ApiCheckMem(argc, 4); m3ApiCheckMem(bufsize, 4);
    m3ApiWriteMem32(argc, 0); m3ApiWriteMem32(bufsize, 0);
    m3ApiReturn(WASI_ESUCCESS);
}

m3ApiRawFunction(wasi_args_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, argv)
    m3ApiGetArg(uint32_t, buf)
    (void)argv; (void)buf;
    m3ApiReturn(WASI_ESUCCESS);
}

// --- filesystem preopens (none yet — Phase 2) -------------------------------------------------

// fd_prestat_get(fd, *prestat) -> errno. Returning EBADF for every fd tells wasi-libc there are no
// preopened directories, ending its preopen scan. Phase 2 mints these from PathCaps.
m3ApiRawFunction(wasi_fd_prestat_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, fd)
    m3ApiGetArg(uint32_t, prestat)
    (void)fd; (void)prestat;
    m3ApiReturn(WASI_EBADF);
}

m3ApiRawFunction(wasi_fd_prestat_dir_name) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, fd)
    m3ApiGetArg(uint32_t, path)
    m3ApiGetArg(uint32_t, path_len)
    (void)fd; (void)path; (void)path_len;
    m3ApiReturn(WASI_EBADF);
}

// --- scheduling -------------------------------------------------------------------------------

m3ApiRawFunction(wasi_sched_yield) {
    m3ApiReturnType(uint32_t)
    m3ApiReturn(WASI_ESUCCESS);
}

m3ApiRawFunction(wasi_poll_oneoff) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, in);  m3ApiGetArg(uint32_t, out)
    m3ApiGetArg(uint32_t, nsub); m3ApiGetArgMem(uint32_t *, nevents)
    (void)in; (void)out; (void)nsub; (void)nevents;
    m3ApiReturn(WASI_ENOTSUP);  // event polling lands with native async (Phase 5)
}

// --- linker -----------------------------------------------------------------------------------

typedef struct { const char *name; const char *sig; M3RawCall fn; } wasi_entry_t;

#define E(n, s, f) { n, s, &f }
static const wasi_entry_t k_wasi[] = {
    E("fd_write",            "i(iiii)", wasi_fd_write),
    E("fd_read",             "i(iiii)", wasi_fd_read),
    E("fd_close",            "i(i)",    wasi_fd_close),
    E("fd_seek",             "i(iIii)", wasi_fd_seek),
    E("fd_fdstat_get",       "i(ii)",   wasi_fd_fdstat_get),
    E("fd_prestat_get",      "i(ii)",   wasi_fd_prestat_get),
    E("fd_prestat_dir_name", "i(iii)",  wasi_fd_prestat_dir_name),
    E("clock_time_get",      "i(iIi)",  wasi_clock_time_get),
    E("clock_res_get",       "i(ii)",   wasi_clock_res_get),
    E("random_get",          "i(ii)",   wasi_random_get),
    E("environ_sizes_get",   "i(ii)",   wasi_environ_sizes_get),
    E("environ_get",         "i(ii)",   wasi_environ_get),
    E("args_sizes_get",      "i(ii)",   wasi_args_sizes_get),
    E("args_get",            "i(ii)",   wasi_args_get),
    E("sched_yield",         "i()",     wasi_sched_yield),
    E("poll_oneoff",         "i(iiii)", wasi_poll_oneoff),
    E("proc_exit",           "v(i)",    wasi_proc_exit),
};
#undef E

M3Result wasm_wasi_link(IM3Module module) {
    for (size_t i = 0; i < sizeof(k_wasi) / sizeof(k_wasi[0]); i++) {
        M3Result r = m3_LinkRawFunction(module, "wasi_snapshot_preview1",
                                        k_wasi[i].name, k_wasi[i].sig, k_wasi[i].fn);
        // A guest that does not import this function is fine; any other error is fatal.
        if (r && r != m3Err_functionLookupFailed) return r;
    }
    return m3Err_none;
}
