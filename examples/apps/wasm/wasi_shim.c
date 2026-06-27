// examples/apps/wasm/wasi_shim — the freestanding WASI Preview 1 shim (docs/wasm-migration-plan.md
// Phases 1-2). Each WASI import is an m3 raw function that reads/writes the guest's linear memory
// and routes effects through the kernel's narrow syscall ABI. This is the standard, reusable
// boundary the migration replaces qjs_host.c's bespoke JS glue with: one shim serves any
// wasm32-wasi guest (C/Rust/Zig/Go/AssemblyScript/JS-via-Javy).
//
// A WASI call is NOT a syscall — the trap boundary stays the six syscalls (user/abi.mc). Console
// I/O maps to SYS_WRITE/SYS_READ; filesystem maps to TOOL_OP_FS_* through SYS_SUBMIT/SYS_POLL and
// the capability broker (allowlist -> budget -> path-cap, with allow/deny audit), exactly as the
// JS host's host_fs_* do. The kernel, syscall ABI, and brokers are unchanged.
//
// Filesystem model: the kernel FS tool is WHOLE-FILE (no offset in the ToolReq ABI) — FS_WRITE
// writes the payload as the file body, FS_READ returns the whole file. The shim therefore buffers
// a written file and flushes it on close, and serves reads sequentially from a per-fd cache. A
// single "/ws" preopen (fd 3) mirrors the kernel's pathcap root; path_open resolves guest-relative
// paths under it.

#include "wasm3.h"
#include "wasi.h"
#include "wasi_shim.h"
#include "tool_abi.h"

#include <stdint.h>
#include <stddef.h>

// The confined platform shim (user/libc/syscall_user.mc) — the only path to the kernel.
extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern long sys_read(void *buf, unsigned long max);
extern long sys_submit(unsigned long req_ptr);
extern long sys_poll(unsigned long events_ptr, unsigned long max, unsigned long timeout);

// m3_info.c (the printf disassembler) is excluded from the freestanding build; provide the one
// symbol m3_FreeRuntime references. See third_party/wasm3/VENDOR.md.
void m3_PrintProfilerInfo(void) {}

const char *const wasm_wasi_proc_exit_result = "wasm3-host: guest called proc_exit";
int wasm_wasi_exit_code = 0;

// No host wall-clock yet: a monotonic counter (advances per call). Real time will route through
// the broker (TOOL_OP_TIMEOUT/SYS_POLL) later; until then this keeps clock_time_get monotonic,
// which is all wasi-libc's stdio/buffering needs.
static uint64_t g_clock_ns = 0;

// random_get placeholder: a deterministic xorshift, NOT cryptographic. A TOOL_OP_RANDOM over the
// kernel rng replaces this once a guest needs real entropy (docs/wasm-migration-plan.md Phase 1).
static uint32_t g_rng = 0x9E3779B9u;

// --- the filesystem fd table -------------------------------------------------------------------

#define WASM_FD_MAX     16
#define WASM_PATH_MAX   128
#define WASM_PREOPEN_FD 3
static const char WASM_PREOPEN_NAME[] = "/ws";  // mirrors the kernel's pathcap root (app_run_demo.mc)

typedef struct {
    int used;
    int is_preopen;
    int can_read, can_write;
    unsigned char path[WASM_PATH_MAX];   // absolute kernel path, e.g. "/ws/a.txt"
    uint32_t path_len;
    // whole-file read cache
    int read_loaded;
    unsigned char rbuf[TOOL_MAX_RES_BYTES];
    uint32_t rlen, rpos;
    // whole-file write buffer (flushed on close)
    unsigned char wbuf[TOOL_MAX_RES_BYTES];
    uint32_t wlen;
    int dirty;
} wasm_fd_t;

static wasm_fd_t g_fds[WASM_FD_MAX];
static int g_fds_inited = 0;

static void fds_init(void) {
    if (g_fds_inited) return;
    g_fds_inited = 1;
    wasm_fd_t *pre = &g_fds[WASM_PREOPEN_FD];   // fd 3 = the single preopen directory "/ws"
    pre->used = 1; pre->is_preopen = 1;
    uint32_t i = 0;
    for (; WASM_PREOPEN_NAME[i] && i < WASM_PATH_MAX; i++) pre->path[i] = (unsigned char)WASM_PREOPEN_NAME[i];
    pre->path_len = i;
}

