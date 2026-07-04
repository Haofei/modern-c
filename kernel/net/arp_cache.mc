// kernel/net/arp_cache — a bounded IP→MAC address cache for ARP resolution. Arch-neutral.
//
// The ARP request/reply framing (kernel/net/arp) resolves a peer's MAC; this caches the
// binding so the stack does not re-ARP on every send. A small fixed table with round-robin
// eviction when full — no allocation, no sentinels (lookup returns a typed `Result`).

import "ethernet.mc"; // MacAddr

pub const ARP_CACHE_MAX: usize = 8;

pub struct ArpEntry {
    ip: u32,
    mac: MacAddr,
    valid: bool,
}

pub enum ArpCacheError {
    Miss, // no binding cached for the requested IP
}

pub struct ArpCache {
    entries: [ARP_CACHE_MAX]ArpEntry,
    hand: usize, // round-robin eviction hand, used only when the cache is full
}

pub fn arp_cache_init(c: *mut ArpCache) -> void {
    var i: usize = 0;
    while i < ARP_CACHE_MAX {
        c.entries[i].valid = false;
        i = i + 1;
    }
    c.hand = 0;
}

pub fn arp_cache_count(c: *mut ArpCache) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < ARP_CACHE_MAX {
        if c.entries[i].valid {
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}

// Insert or refresh the IP→MAC binding: an existing entry for `ip` is updated in place;
// otherwise the lowest free slot is used, or (when full) the round-robin hand evicts one.
pub fn arp_cache_insert(c: *mut ArpCache, ip: u32, mac: MacAddr) -> void {
    var i: usize = 0;
    while i < ARP_CACHE_MAX {
        if c.entries[i].valid {
            if c.entries[i].ip == ip {
                c.entries[i].mac = mac; // refresh an existing binding
                return;
            }
        }
        i = i + 1;
    }
    var j: usize = 0;
    while j < ARP_CACHE_MAX {
        if !c.entries[j].valid {
            c.entries[j].ip = ip;
            c.entries[j].mac = mac;
            c.entries[j].valid = true;
            return;
        }
        j = j + 1;
    }
    // full: evict the entry under the round-robin hand and advance it
    let slot: usize = c.hand;
    c.entries[slot].ip = ip;
    c.entries[slot].mac = mac;
    c.entries[slot].valid = true;
    c.hand = (c.hand + 1) % ARP_CACHE_MAX;
}

// Resolve `ip` to its cached MAC, or Miss (the caller should ARP for it).
pub fn arp_cache_lookup(c: *mut ArpCache, ip: u32) -> Result<MacAddr, ArpCacheError> {
    var i: usize = 0;
    while i < ARP_CACHE_MAX {
        if c.entries[i].valid {
            if c.entries[i].ip == ip {
                return ok(c.entries[i].mac);
            }
        }
        i = i + 1;
    }
    return err(.Miss);
}

// Drop a binding (e.g. a peer that moved, or an interface going down). True if it was present.
pub fn arp_cache_invalidate(c: *mut ArpCache, ip: u32) -> bool {
    var i: usize = 0;
    while i < ARP_CACHE_MAX {
        if c.entries[i].valid {
            if c.entries[i].ip == ip {
                c.entries[i].valid = false;
                return true;
            }
        }
        i = i + 1;
    }
    return false;
}
