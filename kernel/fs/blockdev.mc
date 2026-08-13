// kernel/fs/blockdev — a minimal block-device abstraction.
//
// A BlockDevice is fixed-size (512 B) blocks addressed by index, behind a `trait`
// (docs/spec/MC_0.7_Final_Design.md §32), so any backend (a RAM disk for tests, or the
// virtio-blk driver) can serve it. Callers hold a `*dyn BlockDevice` — one {data,vtable}
// fat pointer over a checked, shared rodata vtable, replacing the former struct of two
// per-instance closures. Block indices are bounds-checked; errors are typed.

const BLOCK_SIZE: usize = 512;

trait BlockDevice {
    fn read(self: *Self, blk: u64, dst: usize) -> bool;  // (block_index, dst_addr) -> ok
    fn write(self: *Self, blk: u64, src: usize) -> bool; // (block_index, src_addr) -> ok
    fn blocks(self: *Self) -> u64;                       // device size, in blocks
}

enum BlockError {
    OutOfRange, // block index past the device
    IoError,    // the backend reported failure
}

// Read one block into `dst` (must hold BLOCK_SIZE bytes), through the device vtable.
#[mc_abi]
export fn bd_read_block(dev: *dyn BlockDevice, blk: u64, dst: usize) -> Result<bool, BlockError> {
    if blk >= dev.blocks() {
        return err(.OutOfRange);
    }
    let ok_io: bool = dev.read(blk, dst); // dynamic dispatch through the trait vtable
    if ok_io {
        return ok(true);
    }
    return err(.IoError);
}

// Write one block from `src` (BLOCK_SIZE bytes) through the device vtable.
#[mc_abi]
export fn bd_write_block(dev: *dyn BlockDevice, blk: u64, src: usize) -> Result<bool, BlockError> {
    if blk >= dev.blocks() {
        return err(.OutOfRange);
    }
    let ok_io: bool = dev.write(blk, src); // dynamic dispatch through the trait vtable
    if ok_io {
        return ok(true);
    }
    return err(.IoError);
}
