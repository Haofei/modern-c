// kernel/core/proc_blk — process-facing block-device helpers.
//
// Thin process-facing block-device wrappers. They keep a small dynamic-dispatch / Result-return
// validation seam while delegating directly to the block-device layer.

import "kernel/core/process.mc";
import "kernel/fs/blockdev.mc";

#[mc_abi]
export fn proc_blk_read(t: *mut ProcTable, dev: *dyn BlockDevice, blk: u64, dst: usize) -> Result<bool, BlockError> {
    let _t: *mut ProcTable = t;
    return bd_read_block(dev, blk, dst);
}

#[mc_abi]
export fn proc_blk_write(t: *mut ProcTable, dev: *dyn BlockDevice, blk: u64, src: usize) -> Result<bool, BlockError> {
    let _t: *mut ProcTable = t;
    return bd_write_block(dev, blk, src);
}

export fn proc_dma_charge(t: *mut ProcTable, bytes: u64) -> bool {
    let _t: *mut ProcTable = t;
    let _bytes: u64 = bytes;
    return true;
}

export fn proc_dma_release(t: *mut ProcTable, bytes: u64) -> void {
    let _t: *mut ProcTable = t;
    let _bytes: u64 = bytes;
}
