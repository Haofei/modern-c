// selfhost/main — the standalone `mcc2` CLI driver (docs/self-host-plan.md, the step after P4).
//
// This packages the subset self-hosted front end (lexer -> parser -> sema -> emit_c) as a real
// command-line program: `mcc2 input.mc` reads the file, runs the whole pipeline, and prints the
// emitted subset C to stdout. It is the "or slow" deliverable's harness — the perf gate times it
// on a large generated input.
//
// HOSTED ENTRY: this program does NOT define `fn main`. It exports `mc_main` (std/hosted_args
// contract) and links `tools/toolchain/mcc2_rt.c`, whose C `main` stashes argv and calls back.
//
// FILE-INPUT FRICTION (gap ledger G12/G13, recorded in docs/self-host-gaps.md): the pipeline
// consumes `source: []const u8`, but MC cannot build a `[]const u8` from a malloc'd `PAddr`+len
// (G12 — slices are not constructible from a raw pointer+length). The working path is a real,
// typed, fixed-size local/global `[N]u8`: read the file INTO it, take `mem.as_bytes(&buf)` for the
// `[]const u8` view, then SUB-SLICE `[0..nread]` (a sub-slice of a plain array works — G13). The
// writable destination address for `io_read` is `(&g_src) as usize` wrapped with `pa(...)` (taking
// the address of a `global` array and casting to `usize` is the sanctioned usize<->addr boundary,
// same idiom as kernel/arch/riscv64/agent_confined_tool_runtime.mc). Hence the 1 MiB `g_src`
// ceiling below: inputs larger than that are rejected rather than silently truncated.

import "selfhost/emit_c.mc";
import "selfhost/sema.mc";
import "selfhost/lexer.mc";
import "std/strbuf.mc";
import "std/mem.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";
import "std/hosted_args.mc";
import "std/hosted_io.mc";

// malloc/free runtime (tools/toolchain/mcc2_rt.c).
extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;
// NOTE: `mc_argv` (raw address of argv[i], a NUL-terminated C string) is already bound by
// std/hosted_args.mc; MC's flat namespace (G22) makes it callable here directly — re-declaring it
// is an E_DUPLICATE_DECLARATION. We use the raw address (not the base+len ByteReader) because
// io_open wants a `*const u8` path, and argv strings are NUL-terminated by the C runtime.

// A libc-malloc-backed allocator for the parser arena + emit buffer (same shape as the P4 gate
// wrapper tests/toolchain/selfhost_emit_user.mc).
struct MallocAlloc {
    count: u32,
}

impl Allocator for MallocAlloc {
    fn alloc(self: *mut MallocAlloc, size: usize, align: usize) -> PAddr {
        if align == 0 { unreachable; }
        self.count = self.count + 1;
        return pa(mc_malloc(size));
    }
    fn free(self: *mut MallocAlloc, addr: PAddr, size: usize) -> void {
        if self.count == 0 { unreachable; }
        mc_free(pa_value(addr), size);
    }
}

// Per-file scratch ceiling (1 MiB). Each module file is read INTO g_src, scanned for imports, then
// copied into the combined buffer; a single file larger than this is rejected. See FILE-INPUT.
const MC_SRC_CAP: usize = 1048576;
global g_src: [1048576]u8;

// ----- P5.4 multi-module loader state (docs/self-host-plan.md) --------------------------------
//
// MC has no separate module/object model: an `import "path";` is resolved by TEXTUAL INCLUSION.
// The loader reads the root file, finds its (transitive) imports, and CONCATENATES every distinct
// module's full source into one big buffer (`g_concat`), then runs the existing single-source
// pipeline once over it. Import statements survive the concatenation verbatim; the parser treats
// each as a no-op `import_decl` (its decls arrive via the concatenated text), and the emitter's
// forward-prototype pass makes function order across modules irrelevant.
//
// PATH RESOLUTION (a deliberate subset): a relative import `rel` is tried FIRST against the ROOT
// file's directory (`<rootdir>/rel`), then AS-GIVEN (cwd/repo-root-relative, so mcc2's own
// `import "std/mem.mc"` / `import "selfhost/lexer.mc"` resolve when run from the repo root). This is
// simpler than MC's real per-importer ancestor walk (src/loader.zig) and is noted as a limit: an
// import is always resolved relative to the ROOT, not to the importing file's own directory.
//
// DEDUP: the queue of import paths doubles as the seen-set — a path string is added only if no
// existing entry compares byte-equal (so a diamond A->{B,C}->D includes D exactly once). Dedup is
// on the import STRING as written; two spellings of the same file would not dedup (a noted limit).