static int fd_is_file(uint32_t fd) {
    return fd < WASM_FD_MAX && g_fds[fd].used && !g_fds[fd].is_preopen;
}
static int fd_is_preopen(uint32_t fd) {
    return fd < WASM_FD_MAX && g_fds[fd].used && g_fds[fd].is_preopen;
}

// Append `rel` (guest-relative) onto the preopen `base` path: base + "/" + rel, into `dst`.
static uint32_t join_path(unsigned char *dst, const wasm_fd_t *base, const char *rel, uint32_t rel_len) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < base->path_len && n < WASM_PATH_MAX; i++) dst[n++] = base->path[i];
    if (n < WASM_PATH_MAX) dst[n++] = '/';
    for (uint32_t i = 0; i < rel_len && n < WASM_PATH_MAX; i++) dst[n++] = (unsigned char)rel[i];
    return n;
}

// --- synchronous bridge over the async Tool ABI -----------------------------------------------

typedef struct { long status; long result; uint32_t out_len; } tool_result_t;

// Submit one fully-built ToolReq, then poll until that id completes (brokered ops are
// ready-immediately, so the first poll delivers; the spin bound guards a missing completion).
static tool_result_t submit_and_wait(ToolReq *req) {
    tool_result_t tr = { -110, 0, 0 };  // default E_TIMEDOUT
    long id = sys_submit((unsigned long)(uintptr_t)req);
    if (id < 0) { tr.status = id; return tr; }

    ToolEvent ev[4];
    for (int spin = 0; spin < 1024; spin++) {
        long c = sys_poll((unsigned long)(uintptr_t)ev, 4, 0);
        if (c < 0) { tr.status = c; return tr; }
        for (long i = 0; i < c; i++) {
            if (ev[i].id == (uint64_t)id) {
                tr.status = ev[i].status; tr.result = ev[i].result; tr.out_len = ev[i].out_len;
                return tr;
            }
        }
    }
    return tr;
}

// A capability-checked FS op: build [path][data] payload, submit, wait. Returns ToolEvent.status
// (negative kernel errno) on failure, else the scalar result; *out_len gets the staged-byte count.
static long tool_call(uint32_t op, const unsigned char *path, uint32_t plen,
                      const unsigned char *data, uint32_t dlen,
                      unsigned char *out, uint32_t out_cap, uint32_t *out_len) {
    static unsigned char payload[TOOL_MAX_REQ_BYTES];
    if ((uint64_t)plen + (uint64_t)dlen > sizeof(payload)) return -105;  // E_NOCAP
    for (uint32_t i = 0; i < plen; i++) payload[i] = path[i];
    for (uint32_t i = 0; i < dlen; i++) payload[plen + i] = data[i];

    ToolReq req;
    for (unsigned i = 0; i < sizeof(req); i++) ((unsigned char *)&req)[i] = 0;
    req.op = op;
    req.arg = plen;
    req.in_ptr = (uint64_t)(uintptr_t)payload;
    req.in_len = plen + dlen;
    if (out_cap) { req.out_cap = out_cap; req.out_ptr = (uint64_t)(uintptr_t)out; }

    tool_result_t tr = submit_and_wait(&req);
    if (out_len) *out_len = tr.out_len;
    if (tr.status < 0) return tr.status;
    return tr.result;
}

// A brokered scalar op (no payload), e.g. TOOL_OP_NET_FETCH: arg + flags in, scalar result out.
static long tool_call_scalar(uint32_t op, uint32_t arg, uint32_t flags) {
    ToolReq req;
    for (unsigned i = 0; i < sizeof(req); i++) ((unsigned char *)&req)[i] = 0;
    req.op = op; req.arg = arg; req.flags = flags;
    tool_result_t tr = submit_and_wait(&req);
    if (tr.status < 0) return tr.status;
    return tr.result;
}

