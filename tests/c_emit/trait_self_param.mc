// Language gap G16: a trait method may write `Self` in a NON-receiver parameter
// position (e.g. `eq(self: *Self, other: *Self)`). Trait-conformance checking now
// substitutes `Self` for the concrete impl type in EVERY parameter and the return
// type — not just the receiver — so `impl Keyed for IntKey { fn eq(self: *IntKey,
// other: *IntKey) }` conforms. A genuine mismatch (wrong type/arity/return) is
// still rejected (see tests/spec/trait_self_param_reject_*.mc).
//
// This exercises a generic `HashMap<K,V>`-style bounded generic end to end: a mini
// open-addressing table whose key type only needs `where K: Keyed`, using BOTH the
// `K.hash` bound (to pick a bucket) and the `K.eq` bound (to compare keys on probe).
// Entry mode diffs C vs LLVM, so any backend disagreement on the bounded
// monomorphized `K.hash` / `K.eq` calls fails.

trait Keyed {
    fn hash(self: *Self) -> u32;
    fn eq(self: *Self, other: *Self) -> bool;      // `other: *Self` — the G16 case
}

struct IntKey {
    v: u32,
}

impl Keyed for IntKey {
    fn hash(self: *IntKey) -> u32 {
        return self.v * 7;                           // small spread; no u32 overflow
    }
    fn eq(self: *IntKey, other: *IntKey) -> bool {
        return self.v == other.v;
    }
}

// A tiny fixed-capacity open-addressing map keyed by IntKey.
struct Slot {
    used: bool,
    key: IntKey,
    val: u32,
}

struct Map {
    slots: [8]Slot,
}

fn map_init(m: *mut Map) -> void {
    var i: usize = 0;
    while i < 8 {
        m.slots[i].used = false;
        m.slots[i].val = 0;
        i = i + 1;
    }
}

// Generic bounded insert: hashes the key to a bucket (K.hash), then linear-probes,
// comparing existing keys with K.eq to overwrite a duplicate.
fn map_insert(comptime K: type, m: *mut Map, key: *K, val: u32) -> void where K: Keyed {
    var idx: usize = (K.hash(key) % 8) as usize;
    var steps: usize = 0;
    while steps < 8 {
        if !m.slots[idx].used {
            m.slots[idx].used = true;
            m.slots[idx].key = *key;
            m.slots[idx].val = val;
            return;
        }
        if K.eq(&m.slots[idx].key, key) {
            m.slots[idx].val = val;
            return;
        }
        idx = (idx + 1) % 8;
        steps = steps + 1;
    }
}

// Generic bounded lookup: same probe sequence; K.eq decides a hit.
fn map_get(comptime K: type, m: *mut Map, key: *K) -> u32 where K: Keyed {
    var idx: usize = (K.hash(key) % 8) as usize;
    var steps: usize = 0;
    while steps < 8 {
        if !m.slots[idx].used {
            return 0;
        }
        if K.eq(&m.slots[idx].key, key) {
            return m.slots[idx].val;
        }
        idx = (idx + 1) % 8;
        steps = steps + 1;
    }
    return 0;
}

export fn trait_self_param_run() -> u32 {
    var m: Map = uninit;
    map_init(&m);

    var k1: IntKey = .{ .v = 7 };
    var k2: IntKey = .{ .v = 15 };   // may collide with k1 depending on hash
    var k3: IntKey = .{ .v = 7 };    // eq-equal to k1

    map_insert(IntKey, &m, &k1, 100);
    map_insert(IntKey, &m, &k2, 200);
    map_insert(IntKey, &m, &k3, 111);   // overwrites k1's slot via K.eq

    let a: u32 = map_get(IntKey, &m, &k1);   // 111 (overwritten)
    let b: u32 = map_get(IntKey, &m, &k2);   // 200
    var missing: IntKey = .{ .v = 99 };
    let c: u32 = map_get(IntKey, &m, &missing); // 0

    if a != 111 {
        return 0;
    }
    if b != 200 {
        return 0;
    }
    if c != 0 {
        return 0;
    }

    // Directly exercise the trait `eq` with `Self`-in-param at a concrete type.
    if !IntKey.eq(&k1, &k3) {
        return 0;
    }
    if IntKey.eq(&k1, &k2) {
        return 0;
    }

    return 1;
}
