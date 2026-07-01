// Focused differential test for the compiler-internal ADDRESSABLE, RUNTIME-SELECTED union
// primitive (`#[c_union]`) — the prerequisite for the async future-union optimization
// (docs/performance-refactor-plan.md §3.5).
//
// A `#[c_union]` is laid out as a real C `union` (all arms at offset 0; size = LARGEST arm,
// not the sum), so `&value.arm` yields a stable, in-place, alias-safe pointer to the shared
// storage reinterpreted as that arm's type — exactly what a stackless async state machine
// needs for `&self.<child>` across suspensions. The C backend emits a real `union` member
// access (the canonical strict-aliasing exception); the LLVM backend emits an
// alignment-carrying storage array whose arm access is the union pointer itself (offset 0).
//
// This entry proves, on BOTH backends:
//   * build into each arm, take its ADDRESS, and access fields through the pointer;
//   * mutate through the pointer ACROSS a "suspend" (an opaque store/reload barrier) and
//     read the value back byte-exact via a FRESH access to the same arm;
//   * the union is sized to the LARGEST arm (shared storage), not the sum (the win);
//   * runtime arm SELECTION (a `which` branch) picks among statically-named arms — the
//     shape the async state machine uses, with `state` as the selector.

struct ArmA {
    tag: u8,
    a: u64,
    b: u32,
}

struct ArmB {
    x: u16,
    y: u16,
}

#[c_union]
struct Slot {
    a: ArmA,
    b: ArmB,
    c: u32,
}

// A suspension barrier: force the union storage through memory (identity read+write of the
// first word) so the optimizer cannot keep everything in registers — models a state-machine
// suspend/resume where `&self.child` must survive across the yield. Byte-preserving.
fn suspend_barrier(p: *mut Slot) -> void {
    let word: u32 = p.c;
    p.c = word;
}

// which=0: struct arm A (largest). which=1: struct arm B. which=2: scalar arm.
fn build_and_check(which: u32) -> u32 {
    var s: Slot = uninit;
    if which == 0 {
        let pa: *mut ArmA = &s.a;
        pa.tag = 0x5A;
        pa.a = 0xDEADBEEFCAFE1234;
        pa.b = 0x11223344;
        suspend_barrier(&s);
        // Reload via a FRESH access to the same arm — the pointer/storage is stable.
        let ra: *mut ArmA = &s.a;
        if ra.tag != 0x5A { return 0; }
        if ra.a != 0xDEADBEEFCAFE1234 { return 0; }
        if ra.b != 0x11223344 { return 0; }
        // Mutate through the pointer across another suspend, then re-read.
        ra.a = ra.a + 1;
        suspend_barrier(&s);
        if s.a.a != 0xDEADBEEFCAFE1235 { return 0; }
        if s.a.tag != 0x5A { return 0; }
        return 1;
    }
    if which == 1 {
        let pb: *mut ArmB = &s.b;
        pb.x = 0xBEEF;
        pb.y = 0xF00D;
        suspend_barrier(&s);
        let rb: *mut ArmB = &s.b;
        if rb.x != 0xBEEF { return 0; }
        if rb.y != 0xF00D { return 0; }
        rb.x = 0x1357;
        suspend_barrier(&s);
        if s.b.x != 0x1357 { return 0; }
        if s.b.y != 0xF00D { return 0; }
        return 1;
    }
    let pc: *mut u32 = &s.c;
    pc.* = 0x99887766;
    suspend_barrier(&s);
    if s.c != 0x99887766 { return 0; }
    let rc: *mut u32 = &s.c;
    rc.* = rc.* + 1;
    suspend_barrier(&s);
    if s.c != 0x99887767 { return 0; }
    return 1;
}

// The layout win: a union is sized to the largest arm and the max alignment — NOT the sum of
// the arms. This is the property that shrinks the async future struct.
fn size_check() -> u32 {
    if sizeof(Slot) != sizeof(ArmA) { return 0; }
    if sizeof(Slot) != 24 { return 0; }
    if alignof(Slot) != 8 { return 0; }
    if field_offset(Slot, .a) != 0 { return 0; }
    if field_offset(Slot, .b) != 0 { return 0; }
    if field_offset(Slot, .c) != 0 { return 0; }
    return 1;
}

export fn c_union_run() -> u32 {
    if build_and_check(0) != 1 { return 0; }
    if build_and_check(1) != 1 { return 0; }
    if build_and_check(2) != 1 { return 0; }
    if size_check() != 1 { return 0; }
    return 1;
}
