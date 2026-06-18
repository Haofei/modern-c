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

// A driver provider conforms to the `DriverProvider` trait (docs/spec §32): `probe` tests
// whether this driver matches a device id; `attach` binds the device given its resources and
// returns a driver-instance endpoint; `class` is the device class it exposes on attach. The
// driver's private state is the trait object's `self`. (All `*mut self`: `attach` records
// the binding, and a uniform self-mode keeps registration a single `&driver` coercion.)
trait DriverProvider {
    fn probe(self: *mut Self, id: DeviceId) -> bool;
    fn attach(self: *mut Self, res: ResourceSet) -> u32;
    fn class(self: *mut Self) -> DeviceClass;
}

const MAX_PROVIDERS: usize = 8;

// Each slot is `?*mut dyn DriverProvider` (docs/spec §32.7): `null` = empty, a trait object
// = a registered driver. Absence is the niche (`data == null`), so there is no `present`
// flag to keep in sync, and a slot can only be probed/attached by narrowing it.
struct Bus {
    providers: [MAX_PROVIDERS]?*mut dyn DriverProvider,
    nprov: usize,
}

enum AttachError {
    NoDriver,     // no registered provider matched the device
    RegistryFull, // a driver matched + attached, but its endpoint could not be registered
}

export fn bus_init(bus: *mut Bus) -> void {
    var i: usize = 0;
    while i < MAX_PROVIDERS {
        bus.providers[i] = null; // empty slot
        i = i + 1;
    }
    bus.nprov = 0;
}

// Register a driver provider (any `*mut dyn DriverProvider`); returns its index. Traps if
// the provider table is full.
export fn bus_register_provider(bus: *mut Bus, provider: *mut dyn DriverProvider) -> usize {
    let id: usize = bus.nprov;
    if id >= MAX_PROVIDERS {
        unreachable; // provider table full
    }
    bus.providers[id] = provider; // `*mut dyn` -> `?*mut dyn` (registered)
    bus.nprov = id + 1;
    return id;
}

// Probe `dev` against each provider; the first match attaches it (binds the driver, sets
// the exposed class + endpoint) and records (class_code -> endpoint) in `reg`. Returns the
// matching provider index, or NoDriver.
export fn bus_probe_attach(bus: *mut Bus, dev: *mut Device, reg: *mut Registry) -> Result<usize, AttachError> {
    var i: usize = 0;
    while i < bus.nprov {
        if let p = bus.providers[i] {
            let matched: bool = p.probe(dev.id); // dynamic dispatch through the trait vtable
            if matched {
                let endpoint: u32 = p.attach(dev.res);
                let cls: DeviceClass = p.class();
                // Register the endpoint first; only mark the device attached if a service can
                // actually discover it. An unregisterable endpoint fails the whole transaction.
                switch registry_add(reg, class_code(cls), endpoint, 0) {
                    ok(slot) => {
                        dev.attached = true;
                        dev.class = cls;
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
        } else {}
        i = i + 1;
    }
    return err(.NoDriver);
}
