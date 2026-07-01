// std/collections/hashmap — `StrHashMap<V>`: a heap-backed, string-keyed hash map.
//
// An open-addressing (linear-probing) hash map from a byte-string key (`[]const u8`) to a
// generic value `V`, backed by an `Allocator`. String keys are the compiler's dominant case
// (symbol tables, interning, keyword sets), so v0 is string-keyed only: this sidesteps needing
// `Hash`/`Eq` trait bounds on an arbitrary key type (which MC does not yet express — see the GAP
// note at the bottom of this file). Keys are hashed with FNV-1a over their bytes and compared
// with `mem.bytes_equal` (length + memcmp).
//
// KEY OWNERSHIP: keys are BORROWED. `strmap_put` stores the caller's `[]const u8` slice as-is
// (pointer + length); it does NOT copy the key bytes. The caller guarantees the key bytes stay
// alive for as long as the entry lives. This matches interned-string usage, where every key is
// a slice into a long-lived string arena — copying would defeat the point.
//
// OWNERSHIP: `StrHashMap<V>` is a plain COPYABLE struct (like `Vec<T>`), not a linear `move`
// type, so it composes freely. Freeing is manual: call `strmap_free` exactly once; do not
// copy-then-free-both (double free). `V` must be COPYABLE (rehash does a raw entry copy).
//
// GROWTH MODEL: the `Allocator` trait (std/alloc) exposes only `alloc`/`free` — no `realloc` —
// so growth is allocate-new + rehash + free-old. The table doubles (start 8, then ×2) whenever
// inserting would push the load factor past ~0.75, keeping probe chains short and lookups O(1)
// amortized. See docs/self-host-plan.md §3 step 0.2.
//
// LOOKUP RETURN: `strmap_get` returns `?*mut V` — a pointer into the entry's value slot, or
// `null` when absent — NOT `?V`. MC optionals are pointer-shaped only (a nullable value type
// like `?u32` is `E_IF_LET_OPTIONAL_REQUIRED`; see the GAP note), so the by-value `?V` the plan
// sketches cannot be expressed. The pointer form is strictly more capable (in-place update) and
// is the expressible analog; `strmap_get_or` gives a by-value read with a fallback.
//
// The pointer returned by `strmap_get` is valid until the next insert that triggers a grow
// (which reallocates and rehashes the slot array); do not hold it across a `strmap_put`.
//
// The allocator is stored in the map (its provenance, like `Vec`), so element ops don't
// re-thread it; it is borrowed and must outlive the map.

import "std/addr.mc";
import "std/alloc/alloc.mc";
import "std/mem.mc";

// One probe slot. `used == false` marks an empty slot (the whole slot array is zeroed on
// allocation, so `used` starts false everywhere and `key`/`val` of an empty slot are never read).
// `val` is field 0 deliberately: the slot's base address is then the value's address, so
// `strmap_get` can mint a `*mut V` into the slot with `raw.ptr<V>` (a fresh pointer, not the
// escaping address of a local) rather than `&slot.val` (which trips E_LOCAL_ADDRESS_ESCAPE).
struct Entry<V> {
    val: V,
    key: []const u8, // borrowed key bytes (pointer + length)
    used: bool,
}

struct StrHashMap<V> {
    slots: PAddr,          // array of Entry<V>; pa(0) while cap == 0
    len: usize,            // number of live entries
    cap: usize,            // slot capacity (0 until the first put)
    a: *mut dyn Allocator, // backing allocator (borrowed provenance)
}

// FNV-1a 32-bit multiply step. FNV needs a modulo-2^32 (wrapping) multiply, but MC's `*` is
// checked and would trap on overflow; computing the 32×32 product in 64 bits (which cannot
// overflow u64) and truncating gives the wrap without leaving the checked domain.
const fn fnv1a_mul(h: u32) -> u32 {
    return (((h as u64) * (16777619 as u64)) & 0x0000_0000_FFFF_FFFF) as u32;
}

// FNV-1a byte hash of a key. XOR-then-multiply per byte; XOR never overflows the checked domain.
fn fnv1a(key: []const u8) -> u32 {
    var h: u32 = 2166136261; // FNV offset basis (32-bit)
    var i: usize = 0;
    while i < key.len {
        h = h ^ (key[i] as u32);
        h = fnv1a_mul(h);
        i = i + 1;
    }
    return h;
}

// Typed pointer to slot `idx` of a slot array. The raw mint is the single unsafe site; callers
// then use ordinary field access (`.used`, `.key`, `.val`).
fn slot_ptr(comptime V: type, slots: PAddr, idx: usize) -> *mut Entry<V> {
    var p: *mut Entry<V> = raw.ptr<Entry<V>>(0);
    unsafe {
        p = raw.ptr<Entry<V>>(pa_offset(slots, idx * sizeof(Entry<V>)));
    }
    return p;
}

// Allocate a fresh, zeroed slot array of `cap` entries from the map's allocator. Zeroing sets
// `used == false` in every slot (the empty state) without constructing empty-key slices.
fn strmap_alloc_slots(comptime V: type, m: *mut StrHashMap<V>, cap: usize) -> PAddr {
    let bytes: usize = cap * sizeof(Entry<V>);
    let p: PAddr = alloc_bytes(m.a, bytes, alignof(Entry<V>));
    mem_set(p, 0, bytes);
    return p;
}

