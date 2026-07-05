// kernel/drivers/virtio/virtio_blk — a virtio-blk driver: bring the device up and
// read a 512-byte sector with a three-descriptor request chain (header / data /
// status), the standard virtio-blk request layout. Errors are typed; the request
// is bounded by a real-time deadline (fail closed, not a spin forever). Built on
// the shared transport (std/virtio), virtqueue chain (std/virtqueue), and DMA
// ownership (std/dma) — the same layering the net driver uses.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "std/alloc/dma.mc";
import "std/mem.mc";
import "std/time.mc";
import "std/addr.mc";
import "kernel/fs/blockdev.mc";

const VIRTIO_BLK_DEVICE_ID: u32 = 2;
const VIRTIO_BLK_T_IN: u32 = 0;  // read from disk into memory
const VIRTIO_BLK_T_OUT: u32 = 1; // write from memory to disk
const SECTOR_SIZE: usize = 512;
const BLK_HDR_SIZE: usize = 16;
const BLK_STATUS_OK: u8 = 0;
const IO_TIMEOUT_TICKS: u64 = 50_000_000; // ~5s of CLINT ticks

enum BlkError {
    DeviceInitFailed,
    QueueUnavailable,
    Timeout,      // the device did not complete the request in time
    IoError,      // the device reported a non-OK status
    DeviceFault,  // the device returned an inconsistent completion (bad id/len/chain)
}

struct BlkDevice {
    regs: MmioPtr<VirtioMmio>,
    vq: *mut Virtq,
}

// Bring the block device up: handshake (no required features), set up the request
// queue, go live.
export fn blk_init(dev: *BlkDevice) -> Result<bool, BlkError> {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let vq: *mut Virtq = dev.vq;
    switch virtio_init(regs, VIRTIO_BLK_DEVICE_ID, 0, 0) {
        ok(up) => {}
        err(e) => {
            return err(.DeviceInitFailed);
        }
    }
    switch vq_setup(regs, 0, vq) {
        ok(up) => {}
        err(e) => {
            return err(.QueueUnavailable);
        }
    }
    virtio_driver_ok(regs);
    return ok(true);
}

// Read sector `sector` (512 bytes). Returns the first little-endian word of the
// sector on success (enough to verify the read), or a typed error. Submits the
// virtio-blk request as header(read) -> data(device-writable) -> status(device-
// writable) and waits for completion under a deadline.
export fn blk_read_sector(dev: *BlkDevice, sector: u64) -> Result<u32, BlkError> {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let vq: *mut Virtq = dev.vq;

    // Request header (little-endian): type, reserved, sector.
    var hdr: CpuBuffer = alloc(BLK_HDR_SIZE);
    write_le32(&hdr, 0, VIRTIO_BLK_T_IN);
    write_le32(&hdr, 4, 0);
    write_le64(&hdr, 8, sector);

    var data: CpuBuffer = alloc(SECTOR_SIZE); // the device writes the sector here
    var status: CpuBuffer = alloc(1);         // the device writes the status byte here

    let hdr_d: DeviceBuffer = clean_for_device(hdr);
    let data_d: DeviceBuffer = clean_for_device(data);
    let status_d: DeviceBuffer = clean_for_device(status);

    switch vq_submit_chain3(vq, hdr_d, data_d, status_d, true) {
        ok(id) => {}
        err(e) => {
            return err(.QueueUnavailable); // not enough descriptors; buffers reclaimed inside
        }
    }
    vq_kick(regs, 0);

    if !vq_wait_used(vq, IO_TIMEOUT_TICKS) {
        // The request is still in flight: the device owns the buffers and may yet write them.
        // Reset so it relinquishes ownership; only THEN is it safe to reconstruct and free the
        // in-flight buffers. If the reset is not acknowledged the device may still write them,
        // so reclaiming (freeing) them would be a use-after-free racing the device — leak the
        // backing memory instead. Either way the device is poisoned; blk_init before reuse.
        if virtio_reset(regs) {
            vq_reset_reclaim(vq);
        }
        return err(.Timeout);
    }
    // Take the three buffers back as owned handles (the descriptors are freed inside).
    var first: u32 = 0;
    var io_ok: bool = false;
    switch vq_complete_chain(vq) {
        ok(done) => {
            // Move each owned buffer out of the completed chain, then consume the
            // (now empty) chain shell. Reclaim each buffer through the typed DMA path
            // (invalidate caches, regain CPU ownership) and read the results through
            // bounds-checked views.
            let hbuf: DeviceBuffer = done.header;
            let dbuf: DeviceBuffer = done.data;
            let sbuf: DeviceBuffer = done.status;
            unsafe { forget_unchecked(done); }
            let chdr: CpuBuffer = invalidate_for_cpu(hbuf);
            let cdata: CpuBuffer = invalidate_for_cpu(dbuf);
            let cstatus: CpuBuffer = invalidate_for_cpu(sbuf);
            first = read_le32(&cdata, 0);
            io_ok = read_u8(&cstatus, 0) == BLK_STATUS_OK;
            free(chdr);
            free(cdata);
            free(cstatus);
        }
        err(e) => {
            // The device returned an inconsistent completion (bad id/len/chain). Reset so it
            // relinquishes the in-flight buffers, then reclaim them — but only if the reset is
            // acknowledged; otherwise the device may still write them and freeing would be a
            // use-after-free, so leak the backing memory instead. The device is poisoned.
            if virtio_reset(regs) {
                vq_reset_reclaim(vq);
            }
            return err(.DeviceFault);
        }
    }
    if !io_ok {
        return err(.IoError);
    }
    return ok(first);
}

