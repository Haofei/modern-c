// SPEC: section=22
// SPEC: milestone=comptime-runtime-effects
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_COMPTIME_FORBIDS_RUNTIME_EFFECT

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
}

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
