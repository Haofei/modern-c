// tests/x86/vm_x86_runtime — the x86-64 `kmain` for the paging proof, in PURE MC.
//
// The MC replacement for kernel/arch/x86_64/vm_runtime.c. boot.S (kept: it is the genuine
// 32-bit multiboot header + protected-mode->long-mode trampoline MC cannot target) reaches
// 64-bit long mode with the low 1 GiB identity-mapped (2 MiB pages), running at 1 MiB, and
// `call kmain`s into here. We:
//
//   1. bring up COM1 (kernel/arch/x86_64/port_io — pure-MC `outb`/`inb`);
//   2. install a minimal IDT with #GP (13) and #PF (14) handlers that print a marker over
//      COM1 and halt, so a paging bug is DIAGNOSED, not a silent triple-fault reboot;
//   3. set EFER.NXE so a PTE_NX bit would be legal (the demo sets none, but this documents
//      the path and matches paging.mc's contract);
//   4. call the MC `vm_x86_build` (tests/x86/vm_x86_demo) — fresh PML4, identity low 1 GiB +
//      a 4 KiB sentinel at 3 GiB, with a software walk asserting the translation BEFORE any
//      CR3 reload;
//   5. load the new PML4 into CR3 (the kernel stays mapped via the identity 1 GiB, so the
//      next fetch survives), flushing the TLB;
//   6. read the sentinel back THROUGH the 3 GiB test VA — reachable only via translation —
//      and compare to the known sentinel.
//
// Print X86-VM-OK iff the software walk AND the live readback both match; else X86-VM-BAD.
//
// IDT shape: x86 long-mode 64-bit interrupt gates are 16 bytes. MC has `packed` structs, so
// `IdtEntry` documents the 16-byte layout and sizes the global array; the entry is POPULATED
// by raw.store of its two 64-bit words at the entry's address (the LLVM backend does not
// support `(*ptr).field = x` on a packed field, and raw stores at byte offsets are the
// portable idiom). The IDTR (a 2-byte limit + 8-byte base) is likewise assembled in a raw
// 10-byte buffer and handed to `lidt` as a memory operand.

import "tests/x86/vm_x86_demo.mc";
import "kernel/arch/x86_64/port_io.mc";

const QEMU_EXIT_PORT: u16 = 0xF4;

const KCODE_SEL: u64 = 0x08;     // boot.S GDT: null, then CODE_SEG at offset 8 (we run CS=0x08)
const GATE_PRESENT_INT64: u64 = 0x8E; // present, DPL0, type 0xE (64-bit interrupt gate)

// TEST_VA / TEST_VALUE are owned by tests/x86/vm_x86_demo.mc; re-declared here under a
// runtime-local name (the demo's consts are module-private, not re-exported through import).
const RT_TEST_VA: usize = 0xC000_0000;    // 3 GiB — outside the identity-mapped low 1 GiB
const RT_TEST_VALUE: u32 = 0xCAFE_BABE;
const HEAP_BYTES: usize = 1024 * 1024;    // page-table backing store: 1 MiB, under the 1 GiB id-map
const IDT_LIMIT: u16 = 0x0FFF;            // 256 gates * 16 bytes - 1
const EFER_MSR: u64 = 0xC000_0080;        // EFER; bit 8 = LME (set by boot.S), bit 11 = NXE

// One long-mode interrupt-gate descriptor (16 bytes). `packed` so it has no padding and the
// array stride is exactly 16; fields are documentary — we write the two words via raw.store.
packed struct IdtEntry {
    off_lo: u16,    // handler bits 15:0
    sel: u16,       // code-segment selector
    ist: u8,        // bits 2:0 IST index (0 = none)
    type_attr: u8,  // gate type + DPL + present
    off_mid: u16,   // handler bits 31:16
    off_hi: u32,    // handler bits 63:32
    zero: u32,      // reserved, must be 0
}

global idt: [256]IdtEntry;
global idtr: [10]u8;             // 2-byte limit + 8-byte base, packed

// --- low-level CPU primitives (the bits that genuinely need asm) ---

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

// Load the IDTR (10-byte limit+base structure at `idtr_addr`) into the CPU.
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

// Reload CR3 with the PML4 physical address `cr3` (full TLB flush).
fn load_cr3(cr3: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %0, %%cr3"
                in("r") cr3: u64,
                clobber("memory")
            }
        }
    }
}

// Read CR2 (the faulting linear address recorded on a #PF).
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

// Set EFER.NXE (MSR 0xC0000080 bit 11) so a PTE_NX bit is non-reserved. boot.S already set
// LME; we read-modify-write to preserve it. rdmsr/wrmsr are hardwired to ECX = MSR index and
// EDX:EAX = value; since MC operands lower to generic `"r"` (the named register is dropped),
// we move the index into RCX and the value out of / into RAX:RDX inside the template, listing
// the fixed registers as clobbers — the same idiom as outb/inb in port_io.mc.
fn enable_nxe() -> void {
    let idx: u64 = EFER_MSR;
    var lo: u64 = 0;
    var hi: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %2, %%rcx\n rdmsr\n mov %%rax, %0\n mov %%rdx, %1"
                out("r") lo: u64,
                out("r") hi: u64,
                in("r") idx: u64,
                clobber("rax"),
                clobber("rcx"),
                clobber("rdx"),
                clobber("memory")
            }
        }
    }
    lo = lo | 0x800; // bit 11 = NXE
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %0, %%rax\n mov %1, %%rdx\n mov %2, %%rcx\n wrmsr"
                in("r") lo: u64,
                in("r") hi: u64,
                in("r") idx: u64,
                clobber("rax"),
                clobber("rcx"),
                clobber("rdx"),
                clobber("memory")
            }
        }
    }
}