// --- console / process ------------------------------------------------------------------------

// fd_write(fd, *iovs, iovs_len, *nwritten) -> errno. fds 0-2 go to the console (SYS_WRITE); a file
// fd buffers the bytes (whole-file model) and flushes on close.
m3ApiRawFunction(wasi_fd_write) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArgMem (const uint32_t *, iovs)
    m3ApiGetArg    (uint32_t, iovs_len)
    m3ApiGetArgMem (uint32_t *, nwritten)

    m3ApiCheckMem(iovs, (uint64_t)iovs_len * 8);
    uint32_t total = 0;
    int file = fd_is_file(fd);
    wasm_fd_t *f = file ? &g_fds[fd] : 0;
    if (file && !f->can_write) m3ApiReturn(WASI_EACCES);

    for (uint32_t i = 0; i < iovs_len; i++) {
        uint32_t off = m3ApiReadMem32(&iovs[i * 2 + 0]);
        uint32_t len = m3ApiReadMem32(&iovs[i * 2 + 1]);
        if (!len) continue;
        void *p = m3ApiOffsetToPtr(off);
        m3ApiCheckMem(p, len);
        if (file) {
            if (f->wlen + len > sizeof(f->wbuf)) m3ApiReturn(WASI_ENOBUFS);
            const unsigned char *src = (const unsigned char *)p;
            for (uint32_t k = 0; k < len; k++) f->wbuf[f->wlen + k] = src[k];
            f->wlen += len; f->dirty = 1;
        } else {
            sys_write(fd, p, len);
        }
        total += len;
    }
    if (nwritten) { m3ApiCheckMem(nwritten, 4); m3ApiWriteMem32(nwritten, total); }
    m3ApiReturn(WASI_ESUCCESS);
}

// fd_read(fd, *iovs, iovs_len, *nread) -> errno. fd 0 is the §0 ingress (SYS_READ); a file fd is
// served sequentially from a whole-file cache (loaded via TOOL_OP_FS_READ on first read).
m3ApiRawFunction(wasi_fd_read) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArgMem (const uint32_t *, iovs)
    m3ApiGetArg    (uint32_t, iovs_len)
    m3ApiGetArgMem (uint32_t *, nread)

    m3ApiCheckMem(iovs, (uint64_t)iovs_len * 8);
    int file = fd_is_file(fd);
    wasm_fd_t *f = file ? &g_fds[fd] : 0;
    if (file) {
        if (!f->can_read) m3ApiReturn(WASI_EACCES);
        if (!f->read_loaded) {
            uint32_t olen = 0;
            long r = tool_call(TOOL_OP_FS_READ, f->path, f->path_len, 0, 0, f->rbuf, sizeof(f->rbuf), &olen);
            if (r < 0) m3ApiReturn(wasi_errno_from_kernel(r));
            f->rlen = olen; f->rpos = 0; f->read_loaded = 1;
        }
    }

    uint32_t total = 0;
    for (uint32_t i = 0; i < iovs_len; i++) {
        uint32_t off = m3ApiReadMem32(&iovs[i * 2 + 0]);
        uint32_t len = m3ApiReadMem32(&iovs[i * 2 + 1]);
        if (!len) continue;
        void *p = m3ApiOffsetToPtr(off);
        m3ApiCheckMem(p, len);
        if (file) {
            uint32_t avail = f->rlen - f->rpos;
            uint32_t take = len < avail ? len : avail;
            unsigned char *dst = (unsigned char *)p;
            for (uint32_t k = 0; k < take; k++) dst[k] = f->rbuf[f->rpos + k];
            f->rpos += take; total += take;
            if (take < len) break;  // EOF
        } else {
            long n = sys_read(p, len);
            if (n < 0) m3ApiReturn(wasi_errno_from_kernel(n));
            total += (uint32_t)n;
            if ((uint32_t)n < len) break;
        }
    }
    if (nread) { m3ApiCheckMem(nread, 4); m3ApiWriteMem32(nread, total); }
    m3ApiReturn(WASI_ESUCCESS);
}

