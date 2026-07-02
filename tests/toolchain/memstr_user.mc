// Exercises the allocation-free byte-slice string ops in `std/mem` (mem_eql,
// mem_starts_with, mem_index_of_byte, mem_index_of, split_by/split_next) at concrete
// inputs. Byte-slice inputs are built from local `[N]u8` arrays via the compiler-
// recognized `mem.as_bytes(&buf)` byte view — string literals lower to a C `*const u8`
// (a pointer, NOT a `[]const u8`), so they cannot seed a slice. Every wrapper is
// nullary and deterministic; the memstr-test driver asserts the exact return values.
//
// The byte searches return a value optional `?usize`, consumed here with `if let`
// (absent -> 0). The cursor splitter still yields a `SplitField` struct because a
// slice value optional (`?[]const u8`) is not yet an accepted consumer form (only
// scalar/address/bool payloads are — see the note in std/mem.mc).
import "std/mem.mc";

// ----- mem_eql -----

export fn mstr_eql_same() -> u32 {
    var a: [3]u8 = .{ 102, 111, 111 }; // "foo"
    var b: [3]u8 = .{ 102, 111, 111 }; // "foo"
    let sa: []const u8 = mem.as_bytes(&a);
    let sb: []const u8 = mem.as_bytes(&b);
    if mem_eql(sa, sb) { return 1; }
    return 0;
}

export fn mstr_eql_diff() -> u32 {
    var a: [3]u8 = .{ 102, 111, 111 }; // "foo"
    var c: [3]u8 = .{ 102, 111, 120 }; // "fox"
    let sa: []const u8 = mem.as_bytes(&a);
    let sc: []const u8 = mem.as_bytes(&c);
    if mem_eql(sa, sc) { return 1; }
    return 0;
}

export fn mstr_eql_difflen() -> u32 {
    var a: [3]u8 = .{ 102, 111, 111 };           // "foo"
    var d: [6]u8 = .{ 102, 111, 111, 98, 97, 114 }; // "foobar"
    let sa: []const u8 = mem.as_bytes(&a);
    let sd: []const u8 = mem.as_bytes(&d);
    if mem_eql(sa, sd) { return 1; }
    return 0;
}

// ----- mem_starts_with -----

export fn mstr_starts_yes() -> u32 {
    var h: [6]u8 = .{ 102, 111, 111, 98, 97, 114 }; // "foobar"
    var p: [3]u8 = .{ 102, 111, 111 };              // "foo"
    let sh: []const u8 = mem.as_bytes(&h);
    let sp: []const u8 = mem.as_bytes(&p);
    if mem_starts_with(sh, sp) { return 1; }
    return 0;
}

export fn mstr_starts_no() -> u32 {
    var h: [6]u8 = .{ 102, 111, 111, 98, 97, 114 }; // "foobar"
    var p: [3]u8 = .{ 98, 97, 114 };                // "bar"
    let sh: []const u8 = mem.as_bytes(&h);
    let sp: []const u8 = mem.as_bytes(&p);
    if mem_starts_with(sh, sp) { return 1; }
    return 0;
}

// prefix longer than the haystack is never a match
export fn mstr_starts_too_long() -> u32 {
    var h: [3]u8 = .{ 102, 111, 111 };              // "foo"
    var p: [6]u8 = .{ 102, 111, 111, 98, 97, 114 }; // "foobar"
    let sh: []const u8 = mem.as_bytes(&h);
    let sp: []const u8 = mem.as_bytes(&p);
    if mem_starts_with(sh, sp) { return 1; }
    return 0;
}

// ----- mem_index_of_byte -----  (present -> 1000+index, absent -> 0)

export fn mstr_index_byte_present() -> u32 {
    var buf: [3]u8 = .{ 97, 44, 98 }; // "a,b"
    let s: []const u8 = mem.as_bytes(&buf);
    if let idx = mem_index_of_byte(s, 44) { return 1000 + (idx as u32); } // ','
    return 0;
}

