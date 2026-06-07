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

const fn is_power_of_two(x: u32) -> bool {
    return x != 0 && (x & (x - 1)) == 0;
}

const fn align_up(x: u32, a: u32) -> u32 {
    return (x + a - 1) & ~(a - 1);
}

const fn gcd(a: u32, b: u32) -> u32 {
    var x: u32 = a;
    var y: u32 = b;
    while y != 0 {
        let t: u32 = y;
        y = x % y;
        x = t;
    }
    return x;
}

const fn array_sum(xs: [4]u32) -> u32 {
    var total: u32 = 0;
    for x in xs {
        total = total + x;
    }
    return total;
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

fn accept_comptime_true_comparison() -> void {
    comptime {
        assert(1 < 2);
        assert((2 + 3) * 2 == 10);
        assert(true && 3 >= 3);
    }
}

fn accept_comptime_const_binding_assertion() -> void {
    comptime {
        let n: u32 = 4;
        let doubled: u32 = n * 2;
        assert(doubled == 8);
        assert(n != doubled);
    }
}

fn reject_comptime_false_comparison() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(2 < 1);
    }
}

fn reject_comptime_false_const_binding() -> void {
    comptime {
        let n: u32 = 4;
        let doubled: u32 = n * 2;
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(doubled == 7);
    }
}

fn reject_comptime_divide_by_zero() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(1 / 0 == 0);
    }
}

fn accept_comptime_const_fn_call() -> void {
    comptime {
        assert(is_power_of_two(16));
        assert(align_up(5, 8) == 8);
    }
}

fn reject_comptime_const_fn_false() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(is_power_of_two(17));
    }
}

fn reject_comptime_const_fn_arithmetic() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(align_up(5, 8) == 16);
    }
}

fn accept_comptime_const_fn_loop() -> void {
    comptime {
        assert(gcd(48, 36) == 12);
        assert(gcd(17, 5) == 1);
    }
}

fn reject_comptime_const_fn_loop() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(gcd(48, 36) == 11);
    }
}

// Comptime array values + `for` loops: a const fn folds over an array argument.
fn accept_comptime_array_fold() -> void {
    comptime {
        assert(array_sum(.{1, 2, 3, 4}) == 10);
    }
}

fn reject_comptime_array_fold() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(array_sum(.{1, 2, 3, 4}) == 11);
    }
}

// Comptime↔type feedback: a const-fn result drives a fixed-array length.
fn accept_comptime_array_length() -> [align_up(3, 4)]u8 {
    return .{1, 2, 3, 4};
}

fn reject_comptime_array_length() -> [align_up(3, 4)]u8 {
    // EXPECT_ERROR: E_ARRAY_LITERAL_LENGTH
    return .{1, 2, 3};
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
