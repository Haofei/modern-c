// BearSSL freestanding SHA-256 + virtio-rng smoke test, M-mode, in PURE MC.
// (Replaces kernel/drivers/virtio/bearssl_smoke_runtime.c.) This is OUR boot seam + test
// body; BearSSL itself (third_party) and the shared virtio_rng.c driver stay vendored C,
// called via extern. The M-mode sibling of tests/qemu/arch/bearssl_smode_runtime.mc:
// bare UART (no SBI), CLINT mtime as the clock, and the SiFive test finisher to halt.
//
// Boots under QEMU `-machine virt -bios none` at 0x80000000 in M-mode; reports over the
// 16550 UART at 0x10000000. PASS requires SHA256-OK + RNG-OK + BEARSSL-SMOKE-OK.

import "kernel/core/mmio_console.mc"; // put_str / put_dec (bare-UART M-mode console)

// Vendored BearSSL (third_party, linked separately). br_sha256_update is a HEADER MACRO
// -> the real linked symbol is br_sha224_update (init/out are real functions).
extern fn br_sha256_init(ctx: usize) -> void;
extern fn br_sha224_update(ctx: usize, data: usize, len: usize) -> void;
extern fn br_sha256_out(ctx: usize, out: usize) -> void;

// Shared virtio-rng driver (kernel/drivers/virtio/virtio_rng.c, linked separately).
extern fn vrng_find() -> usize;
extern fn vrng_init(rng: usize) -> u32;
extern fn vrng_fill(rng: usize, buf: usize, n: u32) -> u32;

// Build epoch, threaded in by the harness as a generated MC fn (replaces -DMC_BUILD_EPOCH).
extern fn mc_build_epoch_fn() -> u64;

global sha256_abc: [32]u8;   // expected SHA256("abc"), filled at runtime
global digest: [32]u8;
global sha_ctx: [128]u8;     // >= sizeof(br_sha256_context) = 112
global rng_a: [16]u8;
global rng_b: [16]u8;

const UART_BASE: usize = 0x10000000;
const CLINT_MTIME: usize = 0x0200BFF8;
const FINISHER: usize = 0x00100000;

// Monotonic ticks from the CLINT mtime counter (QEMU virt: 10 MHz). The shared
// virtio_rng.c links against this symbol.
export fn mc_read_ticks() -> u64 {
    var t: u64 = 0;
    unsafe { t = raw.load<u64>(phys(CLINT_MTIME)); }
    return t;
}

fn putc_(c: u8) -> void {
    unsafe { raw.store<u8>(phys(UART_BASE), c); }
}
fn hex_digit(n: u8) -> u8 {
    if n < 10 { return 48 + n; }   // '0'..'9'
    return 87 + n;                 // 'a'..'f'
}
fn puthex8(b: u8) -> void {
    putc_(hex_digit((b >> 4) & 0xF));
    putc_(hex_digit(b & 0xF));
}
fn print_hex_addr(p: usize, n: usize) -> void {
    var i: usize = 0;
    while i < n {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(p + i)); }
        puthex8(b);
        i = i + 1;
    }
}

fn fill_expected() -> void {
    sha256_abc[0] = 0xba;  sha256_abc[1] = 0x78;  sha256_abc[2] = 0x16;  sha256_abc[3] = 0xbf;
    sha256_abc[4] = 0x8f;  sha256_abc[5] = 0x01;  sha256_abc[6] = 0xcf;  sha256_abc[7] = 0xea;
    sha256_abc[8] = 0x41;  sha256_abc[9] = 0x41;  sha256_abc[10] = 0x40; sha256_abc[11] = 0xde;
    sha256_abc[12] = 0x5d; sha256_abc[13] = 0xae; sha256_abc[14] = 0x22; sha256_abc[15] = 0x23;
    sha256_abc[16] = 0xb0; sha256_abc[17] = 0x03; sha256_abc[18] = 0x61; sha256_abc[19] = 0xa3;
    sha256_abc[20] = 0x96; sha256_abc[21] = 0x17; sha256_abc[22] = 0x7a; sha256_abc[23] = 0x9c;
    sha256_abc[24] = 0xb4; sha256_abc[25] = 0x10; sha256_abc[26] = 0xff; sha256_abc[27] = 0x61;
    sha256_abc[28] = 0xf2; sha256_abc[29] = 0x00; sha256_abc[30] = 0x15; sha256_abc[31] = 0xad;
}

export fn test_main() -> void {
    put_str("bearssl-smoke booting\n");
    put_str("BUILD-EPOCH=");
    put_dec(mc_build_epoch_fn());
    putc_(10);

    fill_expected();
    var sha_ok: u32 = 0;
    var rng_ok: u32 = 0;

    // (1) SHA-256 via BearSSL, checked against the known vector.
    let ctx_addr: usize = (&sha_ctx[0]) as usize;
    let dig_addr: usize = (&digest[0]) as usize;
    let abc: *const u8 = "abc";
    br_sha256_init(ctx_addr);
    br_sha224_update(ctx_addr, abc as usize, 3);
    br_sha256_out(ctx_addr, dig_addr);
    put_str("SHA256(abc)=");
    print_hex_addr(dig_addr, 32);
    putc_(10);
    var matched: u32 = 1;
    var i: usize = 0;
    while i < 32 {
        if digest[i] != sha256_abc[i] { matched = 0; }
        i = i + 1;
    }
    if matched == 1 {
        sha_ok = 1;
        put_str("SHA256-OK\n");
    } else {
        put_str("SHA256-MISMATCH\n");
    }

    // (2) live entropy via the virtio-rng device, two differing reads.
    let rng: usize = vrng_find();
    if rng == 0 {
        put_str("RNG-NODEV\n");
    } else {
        if vrng_init(rng) == 0 {
            put_str("RNG-INIT-FAILED\n");
        } else {
            let a_addr: usize = (&rng_a[0]) as usize;
            let b_addr: usize = (&rng_b[0]) as usize;
            let na: u32 = vrng_fill(rng, a_addr, 16);
            let nb: u32 = vrng_fill(rng, b_addr, 16);
            put_str("RNG1=");
            print_hex_addr(a_addr, 16);
            putc_(10);
            put_str("RNG2=");
            print_hex_addr(b_addr, 16);
            putc_(10);

            var a_nonzero: u32 = 0;
            var b_nonzero: u32 = 0;
            var differ: u32 = 0;
            var j: usize = 0;
            while j < 16 {
                if rng_a[j] != 0 { a_nonzero = 1; }
                if rng_b[j] != 0 { b_nonzero = 1; }
                if rng_a[j] != rng_b[j] { differ = 1; }
                j = j + 1;
            }
            if na >= 16 && nb >= 16 && a_nonzero == 1 && b_nonzero == 1 && differ == 1 {
                rng_ok = 1;
                put_str("RNG-OK\n");
            } else {
                put_str("RNG-BAD\n");
            }
        }
    }

    if sha_ok == 1 && rng_ok == 1 {
        put_str("BEARSSL-SMOKE-OK\n");
    } else {
        put_str("BEARSSL-SMOKE-FAILED\n");
    }

    unsafe { raw.store<u32>(phys(FINISHER), 0x5555); }
    while true { }
}

// QEMU enters here in M-mode at the image base; set up the stack and jump in.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