// Combined-source ceiling (4 MiB): it holds every distinct module, so it is larger than the
// per-file cap. A program whose flattened source exceeds this is rejected rather than truncated.
const MC_CONCAT_CAP: usize = 4194304;
global g_concat: [4194304]u8;
global g_concat_len: usize = 0;

// The import-path queue + seen-set. Path strings are packed end-to-end in g_path_buf; g_path_off /
// g_path_len index them. g_path_count entries are processed in order (indices grow as new imports
// are discovered), giving a breadth-first flatten.
const MC_MAX_FILES: usize = 512;
const MC_PATHBUF_CAP: usize = 131072; // 128 KiB total for all import-path strings
global g_path_off: [512]usize;
global g_path_len: [512]usize;
global g_path_buf: [131072]u8;
global g_path_count: usize = 0;
global g_path_used: usize = 0;

// The root file's directory prefix (bytes before the last '/', no trailing slash) and a scratch
// buffer for the NUL-terminated candidate path handed to io_open.
const MC_PATH_CAP: usize = 4096;
global g_rootdir: [4096]u8;
global g_rootdir_len: usize = 0;
global g_openpath: [4096]u8;

// ----- tiny cstr helpers (string literals are `*const u8`; G12) -----

// Length of a NUL-terminated C string (for writing message literals to a Fd).
fn mc_cstr_len(s: *const u8) -> usize {
    var n: usize = 0;
    var b: u8 = 0;
    unsafe {
        b = raw.load<u8>(pa(s as usize));
    }
    while b != 0 {
        n = n + 1;
        unsafe {
            b = raw.load<u8>(pa((s as usize) + n));
        }
    }
    return n;
}

// Write a NUL-terminated message literal to `fd` (best-effort; ignores the Result).
fn mc_emsg(fd: Fd, s: *const u8) -> void {
    let n: usize = mc_cstr_len(s);
    if let err(e) = io_write(fd, pa(s as usize), n) {}
}

// ----- the pipeline driver -----

// Read the whole file at `path` into g_src, looping over short reads. Returns the byte count read
// on success; a file that does not fit in g_src is reported as `IoError.ReadFailed`.
fn mc_read_all(path: *const u8) -> Result<usize, IoError> {
    let fd: Fd = io_open(path, O_RDONLY, 0)?;
    let base: usize = (&g_src) as usize;
    var total: usize = 0;
    var going: bool = true;
    while going {
        if total >= MC_SRC_CAP {
            if let err(e) = io_close(fd) {}
            return err(.ReadFailed); // file did not fit in the 1 MiB buffer
        }
        let got: usize = io_read(fd, pa(base + total), MC_SRC_CAP - total)?;
        if got == 0 {
            going = false;
        } else {
            total = total + got;
        }
    }
    if let err(e) = io_close(fd) {}
    return ok(total);
}

// ----- P5.4 loader: flatten the import graph by textual concatenation -------------------------

// Store one byte `v` at `base + i` (`base` is a global-array address taken via `... as usize`).
fn mc_bset(base: usize, i: usize, v: u8) -> void {
    unsafe {
        raw.store<u8>(pa(base + i), v);
    }
}

// Load the byte at `base + i` (used to walk the NUL-terminated argv path).
fn mc_bget(base: usize, i: usize) -> u8 {
    var v: u8 = 0;
    unsafe {
        v = raw.load<u8>(pa(base + i));
    }
    return v;
}

// A `*const u8` view of the bytes at global-array address `base` (for io_open's path argument).
fn mc_cptr(base: usize) -> *const u8 {
    var p: *const u8 = raw.ptr<u8>(pa(0));
    unsafe {
        p = raw.ptr<u8>(pa(base));
    }
    return p;
}

// True when `k` (a token-kind ordinal from `token_kind_at`) equals `TokKind` variant `want`. The
// variant is passed as a param so its enum type is inferred (a bare `TokKind.x` value is not a
// subset expression); `.raw()` yields the ordinal to compare against.
fn mc_kind_is(k: u32, want: TokKind) -> bool {
    let w: u32 = want.raw();
    return k == w;
}

// Compute the root file's directory prefix from the NUL-terminated argv path at `argp`: the bytes
// up to (excluding) the last '/'. No slash -> an empty prefix (the file sits in the cwd).
fn mc_compute_rootdir(argp: usize) -> void {
    var i: usize = 0;
    var last: usize = 0;
    var has: bool = false;
    var b: u8 = mc_bget(argp, 0);
    while b != 0 {
        if b == 47 { // '/'
            last = i;
            has = true;
        }
        i = i + 1;
        b = mc_bget(argp, i);
    }
    if has && last <= MC_PATH_CAP {
        mem_copy(pa((&g_rootdir) as usize), pa(argp), last);
        g_rootdir_len = last;
    } else {
        g_rootdir_len = 0;
    }
}

