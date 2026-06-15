import "kernel/net/arp_cache.mc";

global g_arp: ArpCache;

// Build a MAC whose last byte is `tag`, so the C/MC side can identify which binding a lookup
// returned without comparing all six bytes.
fn mk_mac(tag: u8) -> MacAddr {
    return .{ .bytes = .{ 0x02, 0, 0, 0, 0, tag } };
}

// 0 on miss; otherwise the MAC's tag byte + 1 (so a real tag of 0 is distinguishable from miss).
fn lookup_tag(ip: u32) -> u32 {
    switch arp_cache_lookup(&g_arp, ip) {
        ok(m) => { return (m.bytes[5] as u32) + 1; }
        err(e) => { return 0; }
    }
}

export fn arp_cache_run() -> u32 {
    var pass: u32 = 1;
    arp_cache_init(&g_arp);
    if arp_cache_count(&g_arp) != 0 { pass = 0; }

    // insert two bindings; look them up; a third IP misses.
    arp_cache_insert(&g_arp, 0x0A00_0001, mk_mac(11));
    arp_cache_insert(&g_arp, 0x0A00_0002, mk_mac(22));
    if arp_cache_count(&g_arp) != 2 { pass = 0; }
    if lookup_tag(0x0A00_0001) != 12 { pass = 0; }  // tag 11 -> 12
    if lookup_tag(0x0A00_0002) != 23 { pass = 0; }  // tag 22 -> 23
    if lookup_tag(0x0A00_0003) != 0 { pass = 0; }   // miss

    // refresh: re-insert the same IP updates the MAC in place (no new entry).
    arp_cache_insert(&g_arp, 0x0A00_0001, mk_mac(99));
    if arp_cache_count(&g_arp) != 2 { pass = 0; }
    if lookup_tag(0x0A00_0001) != 100 { pass = 0; } // tag 99 -> 100

    // invalidate: the binding is dropped; a second invalidate reports it was absent.
    if !arp_cache_invalidate(&g_arp, 0x0A00_0002) { pass = 0; }
    if lookup_tag(0x0A00_0002) != 0 { pass = 0; }
    if arp_cache_count(&g_arp) != 1 { pass = 0; }
    if arp_cache_invalidate(&g_arp, 0x0A00_0002) { pass = 0; }

    // eviction: fill past capacity (8); the count is capped and the newest binding is present.
    arp_cache_init(&g_arp);
    var k: u32 = 0;
    while k < 12 {
        arp_cache_insert(&g_arp, 0x0B00_0000 + k, mk_mac(k as u8));
        k = k + 1;
    }
    if arp_cache_count(&g_arp) != 8 { pass = 0; }       // capped at ARP_CACHE_MAX
    if lookup_tag(0x0B00_0000 + 11) != 12 { pass = 0; } // the newest (tag 11) survived

    return pass;
}
