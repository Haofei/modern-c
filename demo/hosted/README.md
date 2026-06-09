# Hosted-profile data round-trip

This demo is the canonical **hosted-profile** MC program: it reads `f32` buffers
from a stream, runs an elementwise kernel, and writes `f32` results back. It is
the exact data round-trip a separate frontend relies on, so the buffer/IO
convention is fixed and documented here.

## Profile

MC defaults to the **kernel / freestanding** profile, which has *no ambient I/O*.
A program enters the **hosted** profile two ways, both explicit and opt-in:

- **Language:** `import "std/hosted_io.mc";`. That module is the only place host
  I/O enters MC, and every call is fallible (returns a `Result`). The kernel
  profile never imports it, so a kernel can't accidentally do I/O.
- **Toolchain:** lower with `mcc emit-c <file> --profile=hosted`, which stamps a
  `/* mc-profile: hosted */` marker and tells the toolchain driver to link libc
  and `-lm`. (`--profile=kernel` is the default.)

No implicit global heap: the kernel's work buffers are caller-owned storage.

## Wire convention (stdin → stdout)

All values are little-endian (the host's native byte order):

```
stdin :  u32  N            element count, 1 <= N <= 256
         f32  a[N]         first input array
         f32  b[N]         second input array
stdout:  f32  out[N]       result, out[i] = sqrt(a[i]) + b[i]
```

`sqrt` is the `std/mathf` libm intrinsic; the add is plain IEEE `f32`.

## Files

- `elementwise.mc` — the kernel + entry point `hosted_kernel_run() -> i32`
  (returns 0 on success, or a small non-zero stage code on failure).
- `main.c` — a one-line C `main` that calls the MC entry (MC emits no `main`).
- `run.sh` — runs the full pipeline and verifies the bytes.

## Run it

```sh
zig build                 # build mcc
demo/hosted/run.sh        # MC -> C (--profile=hosted) -> clang -lm -> execute + verify
```

Or by hand:

```sh
zig-out/bin/mcc emit-c demo/hosted/elementwise.mc --profile=hosted > kernel.c
clang -std=c11 kernel.c demo/hosted/main.c -lm -o kernel
python3 -c 'import struct,sys; a=[4,9,16]; b=[1,2,3]; \
  sys.stdout.buffer.write(struct.pack("<I",len(a)) \
    + b"".join(struct.pack("<f",x) for x in a) \
    + b"".join(struct.pack("<f",x) for x in b))' | ./kernel | \
python3 -c 'import struct,sys; d=sys.stdin.buffer.read(); \
  print([struct.unpack("<f",d[i:i+4])[0] for i in range(0,len(d),4)])'
# -> [3.0, 5.0, 7.0]
```
