// demo/hosted — a HOSTED-profile elementwise float kernel: the canonical data
// round-trip a separate frontend relies on.
//
// It reads two `f32` input buffers from stdin, computes `out[i] = sqrt(a[i]) +
// b[i]` (exercising the `std/mathf` libm intrinsic and IEEE float add), and
// writes the `f32` result buffer to stdout. All I/O is explicit and fallible
// via `std/hosted_io` (every libc call returns a `Result`); the work buffers are
// caller-owned fixed storage — no implicit global heap.
//
// WIRE CONVENTION (little-endian, the host's native byte order; documented so a
// frontend can produce/consume it):
//   stdin :  u32 N          — element count, 1 <= N <= CAP
//            f32 a[N]        — first input array
//            f32 b[N]        — second input array
//   stdout:  f32 out[N]      — result, out[i] = sqrt(a[i]) + b[i]
//
// Entry point `hosted_kernel_run() -> i32` returns 0 on success, or a small
// non-zero code identifying the failed stage (see returns below). A C `main`
// that just calls it lives in demo/hosted/main.c; build+run with
// demo/hosted/run.sh.

import "std/addr.mc";
import "std/hosted_io.mc";
import "std/mathf.mc";

// Fixed working-set capacity. A real host would take an allocator (std/alloc)
// and size buffers to N; the demo keeps storage on the stack to stay close to
// the freestanding spirit while still being a hosted program.
const CAP: usize = 256;

// Read exactly `n` bytes into `buf`, looping over short reads. A premature EOF
// (read returns 0 before `n`) is a typed error, never a silent short buffer.
fn read_exact(f: Fd, buf: PAddr, n: usize) -> Result<bool, IoError> {
    var done: usize = 0;
    while done < n {
        let r: usize = io_read(f, pa_offset(buf, done), n - done)?;
        if r == 0 {
            return err(.ReadFailed);
        }
        done = done + r;
    }
    return ok(true);
}

export fn hosted_kernel_run() -> i32 {
    var a: [CAP]f32 = uninit;
    var b: [CAP]f32 = uninit;
    var out: [CAP]f32 = uninit;

    let input: Fd = stdin_fd();
    let output: Fd = stdout_fd();

    // 1. element count (u32, 4 bytes).
    var count_buf: [1]u32 = uninit;
    let count_addr: PAddr = pa((&count_buf[0]) as usize);
    if let err(e) = read_exact(input, count_addr, 4) {
        return 1; // could not read the count header
    }
    let n: usize = count_buf[0] as usize;
    if n > CAP {
        return 2; // count exceeds this build's capacity
    }
    if n == 0 {
        return 3; // empty request
    }

    let a_addr: PAddr = pa((&a[0]) as usize);
    let b_addr: PAddr = pa((&b[0]) as usize);
    let out_addr: PAddr = pa((&out[0]) as usize);

    // 2. the two input arrays.
    if let err(e) = read_exact(input, a_addr, n * 4) {
        return 4; // truncated input a[]
    }
    if let err(e) = read_exact(input, b_addr, n * 4) {
        return 5; // truncated input b[]
    }

    // 3. the kernel: sqrt intrinsic + IEEE add, elementwise.
    var i: usize = 0;
    while i < n {
        out[i] = sqrt_f32(a[i]) + b[i];
        i = i + 1;
    }

    // 4. write the result back.
    if let err(e) = io_write_all(output, out_addr, n * 4) {
        return 6; // write failed
    }
    return 0;
}
