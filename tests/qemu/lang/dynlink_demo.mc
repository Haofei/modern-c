import "kernel/core/dynlink.mc";
import "std/addr.mc";
global g_image: [64]u8;
global g_off: [2]u64;
global g_add: [2]u64;
export fn dynlink_run() -> u32 {
    var pass: u32 = 1;
    g_off[0] = 0;  g_add[0] = 0x100;   // slot at byte 0  -> base+0x100
    g_off[1] = 16; g_add[1] = 0x200;   // slot at byte 16 -> base+0x200
    let base: u64 = 0x8000_0000;
    apply_relative(pa((&g_image[0]) as usize), base, pa((&g_off[0]) as usize), pa((&g_add[0]) as usize), 2);
    var v0: u64 = 0;
    var v1: u64 = 0;
    unsafe {
        v0 = raw.load<u64>(pa((&g_image[0]) as usize));
        v1 = raw.load<u64>(pa((&g_image[16]) as usize));
    }
    if v0 != 0x8000_0100 { pass = 0; }
    if v1 != 0x8000_0200 { pass = 0; }
    return pass;
}
