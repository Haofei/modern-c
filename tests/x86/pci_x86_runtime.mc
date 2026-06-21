// tests/x86/pci_x86_runtime — the x86-64 `kmain` for the PCI device-discovery proof, in PURE MC.
//
// The MC replacement for kernel/arch/x86_64/pci_runtime.c. This proves REAL PCI device discovery
// on x86-64 under QEMU — the analogue of the RISC-V FDT/ECAM discovery, but using the legacy
// port-I/O CAM mechanism instead of memory-mapped ECAM. boot.S (kept) reaches 64-bit long mode
// with the low 1 GiB identity-mapped and `call kmain`s into here. We:
//
//   1. bring up COM1 (kernel/arch/x86_64/port_io — pure-MC outb/inb/outl/inl);
//   2. install an IDT with a diagnostic fault stub PURELY for diagnostics — PCI config access is
//      synchronous port I/O (no interrupts), so unlike the timer demo there is no async ISR and
//      we never `sti`;
//   3. drive the MC enumerator (tests/x86/pci_x86_demo.mc :: pci_x86_scan), which scans bus 0 via
//      the config mechanism (now pure-MC outl/inl) and finds QEMU's virtio-blk-pci device
//      (vendor 0x1AF4);
//   4. report the discovered identity (vendor/device/class/BAR0) over COM1; the gate asserts a
//      REAL device (vendor 0x1AF4, not an all-ones absent read) was found.
//
// STRETCH: after discovery, if BAR0 is an I/O BAR holding the LEGACY virtio header, bring the
// legacy virtio-pci transport up far enough for a clean handshake (reset -> ACKNOWLEDGE|DRIVER,
// read device features) and read one device-config field (virtio-blk capacity). Reported but NOT
// gated on. The old pci_runtime.c (and its C pci_x86_cfg_read32 extern) is deleted; the config
// read is now pure MC in the demo fixture.
//
// IDT shape mirrors vm_x86_runtime: 16-byte long-mode interrupt gates populated by raw.store of
// two 64-bit words (the LLVM backend does not support `(*ptr).field = x` on a packed field).

import "tests/x86/pci_x86_demo.mc";
import "kernel/arch/x86_64/port_io.mc";

const QEMU_EXIT_PORT: u16 = 0xF4;

const KCODE_SEL: u64 = 0x08;
const GATE_PRESENT_INT64: u64 = 0x8E;
const IDT_LIMIT: u16 = 0x0FFF;

// Legacy (transitional) virtio-pci header at the start of the device's I/O BAR (no MSI-X):
//   0x00 device features (u32, RO)      0x12 device status (u8)
//   0x14 device-specific config begins  (virtio-blk: capacity u64 = sectors)
const VIRTIO_PCI_HOST_FEATURES: u16 = 0x00;
const VIRTIO_PCI_STATUS: u16 = 0x12;
const VIRTIO_PCI_CONFIG_LEGACY: u16 = 0x14;
const VIRTIO_STATUS_ACKNOWLEDGE: u8 = 0x01;
const VIRTIO_STATUS_DRIVER: u8 = 0x02;

packed struct IdtEntry {
    off_lo: u16,
    sel: u16,
    ist: u8,
    type_attr: u8,
    off_mid: u16,
    off_hi: u32,
    zero: u32,
}

global idt: [256]IdtEntry;
global idtr: [10]u8;

// --- low-level CPU primitives ---

fn qemu_exit(code: u8) -> void {
    outb(QEMU_EXIT_PORT, code);
}

#[noinline]
fn halt_forever() -> void {
    while true {
        #[unsafe_contract(precise_asm)] {
            unsafe {
                asm precise volatile {
                    "hlt"
                    clobber("memory")
                }
            }
        }
    }
}

fn lidt(idtr_addr: usize) -> void {
    let a: u64 = idtr_addr as u64;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "lidt (%0)"
                in("r") a: u64,
                clobber("memory")
            }
        }
    }
}

fn read_cr2() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %%cr2, %0"
                out("r") v: u64,
                clobber("memory")
            }
        }
    }
    return v;
}

// --- fault handler (diagnostics; never returns) ---

export fn on_fault(vec: u64) -> void {
    let cr2: u64 = read_cr2();
    put_str("\nX86-PCI-BAD TRAP vec=");
    put_hex64(vec);
    put_str(" cr2=");
    put_hex64(cr2);
    console_putc(10);
    qemu_exit(1);
    halt_forever();
}

#[naked]
#[noinline]
export fn fault_stub() -> void {
    asm opaque volatile {
        "cli\n xor %rdi, %rdi\n call on_fault\n 1: hlt\n jmp 1b"
    }
}

// --- IDT construction ---

fn idt_set(vec: usize, handler: usize) -> void {
    let addr: u64 = handler as u64;
    let off_lo: u64 = addr & 0xFFFF;
    let off_mid: u64 = (addr >> 16) & 0xFFFF;
    let off_hi: u64 = (addr >> 32) & 0xFFFF_FFFF;

    let word0: u64 = off_lo | (KCODE_SEL << 16) | (GATE_PRESENT_INT64 << 40) | (off_mid << 48);
    let word1: u64 = off_hi;

    let base: usize = (&idt[0]) as usize;
    let entry: usize = base + vec * 16;
    unsafe {
        raw.store<u64>(phys(entry), word0);
        raw.store<u64>(phys(entry + 8), word1);
    }
}

