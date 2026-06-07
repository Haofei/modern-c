// MC standard library — `virtio`: the virtio-mmio transport (virtio 1.x), shared
// by all virtio device classes (net, block, console, …). Owns the register map,
// the device-init status handshake, and feature negotiation. A device driver
// imports this plus `std/virtqueue` and writes only its device-specific logic.

// virtio-mmio register map (§4.2.2) — reads like the datasheet's register table:
// each register at its exact offset, with its access direction.
extern mmio struct VirtioMmio {
    magic: Reg<u32, .read>                    @offset(0x000), // "virt" = 0x74726976
    version: Reg<u32, .read>                  @offset(0x004), // 2 = modern
    device_id: Reg<u32, .read>                @offset(0x008),
    vendor_id: Reg<u32, .read>                @offset(0x00c),
    device_features: Reg<u32, .read>          @offset(0x010),
    device_features_sel: Reg<u32, .write>     @offset(0x014),
    driver_features: Reg<u32, .write>         @offset(0x020),
    driver_features_sel: Reg<u32, .write>     @offset(0x024),
    queue_sel: Reg<u32, .write>               @offset(0x030),
    queue_num_max: Reg<u32, .read>            @offset(0x034),
    queue_num: Reg<u32, .write>               @offset(0x038),
    queue_ready: Reg<u32, .read_write>        @offset(0x044),
    queue_notify: Reg<u32, .write>            @offset(0x050),
    interrupt_status: Reg<u32, .read>         @offset(0x060),
    interrupt_ack: Reg<u32, .write>           @offset(0x064),
    status: Reg<u32, .read_write>             @offset(0x070),
    queue_desc_low: Reg<u32, .write>          @offset(0x080),
    queue_desc_high: Reg<u32, .write>         @offset(0x084),
    queue_driver_low: Reg<u32, .write>        @offset(0x090),
    queue_driver_high: Reg<u32, .write>       @offset(0x094),
    queue_device_low: Reg<u32, .write>        @offset(0x0a0),
    queue_device_high: Reg<u32, .write>       @offset(0x0a4),
}

// Device status bits (§2.1).
const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;

const VIRTIO_MAGIC: u32 = 0x7472_6976;
const VIRTIO_VERSION_MODERN: u32 = 2;

// The device-init handshake (§3.1.1): verify the device, reset, ACKNOWLEDGE,
// DRIVER, negotiate the requested feature words (lo = bits 0..31, hi = bits
// 32..63), and confirm FEATURES_OK. Returns false if the device is the wrong
// kind or rejects the feature set. Caller then sets up virtqueues and calls
// `driver_ok`.
export fn virtio_init(regs: MmioPtr<VirtioMmio>, device_id: u32, want_lo: u32, want_hi: u32) -> bool {
    if regs.magic.read(.acquire) != VIRTIO_MAGIC {
        return false;
    }
    if regs.version.read(.acquire) != VIRTIO_VERSION_MODERN {
        return false;
    }
    if regs.device_id.read(.acquire) != device_id {
        return false;
    }

    regs.status.write(0, .release); // reset
    regs.status.write(STATUS_ACKNOWLEDGE, .release);
    regs.status.write(STATUS_ACKNOWLEDGE | STATUS_DRIVER, .release);

    regs.driver_features_sel.write(0, .release);
    regs.driver_features.write(want_lo, .release);
    regs.driver_features_sel.write(1, .release);
    regs.driver_features.write(want_hi, .release);

    regs.status.write(STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK, .release);
    if (regs.status.read(.acquire) & STATUS_FEATURES_OK) != STATUS_FEATURES_OK {
        return false;
    }
    return true;
}

// Signal the device that the driver is live (after queue setup).
export fn virtio_driver_ok(regs: MmioPtr<VirtioMmio>) -> void {
    regs.status.write(STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK, .release);
}