// Read a full 512-byte sector into `dst` (a kernel PAddr with room for SECTOR_SIZE bytes). Like
// blk_read_sector but copies the WHOLE sector out (not just the first word) — the read half of a
// BlockDevice over virtio-blk (durable storage, production-readiness §3.1 #3).
export fn blk_read_into(dev: *BlkDevice, sector: u64, dst: PAddr) -> Result<bool, BlkError> {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let vq: *mut Virtq = dev.vq;

    var hdr: CpuBuffer = alloc(BLK_HDR_SIZE);
    write_le32(&hdr, 0, VIRTIO_BLK_T_IN);
    write_le32(&hdr, 4, 0);
    write_le64(&hdr, 8, sector);
    var data: CpuBuffer = alloc(SECTOR_SIZE); // the device writes the sector here
    var status: CpuBuffer = alloc(1);

    let hdr_d: DeviceBuffer = clean_for_device(hdr);
    let data_d: DeviceBuffer = clean_for_device(data);
    let status_d: DeviceBuffer = clean_for_device(status);

    switch vq_submit_chain3(vq, hdr_d, data_d, status_d, true) { // data device-writable (read)
        ok(id) => {}
        err(e) => { return err(.QueueUnavailable); }
    }
    vq_kick(regs, 0);
    if !vq_wait_used(vq, IO_TIMEOUT_TICKS) {
        if virtio_reset(regs) { vq_reset_reclaim(vq); }
        return err(.Timeout);
    }
    var io_ok: bool = false;
    switch vq_complete_chain(vq) {
        ok(done) => {
            let hbuf: DeviceBuffer = done.header;
            let dbuf: DeviceBuffer = done.data;
            let sbuf: DeviceBuffer = done.status;
            unsafe { forget_unchecked(done); }
            let chdr: CpuBuffer = invalidate_for_cpu(hbuf);
            let cdata: CpuBuffer = invalidate_for_cpu(dbuf);
            let cstatus: CpuBuffer = invalidate_for_cpu(sbuf);
            mem_copy(dst, cpu_addr(&cdata), SECTOR_SIZE); // hand the whole sector to the caller
            io_ok = read_u8(&cstatus, 0) == BLK_STATUS_OK;
            free(chdr);
            free(cdata);
            free(cstatus);
        }
        err(e) => {
            if virtio_reset(regs) { vq_reset_reclaim(vq); }
            return err(.DeviceFault);
        }
    }
    if !io_ok {
        return err(.IoError);
    }
    return ok(true);
}

// Write a full 512-byte sector from `src` (a kernel PAddr holding SECTOR_SIZE bytes) to disk. The
// write half of a BlockDevice over virtio-blk: header(read) -> data(device-READABLE, the bytes to
// write) -> status(device-writable). Mirrors blk_read_into but the data descriptor is device-
// readable and we load it from `src` before flushing it to the device.
export fn blk_write(dev: *BlkDevice, sector: u64, src: PAddr) -> Result<bool, BlkError> {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let vq: *mut Virtq = dev.vq;

    var hdr: CpuBuffer = alloc(BLK_HDR_SIZE);
    write_le32(&hdr, 0, VIRTIO_BLK_T_OUT);
    write_le32(&hdr, 4, 0);
    write_le64(&hdr, 8, sector);
    var data: CpuBuffer = alloc(SECTOR_SIZE);
    mem_copy(cpu_addr(&data), src, SECTOR_SIZE); // the bytes to write, into the DMA buffer
    var status: CpuBuffer = alloc(1);

    let hdr_d: DeviceBuffer = clean_for_device(hdr);
    let data_d: DeviceBuffer = clean_for_device(data); // flush the write data out to the device
    let status_d: DeviceBuffer = clean_for_device(status);

    switch vq_submit_chain3(vq, hdr_d, data_d, status_d, false) { // data device-READABLE (write)
        ok(id) => {}
        err(e) => { return err(.QueueUnavailable); }
    }
    vq_kick(regs, 0);
    if !vq_wait_used(vq, IO_TIMEOUT_TICKS) {
        if virtio_reset(regs) { vq_reset_reclaim(vq); }
        return err(.Timeout);
    }
    var io_ok: bool = false;
    switch vq_complete_chain(vq) {
        ok(done) => {
            let hbuf: DeviceBuffer = done.header;
            let dbuf: DeviceBuffer = done.data;
            let sbuf: DeviceBuffer = done.status;
            unsafe { forget_unchecked(done); }
            let chdr: CpuBuffer = invalidate_for_cpu(hbuf);
            let cdata: CpuBuffer = invalidate_for_cpu(dbuf);
            let cstatus: CpuBuffer = invalidate_for_cpu(sbuf);
            io_ok = read_u8(&cstatus, 0) == BLK_STATUS_OK;
            free(chdr);
            free(cdata);
            free(cstatus);
        }
        err(e) => {
            if virtio_reset(regs) { vq_reset_reclaim(vq); }
            return err(.DeviceFault);
        }
    }
    if !io_ok {
        return err(.IoError);
    }
    return ok(true);
}

// ---- BlockDevice adapter -------------------------------------------------------------------
// Adapt the driver to the generic BlockDevice trait (kernel/fs/blockdev.mc). This is the
// production counterpart to the RAM-disk `impl BlockDevice for Disk` used in the host/proc
// tests: it routes the trait's read/write through the real virtio-blk full-sector paths
// (blk_read_into / blk_write, both 512 B), so block-backed services — e.g. durable
// policy/audit checkpointing (kernel/core/block_persistent_audit.mc) — run unchanged over a
// real disk under QEMU/board paths. It lives here (not in a peer file) because a trait impl
// must be in the file that declares the type (E_ORPHAN_IMPL).

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
