// selfhost_commaswitch_user — the behavioral unit for selfhost-semaself-test. It exercises the two
// language features that had to land for mcc2 to compile its OWN sema module (selfhost/sema.mc):
//
//   1. COMMA-LESS block switch arms — real MC (and mcc2's own source) omits the separator comma
//      after a `}`-block-bodied arm (`.a => { .. } .b => { .. }`); mcc2's parser now accepts that
//      (an optional comma, matching src/parser.zig). `color_code` uses the comma-less form.
//
//   2. A `StrHashMap<V>` over a STRUCT value V — the hashmap stores `Entry<V>` with a struct V, so
//      the struct-type-argument monomorphization had to reach the `Entry<struct>` typedef induced by
//      the generic `slot_ptr`/`strmap_*` functions (never written as a concrete `Entry<Rec>`), plus
//      the `mem.bytes_equal` builtin lowering. `map_sum` round-trips struct values through the map.
//
// A C driver (in the gate) links these and asserts the results AT RUNTIME under `clang -Werror`.

import "std/collections/hashmap.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";

extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;

// A malloc-backed allocator (same shape as the other selfhost units).
struct MallocAlloc {
    count: u32,
}

impl Allocator for MallocAlloc {
    fn alloc(self: *mut MallocAlloc, size: usize, align: usize) -> PAddr {
        if align == 0 { unreachable; }
        self.count = self.count + 1;
        return pa(mc_malloc(size));
    }
    fn free(self: *mut MallocAlloc, addr: PAddr, size: usize) -> void {
        if self.count == 0 { unreachable; }
        mc_free(pa_value(addr), size);
    }
}

// A closed enum switched over with COMMA-LESS block arms.
enum Color {
    red,
    green,
    blue,
}

// COMMA-LESS block switch arms: note there is NO comma after each `}` arm.
export fn color_code(c: Color) -> u32 {
    var out: u32 = 0;
    switch c {
        .red => { out = 1; }
        .green => { out = 2; }
        .blue => { out = 3; }
    }
    return out;
}

// A STRUCT value type stored in a StrHashMap.
struct Rec {
    a: u32,
    b: u32,
}

// Round-trip struct values through a `StrHashMap<Rec>` (string keys are program-lifetime `[]const u8`
// literals). Expected: (5+7) + (10+20) = 42.
export fn map_sum() -> u32 {
    var al: MallocAlloc = .{ .count = 0 };
    var m: StrHashMap<Rec> = strmap_new(Rec, &al);
    strmap_put(Rec, &m, "alpha", .{ .a = 5, .b = 7 });
    strmap_put(Rec, &m, "beta", .{ .a = 10, .b = 20 });
    let fb: Rec = .{ .a = 0, .b = 0 };
    let r1: Rec = strmap_get_or(Rec, &m, "alpha", fb);
    let r2: Rec = strmap_get_or(Rec, &m, "beta", fb);
    let out: u32 = r1.a + r1.b + r2.a + r2.b;
    strmap_free(Rec, &m);
    return out;
}

// Prove absence returns the fallback (a struct value): the missing key yields fb -> 0.
export fn map_missing() -> u32 {
    var al: MallocAlloc = .{ .count = 0 };
    var m: StrHashMap<Rec> = strmap_new(Rec, &al);
    strmap_put(Rec, &m, "present", .{ .a = 99, .b = 1 });
    let fb: Rec = .{ .a = 7, .b = 0 };
    let r: Rec = strmap_get_or(Rec, &m, "absent", fb);
    strmap_free(Rec, &m);
    return r.a + r.b;
}