// fd_close(fd) -> errno. A dirty file fd flushes its buffer via TOOL_OP_FS_WRITE; stdio is a no-op.
m3ApiRawFunction(wasi_fd_close) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg(uint32_t, fd)
    if (fd_is_file(fd)) {
        wasm_fd_t *f = &g_fds[fd];
        uint32_t res = WASI_ESUCCESS;
        if (f->dirty) {
            long r = tool_call(TOOL_OP_FS_WRITE, f->path, f->path_len, f->wbuf, f->wlen, 0, 0, 0);
            if (r < 0) res = wasi_errno_from_kernel(r);
        }
        f->used = 0; f->dirty = 0; f->wlen = 0;
        f->read_loaded = 0; f->rlen = 0; f->rpos = 0;
        m3ApiReturn(res);
    }
    m3ApiReturn(WASI_ESUCCESS);  // stdio
}

// fd_seek(fd, offset, whence, *newoffset) -> errno. Files seek the read cursor (whole-file model);
// the console is a pipe (ESPIPE).
m3ApiRawFunction(wasi_fd_seek) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArg    (uint64_t, offset)
    m3ApiGetArg    (uint32_t, whence)
    m3ApiGetArgMem (uint64_t *, newoffset)
    if (fd_is_file(fd)) {
        wasm_fd_t *f = &g_fds[fd];
        int64_t base = (whence == WASI_WHENCE_CUR) ? (int64_t)f->rpos
                     : (whence == WASI_WHENCE_END) ? (int64_t)f->rlen : 0;
        int64_t no = base + (int64_t)offset;
        if (no < 0) no = 0;
        f->rpos = (uint32_t)no;
        if (newoffset) { m3ApiCheckMem(newoffset, 8); m3ApiWriteMem64(newoffset, f->rpos); }
        m3ApiReturn(WASI_ESUCCESS);
    }
    m3ApiReturn(WASI_ESPIPE);
}

// proc_exit(code) -> noreturn
m3ApiRawFunction(wasi_proc_exit) {
    m3ApiGetArg(uint32_t, code)
    wasm_wasi_exit_code = (int)code;
    m3ApiTrap(wasm_wasi_proc_exit_result);
}

// fd_fdstat_get(fd, *stat) -> errno. fds 0-2 are character devices, the preopen is a directory,
// open files are regular files; all advertise full rights so wasi-libc requests the right subset.
m3ApiRawFunction(wasi_fd_fdstat_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArgMem (wasi_fdstat_t *, st)
    m3ApiCheckMem(st, sizeof(wasi_fdstat_t));

    uint8_t ft;
    if (fd_is_preopen(fd))      ft = WASI_FILETYPE_DIRECTORY;
    else if (fd_is_file(fd))    ft = WASI_FILETYPE_REGULAR_FILE;
    else if (fd <= 2)           ft = WASI_FILETYPE_CHARACTER_DEVICE;
    else                        m3ApiReturn(WASI_EBADF);

    st->fs_filetype = ft;
    st->_pad0 = 0;
    st->fs_flags = 0;
    st->_pad1[0] = st->_pad1[1] = st->_pad1[2] = st->_pad1[3] = 0;
    st->fs_rights_base = (uint64_t)-1;
    st->fs_rights_inheriting = (uint64_t)-1;
    m3ApiReturn(WASI_ESUCCESS);
}

// --- filesystem: preopens + path-relative open/mkdir ------------------------------------------

// fd_prestat_get(fd, *prestat) -> errno. Advertises fd 3 as the "/ws" preopen directory; every
// other fd is EBADF, which ends wasi-libc's preopen scan.
m3ApiRawFunction(wasi_fd_prestat_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArgMem (uint8_t *, prestat)
    if (fd_is_preopen(fd)) {
        m3ApiCheckMem(prestat, 8);
        m3ApiWriteMem8(prestat + 0, WASI_PREOPENTYPE_DIR);
        m3ApiWriteMem32(prestat + 4, g_fds[fd].path_len);
        m3ApiReturn(WASI_ESUCCESS);
    }
    m3ApiReturn(WASI_EBADF);
}

