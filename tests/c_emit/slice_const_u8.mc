// Differential-coverage fixture (language gap G12: `[]const u8` slice holes).
// Both backends must agree on the fat-pointer slice representation (`{ptr,len}`) for:
//   1. a STRING LITERAL lowered to a `[]const u8` slice value (ptr = the static C string
//      literal, len = decoded byte length), observed through `.len` and indexing;
//   2. a `[]mut u8` -> `[]const u8` const-narrowing coercion (safe: the fat pointer is
//      layout-identical, only the pointee's constness differs) at a `let`, at a call
//      argument, and via an explicit `as` cast.
// The entry folds every observation into a status word; any divergence on EITHER backend
// (or a regression on the string-literal / const-narrow lowering) makes it return 0.

fn len_of(s: []const u8) -> u32 {
    return s.len as u32;
}

fn first_of(s: []const u8) -> u32 {
    return s[0] as u32;
}

export fn slice_const_run() -> u32 {
    // (1) String-literal `[]const u8`: `.len` + indexing end-to-end.
    let msg: []const u8 = "abc";
    if msg.len != 3 { return 0; }
    if (msg[0] as u32) != 97 { return 0; }   // 'a'
    if (msg[2] as u32) != 99 { return 0; }   // 'c'
    if len_of(msg) != 3 { return 0; }        // string-literal slice passed by value
    if first_of(msg) != 97 { return 0; }

    // (2) `[]mut u8` -> `[]const u8` const-narrowing.
    var buf: [4]u8 = .{ 5, 6, 0, 0 };
    let n: usize = 4;
    let m: []mut u8 = buf[0..n];
    let c1: []const u8 = m;                   // implicit coercion (let)
    let c2: []const u8 = m as []const u8;     // explicit `as` coercion
    if c1.len != 4 { return 0; }
    if (c1[0] as u32) != 5 { return 0; }
    if (c2[1] as u32) != 6 { return 0; }
    if len_of(m) != 4 { return 0; }           // implicit coercion at a call argument
    if first_of(m) != 5 { return 0; }

    return 1;
}
