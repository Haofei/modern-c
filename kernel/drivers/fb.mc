// kernel/drivers/fb — a linear framebuffer device: a WxH grid of 32-bit pixels in a
// memory region (e.g. ramfb / virtio-gpu shared memory). set/get a pixel by coordinate.
import "std/addr.mc";
const FB_W: usize = 16;
const FB_H: usize = 16;
export fn fb_set(fb: PAddr, x: usize, y: usize, color: u32) -> void {
    let off: usize = (y * FB_W + x) * 4;
    unsafe {
        raw.store<u32>(pa_offset(fb, off), color);
    }
}
export fn fb_get(fb: PAddr, x: usize, y: usize) -> u32 {
    let off: usize = (y * FB_W + x) * 4;
    var v: u32 = 0;
    unsafe {
        v = raw.load<u32>(pa_offset(fb, off));
    }
    return v;
}
