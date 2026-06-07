// demo/framebuffer — a large device-visible memory region (not a register, not a
// queue). A framebuffer is mapped, drawn into, and flushed; the mapping is a
// linear handle (unmap exactly once), pixels carry their format, and a flush
// names the dirty rectangle that becomes visible.

// Packed 32-bit pixel; the format is in the type, not a convention.
struct Rgb888 { b: u8, g: u8, r: u8, x: u8 }

// A mapped framebuffer surface. Linear: it must be unmapped exactly once.
move struct Framebuffer {
    base: usize,
    width: u32,
    height: u32,
    stride: u32, // bytes per row
}

extern fn mc_fb_map(base: usize, width: u32, height: u32, stride: u32) -> Framebuffer;
extern fn mc_fb_put(fb: *Framebuffer, x: u32, y: u32, pixel: u32) -> void;          // borrow, write a pixel
extern fn mc_fb_flush(fb: *Framebuffer, x: u32, y: u32, w: u32, h: u32) -> void;    // dirty rect → device
extern fn mc_fb_unmap(fb: Framebuffer) -> void;                                     // consume

fn pack(p: Rgb888) -> u32 {
    return (p.r as u32) | ((p.g as u32) << 8) | ((p.b as u32) << 16);
}

// Fill a rectangle and flush just that dirty region to the display.
export fn fill_rect(base: usize, stride: u32, x: u32, y: u32, w: u32, h: u32, color: Rgb888) -> void {
    let fb: Framebuffer = mc_fb_map(base, 1024, 768, stride);
    let pixel: u32 = pack(color);
    var row: u32 = 0;
    while row < h {
        var col: u32 = 0;
        while col < w {
            mc_fb_put(&fb, x + col, y + row, pixel);
            col = col + 1;
        }
        row = row + 1;
    }
    mc_fb_flush(&fb, x, y, w, h); // only the touched rectangle is pushed
    mc_fb_unmap(fb);             // release the mapping (consumes fb)
}

// what the types forbid:
//   mc_fb_put(&fb, ...) after mc_fb_unmap(fb)  // E_USE_AFTER_MOVE
//   omitting mc_fb_unmap(fb)                    // E_RESOURCE_LEAK: mapping leaked
