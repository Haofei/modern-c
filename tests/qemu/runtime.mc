// Minimal bare-metal riscv64 runtime for the QEMU MMIO execution test, in PURE MC (the all-MC
// replacement for tests/qemu/runtime.c). Drives the MC-generated `uart_putc` over the 16550 UART,
// then exits QEMU through the SiFive test finisher.

const UART: usize = 0x1000_0000;        // QEMU virt 16550
const FINISHER: usize = 0x0010_0000;    // SiFive test device
const FINISHER_HALT: u32 = 0x5555;

// `uart_putc(uart: *Uart16550, ch)` is defined in the MC-generated demo TU (tests/qemu/arch/
// uart_mmio.mc); we only pass the MMIO base as an opaque pointer (ABI-identical to a usize).
extern fn uart_putc(uart: usize, ch: u8) -> void;

export fn test_main() -> void {
    let msg: *const u8 = "MMIO-OK\n";
    let base: usize = msg as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uart_putc(UART, b);
        i = i + 1;
    }
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); } // exit QEMU with status 0
    while true {}
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
