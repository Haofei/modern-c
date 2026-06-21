// tests/x86/timer_x86_runtime — the x86-64 `kmain` for the Local-APIC TIMER proof, in PURE MC.
//
// The MC replacement for kernel/arch/x86_64/timer_runtime.c. This proves REAL, non-polled
// interrupt delivery on x86-64. boot.S (kept: the 32-bit multiboot header + long-mode
// trampoline MC cannot target) reaches 64-bit long mode with the low 1 GiB identity-mapped
// (2 MiB pages), running at 1 MiB, and `call kmain`s into here. We:
//
//   1. bring up COM1 (kernel/arch/x86_64/port_io — pure-MC outb/inb);
//   2. mask BOTH legacy 8259 PICs so the ONLY device that can deliver an interrupt is the
//      Local APIC — a delivered tick therefore PROVES the LAPIC path, not a stray PIC IRQ;
//   3. install an IDT with exception stubs (#GP/#PF etc., for diagnostics) AND a timer gate at
//      vector 0x20 whose naked ISR saves ALL caller-saved registers (an ASYNCHRONOUS interrupt
//      that can preempt kmain at any instruction — unlike the synchronous fault stubs which
//      halt, the timer ISR returns via iretq, so it MUST preserve every register it touches),
//      bumps g_ticks, signals LAPIC EOI, and iretq;
//   4. map the LAPIC MMIO page (default base 0xFEE00000, in the 3-4 GiB PDPT slot which boot.S
//      does NOT cover) by installing a fresh 1 GiB PD identity-mapping that region as huge
//      pages and wiring it into the LIVE PDPT[3] (walked from CR3, raw.store on the page table);
//   5. enable the LAPIC (SVR bit 8) + spurious vector 0xFF, program the LVT timer in PERIODIC
//      mode at vector 0x20, divide-by-16, with an initial count tuned for a few ticks/second;
//   6. `sti`, then spin `while g_ticks < target { hlt; }` — `hlt` parks the CPU until the NEXT
//      interrupt wakes it. If interrupts are NOT delivered the loop never progresses and the
//      bounded QEMU timeout fails the gate; we do NOT paper over no-delivery with a busy poll;
//   7. print `X86-TIMER TICKS=<n>` and `X86-TIMER-OK` over COM1.
//
// The MC fixture (tests/x86/timer_x86_demo.mc) supplies the threshold (timer_target) and the
// final verdict (timer_ok) — one MC compilation unit yields kmain + the fixture, so a real MC
// object participates in the boot image. The old timer_runtime.c is deleted.
//
// IDT shape mirrors vm_x86_runtime: 16-byte long-mode interrupt gates, populated by raw.store
// of their two 64-bit words (the LLVM backend does not support `(*ptr).field = x` on a packed
// field; raw stores at byte offsets are the portable idiom). The IDTR is assembled in a raw
// 10-byte buffer and handed to lidt as a memory operand. LAPIC MMIO is reached via
// raw.load/store<u32> on its identity-mapped physical address.

import "tests/x86/timer_x86_demo.mc";
import "kernel/arch/x86_64/port_io.mc";

const QEMU_EXIT_PORT: u16 = 0xF4;

const KCODE_SEL: u64 = 0x08;          // boot.S GDT: null, then CODE_SEG at offset 8 (CS=0x08)
const GATE_PRESENT_INT64: u64 = 0x8E; // present, DPL0, type 0xE (64-bit interrupt gate)
const IDT_LIMIT: u16 = 0x0FFF;        // 256 gates * 16 bytes - 1

// Local APIC (default xAPIC MMIO base + register offsets).
const LAPIC_BASE: u64 = 0xFEE0_0000;
const LAPIC_SVR: u64 = 0xF0;          // Spurious Interrupt Vector Register
const LAPIC_EOI: u64 = 0xB0;          // End-Of-Interrupt
const LAPIC_LVT_TIMER: u64 = 0x320;
const LAPIC_TIMER_DIV: u64 = 0x3E0;
const LAPIC_TIMER_INIT: u64 = 0x380;
const LAPIC_VERSION: u64 = 0x30;
const TIMER_VECTOR: usize = 0x20;

// IDT shape: one long-mode interrupt-gate descriptor (16 bytes). `packed` so the array stride
// is exactly 16; fields are documentary — entries are written via raw.store of two words.
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
global idtr: [10]u8;                  // 2-byte limit + 8-byte base, packed

// The tick counter the timer ISR bumps and kmain spins on. Mutated asynchronously from the ISR;
// every access in kmain re-reads it through raw.load so the optimizer cannot hoist it.
global g_ticks: u32;

