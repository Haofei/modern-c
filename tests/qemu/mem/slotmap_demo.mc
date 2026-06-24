import "std/collections/slotmap.mc";
global g_sm: SlotMap<u32, 4>;
export fn slotmap_run() -> u32 {
    var pass: u32 = 1;
    slotmap_init(u32, 4, &g_sm);
    if slotmap_count(u32, 4, &g_sm) != 0 { pass = 0; }

    var h0: usize = 99;
    var h1: usize = 99;
    switch slotmap_alloc(u32, 4, &g_sm) { ok(h) => { h0 = h; } err(e) => { pass = 0; } }
    switch slotmap_alloc(u32, 4, &g_sm) { ok(h) => { h1 = h; } err(e) => { pass = 0; } }
    if h0 != 0 { pass = 0; }
    if h1 != 1 { pass = 0; }

    switch slotmap_set(u32, 4, &g_sm, h0, 0xAB) { ok(b) => {} err(e) => { pass = 0; } }
    switch slotmap_get(u32, 4, &g_sm, h0) { ok(v) => { if v != 0xAB { pass = 0; } } err(e) => { pass = 0; } }

    // out-of-range handle -> BadHandle
    switch slotmap_get(u32, 4, &g_sm, 99) { ok(v) => { pass = 0; } err(e) => {} }

    // free h0; reads + double-free now fail closed
    switch slotmap_free(u32, 4, &g_sm, h0) { ok(b) => {} err(e) => { pass = 0; } }
    switch slotmap_get(u32, 4, &g_sm, h0) { ok(v) => { pass = 0; } err(e) => {} }
    switch slotmap_free(u32, 4, &g_sm, h0) { ok(b) => { pass = 0; } err(e) => {} }

    // alloc again reuses the lowest free slot (0)
    switch slotmap_alloc(u32, 4, &g_sm) { ok(h) => { if h != 0 { pass = 0; } } err(e) => { pass = 0; } }
    // fill slots 2,3 -> table full -> next alloc is Full
    switch slotmap_alloc(u32, 4, &g_sm) { ok(h) => {} err(e) => { pass = 0; } }
    switch slotmap_alloc(u32, 4, &g_sm) { ok(h) => {} err(e) => { pass = 0; } }
    switch slotmap_alloc(u32, 4, &g_sm) { ok(h) => { pass = 0; } err(e) => {} }
    if slotmap_count(u32, 4, &g_sm) != 4 { pass = 0; }
    return pass;
}
