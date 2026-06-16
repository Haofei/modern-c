// Durable blob sink: put/get/len by id, typed errors, and a blob survives a reopen.
// Drives a global BlobStore and copies bytes through PAddr source/dest buffers (like the
// other fs byte tests). Returns 1 only if every check passes.

import "kernel/fs/blobstore.mc";
import "std/addr.mc";

global g_store: BlobStore;
global g_src1: [8]u8;
global g_src2: [4]u8;
global g_big: [4096]u8;
global g_dst: [16]u8;

// True if blob_put(id, src, len) returned ok(len).
fn put_ok(id: u32, src: PAddr, len: usize) -> bool {
    switch blob_put(&g_store, id, src, len) {
        ok(n) => { return n == len; }
        err(e) => { return false; }
    }
}

// True if blob_len(id) == want.
fn len_is(id: u32, want: usize) -> bool {
    switch blob_len(&g_store, id) {
        ok(n) => { return n == want; }
        err(e) => { return false; }
    }
}

export fn blobstore_run() -> u32 {
    var pass: u32 = 1;
    blob_init(&g_store);

    if blob_count(&g_store) != 0 { pass = 0; }

    // Source buffers with known contents.
    g_src1[0] = 0x11; g_src1[1] = 0x22; g_src1[2] = 0x33; g_src1[3] = 0x44;
    g_src1[4] = 0x55; g_src1[5] = 0x66; g_src1[6] = 0x77; g_src1[7] = 0x88;
    g_src2[0] = 0xAA; g_src2[1] = 0xBB; g_src2[2] = 0xCC; g_src2[3] = 0xDD;

    // Put two blobs under distinct ids.
    if !put_ok(1, pa((&g_src1[0]) as usize), 8) { pass = 0; }
    if !put_ok(2, pa((&g_src2[0]) as usize), 4) { pass = 0; }

    // Directory + lengths reflect both.
    if blob_count(&g_store) != 2 { pass = 0; }
    if !len_is(1, 8) { pass = 0; }
    if !len_is(2, 4) { pass = 0; }

    // blob_get returns the identical bytes for id=1.
    var i: usize = 0;
    while i < 16 { g_dst[i] = 0; i = i + 1; }
    switch blob_get(&g_store, 1, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { if n != 8 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    i = 0;
    while i < 8 {
        if g_dst[i] != g_src1[i] { pass = 0; }
        i = i + 1;
    }

    // NotFound for an absent id (no slot, no bytes copied).
    switch blob_get(&g_store, 99, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .NotFound => {}
                _ => { pass = 0; }
            }
        }
    }
    switch blob_len(&g_store, 99) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .NotFound => {}
                _ => { pass = 0; }
            }
        }
    }

    // ---- Durability across a reopen ----
    // The backing bytes live in the struct, so a reopen is a fresh view over the same
    // store. Model a close/reopen by trashing the transient bump cursor (as a fresh view
    // would have it uninitialised), then blob_reopen re-derives it from the live
    // directory. The blob put *before* the reopen must still read back byte-for-byte.
    g_store.bump = 0; // transient state lost across the "close"
    blob_reopen(&g_store);
    if blob_count(&g_store) != 2 { pass = 0; }
    if !len_is(1, 8) { pass = 0; }
    i = 0;
    while i < 16 { g_dst[i] = 0; i = i + 1; }
    switch blob_get(&g_store, 1, pa((&g_dst[0]) as usize), 16) {
        ok(n) => { if n != 8 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    i = 0;
    while i < 8 {
        if g_dst[i] != g_src1[i] { pass = 0; }
        i = i + 1;
    }
    // A new put after reopen appends past the re-derived high-water mark (no overlap
    // with the surviving blobs).
    if !put_ok(3, pa((&g_src2[0]) as usize), 4) { pass = 0; }
    if blob_count(&g_store) != 3 { pass = 0; }
    if !len_is(1, 8) { pass = 0; } // earlier blob untouched by the new append

    // ---- Typed capacity errors (no silent drop) ----
    // TooLarge: a single blob bigger than the whole arena cannot fit.
    switch blob_put(&g_store, 4, pa((&g_big[0]) as usize), 4096) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .TooLarge => {}
                _ => { pass = 0; }
            }
        }
    }

    // Full: fill the directory to capacity (MAX_BLOBS=8 entries). Slots 1,2,3 used;
    // add 4..8 with tiny blobs, then a 9th distinct id must fail Full.
    var id: u32 = 4;
    while id <= 8 {
        if !put_ok(id, pa((&g_src2[0]) as usize), 1) { pass = 0; }
        id = id + 1;
    }
    if blob_count(&g_store) != 8 { pass = 0; }
    switch blob_put(&g_store, 9, pa((&g_src2[0]) as usize), 1) {
        ok(n) => { pass = 0; }
        err(e) => {
            switch e {
                .Full => {}
                _ => { pass = 0; }
            }
        }
    }

    return pass;
}
