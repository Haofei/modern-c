// kernel/drivers/uart/ns16550 — a first-class, polled NS16550 UART driver.
//
// Unlike kernel/core/console.mc (the panic-safe fallback that writes a HARDCODED
// 16550 THR with no readiness check), this driver is parameterized by a base
// address discovered from the firmware device tree (kernel/core/bootinfo.mc's
// `bootinfo_console_pa`) and polls the Line Status Register's THRE bit before
// each byte — so it never drops a byte at speed and works at whatever base the
// platform reports.
//
// Arch-neutral by construction: the MMIO base is just a `usize` parameter and the
// register layout is the standard 16550 (reg-shift 0, as on the QEMU virt
// "ns16550a"). Any architecture exposing a 16550 at some base can use it.
//
// The single `unsafe` block per access is the audited MMIO boundary — the one
// raw load/store to the platform's UART registers, behind a safe typed API
// (mirrors the isolated raw access in kernel/core/console.mc).

import "std/addr.mc";

// Standard 16550 register offsets (reg-shift 0). Only the registers this polled,
// no-interrupt driver touches are named.
const REG_THR: usize = 0; // Transmit Holding Register (write)
const REG_IER: usize = 1; // Interrupt Enable Register
const REG_FCR: usize = 2; // FIFO Control Register (write)
const REG_LCR: usize = 3; // Line Control Register
const REG_LSR: usize = 5; // Line Status Register (read)

const LSR_THRE: u8 = 0x20; // bit 5: Transmit-Holding-Register-Empty (ready to send)

// A handle to one 16550 instance at a physical MMIO base.
struct Ns16550 {
    base: usize,
}

// Construct a handle for the 16550 at `base` (e.g. from bootinfo_console_pa).
export fn ns16550_at(base: usize) -> Ns16550 {
    return .{ .base = base };
}

// Raw 8-bit MMIO write to register `off` of this UART. The lone audited raw store.
fn ns16550_write_reg(u: *Ns16550, off: usize, v: u8) -> void {
    unsafe {
        raw.store<u8>(phys(u.base + off), v);
    }
}

// Raw 8-bit MMIO read of register `off` of this UART. The lone audited raw load.
fn ns16550_read_reg(u: *Ns16550, off: usize) -> u8 {
    var v: u8 = 0;
    unsafe {
        v = raw.load<u8>(phys(u.base + off));
    }
    return v;
}

// Minimal robust init: 8 data bits / no parity / 1 stop (8N1), enable + clear the
// RX/TX FIFOs, and disable all interrupts (this driver is polled). QEMU tolerates
// a no-init UART, but a real 16550 needs this, so we do it correctly.
export fn ns16550_init(u: *Ns16550) -> void {
    ns16550_write_reg(u, REG_IER, 0x00); // no interrupts
    ns16550_write_reg(u, REG_LCR, 0x03); // 8N1
    ns16550_write_reg(u, REG_FCR, 0x07); // FIFO enable + clear RX + clear TX
}

// Emit one byte: spin until the transmit holding register is empty (THRE set),
// THEN write the byte. This is the correctness win over console.mc — no dropped
// bytes when the line is busy.
export fn ns16550_putc(u: *Ns16550, c: u8) -> void {
    while (ns16550_read_reg(u, REG_LSR) & LSR_THRE) == 0 {
        // spin: wait for the transmit holding register to drain
    }
    ns16550_write_reg(u, REG_THR, c);
}

// Emit `0x` followed by 16 fixed-width hex digits (no buffer needed). Handy for
// printing the discovered base address through the driver itself.
export fn ns16550_puthex64(u: *Ns16550, v: u64) -> void {
    ns16550_putc(u, '0');
    ns16550_putc(u, 'x');
    var i: u32 = 0;
    while i < 16 {
        let shift: u32 = 60 - i * 4;
        let nibble: u8 = ((v >> shift) & 0xF) as u8;
        var ch: u8 = nibble + '0';
        if nibble >= 10 {
            ch = (nibble - 10) + 'a';
        }
        ns16550_putc(u, ch);
        i = i + 1;
    }
}

// Emit a kernel-owned byte buffer one byte at a time. MC can't carry/index a
// string literal as a `*const u8`, so callers that want a literal drive
// `ns16550_putc` per byte from their own side (e.g. the C boot runtime). This
// helper covers bytes already living at a physical address (`base` + len), read
// through the same audited raw boundary as the MMIO registers.
export fn ns16550_write(u: *Ns16550, src: usize, len: usize) -> void {
    var i: usize = 0;
    while i < len {
        var b: u8 = 0;
        unsafe {
            b = raw.load<u8>(phys(src + i));
        }
        ns16550_putc(u, b);
        i = i + 1;
    }
}