// --- fault handlers (exported so the naked stubs can `call` them by plain symbol) ---

export fn on_gp() -> void {
    put_str("\nX86-VM-BAD #GP\n");
    qemu_exit(1);
    halt_forever();
}

export fn on_pf() -> void {
    let cr2: u64 = read_cr2();
    put_str("\nX86-VM-BAD #PF at ");
    put_hex64(cr2);
    console_putc(10); // '\n'
    qemu_exit(1);
    halt_forever();
}

// Naked stubs installed in the IDT: mask interrupts, jump to the MC handler, never return
// (we halt). On x86 these never come back, so we do not pop the CPU-pushed error code.
#[naked]
#[noinline]
export fn gp_stub() -> void {
    asm opaque volatile {
        "cli\n call on_gp\n 1: hlt\n jmp 1b"
    }
}

#[naked]
#[noinline]
export fn pf_stub() -> void {
    asm opaque volatile {
        "cli\n call on_pf\n 1: hlt\n jmp 1b"
    }
}

// --- IDT construction (pure bit-packing; the entry is two 64-bit words) ---

// Write the 16-byte gate for vector `vec` pointing at `handler`, by storing its two 64-bit
// words at the entry's address. word0 = off_lo | sel<<16 | ist<<32 | type_attr<<40 | off_mid<<48;
// word1 = off_hi | zero<<32.
fn idt_set(vec: usize, handler: usize) -> void {
    let addr: u64 = handler as u64;
    let off_lo: u64 = addr & 0xFFFF;
    let off_mid: u64 = (addr >> 16) & 0xFFFF;
    let off_hi: u64 = (addr >> 32) & 0xFFFF_FFFF;

    let word0: u64 = off_lo | (KCODE_SEL << 16) | (GATE_PRESENT_INT64 << 40) | (off_mid << 48);
    let word1: u64 = off_hi; // ist=0, zero=0

    let base: usize = (&idt[0]) as usize;
    let entry: usize = base + vec * 16;
    unsafe {
        raw.store<u64>(phys(entry), word0);
        raw.store<u64>(phys(entry + 8), word1);
    }
}

fn idt_install() -> void {
    let gp: usize = (&gp_stub) as usize;
    let pf: usize = (&pf_stub) as usize;

    var i: usize = 0;
    while i < 256 {
        idt_set(i, gp); // default every vector to the #GP marker
        i = i + 1;
    }
    idt_set(13, gp);
    idt_set(14, pf);

    // IDTR: 2-byte limit (sizeof table - 1) then the 8-byte base.
    let base: usize = (&idt[0]) as usize;
    let limit: u16 = IDT_LIMIT;
    let idtr_base: usize = (&idtr[0]) as usize;
    unsafe {
        raw.store<u16>(phys(idtr_base), limit);
        raw.store<u64>(phys(idtr_base + 2), base as u64);
    }
    lidt(idtr_base);
}

// Page-table backing store: 1 MiB, 4 KiB-aligned, well under the identity-mapped 1 GiB.
global heap_region: [HEAP_BYTES]u8;

export fn kmain() -> void {
    serial_init();
    put_str("x86-64 long mode: VM demo boot OK\n");

    idt_install();
    put_str("vm: IDT installed (#GP=13, #PF=14)\n");
    enable_nxe();

    var cr3: u64 = 0;
    var test_phys: u64 = 0;
    let region: usize = (&heap_region[0]) as usize;
    let sw_ok: u32 = vm_x86_build(region, HEAP_BYTES, &cr3, &test_phys);
    put_str("vm: table built, cr3=");
    put_hex64(cr3);
    put_str(" test_phys=");
    put_hex64(test_phys);
    put_str(" sw_ok=");
    put_hex(sw_ok);
    console_putc(10);

    if sw_ok != 1 {
        put_str("X86-VM-BAD (software walk)\n");
        qemu_exit(1);
        halt_forever();
    }

    // Activate the freshly built PML4. The kernel stays mapped via the identity low 1 GiB,
    // so execution continues; this reloads CR3 (full TLB flush).
    load_cr3(cr3);
    put_str("vm: CR3 reloaded with fresh PML4\n");

    // Read the sentinel back THROUGH the 3 GiB test VA — reachable only via translation.
    var got: u32 = 0;
    unsafe {
        got = raw.load<u32>(phys(RT_TEST_VA));
    }
    put_str("vm: readback through TEST_VA ");
    put_hex(got);
    console_putc(10);

    if got == RT_TEST_VALUE {
        put_str("X86-VM-OK\n");
        qemu_exit(0);
    } else {
        put_str("X86-VM-BAD (readback)\n");
        qemu_exit(1);
    }
    halt_forever();
}
