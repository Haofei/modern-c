// Exercises the generic heap-backed `std/collections/hashmap` (`StrHashMap<V>`) at a concrete
// value type (u32): insert past several grows (forcing rehash), look up every key, overwrite a
// key, probe collisions, confirm absent keys miss, and free. The hashmap-test driver calls the
// exported wrappers. Keys are 4-byte views (`mem.as_bytes`) of distinct u32s held in a persistent
// array, so the BORROWED key bytes stay alive for the map's whole lifetime (interned-key style).
// The malloc-backed allocator binds wrapper symbols (mc_malloc/mc_free over real malloc/free) so
// libc `malloc`'s prototype is never redeclared (-Werror prototype conflict).
import "std/collections/hashmap.mc";
import "std/addr.mc";
import "std/alloc/alloc.mc";
import "std/mem.mc";

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

// Insert n keys (each a 4-byte view of a distinct u32), value = 2*i + 1. Forcing many grows for
// large n. Then overwrite key 0's value to 99, verify every key reads back and `contains`, and
// that len == n. Returns the sum of the (post-overwrite) fetched values.
//   sum = sum_{i in 0..n} (2i+1) = n*n ; overwriting key 0 (1 -> 99) gives n*n + 98 for n > 0.
export fn hashmap_sum(n: u32) -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var map: StrHashMap<u32> = strmap_new(u32, &m);
    var keys: [512]u32 = uninit; // persistent key storage: borrowed keys must outlive the map
    var i: u32 = 0;
    while i < n {
        keys[i as usize] = i * 7 + 3; // spread the low key bytes so probe chains vary
        let k: []const u8 = mem.as_bytes(&keys[i as usize]);
        strmap_put(u32, &map, k, 2 * i + 1);
        i = i + 1;
    }
    if n > 0 {
        let k0: []const u8 = mem.as_bytes(&keys[0]);
        strmap_put(u32, &map, k0, 99); // overwrite: len must NOT change
    }
    var sum: u32 = 0;
    var j: u32 = 0;
    while j < n {
        let kj: []const u8 = mem.as_bytes(&keys[j as usize]);
        if let vp = strmap_get(u32, &map, kj) {
            sum = sum + *vp; // deref the in-slot value pointer
        } else {
            unreachable; // every inserted key must be found
        }
        if !strmap_contains(u32, &map, kj) {
            unreachable; // contains must agree with get
        }
        j = j + 1;
    }
    if strmap_len(u32, &map) != (n as usize) {
        unreachable; // overwrite must not inflate the length
    }
    strmap_free(u32, &map);
    return sum;
}

// Absent-key behaviour: `contains` false and `get` null for a key never inserted, and both true
// for one that was. Returns a checksum: present-contains(+1) + absent-contains(+10) + get(+5) +
// absent-get-else(+100) = 116.
export fn hashmap_absent() -> u32 {
    var m: MallocAlloc = .{ .count = 0 };
    var map: StrHashMap<u32> = strmap_new(u32, &m);
    var a: u32 = 111;
    var b: u32 = 222;
    let ka: []const u8 = mem.as_bytes(&a);
    let kb: []const u8 = mem.as_bytes(&b);
    strmap_put(u32, &map, ka, 5);
    var r: u32 = 0;
    if strmap_contains(u32, &map, ka) {
        r = r + 1;
    }
    if !strmap_contains(u32, &map, kb) {
        r = r + 10;
    }
    if let vp = strmap_get(u32, &map, ka) {
        r = r + *vp;
    } else {
        r = r + 5000; // ka was inserted; must be found
    }
    if let vp = strmap_get(u32, &map, kb) {
        r = r + *vp + 1000; // kb was never inserted; must not be found
    } else {
        r = r + 100;
    }
    strmap_free(u32, &map);
    return r;
}
