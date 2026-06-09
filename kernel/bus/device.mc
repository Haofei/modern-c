// kernel/bus/device — the device model + a probe/attach driver-binding table. A platform
// describes devices (an id + a resource set); a bus matches each device against registered
// driver providers (probe), and the first match attaches (binds the driver, exposing a
// device class and an endpoint handle, recorded in the registry). This is the "drivers plug
// into buses" half of the plugin model, with static fixed-capacity registration.

import "kernel/lib/registry.mc";

enum DeviceClass {
    None,
    Block,
    Net,
    Console,
    Framebuffer,
    Timer,
}

// A stable numeric code for a class, usable as a registry key.
export fn class_code(c: DeviceClass) -> u32 {
    switch c {
        .None => { return 0; }
        .Block => { return 1; }
        .Net => { return 2; }
        .Console => { return 3; }
        .Framebuffer => { return 4; }
        .Timer => { return 5; }
    }
}

struct DeviceId {
    vendor: u32,
    device: u32,
}

struct ResourceSet {
    mmio_base: usize,
    mmio_len: usize,
    irq: u32,
}

struct Device {
    id: DeviceId,
    res: ResourceSet,
    attached: bool,
    class: DeviceClass, // exposed once a driver attaches
    endpoint: u32,      // the attached driver-instance handle
}

// A driver provider: `probe` tests whether this driver matches a device id; `attach` binds
// the device given its resources and returns a driver-instance endpoint. Closures, so a
// driver captures its private state. `class` is the device class it exposes on attach.
struct Provider {
    probe: closure(DeviceId) -> bool,
    attach: closure(ResourceSet) -> u32,
    class: DeviceClass,
    present: bool,
}

const MAX_PROVIDERS: usize = 8;

struct Bus {
    providers: [MAX_PROVIDERS]Provider,
    nprov: usize,
}

enum AttachError {
    NoDriver,     // no registered provider matched the device
    RegistryFull, // a driver matched + attached, but its endpoint could not be registered
}

export fn bus_init(bus: *mut Bus) -> void {
    var i: usize = 0;
    while i < MAX_PROVIDERS {
        bus.providers[i].present = false;
        i = i + 1;
    }
    bus.nprov = 0;
}

// Register a driver provider; returns its index. Traps if the provider table is full.
export fn bus_register_provider(bus: *mut Bus, probe: closure(DeviceId) -> bool, attach: closure(ResourceSet) -> u32, class: DeviceClass) -> usize {
    let id: usize = bus.nprov;
    if id >= MAX_PROVIDERS {
        unreachable; // provider table full
    }
    bus.providers[id].probe = probe;
    bus.providers[id].attach = attach;
    bus.providers[id].class = class;
    bus.providers[id].present = true;
    bus.nprov = id + 1;
    return id;
}

// Probe `dev` against each provider; the first match attaches it (binds the driver, sets
// the exposed class + endpoint) and records (class_code -> endpoint) in `reg`. Returns the
// matching provider index, or NoDriver.
export fn bus_probe_attach(bus: *mut Bus, dev: *mut Device, reg: *mut Registry) -> Result<usize, AttachError> {
    var i: usize = 0;
    while i < bus.nprov {
        let p: *Provider = &bus.providers[i];
        if p.present {
            let probe: closure(DeviceId) -> bool = p.probe;
            if probe(dev.id) {
                let attach: closure(ResourceSet) -> u32 = p.attach;
                let endpoint: u32 = attach(dev.res);
                // Register the endpoint first; only mark the device attached if a service can
                // actually discover it. An unregisterable endpoint fails the whole transaction.
                switch registry_add(reg, class_code(p.class), endpoint, 0) {
                    ok(slot) => {
                        dev.attached = true;
                        dev.class = p.class;
                        dev.endpoint = endpoint;
                        return ok(i);
                    }
                    err(e) => {
                        dev.attached = false;
                        dev.class = .None;
                        dev.endpoint = 0;
                        return err(.RegistryFull);
                    }
                }
            }
        }
        i = i + 1;
    }
    return err(.NoDriver);
}
