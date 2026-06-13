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
const STATUS_FAILED: u32 = 128; // bit 7: the driver has given up on the device

const VIRTIO_MAGIC: u32 = 0x7472_6976;
const VIRTIO_VERSION_MODERN: u32 = 2;

const RESET_SPINS: u32 = 100_000;

// Why the device-init handshake failed — a typed error instead of a bare `bool`,
// so a driver (and its logs) can tell *which* step went wrong.
enum VirtioError {
    NotVirtio,           // wrong magic — no virtio device at this address
    UnsupportedVersion,  // legacy/unknown transport version
    WrongDeviceId,       // a virtio device, but not the class we asked for
    ResetTimeout,        // device never acknowledged reset
    FeaturesUnsupported, // device does not offer a feature we require
    FeaturesNotAccepted, // device rejected FEATURES_OK
}

// Tell the device the driver has given up (§2.1.2).
fn mark_failed(regs: MmioPtr<VirtioMmio>) -> void {
    regs.status.write(STATUS_FAILED, .release);
}

// Reset the device and wait for it to acknowledge (status reads back 0). Returns true on
// acknowledgement, false on timeout. Used by the init handshake and by a driver reclaiming
// a queue after a fault: the reset makes the device relinquish ownership of every in-flight
// buffer, so the driver can then reclaim them without racing device writes.
export fn virtio_reset(regs: MmioPtr<VirtioMmio>) -> bool {
    regs.status.write(0, .release);
    var spins: u32 = 0;
    while spins < RESET_SPINS {
        if regs.status.read(.acquire) == 0 {
            return true;
        }
        spins = spins + 1;
    }
    return false;
}

// The device-init handshake (§3.1.1): verify the device; reset and wait for the
// device to acknowledge it (status reads back 0); ACKNOWLEDGE + DRIVER; read the
// device's *offered* features and accept only the intersection with what we want
// (failing if a required bit is missing); confirm FEATURES_OK. On any failure the
// device is moved to FAILED and a typed `VirtioError` is returned. The requested
// feature words are lo = bits 0..31, hi = bits 32..63. Caller then sets up
// virtqueues and calls `driver_ok`.
export fn virtio_init(regs: MmioPtr<VirtioMmio>, device_id: u32, want_lo: u32, want_hi: u32) -> Result<bool, VirtioError> {
    if regs.magic.read(.acquire) != VIRTIO_MAGIC {
        return err(.NotVirtio); // not a virtio device at all — nothing to FAIL
    }
    if regs.version.read(.acquire) != VIRTIO_VERSION_MODERN {
        mark_failed(regs);
        return err(.UnsupportedVersion);
    }
    if regs.device_id.read(.acquire) != device_id {
        mark_failed(regs);
        return err(.WrongDeviceId);
    }

    // Reset, then poll until the device confirms (status == 0).
    if !virtio_reset(regs) {
        mark_failed(regs);
        return err(.ResetTimeout);
    }

    regs.status.write(STATUS_ACKNOWLEDGE, .release);
    regs.status.write(STATUS_ACKNOWLEDGE | STATUS_DRIVER, .release);

    // Read the device's offered features (both 32-bit words) and require that it
    // offers everything we need; accept exactly the intersection.
    regs.device_features_sel.write(0, .release);
    let offered_lo: u32 = regs.device_features.read(.acquire);
    regs.device_features_sel.write(1, .release);
    let offered_hi: u32 = regs.device_features.read(.acquire);
    if (offered_lo & want_lo) != want_lo {
        mark_failed(regs);
        return err(.FeaturesUnsupported);
    }
    if (offered_hi & want_hi) != want_hi {
        mark_failed(regs);
        return err(.FeaturesUnsupported);
    }

    regs.driver_features_sel.write(0, .release);
    regs.driver_features.write(offered_lo & want_lo, .release);
    regs.driver_features_sel.write(1, .release);
    regs.driver_features.write(offered_hi & want_hi, .release);

    regs.status.write(STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK, .release);
    if (regs.status.read(.acquire) & STATUS_FEATURES_OK) != STATUS_FEATURES_OK {
        mark_failed(regs);
        return err(.FeaturesNotAccepted);
    }
    return ok(true);
}

// Signal the device that the driver is live (after queue setup).
export fn virtio_driver_ok(regs: MmioPtr<VirtioMmio>) -> void {
    regs.status.write(STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK, .release);
}
