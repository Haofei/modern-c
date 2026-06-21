// Bare-metal riscv64 M-mode SMP bring-up runtime — in PURE MC (no C). The all-MC
// replacement for kernel/arch/riscv64/smp_runtime.c.
//
// On QEMU `virt -bios none`, every hart starts at the kernel entry; each reads its
// mhartid, takes its own stack, and calls hart_main. The boot hart (0) waits until
// all harts have checked in (via the MC shared atomic in tests/qemu/proc/smp_demo.mc,
// linked beside this object) and reports, then halts the machine.
//
// The multi-hart `_start` is a naked entry that gates on `csrr a0, mhartid` and gives
// each hart its own 4 KiB stack slice carved DOWN from the linker's `_stack_top`
// (hart h -> _stack_top - h*4096) before calling hart_main(hartid). Using the linker
// symbol (like the single-hart template) avoids a module-level stack array that the
// C backend would emit `static` and dead-strip (it is only named from naked asm).

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register
const RT_FINISHER: usize = 0x0010_0000; // SiFive test finisher
const RT_FINISHER_HALT: u32 = 0x5555;
const RT_NHARTS: u32 = 2;

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

// MC entry points (tests/qemu/proc/smp_demo.mc).
extern fn smp_hart_arrive() -> u32;
extern fn smp_count() -> u32;

export fn hart_main(hartid: u64) -> void {
    smp_hart_arrive(); // atomically count this hart in
    if hartid == 0 {
        while smp_count() < RT_NHARTS {
        }
        uputs("SMP-OK ");
        uputc((48 + (smp_count() % 10)) as u8);
        uputc(10); // '\n'
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
