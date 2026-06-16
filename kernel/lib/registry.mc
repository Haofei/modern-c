// kernel/lib/registry (v2) — a fixed-capacity registry mapping a numeric key (a service-name
// hash or a device-class code) to an endpoint handle (a driver id or a service pid) plus the
// endpoint's *generation*. This is the static-registration backbone of the plugin model:
// drivers register device-class endpoints, services register named endpoints, clients
// discover them by key. v2 adds:
//   - multiple entries per key (e.g. two NICs of class Net), enumerable by index;
//   - a generation stored with each endpoint, so a client can detect a stale registration;
//   - unregister-by-endpoint, so a process-death hook can drop everything a dead pid owned.

import "std/scan.mc";

const REG_MAX: usize = 16;

enum RegError {
    Full,     // no free registry slot
    NotFound, // no entry for the key (or index)
}

struct RegEntry {
    key: u32,
    endpoint: u32,
    gen: u32, // the endpoint's generation when registered (0 if the endpoint is not generational)
    present: bool,
}

struct Registry {
    entries: [REG_MAX]RegEntry,
    count: usize,
}

export fn registry_init(reg: *mut Registry) -> void {
    var i: usize = 0;
    while i < REG_MAX {
        reg.entries[i].present = false;
        i = i + 1;
    }
    reg.count = 0;
}

export fn registry_count(reg: *mut Registry) -> usize {
    return reg.count;
}

// Register key -> (endpoint, gen). Duplicates per key are allowed. Returns the slot, or Full.
export fn registry_add(reg: *mut Registry, key: u32, endpoint: u32, gen: u32) -> Result<usize, RegError> {
    var i: usize = 0;
    while i < REG_MAX {
        if !reg.entries[i].present {
            reg.entries[i].key = key;
            reg.entries[i].endpoint = endpoint;
            reg.entries[i].gen = gen;
            reg.entries[i].present = true;
            reg.count = reg.count + 1;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.Full);
}

// Predicate: a present entry whose key matches the captured search key.
fn entry_key_matches(key: u32, e: RegEntry) -> bool {
    return e.present && e.key == key;
}

// The first endpoint registered under `key`, or NotFound.
export fn registry_find(reg: *mut Registry, key: u32) -> Result<u32, RegError> {
    let pred: closure(RegEntry) -> bool = bind(key, entry_key_matches);
    let i: usize = find_index(RegEntry, REG_MAX, reg.entries, pred);
    if i < REG_MAX {
        return ok(reg.entries[i].endpoint);
    }
    return err(.NotFound);
}

// The generation registered with the first endpoint for `key` (so a client can compare it to
// the live process generation and detect a stale registration), or NotFound.
export fn registry_find_gen(reg: *mut Registry, key: u32) -> Result<u32, RegError> {
    let pred: closure(RegEntry) -> bool = bind(key, entry_key_matches);
    let i: usize = find_index(RegEntry, REG_MAX, reg.entries, pred);
    if i < REG_MAX {
        return ok(reg.entries[i].gen);
    }
    return err(.NotFound);
}

// How many endpoints are registered under `key` (e.g. how many devices of a class).
export fn registry_count_key(reg: *mut Registry, key: u32) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < REG_MAX {
        if reg.entries[i].present {
            if reg.entries[i].key == key {
                n = n + 1;
            }
        }
        i = i + 1;
    }
    return n;
}

// The `n`-th endpoint registered under `key` (0-based, in slot order), or NotFound — for
// enumerating multiple devices/services of one class.
export fn registry_find_nth(reg: *mut Registry, key: u32, n: usize) -> Result<u32, RegError> {
    var seen: usize = 0;
    var i: usize = 0;
    while i < REG_MAX {
        if reg.entries[i].present {
            if reg.entries[i].key == key {
                if seen == n {
                    return ok(reg.entries[i].endpoint);
                }
                seen = seen + 1;
            }
        }
        i = i + 1;
    }
    return err(.NotFound);
}

// Remove the first entry for `key`, or NotFound.
export fn registry_remove(reg: *mut Registry, key: u32) -> Result<bool, RegError> {
    var i: usize = 0;
    while i < REG_MAX {
        if reg.entries[i].present {
            if reg.entries[i].key == key {
                reg.entries[i].present = false;
                reg.count = reg.count - 1;
                return ok(true);
            }
        }
        i = i + 1;
    }
    return err(.NotFound);
}

// Drop every entry owned by `endpoint` (regardless of key) — the process-death hook: when a
// pid exits, all of its registrations are revoked so no client resolves a dead endpoint.
// Returns how many entries were removed.
export fn registry_unregister_endpoint(reg: *mut Registry, endpoint: u32) -> usize {
    var removed: usize = 0;
    var i: usize = 0;
    while i < REG_MAX {
        if reg.entries[i].present {
            if reg.entries[i].endpoint == endpoint {
                reg.entries[i].present = false;
                reg.count = reg.count - 1;
                removed = removed + 1;
            }
        }
        i = i + 1;
    }
    return removed;
}
