// std/strbuf — `StrBuf`: a growable byte buffer, the `allocPrint`/StringBuilder a
// compiler needs to assemble mangled names and emitted source a byte (or run) at a time.
//
// It is a thin, string-shaped facade over `Vec<u8>` (std/collections/dynarray): the
// buffer *is* a `Vec<u8>`, so it inherits the vec's amortized-O(1) grow (allocate-new
// + copy + free-old over the `Allocator` trait — there is no `realloc`) and its
// ownership contract. `StrBuf` exists so producers say "append this string / this
// decimal / this hex nibble" instead of open-coding the digit arithmetic and the
// `vec_push(u8, ...)` at every call site.
//
// OWNERSHIP: like `Vec<T>`, `StrBuf` is a plain COPYABLE struct, not a linear `move`
// type — so it composes freely. The cost is manual freeing: call `sb_free` exactly
// once when done, and do not copy-then-free-both (that double-frees the backing Vec).
// For the arena / "allocate a batch, free together" pattern the backing allocator
// reclaims everything at once and `sb_free` is a no-op you may skip.
//
// The allocator is stored in the backing Vec (its provenance); it is borrowed and must
// outlive the StrBuf. See docs/self-host.md (§1) §3 step 0.3.
//
// READING BACK: use `sb_byte(sb, i)` (bounds-checked) or iterate `0..sb_len(sb)`.
// There is deliberately no `sb_as_slice` returning `[]const u8`: MC has no way to
// construct a slice from a raw pointer + runtime length (the backing store is a
// `PAddr`, and neither pointer-slicing nor a slice struct-literal is accepted by the
// front end), so a byte-at-a-time reader is the honest interface. See the module's
// gate (tests/toolchain/strbuf_user.mc) for the checksum-based consumption pattern.

import "std/collections/dynarray.mc";
import "std/addr.mc";

pub struct StrBuf {
    v: Vec<u8>,                // backing byte storage (owns the allocation)
}

// A fresh empty buffer bound to allocator `a`. No allocation happens until the first put.
pub fn sb_new(a: *mut dyn Allocator) -> StrBuf {
    return .{ .v = vec_new(u8, a) };
}

// Number of bytes appended so far.
pub fn sb_len(sb: *StrBuf) -> usize {
    return vec_len(u8, &sb.v);
}

// The byte at `i` (bounds-checked: out of range traps). The read-back primitive.
pub fn sb_byte(sb: *StrBuf, i: usize) -> u8 {
    return vec_get(u8, &sb.v, i);
}

// The address of the contiguous backing bytes (pa(0) while nothing has been
// appended). Paired with `sb_len`, this lets a hosted caller flush the whole
// buffer in ONE `io_write` instead of one syscall per byte.
pub fn sb_ptr(sb: *StrBuf) -> PAddr {
    return sb.v.data;
}

// Append one byte, growing storage if full. Amortized O(1).
pub fn sb_put_byte(sb: *mut StrBuf, b: u8) -> void {
    vec_push(u8, &sb.v, b);
}

// Append the bytes of `s` (a `[]const u8`) in order.
pub fn sb_put_str(sb: *mut StrBuf, s: []const u8) -> void {
    var i: usize = 0;
    while i < s.len {
        vec_push(u8, &sb.v, s[i]);
        i = i + 1;
    }
}

// Append the bytes of a NUL-terminated C string `s` (a `*const u8`), stopping at (and not
// copying) the terminating 0. This is the emitter's workhorse: MC string literals lower to
// `*const u8`, NOT `[]const u8` (self-host gap G12), so `sb_put_str("...")` will not compile;
// `sb_put_cstr(sb, "...")` does. Reads a byte at a time via `raw.load<u8>` off the pointer's
// address (the same raw-boundary pattern as std/libc `mc_strlen`).
pub fn sb_put_cstr(sb: *mut StrBuf, s: *const u8) -> void {
    let base: PAddr = pa(s as usize);
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe {
            b = raw.load<u8>(pa_offset(base, i));
        }
        if b == 0 {
            break;
        }
        vec_push(u8, &sb.v, b);
        i = i + 1;
    }
}

// Append `n` in decimal (no leading zeros; "0" for zero).
pub fn sb_put_u32(sb: *mut StrBuf, n: u32) -> void {
    if n == 0 {
        vec_push(u8, &sb.v, 48); // '0'
        return;
    }
    // 10 digits is enough for any u32 (max 4294967295). Fill least-significant first.
    var buf: [10]u8 = .{ 0,0,0,0,0,0,0,0,0,0 };
    var m: u32 = n;
    var i: usize = 0;
    while m > 0 {
        let d: u32 = m % 10;
        buf[i] = (48 + d) as u8; // '0' + digit
        m = m / 10;
        i = i + 1;
    }
    // Emit most-significant digit first.
    while i > 0 {
        i = i - 1;
        vec_push(u8, &sb.v, buf[i]);
    }
}

// Append `n` as `0x` + 8 fixed-width lowercase hex nibbles, most significant first.
pub fn sb_put_hex_u32(sb: *mut StrBuf, n: u32) -> void {
    vec_push(u8, &sb.v, 48);  // '0'
    vec_push(u8, &sb.v, 120); // 'x'
    var s: i32 = 28; // top nibble shift for a 32-bit value
    while s >= 0 {
        let nib: u32 = (n >> (s as u32)) & 0xF;
        if nib < 10 {
            vec_push(u8, &sb.v, (48 + nib) as u8);  // '0'..'9'
        } else {
            vec_push(u8, &sb.v, (87 + nib) as u8);  // 'a'..'f' ('a' == 97 == 87 + 10)
        }
        s = s - 4;
    }
}

// Release the backing storage. Call exactly once; the buffer becomes empty and may be
// reused (a subsequent put re-allocates). A no-op when nothing is allocated.
pub fn sb_free(sb: *mut StrBuf) -> void {
    vec_free(u8, &sb.v);
}
