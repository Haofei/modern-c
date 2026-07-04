// MC standard library — `hosted_io`: explicit, fallible byte I/O for the HOSTED
// profile.
//
// This module is the ONLY place ambient host I/O enters MC, and it is strictly
// OPT-IN: the default kernel/freestanding profile never imports it, so a kernel
// can never accidentally call `read`/`write`. A program enters the hosted
// profile by importing this file (the language-level opt-in) and linking against
// libc (the toolchain-level opt-in, done automatically by
// `mcc-cc.sh --profile=hosted`).
//
// PRINCIPLES (spec §0): the machine contract is made explicit. The raw POSIX
// calls report failure by returning -1 (and setting errno) — an invisible
// assumption. Here every call instead returns a `Result`: an error is a value
// you must handle, never a silently-wrong number. The negative raw return code
// is carried in the error so callers can inspect/propagate it.
//
// No implicit global heap: callers pass the buffer in (as a typed `PAddr`) and
// own its storage, exactly like `std/alloc` passes the allocator in.

import "std/addr.mc";

// ----- file descriptor: a typed, opaque wrapper over the POSIX int fd -----

pub struct Fd {
    raw: i32,
}

pub fn fd_raw(f: Fd) -> i32 {
    return f.raw;
}
// The conventional standard streams.
pub fn stdin_fd() -> Fd { return .{ .raw = 0 }; }
pub fn stdout_fd() -> Fd { return .{ .raw = 1 }; }
pub fn stderr_fd() -> Fd { return .{ .raw = 2 }; }

// ----- open() flags (Linux/glibc values; the hosted target is Linux libc) -----

pub const O_RDONLY: i32 = 0;
pub const O_WRONLY: i32 = 1;
pub const O_RDWR:   i32 = 2;
pub const O_CREAT:  i32 = 64;    // 0o100
pub const O_TRUNC:  i32 = 512;   // 0o1000

// Default mode bits (0o644) for files created with O_CREAT.
pub const MODE_0644: i32 = 420;

// AT_FDCWD: resolve relative paths against the current working directory. Used
// with `openat` (we bind `openat`, not `open`, because `open` is an MC keyword).
//
// PLATFORM LIMITATION (gap G29): this value is LINUX-specific (`-100`). The hosted
// profile targets Linux libc (see §0 above), which is where CI/Docker run, so this is
// correct there. On macOS the constant is `-2`, so a RELATIVE path passed to `io_open`
// on a macOS host fails (ENOENT/`OpenFailed`); ABSOLUTE paths work everywhere (dirfd is
// ignored). Consequence: the `mcc2` hosted CLI resolves relative input/import paths only
// on Linux; on a macOS host, pass absolute paths (or run under Docker). A portable fix
// needs compile-time target-OS selection, which the language does not yet expose.
const AT_FDCWD: i32 = -100;

// One typed error for every I/O failure. `code` is the raw negative return from
// the underlying libc call (e.g. -1), preserved so callers can distinguish/log
// it; the variant names the operation that failed.
pub enum IoError {
    OpenFailed,
    ReadFailed,
    WriteFailed,
    CloseFailed,
    FormatFailed,
}

// ----- raw libc bindings (explicit machine contract) -----
//
// Each is the genuine POSIX/libc symbol. `openat` is variadic in C
// (`openat(dirfd, path, flags, ...mode)`); we bind the concrete 4-argument
// form, which is ABI-correct for the call we make. `dprintf` is likewise bound
// at one concrete trailing-argument arity (a single f64), enough for the
// formatted numeric write a kernel host needs.

extern "C" fn openat(dirfd: i32, path: *const u8, flags: i32, mode: i32) -> i32;
extern "C" fn read(fd: i32, buf: *mut u8, n: usize) -> isize;
extern "C" fn write(fd: i32, buf: *const u8, n: usize) -> isize;
extern "C" fn close(fd: i32) -> i32;
extern "C" fn dprintf(fd: i32, fmt: *const u8, value: f64) -> i32;

// ----- the fallible MC surface -----

// Open `path` with POSIX `flags` (and `mode` for O_CREAT). Returns a typed `Fd`
// or `IoError.OpenFailed` on failure (raw fd < 0).
pub fn io_open(path: *const u8, flags: i32, mode: i32) -> Result<Fd, IoError> {
    let r: i32 = openat(AT_FDCWD, path, flags, mode);
    if r < 0 {
        return err(.OpenFailed);
    }
    return ok(.{ .raw = r });
}

// Read up to `n` bytes from `fd` into `buf`. Returns the number of bytes read
// (0 means end-of-file), or `IoError.ReadFailed` on error (raw < 0). The caller
// owns `buf` and guarantees it has room for `n` bytes (an unchecked contract,
// like every raw-buffer boundary in MC).
pub fn io_read(f: Fd, buf: PAddr, n: usize) -> Result<usize, IoError> {
    var p: *mut u8 = raw.ptr<u8>(0);
    unsafe {
        p = raw.ptr<u8>(buf);
    }
    let r: isize = read(f.raw, p, n);
    if r < 0 {
        return err(.ReadFailed);
    }
    return ok(r as usize);
}

// Write `n` bytes from `buf` to `fd`. Returns the number of bytes written, or
// `IoError.WriteFailed` on error (raw < 0). A short write (returned count < n)
// is reported as a value, not hidden — the caller decides whether to loop.
pub fn io_write(f: Fd, buf: PAddr, n: usize) -> Result<usize, IoError> {
    var p: *const u8 = raw.ptr<u8>(0);
    unsafe {
        p = raw.ptr<u8>(buf);
    }
    let r: isize = write(f.raw, p, n);
    if r < 0 {
        return err(.WriteFailed);
    }
    return ok(r as usize);
}

// Write exactly `n` bytes from `buf` to `fd`, looping over short writes. Returns
// the total written (== n on success) or the first `IoError.WriteFailed`.
pub fn io_write_all(f: Fd, buf: PAddr, n: usize) -> Result<usize, IoError> {
    var done: usize = 0;
    while done < n {
        let w: usize = io_write(f, pa_offset(buf, done), n - done)?;
        if w == 0 {
            return err(.WriteFailed);
        }
        done = done + done_step(w);
    }
    return ok(done);
}

// (helper kept trivial so io_write_all reads cleanly; identity on the count.)
fn done_step(w: usize) -> usize {
    return w;
}

// Close `fd`. Returns true on success or `IoError.CloseFailed` (raw < 0).
pub fn io_close(f: Fd) -> Result<bool, IoError> {
    let r: i32 = close(f.raw);
    if r < 0 {
        return err(.CloseFailed);
    }
    return ok(true);
}

// Formatted write: render `value` through the printf `fmt` (which must contain
// exactly one floating conversion, e.g. "%g\n") and write it to `fd`. Returns
// the number of bytes written or `IoError.FormatFailed` (raw < 0). This is the
// explicit, fallible analogue of an ambient `printf`.
pub fn io_printf_f64(f: Fd, fmt: *const u8, value: f64) -> Result<usize, IoError> {
    let r: i32 = dprintf(f.raw, fmt, value);
    if r < 0 {
        return err(.FormatFailed);
    }
    return ok(r as usize);
}