// Enqueue import path `g_src[src_off .. src_off+len]` (the string-literal text minus its quotes)
// unless an equal path is already queued (the queue is also the seen-set — dedup). Returns false
// (a LOAD ERROR, surfaced by the caller — never a silent drop) when the path is too long to fit the
// NUL-terminated candidate buffer `g_openpath[MC_PATH_CAP]`, or when the file/pathbuf caps are hit.
fn mc_queue_path(src_off: usize, len: usize) -> bool {
    if len == 0 {
        return true; // empty import string — nothing to queue, not an error
    }
    // Per-path length cap (fixes a g_openpath[MC_PATH_CAP] overflow): the path must fit BOTH the
    // as-given NUL-terminated form (len + NUL) AND the root-composed form
    // (rootdir + '/' + rel + NUL) that mc_read_import builds into g_openpath.
    if len + 1 > MC_PATH_CAP {
        return false;
    }
    if g_rootdir_len + 1 + len + 1 > MC_PATH_CAP {
        return false;
    }
    let rel: []const u8 = mem.as_bytes(&g_src)[src_off..src_off + len];
    var i: usize = 0;
    while i < g_path_count {
        let stored: []const u8 = mem.as_bytes(&g_path_buf)[g_path_off[i]..g_path_off[i] + g_path_len[i]];
        if mem_eql(rel, stored) {
            return true; // already queued (dedup)
        }
        i = i + 1;
    }
    if g_path_count >= MC_MAX_FILES {
        return false; // too many imports — a load error, not a silent omission
    }
    if g_path_used + len > MC_PATHBUF_CAP {
        return false; // import-path buffer exhausted — a load error, not a silent omission
    }
    mem_copy(pa((&g_path_buf) as usize + g_path_used), pa((&g_src) as usize + src_off), len);
    g_path_off[g_path_count] = g_path_used;
    g_path_len[g_path_count] = len;
    g_path_used = g_path_used + len;
    g_path_count = g_path_count + 1;
    return true;
}

// Lex the `nread` bytes currently in g_src and enqueue every top-level `import "path";` directive
// (identifier `import` + string literal + `;` at brace-depth 0), mirroring src/loader.zig's scan.
fn mc_scan_imports(nread: usize) -> bool {
    var ma: MallocAlloc = .{ .count = 0 };
    var tl: TokenList = token_list_new(&ma);
    let view: []const u8 = mem.as_bytes(&g_src)[0..nread];
    lex(view, &tl);
    let n: usize = token_count(&tl);
    var okq: bool = true;
    var depth: i32 = 0;
    var i: usize = 0;
    while i < n {
        let k: u32 = token_kind_at(&tl, i);
        if mc_kind_is(k, .l_brace) {
            depth = depth + 1;
        } else if mc_kind_is(k, .r_brace) {
            depth = depth - 1;
        } else if depth == 0 && mc_kind_is(k, .identifier) {
            let st: usize = token_start_at(&tl, i);
            let ln: usize = token_len_at(&tl, i);
            let lex_word: []const u8 = mem.as_bytes(&g_src)[st..st + ln];
            if mem_eql(lex_word, "import") && i + 2 < n {
                let k1: u32 = token_kind_at(&tl, i + 1);
                let k2: u32 = token_kind_at(&tl, i + 2);
                if mc_kind_is(k1, .string_literal) && mc_kind_is(k2, .semicolon) {
                    let sst: usize = token_start_at(&tl, i + 1);
                    let sln: usize = token_len_at(&tl, i + 1);
                    if sln >= 2 {
                        if !mc_queue_path(sst + 1, sln - 2) { // strip the surrounding quotes
                            okq = false;
                        }
                    }
                    i = i + 3;
                    continue;
                }
            }
        }
        i = i + 1;
    }
    token_list_free(&tl);
    return okq;
}

// Append the `nread` bytes now in g_src to the combined buffer, then a newline separator (so a file
// with no trailing newline cannot merge tokens with the next). Returns false if it would overflow.
fn mc_append_concat(nread: usize) -> bool {
    if g_concat_len + nread + 1 > MC_CONCAT_CAP {
        return false;
    }
    mem_copy(pa((&g_concat) as usize + g_concat_len), pa((&g_src) as usize), nread);
    g_concat_len = g_concat_len + nread;
    mc_bset((&g_concat) as usize, g_concat_len, 10); // '\n'
    g_concat_len = g_concat_len + 1;
    return true;
}

