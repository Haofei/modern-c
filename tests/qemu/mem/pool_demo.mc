// Generational pool: alloc/set/load/free a slot, then show that a freed handle fails
// (use-after-free), a second free fails (double-free), and after the slot is reused
// the old handle stays stale (generation differs). Runtime, fail-closed.

import "std/alloc/pool.mc";

struct Cell { v: u32 }
global g_pool: Pool<Cell, 16>;

export fn pool_demo_run() -> u32 {
    pool_init(Cell, 16, &g_pool);
    var pass: u32 = 1;

    var r1: PoolRef<Cell> = uninit;
    switch pool_alloc(Cell, 16, &g_pool) {
        ok(r) => { r1 = r; }
        err(e) => { pass = 0; }
    }
    // Reserved but not initialized yet: loading must fail closed.
    switch pool_load(Cell, 16, &g_pool, r1) {
        ok(c) => { pass = 0; }
        err(e) => {}
    }
    let v1: Cell = .{ .v = 0xAB };
    switch pool_set(Cell, 16, &g_pool, r1, v1) {
        ok(b) => {}
        err(e) => { pass = 0; }
    }
    switch pool_load(Cell, 16, &g_pool, r1) {
        ok(c) => { if c.v != 0xAB { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch pool_free(Cell, 16, &g_pool, r1) {
        ok(b) => {}
        err(e) => { pass = 0; }
    }
    // use-after-free
    switch pool_load(Cell, 16, &g_pool, r1) {
        ok(c) => { pass = 0; }
        err(e) => {}
    }
    // double-free
    switch pool_free(Cell, 16, &g_pool, r1) {
        ok(b) => { pass = 0; }
        err(e) => {}
    }
    // reuse the slot; the old handle must remain stale (new generation)
    var r2: PoolRef<Cell> = uninit;
    switch pool_alloc(Cell, 16, &g_pool) {
        ok(r) => { r2 = r; }
        err(e) => { pass = 0; }
    }
    switch pool_load(Cell, 16, &g_pool, r1) {
        ok(c) => { pass = 0; }
        err(e) => {}
    }
    let v2: Cell = .{ .v = 0xCD };
    switch pool_set(Cell, 16, &g_pool, r2, v2) {
        ok(b) => {}
        err(e) => { pass = 0; }
    }
    return pass;
}
