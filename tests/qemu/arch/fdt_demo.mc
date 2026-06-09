import "kernel/core/fdt.mc";
import "std/addr.mc";
global g_blob: [40]u8;
fn put_be32(off: usize, v: u32) -> void {
    g_blob[off+0] = ((v >> 24) & 0xFF) as u8;
    g_blob[off+1] = ((v >> 16) & 0xFF) as u8;
    g_blob[off+2] = ((v >> 8) & 0xFF) as u8;
    g_blob[off+3] = (v & 0xFF) as u8;
}
export fn fdt_run() -> u32 {
    var pass: u32 = 1;
    put_be32(0, 0xD00DFEED); // magic
    put_be32(4, 256);        // totalsize
    put_be32(20, 17);        // version
    let blob: PAddr = pa((&g_blob[0]) as usize);
    if !fdt_valid(blob, 40) { pass = 0; }
    if fdt_totalsize(blob, 40) != 256 { pass = 0; }
    if fdt_version(blob, 40) != 17 { pass = 0; }
    put_be32(0, 0x12345678); // corrupt magic
    if fdt_valid(blob, 40) { pass = 0; } // now invalid
    return pass;
}
