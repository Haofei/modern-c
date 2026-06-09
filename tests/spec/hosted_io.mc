// SPEC: section=0,24
// SPEC: milestone=hosted-profile-io
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error
// SPEC: check=E_UNHANDLED_RESULT

// Hosted-profile I/O: the opt-in, EXPLICIT, FALLIBLE host I/O surface. This is
// the self-contained spec form of std/hosted_io: the libc syscalls are bound
// `extern "C"`, and the MC surface wraps each so failure is a `Result` value
// (the raw -1 contract is converted to a typed error), never a silent wrong
// number. Buffers are passed in by the caller (no implicit global heap).

struct Fd {
    raw: i32,
}

enum IoError {
    OpenFailed,
    ReadFailed,
    WriteFailed,
    CloseFailed,
}

extern "C" fn openat(dirfd: i32, path: *const u8, flags: i32, mode: i32) -> i32;
extern "C" fn read(fd: i32, buf: *mut u8, n: usize) -> isize;
extern "C" fn write(fd: i32, buf: *const u8, n: usize) -> isize;
extern "C" fn close(fd: i32) -> i32;

const AT_FDCWD: i32 = -100;

// open is fallible: a negative raw fd becomes a typed OpenFailed.
fn io_open(path: *const u8, flags: i32, mode: i32) -> Result<Fd, IoError> {
    let r: i32 = openat(AT_FDCWD, path, flags, mode);
    if r < 0 {
        return err(.OpenFailed);
    }
    return ok(.{ .raw = r });
}

// read is fallible: a negative raw count becomes a typed ReadFailed; 0 is EOF.
fn io_read(f: Fd, buf: *mut u8, n: usize) -> Result<usize, IoError> {
    let r: isize = read(f.raw, buf, n);
    if r < 0 {
        return err(.ReadFailed);
    }
    return ok(r as usize);
}

// write is fallible and reports its (possibly short) count as a value.
fn io_write(f: Fd, buf: *const u8, n: usize) -> Result<usize, IoError> {
    let r: isize = write(f.raw, buf, n);
    if r < 0 {
        return err(.WriteFailed);
    }
    return ok(r as usize);
}

fn io_close(f: Fd) -> Result<bool, IoError> {
    let r: i32 = close(f.raw);
    if r < 0 {
        return err(.CloseFailed);
    }
    return ok(true);
}

// A caller handles the fallible surface with `?` propagation: open, read into a
// caller-owned buffer, close — any failure short-circuits to the typed error.
fn copy_one(path: *const u8, buf: *mut u8, n: usize) -> Result<usize, IoError> {
    let f: Fd = io_open(path, 0, 0)?;
    let got: usize = io_read(f, buf, n)?;
    let ok_close: bool = io_close(f)?;
    return ok(got);
}

// The I/O Result must be handled: ignoring it (calling for effect, discarding
// the Result) is a compile error — failure can never be silently dropped.
fn reject_ignored_result(f: Fd, buf: *const u8, n: usize) -> void {
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    io_write(f, buf, n);
}