// Backing store for a fresh page directory identity-mapping the 3..4 GiB region with 2 MiB huge
// pages, so the LAPIC MMIO page (0xFEE00000) is readable/writable. A PD pointer in a PDPT entry
// must be 4 KiB-aligned (the low 12 bits are flags), but MC globals carry no alignment attribute,
// so we over-allocate by one page (512*8 = 4 KiB usable + 4 KiB slack) and align the base at
// runtime. Under the identity-mapped low 1 GiB, so its physical == virtual address.
global lapic_pd_store: [8192]u8;

// 4 KiB-aligned base inside lapic_pd_store.
fn lapic_pd_base() -> usize {
    let raw_base: usize = (&lapic_pd_store[0]) as usize;
    return (raw_base + 0xFFF) & 0xFFFFFFFFFFFFF000;
}

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

// Mask every legacy-PIC IRQ line (OCW1 = 0xFF to both data ports). The BIOS leaves the master
// PIC mapped to vectors 0x08..0x0F; masking both PICs guarantees a delivered vector-0x20
// interrupt came from the LAPIC timer, not a stray 8259 line.
fn pic_mask_all() -> void {
    outb(0x21, 0xFF); // master PIC data: mask IRQ0..7
    outb(0xA1, 0xFF); // slave PIC data:  mask IRQ8..15
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

// Read CR3 (physical address of the live PML4, plus flags in the low bits).
fn read_cr3() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %%cr3, %0"
                out("r") v: u64,
                clobber("memory")
            }
        }
    }
    return v;
}

// Reload CR3 with `cr3` (full TLB flush).
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

// Enable interrupts (sti).
fn enable_interrupts() -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "sti"
                clobber("memory")
            }
        }
    }
}

// --- LAPIC MMIO (32-bit registers at the identity-mapped physical base) ---

fn lapic_write(off: u64, val: u32) -> void {
    let addr: usize = (LAPIC_BASE + off) as usize;
    unsafe { raw.store<u32>(phys(addr), val); }
}

fn lapic_read(off: u64) -> u32 {
    let addr: usize = (LAPIC_BASE + off) as usize;
    var v: u32 = 0;
    unsafe { v = raw.load<u32>(phys(addr)); }
    return v;
}

// --- fault + timer handlers (exported so the naked stubs can `call` them by plain symbol) ---

export fn on_fault(vec: u64) -> void {
    let cr2: u64 = read_cr2();
    put_str("\nX86-TIMER-BAD TRAP vec=");
    put_hex64(vec);
    put_str(" cr2=");
    put_hex64(cr2);
    console_putc(10);
    qemu_exit(1);
    halt_forever();
}

// Timer handler: minimal, async-safe. Bump the tick counter (read-modify-write through raw ops
// so the store is observable) and signal LAPIC EOI so the next periodic interrupt is delivered.
export fn timer_handler() -> void {
    let base: usize = (&g_ticks) as usize;
    var n: u32 = 0;
    unsafe { n = raw.load<u32>(phys(base)); }
    n = n + 1;
    unsafe { raw.store<u32>(phys(base), n); }
    lapic_write(LAPIC_EOI, 0);
}

// Exception stub: mask interrupts, pass the vector to on_fault, halt forever (never returns).
#[naked]
#[noinline]
export fn fault_stub() -> void {
    asm opaque volatile {
        "cli\n xor %rdi, %rdi\n call on_fault\n 1: hlt\n jmp 1b"
    }
}

// Timer ISR stub. ASYNCHRONOUS: it can preempt kmain at an arbitrary instruction, so it MUST
// preserve every caller-saved (System-V scratch) register — rax,rcx,rdx,rsi,rdi,r8..r11 —
// around the `call`, because timer_handler is free to clobber them and the interrupted code
// expects them intact. The interrupt gate (type 0xE) cleared IF on entry, so we are not
// re-entered. Return with iretq (restores RIP/CS/RFLAGS/RSP/SS).
#[naked]
#[noinline]
export fn timer_stub() -> void {
    asm opaque volatile {
        "push %rax\n push %rcx\n push %rdx\n push %rsi\n push %rdi\n push %r8\n push %r9\n push %r10\n push %r11\n call timer_handler\n pop %r11\n pop %r10\n pop %r9\n pop %r8\n pop %rdi\n pop %rsi\n pop %rdx\n pop %rcx\n pop %rax\n iretq"
    }
}

// --- IDT construction (pure bit-packing; the entry is two 64-bit words) ---

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
    let fault: usize = (&fault_stub) as usize;
    let timer: usize = (&timer_stub) as usize;

    var i: usize = 0;
    while i < 256 {
        idt_set(i, fault); // default every vector to the diagnostic fault stub
        i = i + 1;
    }
    idt_set(TIMER_VECTOR, timer);

    let base: usize = (&idt[0]) as usize;
    let limit: u16 = IDT_LIMIT;
    let idtr_base: usize = (&idtr[0]) as usize;
    unsafe {
        raw.store<u16>(phys(idtr_base), limit);
        raw.store<u64>(phys(idtr_base + 2), base as u64);
    }
    lidt(idtr_base);
}