// Read queued import `idx` into g_src, trying `<rootdir>/rel` first, then `rel` as-given.
fn mc_read_import(idx: usize) -> Result<usize, IoError> {
    let off: usize = g_path_off[idx];
    let len: usize = g_path_len[idx];
    // Candidate 1: root-directory-relative.
    if g_rootdir_len > 0 {
        var pos: usize = 0;
        mem_copy(pa((&g_openpath) as usize), pa((&g_rootdir) as usize), g_rootdir_len);
        pos = g_rootdir_len;
        mc_bset((&g_openpath) as usize, pos, 47); // '/'
        pos = pos + 1;
        mem_copy(pa((&g_openpath) as usize + pos), pa((&g_path_buf) as usize + off), len);
        pos = pos + len;
        mc_bset((&g_openpath) as usize, pos, 0); // NUL
        if let ok(v) = mc_read_all(mc_cptr((&g_openpath) as usize)) {
            return ok(v);
        }
    }
    // Candidate 2: as-given (cwd / repo-root-relative).
    mem_copy(pa((&g_openpath) as usize), pa((&g_path_buf) as usize + off), len);
    mc_bset((&g_openpath) as usize, len, 0); // NUL
    return mc_read_all(mc_cptr((&g_openpath) as usize));
}

// Load the whole import graph rooted at the NUL-terminated path `argp` into g_concat. The root is
// read+scanned+appended first; then each newly-discovered import (breadth-first, deduped) in turn.
// Returns true on success; false if a file is missing/unreadable or the combined source overflows.
fn mc_load_all(argp: usize) -> bool {
    mc_compute_rootdir(argp);
    var nread: usize = 0;
    if let ok(v) = mc_read_all(mc_cptr(argp)) {
        nread = v;
    } else {
        return false;
    }
    if !mc_scan_imports(nread) {
        return false; // an import path was too long / too many imports — a load error
    }
    if !mc_append_concat(nread) {
        return false;
    }
    var qi: usize = 0;
    while qi < g_path_count {
        var in_read: usize = 0;
        if let ok(v) = mc_read_import(qi) {
            in_read = v;
        } else {
            return false;
        }
        if !mc_scan_imports(in_read) {
            return false; // nested import path too long / too many — a load error
        }
        if !mc_append_concat(in_read) {
            return false;
        }
        qi = qi + 1;
    }
    return true;
}

// mcc2 entry: `mcc2 input.mc` -> emitted subset C on stdout.
export fn mc_main() -> i32 {
    if args_count() < 2 {
        mc_emsg(stderr_fd(), "usage: mcc2 <input.mc>\n");
        return 2;
    }

    // Flatten the module's whole import graph into g_concat by textual concatenation.
    let argp: usize = mc_argv(1) as usize;
    if !mc_load_all(argp) {
        mc_emsg(stderr_fd(), "mcc2: cannot load input (missing/unreadable import, or combined source too large)\n");
        return 3;
    }

    // Build the `[]const u8` view the pipeline wants: a view of the combined-source global,
    // sub-sliced to the bytes actually loaded (G12/G13 file-input path).
    let full: []const u8 = mem.as_bytes(&g_concat);
    let src: []const u8 = full[0..g_concat_len];

    // Sema pass first: report (but do not hard-fail on) type errors, then still emit — a subset
    // "best effort" so the perf harness always produces C to measure. Parse errors are surfaced too.
    var ma: MallocAlloc = .{ .count = 0 };
    var st: SmState = sema_check(src, &ma);
    let perr: u32 = sema_parse_err_count(&st);
    let serr: u32 = sema_err_count(&st);
    sema_free(&st);
    if perr != 0 {
        mc_emsg(stderr_fd(), "mcc2: parse errors in input\n");
    }
    if serr != 0 {
        mc_emsg(stderr_fd(), "mcc2: semantic errors in input\n");
    }

    // Emit: run lex -> parse -> emit and flush the whole StrBuf to stdout in one write.
    var mb: MallocAlloc = .{ .count = 0 };
    var sb: StrBuf = emit_c_run(src, &mb);
    let len: usize = sb_len(&sb);
    if len != 0 {
        if let err(e) = io_write(stdout_fd(), sb_ptr(&sb), len) {}
    }
    sb_free(&sb);

    // Emission is best-effort (C is still written above so a perf/inspection caller gets output),
    // but the EXIT CODE must reflect validity so CI/scripts reject bad input: nonzero on ANY
    // parse OR semantic error. (Was: only parse errors failed, so invalid MC exited 0.)
    if perr != 0 {
        return 4;
    }
    if serr != 0 {
        return 5;
    }
    return 0;
}
