// virtio-blk demo entry for the QEMU test: bring the block device up and read a
// sector, returning the sector's first little-endian word (or a sentinel on error)
// so the C runtime can print/verify it.

import "kernel/drivers/virtio/virtio_blk.mc";

const BLK_INIT_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF;
const BLK_READ_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFE;

export fn blk_demo_run(regs: MmioPtr<VirtioMmio>, vq: *mut Virtq, sector: u64) -> u64 {
    var dev: BlkDevice = .{ .regs = regs, .vq = vq };
    switch blk_init(&dev) {
        ok(up) => {}
        err(e) => {
            return BLK_INIT_ERR;
        }
    }
    switch blk_read_sector(&dev, sector) {
        ok(word) => {
            return word as u64;
        }
        err(e) => {
            return BLK_READ_ERR;
        }
    }
}
