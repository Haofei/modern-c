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

enum BootState : u8 {
    cold = 0,
    warm = 1,
    ready = 2,
}

const DEFAULT_BOOT_STATE: BootState = .ready;

const DEFAULT_NUMBERS: [4]u32 = .{ 1, 2, 3, 4 };

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

struct ComptimeRect {
    w: u32,
    h: u32,
}

const DEFAULT_RECT: ComptimeRect = .{ .w = 5, .h = 6 };

const fn rect_area(r: ComptimeRect) -> u32 {
    return r.w * r.h;
}

const fn classify(x: u32) -> u32 {
    switch x {
        0 => { return 100; },
        1 => { return 200; },
        _ => { return 999; },
    }
}

const fn boot_rank(state: BootState) -> u32 {
    switch state {
        .cold => { return 10; },
        .warm => { return 20; },
        .ready => { return 30; },
    }
}

const fn require_power_of_two(x: u32) -> u32 {
    assert(is_power_of_two(x));
    return x;
}

const fn make_squares() -> [4]usize {
    var a: [4]usize = .{0, 0, 0, 0};
    var i: usize = 0;
    while i < 4 {
        a[i] = i * i;
        i = i + 1;
    }
    return a;
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

fn accept_comptime_block_loop_assignment() -> void {
    comptime {
        var total: u32 = 0;
        var i: u32 = 0;
        while i < 4 {
            total = total + i;
            i = i + 1;
        }
        assert(total == 6);
    }
}

fn reject_comptime_block_loop_assignment() -> void {
    comptime {
        var total: u32 = 0;
        var i: u32 = 0;
        while i < 4 {
            total = total + i;
            i = i + 1;
        }
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(total == 7);
    }
}

fn accept_comptime_block_switch_assignment() -> void {
    comptime {
        var selected: u32 = 0;
        switch 2 {
            1 => { selected = 10; },
            2 => { selected = 20; },
            _ => { selected = 30; },
        }
        assert(selected == 20);
    }
}

fn reject_comptime_block_switch_assignment() -> void {
    comptime {
        var selected: u32 = 0;
        switch 2 {
            1 => { selected = 10; },
            2 => { selected = 20; },
            _ => { selected = 30; },
        }
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(selected == 30);
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

fn accept_comptime_const_fn_assert() -> void {
    comptime {
        assert(require_power_of_two(16) == 16);
    }
}

fn reject_comptime_const_fn_assert() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(require_power_of_two(18) == 18);
    }
}

fn accept_comptime_const_fn_expr_statement() -> void {
    comptime {
        require_power_of_two(16);
    }
}

fn reject_comptime_const_fn_expr_statement() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        require_power_of_two(18);
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

// Named aggregate const globals participate in comptime evaluation too.
fn accept_comptime_const_array_global() -> void {
    comptime {
        assert(DEFAULT_NUMBERS[2] == 3);
        assert(array_sum(DEFAULT_NUMBERS) == 10);
    }
}

fn reject_comptime_const_array_global() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(DEFAULT_NUMBERS[1] == 3);
    }
}

fn accept_comptime_array_equality() -> void {
    comptime {
        assert(.{ 1, 2, 3 } == .{ 1, 2, 3 });
        assert(.{ 1, 2, 3 } != .{ 1, 2, 4 });
    }
}

fn reject_comptime_array_equality() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(.{ 1, 2, 3 } == .{ 1, 2, 4 });
    }
}

// Comptime struct values: a const fn folds over a struct argument's fields.
fn accept_comptime_struct_fold() -> void {
    comptime {
        assert(rect_area(.{ .w = 3, .h = 4 }) == 12);
    }
}

fn reject_comptime_struct_fold() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(rect_area(.{ .w = 3, .h = 4 }) == 13);
    }
}

fn accept_comptime_const_struct_global() -> void {
    comptime {
        assert(DEFAULT_RECT.w == 5);
        assert(rect_area(DEFAULT_RECT) == 30);
    }
}

fn reject_comptime_const_struct_global() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(DEFAULT_RECT.h == 5);
    }
}

fn accept_comptime_struct_equality() -> void {
    comptime {
        assert(.{ .w = 3, .h = 4 } == .{ .h = 4, .w = 3 });
        assert(.{ .w = 3, .h = 4 } != .{ .w = 3, .h = 5 });
    }
}

fn reject_comptime_struct_equality() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(.{ .w = 3, .h = 4 } == .{ .w = 3, .h = 5 });
    }
}

// Comptime switch: a const fn dispatches on a constant subject.
fn accept_comptime_switch_fold() -> void {
    comptime {
        assert(classify(0) == 100);
        assert(classify(1) == 200);
        assert(classify(7) == 999);
    }
}

fn reject_comptime_switch_fold() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(classify(1) == 100);
    }
}

// Comptime enum tags: literals, const globals, equality, and switch dispatch.
fn accept_comptime_enum_tag_fold() -> void {
    comptime {
        let state: BootState = .ready;
        assert(state == .ready);
        assert(boot_rank(.cold) == 10);
        assert(boot_rank(state) == 30);
        assert(boot_rank(DEFAULT_BOOT_STATE) == 30);
    }
}

fn reject_comptime_enum_tag_fold() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(boot_rank(.warm) == 30);
    }
}

// Comptime mutable aggregates: a const fn builds an array via element stores.
fn accept_comptime_array_build() -> void {
    comptime {
        assert(make_squares()[2] == 4);
        assert(make_squares()[3] == 9);
    }
}

fn reject_comptime_array_build() -> void {
    comptime {
        // EXPECT_ERROR: E_COMPTIME_TRAP
        assert(make_squares()[3] == 8);
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
