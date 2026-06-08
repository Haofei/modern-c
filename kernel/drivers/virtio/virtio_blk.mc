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
    Timeout,    // the device did not complete the request in time
    IoError,    // the device reported a non-OK status
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

    // Keep the CPU-visible addresses to read the results back (QEMU is coherent;
    // a real platform would reclaim via invalidate_for_cpu after the chain).
    let data_addr: PAddr = cpu_addr(&data);
    let status_addr: PAddr = cpu_addr(&status);

    let hdr_d: DeviceBuffer = clean_for_device(hdr);
    let data_d: DeviceBuffer = clean_for_device(data);
    let status_d: DeviceBuffer = clean_for_device(status);

    vq_submit_chain3(vq, hdr_d, data_d, status_d, true);
    vq_kick(regs, 0);

    if !vq_wait_used(vq, IO_TIMEOUT_TICKS) {
        return err(.Timeout);
    }
    let used: u32 = vq_complete_chain(vq);

    var st: u8 = 0;
    var first: u32 = 0;
    unsafe {
        st = raw.load<u8>(status_addr);
        first = raw.load<u32>(data_addr);
    }
    if st != BLK_STATUS_OK {
        return err(.IoError);
    }
    return ok(first);
}
