// SPEC: section=22
// SPEC: milestone=comptime-runtime-effects
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_COMPTIME_FORBIDS_RUNTIME_EFFECT,E_COMPTIME_TRAP

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    lsr: Reg<u8, .read>,
}

extern fn runtime_value() -> u32;

fn accept_pure_comptime_block() -> u32 {
    comptime {
        let x: u32 = 1;
        assert(true);
    }
    return 1;
}

fn reject_comptime_raw_store(addr: PAddr, value: u64) -> void {
    comptime {
        unsafe {
            // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
            raw.store<u64>(addr, value);
        }
    }
}

fn reject_comptime_mmio_map(pa: PAddr) -> void {
    comptime {
        unsafe {
            // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
            mmio.map<Uart16550>(pa)?;
        }
    }
}

fn reject_comptime_asm() -> void {
    comptime {
        unsafe {
            // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
            asm opaque volatile {
                "cli"
            }
        }
    }
}

fn reject_comptime_cpu_pause() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
        cpu.pause();
    }
}

fn reject_comptime_runtime_call() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
        let x: u32 = runtime_value();
    }
}

fn reject_comptime_return() -> u32 {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
        return 1;
    }
    return 2;
}

fn reject_comptime_break() -> void {
    while true {
        comptime {
            // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
            break;
        }
    }
}

fn reject_comptime_continue() -> void {
    while true {
        comptime {
            // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
            continue;
        }
    }
}

fn reject_comptime_assert_false() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(false);
    }
}

fn reject_comptime_trap() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        trap(.Assert);
    }
}

fn reject_comptime_unreachable() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        unreachable;
    }
}

fn reject_comptime_pointer_deref(p: *const u32) -> u32 {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
        return p.*;
    }
}

fn reject_comptime_mmio_read(uart: MmioPtr<Uart16550>) -> u8 {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
        return uart.lsr.read(.acquire);
    }
}

fn reject_comptime_mmio_write(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
        uart.thr.write(ch, .release);
    }
}

fn reject_comptime_direct_mmio_assign(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_FORBIDS_RUNTIME_EFFECT
        uart.thr = ch;
    }
}