export fn mstr_index_byte_absent() -> u32 {
    var buf: [3]u8 = .{ 97, 44, 98 }; // "a,b"
    let s: []const u8 = mem.as_bytes(&buf);
    if let idx = mem_index_of_byte(s, 122) { return 1000 + (idx as u32); } // 'z'
    return 0;
}

// ----- mem_index_of -----  (present -> 1000+index, absent -> 0)

export fn mstr_index_of_present() -> u32 {
    var buf: [5]u8 = .{ 97, 98, 99, 98, 99 }; // "abcbc"
    var nd: [2]u8 = .{ 98, 99 };              // "bc"
    let s: []const u8 = mem.as_bytes(&buf);
    let n: []const u8 = mem.as_bytes(&nd);
    if let idx = mem_index_of(s, n) { return 1000 + (idx as u32); }
    return 0;
}

export fn mstr_index_of_absent() -> u32 {
    var buf: [5]u8 = .{ 97, 98, 99, 98, 99 }; // "abcbc"
    var nd: [2]u8 = .{ 120, 121 };            // "xy"
    let s: []const u8 = mem.as_bytes(&buf);
    let n: []const u8 = mem.as_bytes(&nd);
    if let idx = mem_index_of(s, n) { return 1000 + (idx as u32); }
    return 0;
}

// A zero-length view of `v`. Sub-slicing must go through a `[]const u8` PARAMETER: the
// C emitter cannot recover the source type of a re-sliced `mem.as_bytes()` local
// (exprSourceTypeForEmission -> null -> UnsupportedCEmission), but a param slices fine.
fn empty_view(v: []const u8) -> []const u8 {
    return v[0..0];
}

// empty needle matches at 0
export fn mstr_index_of_empty() -> u32 {
    var buf: [3]u8 = .{ 97, 98, 99 }; // "abc"
    var nd: [3]u8 = .{ 0, 0, 0 };
    let s: []const u8 = mem.as_bytes(&buf);
    let empty: []const u8 = empty_view(mem.as_bytes(&nd));
    if let idx = mem_index_of(s, empty) { return 1000 + (idx as u32); }
    return 0;
}

// ----- split_by / split_next -----

// "a,bb,ccc" -> 3 fields of len 1,2,3. Returns count*100 + sum(len) = 306.
export fn mstr_split_encoded() -> u32 {
    var buf: [8]u8 = .{ 97, 44, 98, 98, 44, 99, 99, 99 };
    let s: []const u8 = mem.as_bytes(&buf);
    var sp: Split = split_by(s, 44); // ','
    var count: u32 = 0;
    var sumlen: u32 = 0;
    var f: SplitField = split_next(&sp);
    while f.valid {
        count = count + 1;
        sumlen = sumlen + (f.s.len as u32);
        f = split_next(&sp);
    }
    return count * 100 + sumlen;
}

// "a,,c" -> 3 fields of len 1,0,1 (empty middle field kept). Returns 302.
export fn mstr_split_empty_field() -> u32 {
    var buf: [4]u8 = .{ 97, 44, 44, 99 };
    let s: []const u8 = mem.as_bytes(&buf);
    var sp: Split = split_by(s, 44);
    var count: u32 = 0;
    var sumlen: u32 = 0;
    var f: SplitField = split_next(&sp);
    while f.valid {
        count = count + 1;
        sumlen = sumlen + (f.s.len as u32);
        f = split_next(&sp);
    }
    return count * 100 + sumlen;
}

// The second field of "a,bb,ccc" borrows the correct bytes -> equals "bb". Returns 1.
export fn mstr_split_field_bytes() -> u32 {
    var buf: [8]u8 = .{ 97, 44, 98, 98, 44, 99, 99, 99 };
    var exp: [2]u8 = .{ 98, 98 }; // "bb"
    let s: []const u8 = mem.as_bytes(&buf);
    let e: []const u8 = mem.as_bytes(&exp);
    var sp: Split = split_by(s, 44);
    let f1: SplitField = split_next(&sp); // "a"
    let f2: SplitField = split_next(&sp); // "bb"
    if !f1.valid { return 0; }
    if !f2.valid { return 0; }
    if mem_eql(f2.s, e) { return 1; }
    return 0;
}