// fd_prestat_dir_name(fd, *path, path_len) -> errno. Copies the preopen's name ("/ws").
m3ApiRawFunction(wasi_fd_prestat_dir_name) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, fd)
    m3ApiGetArgMem (uint8_t *, path)
    m3ApiGetArg    (uint32_t, path_len)
    if (!fd_is_preopen(fd)) m3ApiReturn(WASI_EBADF);
    wasm_fd_t *f = &g_fds[fd];
    uint32_t n = path_len < f->path_len ? path_len : f->path_len;
    m3ApiCheckMem(path, n);
    for (uint32_t i = 0; i < n; i++) path[i] = f->path[i];
    m3ApiReturn(WASI_ESUCCESS);
}

// path_open(dirfd, dirflags, *path, path_len, oflags, rights_base, rights_inheriting, fdflags,
//           *opened_fd) -> errno. Resolves a guest-relative path under the preopen and allocates a
// file fd; the actual TOOL_OP_FS_* call happens lazily on first read / on close-flush.
m3ApiRawFunction(wasi_path_open) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, dirfd)
    m3ApiGetArg    (uint32_t, dirflags)
    m3ApiGetArgMem (const char *, path)
    m3ApiGetArg    (uint32_t, path_len)
    m3ApiGetArg    (uint32_t, oflags)
    m3ApiGetArg    (uint64_t, rights_base)
    m3ApiGetArg    (uint64_t, rights_inheriting)
    m3ApiGetArg    (uint32_t, fdflags)
    m3ApiGetArgMem (uint32_t *, opened_fd)
    (void)dirflags; (void)oflags; (void)rights_inheriting; (void)fdflags;

    m3ApiCheckMem(path, path_len);
    if (!fd_is_preopen(dirfd)) m3ApiReturn(WASI_EBADF);

    int slot = -1;
    for (int i = WASM_PREOPEN_FD + 1; i < WASM_FD_MAX; i++) if (!g_fds[i].used) { slot = i; break; }
    if (slot < 0) m3ApiReturn(WASI_EMFILE);

    wasm_fd_t *f = &g_fds[slot];
    for (unsigned i = 0; i < sizeof(*f); i++) ((unsigned char *)f)[i] = 0;
    f->used = 1; f->is_preopen = 0;
    // Derive access from the requested rights; default to read if neither bit is requested.
    f->can_read  = (rights_base & WASI_RIGHTS_FD_READ)  != 0;
    f->can_write = (rights_base & WASI_RIGHTS_FD_WRITE) != 0;
    if (!f->can_read && !f->can_write) f->can_read = 1;
    f->path_len = join_path(f->path, &g_fds[dirfd], path, path_len);

    m3ApiCheckMem(opened_fd, 4);
    m3ApiWriteMem32(opened_fd, (uint32_t)slot);
    m3ApiReturn(WASI_ESUCCESS);
}

// path_create_directory(dirfd, *path, path_len) -> errno. Maps to TOOL_OP_FS_MKDIR (not in the
// agent's allowlist in app_run_demo.mc, so this is the DENIED+audited case).
m3ApiRawFunction(wasi_path_create_directory) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, dirfd)
    m3ApiGetArgMem (const char *, path)
    m3ApiGetArg    (uint32_t, path_len)
    m3ApiCheckMem(path, path_len);
    if (!fd_is_preopen(dirfd)) m3ApiReturn(WASI_EBADF);

    unsigned char full[WASM_PATH_MAX];
    uint32_t n = join_path(full, &g_fds[dirfd], path, path_len);
    long r = tool_call(TOOL_OP_FS_MKDIR, full, n, 0, 0, 0, 0, 0);
    if (r < 0) m3ApiReturn(wasi_errno_from_kernel(r));
    m3ApiReturn(WASI_ESUCCESS);
}

// --- clocks / randomness ----------------------------------------------------------------------

m3ApiRawFunction(wasi_clock_time_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, clk_id)
    m3ApiGetArg    (uint64_t, precision)
    m3ApiGetArgMem (uint64_t *, time)
    (void)clk_id; (void)precision;
    m3ApiCheckMem(time, 8);
    g_clock_ns += 1000000;
    m3ApiWriteMem64(time, g_clock_ns);
    m3ApiReturn(WASI_ESUCCESS);
}

