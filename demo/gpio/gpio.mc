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

export fn config_output(regs: MmioPtr<GpioRegs>, pin: u32) -> OutputPin {
    let mask: u32 = (1 as u32) << pin;
    let cur: u32 = regs.dir.read(.acquire);
    regs.dir.write(cur | mask, .release);
    return .{ .pin = pin };
}

export fn config_input(regs: MmioPtr<GpioRegs>, pin: u32) -> InputPin {
    let mask: u32 = (1 as u32) << pin;
    let cur: u32 = regs.dir.read(.acquire);
    regs.dir.write(cur & ~mask, .release);
    return .{ .pin = pin };
}

// Releasing a capability consumes it (the pin may be reconfigured afterwards).
extern fn release_output(p: OutputPin) -> void;
extern fn release_input(p: InputPin) -> void;

// Drive an output pin. Borrows the capability, so a pin can be driven repeatedly
// while it is held.
export fn gpio_set(regs: MmioPtr<GpioRegs>, p: *OutputPin, level: bool) -> void {
    let mask: u32 = (1 as u32) << p.pin;
    let cur: u32 = regs.data.read(.acquire);
    switch level {
        true => { regs.data.write(cur | mask, .release); },
        false => { regs.data.write(cur & ~mask, .release); },
    }
}

export fn gpio_get(regs: MmioPtr<GpioRegs>, p: *InputPin) -> bool {
    let mask: u32 = (1 as u32) << p.pin;
    return (regs.data.read(.acquire) & mask) != 0;
}

// Blink: configure as output, drive high then low, release the capability.
export fn blink(regs: MmioPtr<GpioRegs>, pin: u32) -> void {
    let led: OutputPin = config_output(regs, pin);
    gpio_set(regs, &led, true);
    gpio_set(regs, &led, false);
    release_output(led); // consume the capability
}

// what the types forbid:
//   gpio_set(regs, &input_cap, true)   // E_NO_IMPLICIT_CONVERSION: InputPin is not an OutputPin
//   gpio_set after release_output(led) // E_USE_AFTER_MOVE
//   forgetting release_output(led)     // E_RESOURCE_LEAK