fn idt_install() -> void {
    let fault: usize = (&fault_stub) as usize;
    var i: usize = 0;
    while i < 256 {
        idt_set(i, fault);
        i = i + 1;
    }

    let base: usize = (&idt[0]) as usize;
    let limit: u16 = IDT_LIMIT;
    let idtr_base: usize = (&idtr[0]) as usize;
    unsafe {
        raw.store<u16>(phys(idtr_base), limit);
        raw.store<u64>(phys(idtr_base + 2), base as u64);
    }
    lidt(idtr_base);
}

// --- virtio-pci legacy transport (STRETCH) ---
// Try the legacy virtio-pci transport handshake over the device's I/O BAR. `bar0` is the raw BAR
// register: bit 0 set => I/O space, base = bar0 & ~0x3. Returns 1 if the handshake looked sane
// (status read back our ACKNOWLEDGE|DRIVER bits) and writes the device features + first 8 bytes of
// device config (virtio-blk capacity) through the out-pointers. Returns 0 if BAR0 is not I/O space.
fn virtio_legacy_handshake(bar0: u32, out_features: *mut u32, out_capacity: *mut u64, out_status: *mut u8) -> u32 {
    if (bar0 & 0x1) == 0 {
        return 0; // not an I/O BAR — legacy transport lives in I/O space
    }
    let io: u16 = (bar0 & 0xFFFC) as u16;

    // Reset: write 0 to the status register (the device acks by clearing it).
    outb(io + VIRTIO_PCI_STATUS, 0);
    // Drive the spec handshake: ACKNOWLEDGE then DRIVER.
    outb(io + VIRTIO_PCI_STATUS, VIRTIO_STATUS_ACKNOWLEDGE);
    outb(io + VIRTIO_PCI_STATUS, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER);

    let st: u8 = inb(io + VIRTIO_PCI_STATUS);
    let feat: u32 = inl(io + VIRTIO_PCI_HOST_FEATURES);

    // virtio-blk device config: capacity is a little-endian u64 at config offset 0 (== 0x14).
    let cap_lo: u32 = inl(io + VIRTIO_PCI_CONFIG_LEGACY + 0);
    let cap_hi: u32 = inl(io + VIRTIO_PCI_CONFIG_LEGACY + 4);

    *out_features = feat;
    *out_capacity = ((cap_hi as u64) << 32) | (cap_lo as u64);
    *out_status = st;

    let want: u8 = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER;
    if (st & want) == want {
        return 1;
    }
    return 0;
}

// Print an unsigned value as `nibbles` fixed-width hex digits (no `0x` prefix).
fn put_hexw(v: u32, nibbles: i32) -> void {
    var s: i32 = (nibbles - 1) * 4;
    while s >= 0 {
        let nib: u32 = (v >> (s as u32)) & 0xF;
        if nib < 10 {
            console_putc((48 + nib) as u8);
        } else {
            console_putc((87 + nib) as u8);
        }
        s = s - 4;
    }
}

export fn kmain() -> void {
    serial_init();
    put_str("x86-64 long mode: PCI device-discovery demo boot OK\n");

    idt_install();
    put_str("pci: IDT installed (fault stubs for diagnostics)\n");

    // Sanity: read the host bridge at 00:00.0 — bus 0 always has the i440FX/Q35 host bridge
    // (Intel vendor 0x8086). A real bus answers; an all-ones read would mean no CAM at all.
    let hb: u32 = pci_x86_cfg_read32(0, 0, 0, 0);
    put_str("pci: host-bridge id @00:00.0 = ");
    put_hex(hb);
    put_str(" (vendor=");
    put_hexw(hb & 0xFFFF, 4);
    put_str(")\n");

    // Drive the MC enumerator: scan bus 0 for the QEMU virtio-blk-pci device (vendor 0x1AF4).
    var vendor: u32 = 0;
    var device: u32 = 0;
    var class_reg: u32 = 0;
    var bar0: u32 = 0;
    let found: u32 = pci_x86_scan(&vendor, &device, &class_reg, &bar0);

    if found != 1 {
        put_str("X86-PCI-BAD no virtio device (vendor 0x1AF4) found on bus 0\n");
        qemu_exit(1);
        halt_forever();
    }

    // Class code is in bits 24..31, subclass in 16..23 of register 0x08.
    let cls: u32 = (class_reg >> 24) & 0xFF;
    let sub: u32 = (class_reg >> 16) & 0xFF;
    put_str("X86-PCI virtio vendor=");
    put_hexw(vendor, 4);
    put_str(" device=");
    put_hexw(device, 4);
    put_str(" class=");
    put_hexw(cls, 2);
    put_str(" subclass=");
    put_hexw(sub, 2);
    put_str(" bar0=");
    put_hex(bar0);
    console_putc(10);

    // The discovered vendor MUST be 0x1AF4 and NOT an all-ones absent read — the floor proof that
    // real config-space enumeration found the QEMU-attached virtio-pci device.
    if vendor != 0x1AF4 {
        put_str("X86-PCI-BAD vendor mismatch\n");
        qemu_exit(1);
        halt_forever();
    }

    // STRETCH: bring up the legacy virtio-pci transport over the I/O BAR and read a config field.
    var feat: u32 = 0;
    var cap: u64 = 0;
    var st: u8 = 0;
    if virtio_legacy_handshake(bar0, &feat, &cap, &st) == 1 {
        put_str("X86-PCI-VIRTIO legacy handshake OK status=");
        put_hexw(st as u32, 2);
        put_str(" features=");
        put_hex(feat);
        put_str(" capacity=");
        put_hex64(cap);
        put_str(" sectors\n");
    } else {
        put_str("pci: BAR0 not an I/O BAR (modern virtio transport); skipping legacy handshake\n");
    }

    put_str("X86-PCI-OK\n");
    qemu_exit(0);
    halt_forever();
}
