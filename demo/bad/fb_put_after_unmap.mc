// EXPECT: E_USE_AFTER_MOVE — drawing after the framebuffer was unmapped.
import "demo/framebuffer/framebuffer.mc";
fn bad(base: usize, stride: u32, color: Rgb888) -> void {
    var fb: Framebuffer = mc_fb_map(base, 100, 100, stride);
    mc_fb_unmap(fb);
    mc_fb_put(&fb, 0, 0, color);
}
