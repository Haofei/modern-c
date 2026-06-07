// demo/virtio-blk — block IO over a virtio DMA queue (request/response).
//
// A block request carries DMA buffers with distinct device directions: the
// 16-byte header is device-readable, the 512-byte data is device-writable (for a
// read), and a status byte the device writes. Each is a linear DMA handle, so the
// CPU cannot read the data until the device returns it. (A production driver
// publishes a 3-descriptor chain — header RO, data RW, status RW; that needs the
// descriptor-chain API, the P1 increment, so the chain submit is a primitive here.)

import "std/virtqueue.mc";

const VIRTIO_BLK_T_IN: u32 = 0;  // read from device
const VIRTIO_BLK_T_OUT: u32 = 1; // write to device

// virtio-blk request header (§5.2.6).
struct BlkReqHeader {
    kind: u32,
    reserved: u32,
    sector: u64,
}

// Publish the header + data as a request chain; returns the in-flight data handle.
extern fn mc_blk_submit(vq: *mut Virtq, hdr: DeviceBuffer, data: DeviceBuffer) -> DeviceBuffer;

// Read one 512-byte sector into a freshly reclaimed CPU buffer.
export fn read_sector(regs: MmioPtr<VirtioMmio>, vq: *mut Virtq, sector: u64) -> bool {
    let hdr_cpu: CpuBuffer = alloc(16);
    let data_cpu: CpuBuffer = alloc(512);

    // (The header fields — kind = VIRTIO_BLK_T_IN, sector — are written into
    // hdr_cpu's memory before handoff; omitted here for brevity.)
    let hdr: DeviceBuffer = clean_for_device(hdr_cpu);   // hdr_cpu consumed
    let data: DeviceBuffer = clean_for_device(data_cpu); // data_cpu consumed

    let inflight: DeviceBuffer = mc_blk_submit(vq, hdr, data); // hdr + data handed to device
    vq_kick(regs, 0);
    let ready: bool = vq_wait_used(vq, 1_000_000);

    // Reclaim the data buffer for the CPU before reading it.
    let result: CpuBuffer = invalidate_for_cpu(inflight);
    free(result);
    return ready;
}

// what the types forbid:
//   reading data_cpu after clean_for_device   // E_USE_AFTER_MOVE: it is device-owned
//   passing a CpuBuffer to mc_blk_submit       // E_NO_IMPLICIT_CONVERSION: needs DeviceBuffer
