// virtio-rng demo entry for the QEMU/host test: bring the entropy device up via the
// kernel/drivers/rng entropy service and fill a caller buffer with live device randomness,
// returning the byte count (or a sentinel on error) so the C runtime can verify the
// bytes are non-zero. Mirrors tests/qemu/fs/blk_demo.mc — a thin typed entry over
// the driver so the freestanding runtime stays in C.

import "kernel/drivers/rng/rng.mc";

const RNG_OPEN_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF;
const RNG_FILL_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFE;

// Open the device onto caller-owned queue storage, then fill `len` bytes at `dst`.
// Returns the number of bytes filled, or a sentinel error.
export fn rng_demo_fill(vq: *mut Virtq, dst: usize, len: usize) -> u64 {
    var dev: RngDevice = uninit;
    switch rng_open(vq) {
        ok(opened) => { dev = opened; }
        err(e) => { return RNG_OPEN_ERR; }
    }
    if rng_fill(&dev, dst, len) {
        return len as u64;
    }
    return RNG_FILL_ERR;
}
