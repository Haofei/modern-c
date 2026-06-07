// demo/gpio — pin capabilities.
//
// A pin is not a number you can poke; it is a *capability*. `config_output`
// configures the direction and hands back an `OutputPin`; only an `OutputPin`
// can be driven, only an `InputPin` can be read. Passing the wrong kind is a
// compile error (distinct capability types are not interchangeable).

extern mmio struct GpioRegs {
    dir: Reg<u32, .read_write>  @offset(0x00), // 1 = output
    data: Reg<u32, .read_write> @offset(0x04),
}

// Capability tokens: holding one proves the pin is configured for that direction.
struct OutputPin { pin: u32 }
struct InputPin { pin: u32 }

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

// Drive an output pin (capability required).
export fn gpio_set(regs: MmioPtr<GpioRegs>, p: OutputPin, level: bool) -> void {
    let mask: u32 = (1 as u32) << p.pin;
    let cur: u32 = regs.data.read(.acquire);
    switch level {
        true => { regs.data.write(cur | mask, .release); },
        false => { regs.data.write(cur & ~mask, .release); },
    }
}

export fn gpio_get(regs: MmioPtr<GpioRegs>, p: InputPin) -> bool {
    let mask: u32 = (1 as u32) << p.pin;
    return (regs.data.read(.acquire) & mask) != 0;
}

// what the types forbid:
//   gpio_set(regs, config_input(regs, 3), true)  // E_NO_IMPLICIT_CONVERSION: InputPin is not an OutputPin
