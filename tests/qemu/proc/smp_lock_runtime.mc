// Bare-metal riscv64 M-mode SMP spinlock-contention runtime — in PURE MC (no C).
// The all-MC replacement for kernel/arch/riscv64/smp_lock_runtime.c.
//
// Every hart runs the locked-increment worker (tests/qemu/proc/smp_lock_demo.mc,
// linked beside this object); the boot hart waits for all to finish and reports the
// final shared counter. If the lock provides real mutual exclusion the counter equals
// harts * ITERS exactly (here 2 * 2000 = 4000).

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register
const RT_FINISHER: usize = 0x0010_0000; // SiFive test finisher
const RT_FINISHER_HALT: u32 = 0x5555;
const RT_NHARTS: u32 = 2;
const RT_ITERS: u32 = 2000;
const RT_EXPECTED: u32 = 4000; // NHARTS * ITERS

fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uputc(b);
        i = i + 1;
    }
}

fn uputdec(v: u32) -> void {
    if v == 0 {
        uputc(48); // '0'
        return;
    }
    var buf: [12]u8 = uninit;
    var n: usize = 0;
    var x: u32 = v;
    while x != 0 {
        buf[n] = (48 + (x % 10)) as u8;
        n = n + 1;
        x = x / 10;
    }
    while n != 0 {
        n = n - 1;
        uputc(buf[n]);
    }
}

// MC entry points (tests/qemu/proc/smp_lock_demo.mc).
extern fn lock_worker() -> void;
extern fn lock_done_count() -> u32;
extern fn lock_counter() -> u32;

export fn hart_main(hartid: u64) -> void {
    lock_worker(); // ITERS locked increments of the shared counter
    if hartid == 0 {
        while lock_done_count() < RT_NHARTS {
        }
        uputs("SMP-LOCK ");
        uputdec(lock_counter());
        uputc(10); // '\n'
        if lock_counter() == RT_EXPECTED {
            uputs("LOCK-OK\n");
        }
        unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    }
    while true {
        unsafe { asm opaque volatile { "wfi" } }
    }
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "csrr a0, mhartid\n la t0, _stack_top\n slli t1, a0, 12\n sub sp, t0, t1\n call hart_main\n 1: wfi\n j 1b"
    }
}
