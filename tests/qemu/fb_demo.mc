import "kernel/drivers/fb.mc";
import "std/addr.mc";
global g_fb: [1024]u8; // 16*16*4
export fn fb_run() -> u32 {
    var pass: u32 = 1;
    let fb: PAddr = pa((&g_fb[0]) as usize);
    fb_set(fb, 0, 0, 0);
    fb_set(fb, 2, 3, 0x00FF00FF); // magenta at (2,3)
    fb_set(fb, 5, 5, 0x0000FF00); // green at (5,5)
    if fb_get(fb, 2, 3) != 0x00FF00FF { pass = 0; }
    if fb_get(fb, 5, 5) != 0x0000FF00 { pass = 0; }
    if fb_get(fb, 0, 0) != 0 { pass = 0; }       // untouched
    if fb_get(fb, 2, 3) == fb_get(fb, 5, 5) { pass = 0; } // independent pixels
    return pass;
}
