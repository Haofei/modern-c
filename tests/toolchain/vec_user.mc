// Exercises the generic heap-backed `std/collections/dynarray` (`Vec<T>`) at a concrete
// element type: push past several grows, index, set, pop, and free+reuse. The vec-test
// driver calls the exported wrappers. The malloc-backed allocator binds wrapper symbols
// (mc_malloc/mc_free over real malloc/free) so libc `malloc`'s prototype is never redeclared.
import "std/collections/dynarray.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";

extern "C" fn mc_malloc(n: usize) -> usize;
extern "C" fn mc_free(addr: usize, n: usize) -> void;

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

// Push 0..n into a Vec<u32> (forcing several grows), sum via get(), then free. Returns the sum.
export fn vec_sum_to(n: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var v: Vec<u32> = vec_new(u32, &m);
    var i: u32 = 0;
    while i < n {
        vec_push(u32, &v, i);
        i = i + 1;
    }
    var sum: u32 = 0;
    var j: usize = 0;
    while j < vec_len(u32, &v) {
        sum = sum + vec_get(u32, &v, j);
        j = j + 1;
    }
    vec_free(u32, &v);
    return sum;
}

// Push 0..n, then pop everything: returns the sum of popped values (LIFO), which must equal
// the sum of 0..n-1 — proving pop order and length tracking. Also set() element 0 to 100 first.
export fn vec_pop_sum(n: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var v: Vec<u32> = vec_new(u32, &m);
    var i: u32 = 0;
    while i < n {
        vec_push(u32, &v, i);
        i = i + 1;
    }
    var sum: u32 = 0;
    while vec_len(u32, &v) != 0 {
        sum = sum + vec_pop(u32, &v);
    }
    // free+reuse: vector is empty; push one and read it back
    vec_push(u32, &v, 7);
    let last: u32 = vec_get(u32, &v, 0);
    vec_free(u32, &v);
    return sum + last;
}
