// kernel/drivers/virtio/virtio_blk_blockdev — adapt the virtio-blk driver to the generic
// BlockDevice trait (kernel/fs/blockdev.mc).
//
// This is the production counterpart to the RAM-disk `impl BlockDevice for Disk` used in the
// host/proc tests: it routes the trait's read/write through the real virtio-blk full-sector
// paths (blk_read_into / blk_write, both 512 B), so block-backed services — e.g. durable
// policy/audit checkpointing (kernel/core/block_persistent_audit.mc) — run unchanged over a
// real disk under QEMU/board paths.

import "kernel/drivers/virtio/virtio_blk.mc";
import "kernel/fs/blockdev.mc";
import "std/addr.mc";

// The trait's bounds check (`blk >= dev.blocks()`) needs a capacity. BlkDevice itself carries no
// size field, so report a fixed window of sectors here; the backing disk image must be at least
// this many 512-byte sectors. Callers that need a smaller logical store simply use lower indices.
const VBLK_BD_BLOCKS: u64 = 16;

impl BlockDevice for BlkDevice {
    fn read(self: *BlkDevice, blk: u64, dst: usize) -> bool {
        switch blk_read_into(self, blk, pa(dst)) {
            ok(b) => { return true; }
            err(e) => { return false; }
        }
    }

    fn write(self: *BlkDevice, blk: u64, src: usize) -> bool {
        switch blk_write(self, blk, pa(src)) {
            ok(b) => { return true; }
            err(e) => { return false; }
        }
    }

    fn blocks(self: *BlkDevice) -> u64 {
        return VBLK_BD_BLOCKS;
    }
}
