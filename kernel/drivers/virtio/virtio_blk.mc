// kernel/drivers/virtio/virtio_blk — a virtio-blk driver: bring the device up and
// read a 512-byte sector with a three-descriptor request chain (header / data /
// status), the standard virtio-blk request layout. Errors are typed; the request
// is bounded by a real-time deadline (fail closed, not a spin forever). Built on
// the shared transport (std/virtio), virtqueue chain (std/virtqueue), and DMA
// ownership (std/dma) — the same layering the net driver uses.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "std/dma.mc";
import "std/time.mc";

const VIRTIO_BLK_DEVICE_ID: u32 = 2;
const VIRTIO_BLK_T_IN: u32 = 0; // read from disk into memory
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

    vq_submit_chain3(vq, hdr_d, data_d, status_d, true);
    vq_kick(regs, 0);

    if !vq_wait_used(vq, IO_TIMEOUT_TICKS) {
        // The request is still in flight: the device owns the buffers and may yet write
        // them. Reset the device so it relinquishes ownership, then reclaim and free every
        // in-flight buffer — failing closed without abandoning the DMA allocations.
        virtio_reset(regs);
        vq_reset_reclaim(vq);
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
            drop(done);
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
            // The device returned an inconsistent completion (bad id/len/chain). Reset the
            // device and reclaim every in-flight buffer rather than leaving them queued.
            virtio_reset(regs);
            vq_reset_reclaim(vq);
            return err(.DeviceFault);
        }
    }
    if !io_ok {
        return err(.IoError);
    }
    return ok(first);
}
