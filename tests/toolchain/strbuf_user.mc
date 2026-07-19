// Exercises the growable `std/strbuf` (`StrBuf`, built on `Vec<u8>`) at its full API:
// put_str/put_byte/put_u32/put_hex_u32 past several grows, read-back via sb_byte, and
// free+reuse. The strbuf-test driver calls the exported wrappers and checks the exact
// bytes. The malloc-backed allocator binds wrapper symbols (mc_malloc/mc_free over real
// malloc/free) so libc `malloc`'s prototype is never redeclared.
import "std/strbuf.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";

extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;
// The driver returns a `[]const u8` over a static "N=" so sb_put_str is exercised with a
// genuine slice. (MC's own ways to mint a `[]const u8` locally do not lower on the C
// backend — string-literal-to-slice and array-slice-view both fail; see findings — so an
// a backend-private extern returning a slice, as in tests/llvm/slices.mc, supplies the fixture.)
// This is a backend-private MC declaration implemented by the C-only test driver;
// it is deliberately not an `extern "C"` stable-ABI declaration.
extern fn sb_label() -> []const u8;

struct MallocAlloc {
    count: u32, // allocations served (also keeps `self` used)
}

impl Allocator for MallocAlloc {
    fn alloc(self: *mut MallocAlloc, size: usize, align: usize) -> PAddr {
        if align == 0 { unreachable; } // align is a power of two (>= 1)
        self.count = self.count + 1;
        return pa(mc_malloc(size));
    }
    fn free(self: *mut MallocAlloc, addr: PAddr, size: usize) -> void {
        if self.count == 0 { unreachable; } // free before any alloc
        mc_free(pa_value(addr), size);
    }
}

// Build the canonical demo string into `sb`:
//   "N=" + u32(4294967295) + " " + hex(0xDEADBEEF) + u32(0)
// == "N=4294967295 0xdeadbeef0" (24 bytes), forcing several vec grows from cap 4.
fn build(sb: *mut StrBuf) -> void {
    let label: []const u8 = sb_label(); // "N=" (driver-provided slice)
    sb_put_str(sb, label);
    sb_put_u32(sb, 4294967295); // u32 max -> "4294967295"
    sb_put_byte(sb, 32);        // ' '
    sb_put_hex_u32(sb, 3735928559); // 0xDEADBEEF -> "0xdeadbeef"
    sb_put_u32(sb, 0);          // "0"
}

// Length of the canonical string (must be 24).
export fn strbuf_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var sb: StrBuf = sb_new(&m);
    build(&sb);
    let n: usize = sb_len(&sb);
    sb_free(&sb);
    return n as u32;
}

// Byte `i` of the canonical string (bounds-checked in sb_byte).
export fn strbuf_byte(i: u32) -> u8 {
    var m: MallocAlloc = .{ .count = 0 };
    var sb: StrBuf = sb_new(&m);
    build(&sb);
    let b: u8 = sb_byte(&sb, i as usize);
    sb_free(&sb);
    return b;
}

// Weighted checksum: sum over i of byte[i] * (i+1). The canonical string is 24 ASCII
// bytes, so the sum stays well under u32 (no overflow trap). Also exercises free+reuse:
// build, checksum, free, then build again and checksum — both must agree, proving the
// buffer is reusable after free.
export fn strbuf_checksum() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var sb: StrBuf = sb_new(&m);
    build(&sb);
    var sum: u32 = 0;
    var i: usize = 0;
    while i < sb_len(&sb) {
        let b: u32 = sb_byte(&sb, i) as u32;
        sum = sum + b * ((i as u32) + 1);
        i = i + 1;
    }
    sb_free(&sb);
    // free+reuse: build the same string again on the emptied buffer.
    build(&sb);
    var sum2: u32 = 0;
    var j: usize = 0;
    while j < sb_len(&sb) {
        let b2: u32 = sb_byte(&sb, j) as u32;
        sum2 = sum2 + b2 * ((j as u32) + 1);
        j = j + 1;
    }
    sb_free(&sb);
    if sum != sum2 {
        return 0; // reuse mismatch -> driver's non-zero expectation fails
    }
    return sum;
}

// Exercise sb_put_cstr: append a NUL-terminated string literal (a `*const u8`) directly.
// "uint32_t" is 8 bytes; the driver checks the length and exact bytes. This is the exact
// pattern the C emitter relies on (fixed C fragments come in as string literals).
export fn strbuf_cstr_len() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var sb: StrBuf = sb_new(&m);
    sb_put_cstr(&sb, "uint32_t");
    let n: usize = sb_len(&sb);
    sb_free(&sb);
    return n as u32;
}

// Byte `i` of the sb_put_cstr("uint32_t") result.
export fn strbuf_cstr_byte(i: u32) -> u8 {
    var m: MallocAlloc = .{ .count = 0 };
    var sb: StrBuf = sb_new(&m);
    sb_put_cstr(&sb, "uint32_t");
    let b: u8 = sb_byte(&sb, i as usize);
    sb_free(&sb);
    return b;
}