m3ApiRawFunction(wasi_clock_res_get) {
    m3ApiReturnType(uint32_t)
    m3ApiGetArg    (uint32_t, clk_id)
    m3ApiGetArgMem (uint64_t *, res)
    (void)clk_id;
    m3ApiCheckMem(res, 8);
    m3ApiWriteMem64(res, 1);
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

// --- MC host tool surface (non-WASI): brokered network fetch ----------------------------------

// net_fetch(endpoint, token) -> result. The WASM analogue of the JS host_net_fetch: a FETCH-ONLY
// egress surface over the kernel's pre-registered endpoint-id + NetCap machinery
// (docs/wasm-migration-plan.md Phase 3) — NOT general sockets. Maps onto TOOL_OP_NET_FETCH
// (arg = endpoint id, flags = request token). Returns the broker's scalar response (>=0), or a
// negative kernel errno directly (-E_DENIED = not allowlisted, -E_AGAIN = budget exhausted); the
// guest is MC-aware, exactly as a JS agent calling host_net_fetch is. Imported under module "mc"
// (the MC host tool surface), distinct from "wasi_snapshot_preview1".
m3ApiRawFunction(host_net_fetch) {
    m3ApiReturnType(int32_t)
    m3ApiGetArg(uint32_t, endpoint)
    m3ApiGetArg(uint32_t, token)
    long r = tool_call_scalar(TOOL_OP_NET_FETCH, endpoint, token);
    m3ApiReturn((int32_t)r);
}

// --- linker -----------------------------------------------------------------------------------

typedef struct { const char *name; const char *sig; M3RawCall fn; } wasi_entry_t;

#define E(n, s, f) { n, s, &f }
static const wasi_entry_t k_wasi[] = {
    E("fd_write",             "i(iiii)",     wasi_fd_write),
    E("fd_read",              "i(iiii)",     wasi_fd_read),
    E("fd_close",             "i(i)",        wasi_fd_close),
    E("fd_seek",              "i(iIii)",     wasi_fd_seek),
    E("fd_fdstat_get",        "i(ii)",       wasi_fd_fdstat_get),
    E("fd_prestat_get",       "i(ii)",       wasi_fd_prestat_get),
    E("fd_prestat_dir_name",  "i(iii)",      wasi_fd_prestat_dir_name),
    E("path_open",            "i(iiiiiIIii)", wasi_path_open),
    E("path_create_directory","i(iii)",      wasi_path_create_directory),
    E("clock_time_get",       "i(iIi)",      wasi_clock_time_get),
    E("clock_res_get",        "i(ii)",       wasi_clock_res_get),
    E("random_get",           "i(ii)",       wasi_random_get),
    E("environ_sizes_get",    "i(ii)",       wasi_environ_sizes_get),
    E("environ_get",          "i(ii)",       wasi_environ_get),
    E("args_sizes_get",       "i(ii)",       wasi_args_sizes_get),
    E("args_get",             "i(ii)",       wasi_args_get),
    E("sched_yield",          "i()",         wasi_sched_yield),
    E("poll_oneoff",          "i(iiii)",     wasi_poll_oneoff),
    E("proc_exit",            "v(i)",        wasi_proc_exit),
};
#undef E

M3Result wasm_wasi_link(IM3Module module) {
    fds_init();
    for (size_t i = 0; i < sizeof(k_wasi) / sizeof(k_wasi[0]); i++) {
        M3Result r = m3_LinkRawFunction(module, "wasi_snapshot_preview1",
                                        k_wasi[i].name, k_wasi[i].sig, k_wasi[i].fn);
        // A guest that does not import this function is fine; any other error is fatal.
        if (r && r != m3Err_functionLookupFailed) return r;
    }
    // MC host tool surface (non-WASI): the fetch-only network egress tool.
    M3Result rn = m3_LinkRawFunction(module, "mc", "net_fetch", "i(ii)", &host_net_fetch);
    if (rn && rn != m3Err_functionLookupFailed) return rn;
    return m3Err_none;
}
