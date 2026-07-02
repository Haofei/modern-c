// selfhost_genstruct_user — the STRUCT-type-argument monomorphization behavioral unit for
// selfhost-parseself-test. mcc2 gained the ability to monomorphize a generic container/function at a
// NAMED STRUCT type argument (`Vec<Pt>`, `vec_push(Pt, ..)`, `vec_get(Pt, ..)`), not just scalars —
// the feature that lets it compile its own parser's `Vec<Node>`. This program pushes struct elements
// into a `Vec<Pt>`, reads them back, and reads their fields; a C driver (in the gate) links these and
// asserts the results AT RUNTIME (behavior, not just compilation), under `clang -Werror`.

import "std/collections/dynarray.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";

extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;

// A malloc-backed allocator for the vector's backing store (same shape as the other selfhost units).
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

// The STRUCT element type of the generic container. Two scalar fields so the driver can prove a whole
// struct value round-trips through push/get, and that a field read after get works.
struct Pt {
    x: u32,
    y: u32,
}

// Push two `Pt` values into a `Vec<Pt>`, read them back, and sum their fields.
// Expected: (3+4) + (10+20) = 37.
export fn sum_pts() -> u32 {
    var a: MallocAlloc = .{ .count = 0 };
    var v: Vec<Pt> = vec_new(Pt, &a);
    vec_push(Pt, &v, .{ .x = 3, .y = 4 });
    vec_push(Pt, &v, .{ .x = 10, .y = 20 });
    let p0: Pt = vec_get(Pt, &v, 0);
    let p1: Pt = vec_get(Pt, &v, 1);
    let out: u32 = p0.x + p0.y + p1.x + p1.y;
    vec_free(Pt, &v);
    return out;
}

// Prove element COUNT tracks pushes, and that a single field of a struct element read from the vector
// is correct (get returns a full struct value; `.y` is read off it).
export fn second_y(n: u32) -> u32 {
    var a: MallocAlloc = .{ .count = 0 };
    var v: Vec<Pt> = vec_new(Pt, &a);
    vec_push(Pt, &v, .{ .x = 1, .y = n });
    vec_push(Pt, &v, .{ .x = 2, .y = n + n });
    let len: u32 = vec_len(Pt, &v) as u32;
    let p1: Pt = vec_get(Pt, &v, 1);
    let out: u32 = len * 100 + p1.y;
    vec_free(Pt, &v);
    return out;
}
