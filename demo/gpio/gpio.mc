// demo/gpio — pin capabilities (linear).
//
// A pin is not a number you can poke; it is a *capability*. `config_output`
// configures the direction and hands back a linear `OutputPin`; only an
// `OutputPin` can be driven, only an `InputPin` read, and the capability must be
// released exactly once. Passing the wrong kind is a compile error (distinct
// capability types), and a copied/leaked capability is a compile error (linear).

extern mmio struct GpioRegs {
    dir: Reg<u32, .read_write>  @offset(0x00), // 1 = output
    data: Reg<u32, .read_write> @offset(0x04),
}

// Capability tokens: holding one proves the pin is configured for that direction.
// `move` = a pin is owned by exactly one holder; it cannot be duplicated.
move struct OutputPin { pin: u32 }
move struct InputPin { pin: u32 }

#[mc_abi]
export fn config_output(regs: MmioPtr<GpioRegs>, pin: u32) -> OutputPin {
    let mask: u32 = (1 as u32) << pin;
    let cur: u32 = regs.dir.read(.acquire);
    regs.dir.write(cur | mask, .release);
    return .{ .pin = pin };
}

#[mc_abi]
export fn config_input(regs: MmioPtr<GpioRegs>, pin: u32) -> InputPin {
    let mask: u32 = (1 as u32) << pin;
    let cur: u32 = regs.dir.read(.acquire);
    regs.dir.write(cur & ~mask, .release);
    return .{ .pin = pin };
}

// Releasing a capability consumes it (the pin may be reconfigured afterwards).
extern fn release_output(p: OutputPin) -> void;
extern fn release_input(p: InputPin) -> void;

// Drive an output pin. Consumes and returns the capability so no pointer to
// move-only storage crosses the exported boundary.
fn gpio_set(regs: MmioPtr<GpioRegs>, p: OutputPin, level: bool) -> OutputPin {
    let mask: u32 = (1 as u32) << p.pin;
    let cur: u32 = regs.data.read(.acquire);
    switch level {
        true => { regs.data.write(cur | mask, .release); },
        false => { regs.data.write(cur & ~mask, .release); },
    }
    return move p;
}

fn gpio_get(regs: MmioPtr<GpioRegs>, p: InputPin) -> InputPin {
    let mask: u32 = (1 as u32) << p.pin;
    let _level: bool = (regs.data.read(.acquire) & mask) != 0;
    return move p;
}

// Blink: configure as output, drive high then low, release the capability.
export fn blink(regs: MmioPtr<GpioRegs>, pin: u32) -> void {
    let led0: OutputPin = config_output(regs, pin);
    let led1: OutputPin = gpio_set(regs, move led0, true);
    let led2: OutputPin = gpio_set(regs, move led1, false);
    release_output(move led2); // consume the capability
}

// what the types forbid:
//   gpio_set(regs, move input_cap, true) // E_NO_IMPLICIT_CONVERSION: InputPin is not an OutputPin
//   gpio_set after release_output(led)   // E_USE_AFTER_MOVE
//   forgetting release_output(led)       // E_RESOURCE_LEAK
