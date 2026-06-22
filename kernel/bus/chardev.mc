// kernel/bus/chardev — a char-device driver registry.
//
// A driver conforms to the `CharDevice` trait (docs/spec/MC_0.7_Final_Design.md §32),
// supplying a `putc` operation; the kernel writes characters through the registry,
// dispatching via the trait vtable. This decouples the console/log layer from any
// concrete device — the driver-framework core. A registered slot holds one `*dyn
// CharDevice` (the driver object is the trait object's `data`; the vtable is shared
// rodata). Registration is bounds-checked; writing to a missing or unregistered device
// fails closed.

const MAX_CHARDEV: usize = 4;

trait CharDevice {
    fn putc(self: *Self, b: u8) -> void; // the driver's private context is `self`
}

// Each slot is `?*dyn CharDevice` (docs/spec/MC_0.7_Final_Design.md §32.7): `null` =
// absent, a trait object = registered. Absence is the type's niche (`data == null`), so
// there is no parallel `present` flag to keep in sync — a slot can only be dispatched by
// narrowing it, which type-checks that it is present.
struct CharRegistry {
    devs: [MAX_CHARDEV]?*dyn CharDevice,
    count: usize,
}

export fn char_registry_init(reg: *mut CharRegistry) -> void {
    var i: usize = 0;
    while i < MAX_CHARDEV {
        reg.devs[i] = null; // absent
        i = i + 1;
    }
    reg.count = 0;
}

// Register a char device (any `*dyn CharDevice`), returning its id. Traps if full.
export fn register_chardev(reg: *mut CharRegistry, dev: *dyn CharDevice) -> usize {
    let id: usize = reg.count;
    if id >= MAX_CHARDEV {
        unreachable; // registry full
    }
    reg.devs[id] = dev; // `*dyn CharDevice` -> `?*dyn CharDevice` (present)
    reg.count = id + 1;
    return id;
}

// Write one byte to device `id` through its registered op.
export fn chardev_putc(reg: *mut CharRegistry, id: usize, b: u8) -> void {
    if id >= reg.count {
        unreachable; // no such device
    }
    if let d = reg.devs[id] {
        d.putc(b); // dynamic dispatch through the trait vtable
    } else {
        unreachable; // slot < count is always registered
    }
}
