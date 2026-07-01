// kernel/core/proc_blk — the block-I/O accounting seam over the block-device layer.
//
// The block layer (kernel/fs/blockdev.mc) does device I/O through a `*dyn BlockDevice` vtable but
// carries no per-table accounting. These thin wrappers route a block read/write through the
// ProcTable's UNIFIED ledger (charge one BlockIo unit per op) and the hot-path metrics (BlkRead /
// BlkWrite), then perform the real device I/O via bd_read_block / bd_write_block. This is the
// representative wiring of task (A)/(B) for the block dimension: a caller that wants I/O accounted
// against the table's budgets calls these instead of the bare bd_* funnels; the raw funnels remain
// for un-accounted internal use.
//
// FAIL-CLEAN: if the ledger refuses the BlockIo charge (over limit), the op returns err(.IoError)
// WITHOUT touching the device — the ledger gates real I/O, and an over-limit request is a clean
// no-op, never a trap. A BlockIo dimension with limit 0 is unlimited, so an un-configured ledger
// never blocks I/O.

import "kernel/core/process.mc";
import "kernel/fs/blockdev.mc";

// Charged block read: charge one BlockIo unit, meter BlkRead, then read block `blk` into `dst`
// through the device. err(.IoError) with the device untouched if the ledger refuses the charge.
export fn proc_blk_read(t: *mut ProcTable, dev: *dyn BlockDevice, blk: u64, dst: usize) -> Result<bool, BlockError> {
    switch ledger_charge(proc_ledger(t), .BlockIo, 1) {
        ok(v) => {}
        err(e) => { return err(.IoError); } // over the BlockIo ceiling — gate the I/O, do not trap
    }
    metrics_inc(proc_metrics(t), .BlkRead); // hot-path counter: a block read was issued
    return bd_read_block(dev, blk, dst);
}

// Charged block write: charge one BlockIo unit, meter BlkWrite, then write block `blk` from `src`
// through the device. err(.IoError) with the device untouched if the ledger refuses the charge.
export fn proc_blk_write(t: *mut ProcTable, dev: *dyn BlockDevice, blk: u64, src: usize) -> Result<bool, BlockError> {
    switch ledger_charge(proc_ledger(t), .BlockIo, 1) {
        ok(v) => {}
        err(e) => { return err(.IoError); } // over the BlockIo ceiling — gate the I/O, do not trap
    }
    metrics_inc(proc_metrics(t), .BlkWrite); // hot-path counter: a block write was issued
    return bd_write_block(dev, blk, src);
}

// ----- DMA accounting seam (representative wiring for the DmaBytes dimension) -----
// The std/alloc/dma.mc provider (mc_dma_alloc_base) carries no ProcTable, so DMA byte accounting
// rides this seam: a driver charges `bytes` against the DmaBytes dimension at the alloc point and
// releases them on free. Over-limit returns false (the caller degrades — e.g. dma.try_alloc's
// OutOfMemory path) rather than trapping. A DmaBytes limit of 0 is unlimited.
export fn proc_dma_charge(t: *mut ProcTable, bytes: u64) -> bool {
    switch ledger_charge(proc_ledger(t), .DmaBytes, bytes) {
        ok(v) => { return true; }
        err(e) => { return false; } // over the DmaBytes ceiling — reserve nothing, do not trap
    }
}

// Release `bytes` of previously-charged device DMA on free (saturating; refuses an underflow).
export fn proc_dma_release(t: *mut ProcTable, bytes: u64) -> void {
    switch ledger_release(proc_ledger(t), .DmaBytes, bytes) {
        ok(v) => {}
        err(e) => {}
    }
}
