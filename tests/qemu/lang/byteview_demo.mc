import "std/byteview.mc";
import "std/addr.mc";
global g_buf: ByteBuf<8>;
global g_src: [8]u8;
global g_dst: [8]u8;
export fn byteview_run() -> u32 {
    var pass: u32 = 1;
    bytebuf_init(8, &g_buf);
    g_src[0] = 0x11; g_src[1] = 0x22; g_src[2] = 0x33;

    switch bytebuf_copy_from(8, &g_buf, pa((&g_src[0]) as usize), 3) {
        ok(m) => { if m != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if bytebuf_len(8, &g_buf) != 3 { pass = 0; }   // copy_from set the logical length
    if bytebuf_get(8, &g_buf, 0) != 0x11 { pass = 0; }
    if bytebuf_get(8, &g_buf, 2) != 0x33 { pass = 0; }
    if bytebuf_get(8, &g_buf, 99) != 0 { pass = 0; } // saturating read -> 0

    // set is bounds-checked: out-of-range errors (not a silent dropped write)
    switch bytebuf_set(8, &g_buf, 99, 0xAB) {
        ok(b) => { pass = 0; }
        err(e) => {}
    }

    // copy_to refuses to read past the logical length (no stale/uninitialized bytes)
    switch bytebuf_copy_to(8, &g_buf, pa((&g_dst[0]) as usize), 5) { // 5 > len(3)
        ok(m) => { pass = 0; }
        err(e) => {}
    }
    // within len it copies the meaningful bytes
    switch bytebuf_copy_to(8, &g_buf, pa((&g_dst[0]) as usize), 3) {
        ok(m) => { if m != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if g_dst[0] != 0x11 { pass = 0; }
    if g_dst[2] != 0x33 { pass = 0; }

    // set at/after the end extends len, which then allows a longer copy_to
    switch bytebuf_set(8, &g_buf, 4, 0x55) { // index 4 >= len(3) -> len becomes 5
        ok(b) => {}
        err(e) => { pass = 0; }
    }
    if bytebuf_len(8, &g_buf) != 5 { pass = 0; }
    switch bytebuf_copy_to(8, &g_buf, pa((&g_dst[0]) as usize), 5) { // now within len
        ok(m) => { if m != 5 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if g_dst[4] != 0x55 { pass = 0; }

    // OutOfBounds: copying n=99 into N=8 must FAIL (typed error), not silently clamp.
    switch bytebuf_copy_from(8, &g_buf, pa((&g_src[0]) as usize), 99) {
        ok(m) => { pass = 0; }
        err(e) => {}
    }
    return pass;
}
