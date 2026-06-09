import "std/byteview.mc";
import "std/addr.mc";
global g_buf: ByteBuf<8>;
global g_src: [8]u8;
global g_dst: [8]u8;
export fn byteview_run() -> u32 {
    var pass: u32 = 1;
    bytebuf_init(8, &g_buf);
    g_src[0] = 0x11; g_src[1] = 0x22; g_src[2] = 0x33;

    let m: usize = bytebuf_copy_from(8, &g_buf, pa((&g_src[0]) as usize), 3);
    if m != 3 { pass = 0; }
    if bytebuf_len(8, &g_buf) != 3 { pass = 0; }
    if bytebuf_get(8, &g_buf, 0) != 0x11 { pass = 0; }
    if bytebuf_get(8, &g_buf, 2) != 0x33 { pass = 0; }
    if bytebuf_get(8, &g_buf, 99) != 0 { pass = 0; } // out of range -> 0

    bytebuf_copy_to(8, &g_buf, pa((&g_dst[0]) as usize), 3);
    if g_dst[0] != 0x11 { pass = 0; }
    if g_dst[2] != 0x33 { pass = 0; }

    let m2: usize = bytebuf_copy_from(8, &g_buf, pa((&g_src[0]) as usize), 99); // clamps to N=8
    if m2 != 8 { pass = 0; }
    return pass;
}
