// Agent KV store: u64 key -> bytes with put/get/has/len/delete + in-place overwrite
// and slot/arena reuse, plus typed Full/NotFound/TooLarge. Drives a global KvStore
// and copies bytes through PAddr source/dest buffers (like the other fs byte tests).
// Returns 1 only if every check passes.

import "kernel/fs/kvstore.mc";
import "std/addr.mc";

global g_store: KvStore;
global g_a: [8]u8;
global g_b: [4]u8;
global g_a2: [3]u8;
global g_big: [4096]u8;
global g_dst: [16]u8;

// True if kv_put(key, src, len) returned ok(len).
fn put_ok(key: u64, src: PAddr, len: usize) -> bool {
    switch kv_put(&g_store, key, src, len) {
        ok(n) => { return n == len; }
        err(e) => { return false; }
    }
}

// True if kv_len(key) == want.
fn len_is(key: u64, want: usize) -> bool {
    switch kv_len(&g_store, key) {
        ok(n) => { return n == want; }
        err(e) => { return false; }
    }
}

export fn kvstore_run() -> u32 {
    var pass: u32 = 1;
    kv_init(&g_store);

    if kv_count(&g_store) != 0 { pass = 0; }
    if kv_has(&g_store, 0xA) { pass = 0; } // nothing present yet

    // Source buffers with known contents.
    g_a[0] = 0x11; g_a[1] = 0x22; g_a[2] = 0x33; g_a[3] = 0x44;
    g_a[4] = 0x55; g_a[5] = 0x66; g_a[6] = 0x77; g_a[7] = 0x88;
    g_b[0] = 0xAA; g_b[1] = 0xBB; g_b[2] = 0xCC; g_b[3] = 0xDD;
    g_a2[0] = 0xE1; g_a2[1] = 0xE2; g_a2[2] = 0xE3;

    // ---- Put two values under distinct keys ----
    if !put_ok(0xA, pa((&g_a[0]) as usize), 8) { pass = 0; }
    if !put_ok(0xB, pa((&g_b[0]) as usize), 4) { pass = 0; }

    if kv_count(&g_store) != 2 { pass = 0; }
    if !kv_has(&g_store, 0xA) { pass = 0; }
    if !kv_has(&g_store, 0xB) { pass = 0; }
    if !len_is(0xA, 8) { pass = 0; }
    if !len_is(0xB, 4) { pass = 0; }

    // kv_get returns the identical bytes for key=0xA.
    var i: usize = 0;
    while i < 16 { g_dst[i] = 0; i = i + 1; }
    switch kv_get(&g_store, 0xA, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { if n != 8 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    i = 0;
    while i < 8 {
        if g_dst[i] != g_a[i] { pass = 0; }
        i = i + 1;
    }

    // ---- NotFound for an absent key (no slot, no bytes copied) ----
    switch kv_get(&g_store, 0xFF, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .NotFound => {}
                _ => { pass = 0; }
            }
        }
    }
    switch kv_len(&g_store, 0xFF) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .NotFound => {}
                _ => { pass = 0; }
            }
        }
    }

    // ---- OVERWRITE key=0xA with a new (shorter) value ----
    // The arena compacts the old 8-byte value; get must return the new bytes/len.
    if !put_ok(0xA, pa((&g_a2[0]) as usize), 3) { pass = 0; }
    if kv_count(&g_store) != 2 { pass = 0; } // still two keys, no new slot
    if !len_is(0xA, 3) { pass = 0; }
    i = 0;
    while i < 16 { g_dst[i] = 0; i = i + 1; }
    switch kv_get(&g_store, 0xA, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { if n != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    i = 0;
    while i < 3 {
        if g_dst[i] != g_a2[i] { pass = 0; }
        i = i + 1;
    }
    // key=0xB survived the overwrite's arena compaction byte-for-byte.
    i = 0;
    while i < 16 { g_dst[i] = 0; i = i + 1; }
    switch kv_get(&g_store, 0xB, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { if n != 4 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    i = 0;
    while i < 4 {
        if g_dst[i] != g_b[i] { pass = 0; }
        i = i + 1;
    }

    // ---- DELETE key=0xA: has=false, count drops, get => NotFound ----
    switch kv_delete(&g_store, 0xA) {
        ok(b) => { if !b { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if kv_has(&g_store, 0xA) { pass = 0; }
    if kv_count(&g_store) != 1 { pass = 0; }
    switch kv_get(&g_store, 0xA, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .NotFound => {}
                _ => { pass = 0; }
            }
        }
    }
    // Deleting an absent key is a typed NotFound, not a silent no-op.
    switch kv_delete(&g_store, 0xA) {
        ok(b) => { pass = 0; }
        err(e) => {
            switch e {
                .NotFound => {}
                _ => { pass = 0; }
            }
        }
    }
    // 0xB still present and intact after the delete compaction.
    if !kv_has(&g_store, 0xB) { pass = 0; }
    if !len_is(0xB, 4) { pass = 0; }
    i = 0;
    while i < 16 { g_dst[i] = 0; i = i + 1; }
    switch kv_get(&g_store, 0xB, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { if n != 4 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    i = 0;
    while i < 4 {
        if g_dst[i] != g_b[i] { pass = 0; }
        i = i + 1;
    }

    // ---- Put after delete reuses the freed slot ----
    if !put_ok(0xC, pa((&g_a[0]) as usize), 8) { pass = 0; }
    if kv_count(&g_store) != 2 { pass = 0; }
    if !kv_has(&g_store, 0xC) { pass = 0; }
    if !len_is(0xC, 8) { pass = 0; }

    // ---- Fill the directory to capacity (MAX_KEYS=8), then Full typed ----
    // 0xB and 0xC occupy two slots; add six more keys to reach eight.
    var k: u64 = 0x10;
    while k < 0x16 {
        if !put_ok(k, pa((&g_b[0]) as usize), 1) { pass = 0; }
        k = k + 1;
    }
    if kv_count(&g_store) != 8 { pass = 0; }
    switch kv_put(&g_store, 0x99, pa((&g_b[0]) as usize), 1) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .Full => {}
                _ => { pass = 0; }
            }
        }
    }

    // ---- Oversized value => TooLarge typed (overwrite an existing key) ----
    // A value bigger than the whole arena cannot fit even after evicting the old one.
    switch kv_put(&g_store, 0xB, pa((&g_big[0]) as usize), 4096) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .TooLarge => {}
                _ => { pass = 0; }
            }
        }
    }

    return pass;
}