// Linear-probe for `key` in `slots` (capacity `cap`, which must be > 0). Returns the slot index
// of the matching entry if present, or the first empty slot on the probe chain otherwise. The
// load factor is kept below 1, so an empty slot always exists and the scan terminates.
fn strmap_probe(comptime V: type, slots: PAddr, cap: usize, key: []const u8) -> usize {
    var idx: usize = (fnv1a(key) as usize) % cap;
    var step: usize = 0;
    while step < cap {
        let slot: *mut Entry<V> = slot_ptr(V, slots, idx);
        if !slot.used {
            return idx;
        }
        if mem.bytes_equal(slot.key, key) {
            return idx;
        }
        idx = idx + 1;
        if idx >= cap {
            idx = 0;
        }
        step = step + 1;
    }
    unreachable; // table full — impossible while the load factor stays below 0.75
}

// Grow the table to the next capacity (8, then doubling) and rehash every live entry into it.
fn strmap_grow(comptime V: type, m: *mut StrHashMap<V>) -> void {
    var newcap: usize = 8;
    if m.cap != 0 {
        newcap = m.cap * 2;
    }
    let newslots: PAddr = strmap_alloc_slots(V, m, newcap);
    var i: usize = 0;
    while i < m.cap {
        let old: *mut Entry<V> = slot_ptr(V, m.slots, i);
        if old.used {
            let j: usize = strmap_probe(V, newslots, newcap, old.key);
            let dst: *mut Entry<V> = slot_ptr(V, newslots, j);
            dst.key = old.key;
            dst.val = old.val;
            dst.used = true;
        }
        i = i + 1;
    }
    if m.cap != 0 {
        free_bytes(m.a, m.slots, m.cap * sizeof(Entry<V>));
    }
    m.slots = newslots;
    m.cap = newcap;
}

// A fresh empty map bound to allocator `a`. No allocation happens until the first put.
export fn strmap_new(comptime V: type, a: *mut dyn Allocator) -> StrHashMap<V> {
    return .{ .slots = pa(0), .len = 0, .cap = 0, .a = a };
}

// Number of live entries.
export fn strmap_len(comptime V: type, m: *StrHashMap<V>) -> usize {
    return m.len;
}

// Insert or overwrite: bind `key` to `val`. On a new key the table grows first if inserting
// would exceed the ~0.75 load factor. The key slice is stored by reference (borrowed).
export fn strmap_put(comptime V: type, m: *mut StrHashMap<V>, key: []const u8, val: V) -> void {
    // Grow when (len + 1) / cap would exceed 3/4, written as a cross-multiply to avoid floats.
    // Also grows from cap == 0 on the first put ((0 + 1) * 4 > 0).
    if (m.len + 1) * 4 > m.cap * 3 {
        strmap_grow(V, m);
    }
    let idx: usize = strmap_probe(V, m.slots, m.cap, key);
    let slot: *mut Entry<V> = slot_ptr(V, m.slots, idx);
    if !slot.used {
        m.len = m.len + 1;
    }
    slot.key = key;
    slot.val = val;
    slot.used = true;
}

// A pointer to the value bound to `key`, or `null` if absent. The pointer is into the map's
// storage: valid until the next grow-triggering `strmap_put`. (MC has no by-value `?V`; see the
// module header and the GAP note.)
export fn strmap_get(comptime V: type, m: *StrHashMap<V>, key: []const u8) -> ?*mut V {
    if m.cap == 0 {
        return null;
    }
    let idx: usize = strmap_probe(V, m.slots, m.cap, key);
    let slot: *mut Entry<V> = slot_ptr(V, m.slots, idx);
    if !slot.used {
        return null;
    }
    // `val` is field 0, so the slot base is the value address. `raw.ptr` mints a fresh pointer
    // into the heap slot (not the address of a local), so this does not escape-fault.
    var vp: *mut V = raw.ptr<V>(0);
    unsafe {
        vp = raw.ptr<V>(pa_offset(m.slots, idx * sizeof(Entry<V>)));
    }
    return vp;
}

// The value bound to `key`, or `fallback` if absent — the by-value read the pointer-only `?V`
// cannot provide. `V` is copied out, so the result is independent of later map mutation.
export fn strmap_get_or(comptime V: type, m: *StrHashMap<V>, key: []const u8, fallback: V) -> V {
    if m.cap == 0 {
        return fallback;
    }
    let idx: usize = strmap_probe(V, m.slots, m.cap, key);
    let slot: *mut Entry<V> = slot_ptr(V, m.slots, idx);
    if slot.used {
        return slot.val;
    }
    return fallback;
}

// Whether `key` is present.
export fn strmap_contains(comptime V: type, m: *StrHashMap<V>, key: []const u8) -> bool {
    if m.cap == 0 {
        return false;
    }
    let idx: usize = strmap_probe(V, m.slots, m.cap, key);
    let slot: *mut Entry<V> = slot_ptr(V, m.slots, idx);
    return slot.used;
}

// Release the backing slot array. Call exactly once; the map becomes empty (len == cap == 0)
// and may be reused (a subsequent put re-allocates). A no-op when nothing is allocated. Borrowed
// key bytes are the caller's to free (this map never owned them).
export fn strmap_free(comptime V: type, m: *mut StrHashMap<V>) -> void {
    if m.cap != 0 {
        free_bytes(m.a, m.slots, m.cap * sizeof(Entry<V>));
    }
    m.slots = pa(0);
    m.len = 0;
    m.cap = 0;
}

// ---------------------------------------------------------------------------------------------
// GAP (docs/self-host-gaps.md): a fully generic `HashMap<K, V>` is blocked twice over —
//   1. Key comparison/hashing needs `where K: Hash + Eq` trait bounds and a way to invoke a
//      trait method on a comptime-generic value; string keys sidestep this with the built-in
//      `mem.bytes_equal` + a hand-written FNV.
//   2. Lookups want `?V` (by-value optional), but MC optionals are pointer-shaped only, so we
//      return `?*mut V`. A by-value optional over an arbitrary `V` is not expressible today.
// ---------------------------------------------------------------------------------------------
