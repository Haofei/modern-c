// kernel/core/device — a char-device driver registry.
//
// A driver registers a `putc` operation (a function pointer) plus a private context
// word (e.g. its MMIO base address); the kernel writes characters through the
// registry, dispatching via the function pointer. This decouples the console/log
// layer from any concrete device — the driver-framework core, function-pointer
// dispatch in real use. Registration is bounds-checked; writing to a missing or
// unregistered device fails closed.

const MAX_CHARDEV: usize = 4;

struct CharDevice {
    putc: closure(u8) -> void, // a capturing function value: the driver's private
                               // context (e.g. its MMIO base) is captured, not threaded
                               // through a separate untyped ctx word.
    present: bool,
}

struct CharRegistry {
    devs: [MAX_CHARDEV]CharDevice,
    count: usize,
}

export fn char_registry_init(reg: *mut CharRegistry) -> void {
    var i: usize = 0;
    while i < MAX_CHARDEV {
        reg.devs[i].present = false;
        i = i + 1;
    }
    reg.count = 0;
}

// Register a char device's write closure, returning its id. Traps if full.
export fn register_chardev(reg: *mut CharRegistry, putc: closure(u8) -> void) -> usize {
    let id: usize = reg.count;
    if id >= MAX_CHARDEV {
        unreachable; // registry full
    }
    reg.devs[id].putc = putc;
    reg.devs[id].present = true;
    reg.count = id + 1;
    return id;
}

// Write one byte to device `id` through its registered op.
export fn chardev_putc(reg: *mut CharRegistry, id: usize, b: u8) -> void {
    if id >= reg.count {
        unreachable; // no such device
    }
    let dev: *CharDevice = &reg.devs[id];
    let present: bool = dev.present;
    if !present {
        unreachable; // device unregistered
    }
    let write: closure(u8) -> void = dev.putc;
    write(b); // dispatches through the closure's {code, env}
}
