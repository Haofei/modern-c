// kernel/arch/x86_64/port_io — x86-64 programmed I/O + a COM1 serial console, in PURE MC.
//
// The x86 analogue of kernel/arch/riscv64/sbi.mc / kernel/core/mmio_console.mc: the one
// place the platform's port-I/O instructions live, behind a typed safe API. x86 has NO
// memory-mapped path for the legacy serial port — it is reached ONLY through the `in`/`out`
// port-I/O instruction pair, which take their port in DX and their data in AL/AX/EAX. So the
// two primitives below MUST be inline asm; there is no MMIO alternative on this ISA.
//
// Register binding via the clobber + template-mov idiom. MC precise-asm operands lower to
// GENERIC `"r"` constraints on both backends — the named register is only provenance and is
// NOT honored — so a requested `a`/`d` class would not actually pin the operand. `out`/`in`
// however REQUIRE the data in AL and the port in DX, so each primitive takes its operands in
// generic registers, moves them into RAX/RDX inside the template, and lists RAX/RDX as
// clobbers. The clobber tells the register allocator those registers are destroyed, so it
// never places a still-needed operand there; the explicit `mov` then loads the fixed register
// the instruction demands. This is the x86 equivalent of the C `"a"(val)`/`"Nd"(port)` the
// inline asm this replaces used, expressed through MC's generic-operand model.

const COM1: u16 = 0x3F8;        // base port of the legacy 16550 UART
const COM1_LSR: u16 = 0x3FD;    // line-status register (COM1 + 5)
const LSR_THRE: u8 = 0x20;      // transmit-holding-register-empty bit

// Write `val` to I/O `port` (`out %al, %dx`). Volatile: a port write is a visible side effect.
export fn outb(port: u16, val: u8) -> void {
    let p: u64 = port as u64;
    let v: u64 = val as u64;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %0, %%rax\n mov %1, %%rdx\n outb %%al, %%dx"
                in("r") v: u64,
                in("r") p: u64,
                clobber("rax"),
                clobber("rdx"),
                clobber("memory")
            }
        }
    }
}

// Read a byte from I/O `port` (`in %dx, %al`).
export fn inb(port: u16) -> u8 {
    let p: u64 = port as u64;
    var r: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "xor %%rax, %%rax\n mov %1, %%rdx\n inb %%dx, %%al\n mov %%rax, %0"
                out("r") r: u64,
                in("r") p: u64,
                clobber("rax"),
                clobber("rdx"),
                clobber("memory")
            }
        }
    }
    return (r & 0xFF) as u8;
}

// ---- COM1 serial console (the x86 analogue of mmio_console, over outb/inb) ----

// Bring COM1 up: 8N1, divisor 1, FIFOs on, IRQs off (we poll the LSR).
export fn serial_init() -> void {
    outb(COM1 + 1, 0x00); // disable interrupts
    outb(COM1 + 3, 0x80); // DLAB on: next two writes set the baud divisor
    outb(COM1 + 0, 0x03); // divisor low  = 3
    outb(COM1 + 1, 0x00); // divisor high = 0
    outb(COM1 + 3, 0x03); // DLAB off: 8 bits, no parity, 1 stop
    outb(COM1 + 2, 0xC7); // enable + clear FIFOs, 14-byte threshold
    outb(COM1 + 4, 0x0B); // RTS/DSR set
}

// Emit one byte, polling the line-status THRE bit so we never overrun the holding register.
export fn console_putc(c: u8) -> void {
    while (inb(COM1_LSR) & LSR_THRE) == 0 {
    }
    outb(COM1, c);
}

// Print a NUL-terminated byte string read from raw memory.
export fn put_str(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        console_putc(b);
        i = i + 1;
    }
}

// Print an unsigned 32-bit value as `0x` + 8 fixed-width hex nibbles.
export fn put_hex(v: u32) -> void {
    console_putc(48);  // '0'
    console_putc(120); // 'x'
    var s: i32 = 28;
    while s >= 0 {
        let nib: u32 = (v >> (s as u32)) & 0xF;
        if nib < 10 {
            console_putc((48 + nib) as u8);   // '0'..'9'
        } else {
            console_putc((87 + nib) as u8);   // 'a'..'f'
        }
        s = s - 4;
    }
}

// Print an unsigned 64-bit value as `0x` + 16 fixed-width hex nibbles.
export fn put_hex64(v: u64) -> void {
    console_putc(48);  // '0'
    console_putc(120); // 'x'
    var s: i32 = 60;
    while s >= 0 {
        let nib: u64 = (v >> (s as u64)) & 0xF;
        if nib < 10 {
            console_putc((48 + nib) as u8);
        } else {
            console_putc((87 + nib) as u8);
        }
        s = s - 4;
    }
}

// Print an unsigned 64-bit value in decimal (no leading zeros; "0" for zero).
export fn put_dec(v: u64) -> void {
    if v == 0 {
        console_putc(48);
        return;
    }
    var buf: [20]u8 = .{ 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };
    var n: u64 = v;
    var i: usize = 0;
    while n > 0 {
        let d: u64 = n % 10;
        buf[i] = (48 + d) as u8;
        n = n / 10;
        i = i + 1;
    }
    while i > 0 {
        i = i - 1;
        console_putc(buf[i]);
    }
}
