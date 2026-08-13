// EXPECT: E_USE_AFTER_MOVE — drawing after the framebuffer was unmapped.
import "demo/framebuffer/framebuffer.mc";
fn bad(base: usize, stride: u32, color: *Rgb888) -> void {
    let fb: Framebuffer = fb_map(base, 100, 100, stride);
    fb_unmap(move fb);
    mc_fb_put(fb.base, fb.stride, 0, 0, color);
}