// Map the LAPIC MMIO region by walking the LIVE page tables from CR3. boot.S maps PML4[0]->PDPT
// over only the low 1 GiB (PDPT slot 0); the LAPIC at 0xFEE00000 lives in PDPT slot 3
// (0xFEE00000 >> 30 == 3), which is unmapped. PML4 and the PDPT it points to are both in the
// low-1-GiB identity map, so their physical addresses are directly addressable here.
fn map_lapic_mmio() -> void {
    // Identity-map [3 GiB, 4 GiB) with 2 MiB huge pages: pd[i] = (3 GiB + i*2 MiB) | P|W|PS.
    let pd_base: usize = lapic_pd_base();
    var i: u64 = 0;
    while i < 512 {
        let off: usize = (i as usize) * 8;
        let slot: usize = pd_base + off;
        let pa: u64 = 0xC000_0000 + (i << 21);
        let ent: u64 = pa | 0x83; // P | W | PS(huge)
        unsafe { raw.store<u64>(phys(slot), ent); }
        i = i + 1;
    }

    let cr3: u64 = read_cr3();
    let pml4: usize = (cr3 & 0xFFFFFFFFFFFFF000) as usize;
    var pml4_0: u64 = 0;
    unsafe { pml4_0 = raw.load<u64>(phys(pml4)); }
    let live_pdpt: usize = (pml4_0 & 0x000FFFFFFFFFF000) as usize;

    // Wire the new PD into PDPT slot 3 (covers 0xC0000000..0xFFFFFFFF, containing 0xFEE00000).
    let pdpt3: usize = live_pdpt + 24;       // slot 3 * 8 bytes
    let pd_ent: u64 = (pd_base as u64) | 0x3; // P | W
    unsafe { raw.store<u64>(phys(pdpt3), pd_ent); }

    // Flush the TLB so the new mapping takes effect (reload CR3).
    load_cr3(cr3);
}

fn lapic_init_timer() -> void {
    // Enable the LAPIC: SVR bit 8 (APIC software enable) | spurious vector 0xFF.
    let svr: u32 = 0x100 | 0xFF;
    lapic_write(LAPIC_SVR, svr);
    // Divide configuration: 0x3 == divide by 16.
    lapic_write(LAPIC_TIMER_DIV, 0x3);
    // LVT timer: vector 0x20 | periodic mode (bit 17). Unmasked (bit 16 clear).
    let lvt: u32 = (TIMER_VECTOR as u32) | 0x20000;
    lapic_write(LAPIC_LVT_TIMER, lvt);
    // Initial count: periodic reload value. Tuned so several ticks fire within the bounded spin.
    lapic_write(LAPIC_TIMER_INIT, 0x0010_0000);
}

export fn kmain() -> void {
    serial_init();
    put_str("x86-64 long mode: LAPIC timer demo boot OK\n");

    pic_mask_all();
    put_str("timer: 8259 PICs masked (LAPIC is the only interrupt source)\n");

    idt_install();
    put_str("timer: IDT installed (faults + timer vec 0x20)\n");

    map_lapic_mmio();
    // Confirm the LAPIC MMIO page is reachable: read the (read-only) version register at 0x30.
    let ver: u32 = lapic_read(LAPIC_VERSION);
    put_str("timer: LAPIC MMIO mapped, version reg=");
    put_hex(ver);
    console_putc(10);

    lapic_init_timer();
    put_str("timer: LAPIC enabled, periodic timer armed at vec 0x20\n");

    let target: u32 = timer_target();
    put_str("timer: target ticks=");
    put_dec(target as u64);
    console_putc(10);

    enable_interrupts();
    put_str("timer: interrupts enabled (sti); waiting on real LAPIC ticks...\n");

    // Park on hlt until each tick wakes us. If no interrupt is ever delivered the loop NEVER
    // progresses and the bounded QEMU timeout fails the gate — we do NOT fall back to a busy poll.
    let tbase: usize = (&g_ticks) as usize;
    var n: u32 = 0;
    unsafe { n = raw.load<u32>(phys(tbase)); }
    while n < target {
        #[unsafe_contract(precise_asm)] {
            unsafe {
                asm precise volatile {
                    "hlt"
                    clobber("memory")
                }
            }
        }
        unsafe { n = raw.load<u32>(phys(tbase)); }
    }

    put_str("X86-TIMER TICKS=");
    put_dec(n as u64);
    console_putc(10);

    if timer_ok(n) == 1 {
        put_str("X86-TIMER-OK\n");
        qemu_exit(0);
    } else {
        put_str("X86-TIMER-BAD (verdict)\n");
        qemu_exit(1);
    }
    halt_forever();
}
