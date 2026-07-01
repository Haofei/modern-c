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

// Fixed source ceiling (1 MiB). The file must fit here — see the FILE-INPUT FRICTION note.
const MC_SRC_CAP: usize = 1048576;
global g_src: [1048576]u8;

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

// mcc2 entry: `mcc2 input.mc` -> emitted subset C on stdout.
export fn mc_main() -> i32 {
    if args_count() < 2 {
        mc_emsg(stderr_fd(), "usage: mcc2 <input.mc>\n");
        return 2;
    }

    let path: *const u8 = mc_argv(1) as *const u8;
    var nread: usize = 0;
    if let ok(v) = mc_read_all(path) {
        nread = v;
    } else {
        mc_emsg(stderr_fd(), "mcc2: cannot read input (missing, unreadable, or > 1 MiB)\n");
        return 3;
    }

    // Build the `[]const u8` view the pipeline wants: a view of the typed global, sub-sliced to the
    // bytes actually read (G12/G13 file-input path).
    let full: []const u8 = mem.as_bytes(&g_src);
    let src: []const u8 = full[0..nread];

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

    if perr != 0 {
        return 4;
    }
    return 0;
}
