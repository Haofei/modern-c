// x86-64 CONFINED QuickJS agent runtime — PURE MC (replaces kernel/arch/x86_64/qjs_user_runtime.c).
//
// Reuses M6's ring-3 machinery VERBATIM from user_x86_runtime.mc — the GDT (ring0/ring3 + TSS),
// the IDT with an int-0x80 syscall gate (DPL3) + #GP/#PF diagnostics, and the iretq-to-ring-3
// entry — but instead of a hand-assembled program it: (1) loads the REAL multi-segment QuickJS
// U-mode ELF (embedded as app_image[], read via `extern global`) into an ISOLATED 4-level space
// via app_build_x86 (the MC fixture qjs_x86_demo.mc), which also adds the kernel's low-1-GiB
// supervisor-only window; (2) installs GDT/TSS/IDT, reloads CR3, and iretq's into the QuickJS
// entry. Syscalls (except SYS_EXIT) dispatch through the SAME MC table the riscv path uses
// (mc_syscall). boot.S (the 32-bit multiboot/long-mode trampoline MC cannot target) stays C and
// `call kmain`s into this object; QuickJS stays vendored.

import "kernel/arch/x86_64/port_io.mc"; // serial_init/console_putc/put_str/put_hex64 + outb/inb

// The MC fixture (qjs_x86_demo.mc) — linked separately, so declared extern (importing duplicates).
extern fn app_build_x86(image_base: usize, image_len: usize, region_base: usize, region_len: usize, out_cr3: *mut u64) -> u32;
extern fn app_build_status_x86() -> u32;
extern fn app_entry_x86() -> u64;
extern fn app_kernel_not_user_x86(kernel_va: usize) -> u32;
extern fn app_entry_is_user_x86() -> u32;
extern fn syscall_setup() -> void;
extern fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64;

// The embedded QuickJS agent ELF (the harness emits app_image.c) — read via `extern global`.
extern global app_image: u8;
extern global app_image_len: u32;

// §0 ingress (SYS_READ) default: no embedded agent source. WEAK so a source-serving test that
// links a STRONG mc_agent_source (its embedded JS) overrides it.
#[weak]
export fn mc_agent_source(out_len: *mut usize) -> usize {
    unsafe { raw.store<u64>(phys(out_len as usize), 0); }
    return 0;
}

const SYS_EXIT: u64 = 3;                  // qjs agent ABI (user/abi.mc), NOT M6's 2
const QEMU_EXIT_PORT: u16 = 0xf4;
const KERNEL_VA: usize = 0x10_0000;       // 1 MiB: the kernel image load address
const REGION_LEN: usize = 16 * 1024 * 1024; // 16 MiB
const PAGE: usize = 4096;

const SEG_S: u64 = (1 as u64) << 44;
const SEG_P: u64 = (1 as u64) << 47;
const SEG_EX: u64 = (1 as u64) << 43;
const SEG_L: u64 = (1 as u64) << 53;
const SEG_W: u64 = (1 as u64) << 41;

const IDT_LIMIT: u16 = 0x0FFF;
const GATE_PRESENT_INT64: u64 = 0x8E;
const GATE_DPL3_INT64: u64 = 0xEE;
const KCODE_SEL64: u64 = 0x08;

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
global gdt: [7]u64;
global gdtr: [10]u8;
global tss: [104]u8;
// The agent's page tables + per-page frames (8 MiB arena + engine + 512 KiB stack + tables).
global region: [16781312]u8;          // 16 MiB + a page for alignment
global kernel_trap_stack: [16384 + 4096]u8; // RSP0

fn align_up(x: usize, a: usize) -> usize {
    let m: usize = a - 1;
    let s: usize = x + m;
    let inv: usize = ~m;
    return s & inv;
}

fn qemu_exit(code: u8) -> void { outb(QEMU_EXIT_PORT, code); }

// The console sink the MC SYS_WRITE handler (qjs_x86_demo.mc's syscall table) calls per byte.
export fn mc_console_putc(c: u8) -> void { console_putc(c); }

// Mask every legacy-PIC IRQ (the agent uses polled I/O; an unmasked IRQ would land in an
// exception vector). Both PICs: OCW1 = 0xFF to the data ports (0x21 master, 0xA1 slave).
fn pic_mask_all() -> void {
    outb(0x21, 0xFF);
    outb(0xA1, 0xFF);
}

#[noinline]
fn halt_forever() -> void {
    while true {
        unsafe { asm opaque volatile { "hlt" } }
    }
}

fn lidt(idtr_addr: usize) -> void {
    let a: u64 = idtr_addr as u64;
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "lidt (%0)" in("r") a: u64, clobber("memory") }
    } }
}
fn lgdt(gdtr_addr: usize) -> void {
    let a: u64 = gdtr_addr as u64;
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "lgdt (%0)" in("r") a: u64, clobber("memory") }
    } }
}
fn load_cr3(cr3: u64) -> void {
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "mov %0, %%cr3" in("r") cr3: u64, clobber("memory") }
    } }
}
fn read_cr2() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe {
        asm precise volatile { "mov %%cr2, %0" out("r") v: u64, clobber("memory") }
    } }
    return v;
}

fn reload_kernel_segments() -> void {
    unsafe {
        asm opaque volatile {
            "mov $0x10, %%ax\n mov %%ax, %%ds\n mov %%ax, %%es\n mov %%ax, %%ss\n mov %%ax, %%fs\n mov %%ax, %%gs\n lea 1f(%%rip), %%rax\n push $0x08\n push %%rax\n lretq\n 1:"
            clobber("rax")
            clobber("memory")
        }
    }
}
fn load_tr() -> void {
    unsafe {
        asm opaque volatile { "mov $0x28, %%ax\n ltr %%ax" clobber("rax") clobber("memory") }
    }
}

export fn on_gp() -> void {
    put_str("\nQJS-X86-BAD #GP\n");
    qemu_exit(1);
    halt_forever();
}
export fn on_pf() -> void {
    let cr2: u64 = read_cr2();
    put_str("\nQJS-X86-BAD #PF at ");
    put_hex64(cr2);
    console_putc(10);
    qemu_exit(1);
    halt_forever();
}

#[naked]
#[noinline]
export fn gp_stub() -> void {
    asm opaque volatile { "cli\n call on_gp\n 1: hlt\n jmp 1b" }
}
#[naked]
#[noinline]
export fn pf_stub() -> void {
    asm opaque volatile { "cli\n call on_pf\n 1: hlt\n jmp 1b" }
}

// int-0x80 dispatch: SYS_EXIT handled here; everything else through the MC syscall table.
// Frame layout (struct-regs order pushed by syscall_stub): rdi@0 rsi@8 rdx@16 rcx@24 rbx@32 rax@40.
export fn qjs_syscall_dispatch(frame: usize) -> void {
    var nr: u64 = 0;
    unsafe { nr = raw.load<u64>(phys(frame + 40)); } // rax
    if nr == SYS_EXIT {
        put_str("\nUSER-EXIT from ring3\n");
        qemu_exit(0);
        halt_forever();
    }
    var a0: u64 = 0;
    var a1: u64 = 0;
    var a2: u64 = 0;
    unsafe {
        a0 = raw.load<u64>(phys(frame + 0));  // rdi
        a1 = raw.load<u64>(phys(frame + 8));  // rsi
        a2 = raw.load<u64>(phys(frame + 16)); // rdx
    }
    let res: u64 = mc_syscall(nr, a0, a1, a2);
    unsafe { raw.store<u64>(phys(frame + 40), res); } // write back rax
}

#[naked]
#[noinline]
export fn syscall_stub() -> void {
    asm opaque volatile {
        "push %r15\n push %r14\n push %r13\n push %r12\n push %r11\n push %r10\n push %r9\n push %r8\n push %rbp\n push %rax\n push %rbx\n push %rcx\n push %rdx\n push %rsi\n push %rdi\n mov %rsp, %rdi\n call qjs_syscall_dispatch\n pop %rdi\n pop %rsi\n pop %rdx\n pop %rcx\n pop %rbx\n pop %rax\n pop %rbp\n pop %r8\n pop %r9\n pop %r10\n pop %r11\n pop %r12\n pop %r13\n pop %r14\n pop %r15\n iretq"
    }
}

#[naked]
#[noinline]
export fn enter_user(entry: u64, user_rsp: u64) -> void {
    asm opaque volatile {
        "mov $0x23, %ax\n mov %ax, %ds\n mov %ax, %es\n mov %ax, %fs\n mov %ax, %gs\n push $0x23\n push %rsi\n push $0x202\n push $0x1b\n push %rdi\n iretq"
    }
}

fn make_seg(is_code: bool, dpl: u64) -> u64 {
    let dpl3: u64 = dpl & 3;
    let dplbits: u64 = dpl3 << 45;
    var d: u64 = SEG_S | SEG_P | dplbits;
    if is_code {
        d = d | SEG_EX | SEG_L;
    } else {
        d = d | SEG_W;
    }
    return d;
}

fn gdt_install() -> void {
    gdt[0] = 0;
    gdt[1] = make_seg(true, 0);
    gdt[2] = make_seg(false, 0);
    gdt[3] = make_seg(true, 3);
    gdt[4] = make_seg(false, 3);

    let base: u64 = (&tss[0]) as usize as u64;
    let limit: u64 = 103;
    let base_lo24: u64 = base & 0xFF_FFFF;
    let base_24_31: u64 = (base >> 24) & 0xFF;
    let limit_16_19: u64 = (limit >> 16) & 0xF;
    var lo: u64 = limit & 0xFFFF;
    lo = lo | (base_lo24 << 16);
    lo = lo | ((0x9 as u64) << 40);
    lo = lo | ((1 as u64) << 47);
    lo = lo | (limit_16_19 << 48);
    lo = lo | (base_24_31 << 56);
    gdt[5] = lo;
    gdt[6] = (base >> 32) & 0xFFFF_FFFF;

    let gbase: u64 = (&gdt[0]) as usize as u64;
    let glimit: u16 = 55;
    let gdtr_base: usize = (&gdtr[0]) as usize;
    unsafe {
        raw.store<u16>(phys(gdtr_base), glimit);
        raw.store<u64>(phys(gdtr_base + 2), gbase);
    }
    lgdt(gdtr_base);
    reload_kernel_segments();
    load_tr();
}

fn idt_set(vec: usize, handler: usize, type_attr: u64) -> void {
    let addr: u64 = handler as u64;
    let off_lo: u64 = addr & 0xFFFF;
    let off_mid: u64 = (addr >> 16) & 0xFFFF;
    let off_hi: u64 = (addr >> 32) & 0xFFFF_FFFF;

    let word0: u64 = off_lo | (KCODE_SEL64 << 16) | (type_attr << 40) | (off_mid << 48);
    let word1: u64 = off_hi;

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
    let sc: usize = (&syscall_stub) as usize;

    var i: usize = 0;
    while i < 256 {
        idt_set(i, gp, GATE_PRESENT_INT64);
        i = i + 1;
    }
    idt_set(13, gp, GATE_PRESENT_INT64);
    idt_set(14, pf, GATE_PRESENT_INT64);
    idt_set(0x80, sc, GATE_DPL3_INT64);

    let base: usize = (&idt[0]) as usize;
    let limit: u16 = IDT_LIMIT;
    let idtr_base: usize = (&idtr[0]) as usize;
    unsafe {
        raw.store<u16>(phys(idtr_base), limit);
        raw.store<u64>(phys(idtr_base + 2), base as u64);
    }
    lidt(idtr_base);
}

fn print_load_status(s: u32) -> void {
    if s == 1 { put_str("APP-LOAD-FAIL: BadElf\n"); }
    else { if s == 2 { put_str("APP-LOAD-FAIL: TooManyPages\n"); }
    else { if s == 3 { put_str("APP-LOAD-FAIL: NoFrame\n"); }
    else { if s == 4 { put_str("APP-LOAD-FAIL: BadSegment\n"); }
    else { put_str("APP-LOAD-FAIL: unknown\n"); } } } }
}

export fn kmain() -> void {
    serial_init();
    pic_mask_all(); // legacy PIC IRQs overlap exception vectors; agent uses polled I/O
    put_str("x86-64 long mode: confined QuickJS agent boot OK\n");

    gdt_install();
    put_str("qjs: GDT+TSS installed (ring0/ring3 segments, TR loaded)\n");
    idt_install();
    put_str("qjs: IDT installed (#GP=13, #PF=14, syscall=0x80 DPL3)\n");

    let trap_base: usize = align_up((&kernel_trap_stack[0]) as usize, 16);
    let rsp0: u64 = (trap_base + 16384) as u64;
    let tss_base: usize = (&tss[0]) as usize;
    unsafe {
        raw.store<u64>(phys(tss_base + 4), rsp0);   // rsp0 @ offset 4
        raw.store<u16>(phys(tss_base + 102), 104);  // iomap_base @ offset 102
    }

    // Register the MC syscall table before any int 0x80.
    syscall_setup();

    let image_base: usize = (&app_image) as usize;
    let image_len: usize = app_image_len as usize;
    let region_base: usize = align_up((&region[0]) as usize, PAGE);

    var cr3: u64 = 0;
    let built: u32 = app_build_x86(image_base, image_len, region_base, REGION_LEN, &cr3);
    if built == 0 || cr3 == 0 {
        print_load_status(app_build_status_x86());
        qemu_exit(1);
        halt_forever();
    }
    put_str("qjs: agent address space built, cr3=");
    put_hex64(cr3);
    console_putc(10);

    if app_kernel_not_user_x86(KERNEL_VA) == 1 {
        put_str("CONFINED: kernel mapped supervisor-only (no PTE_US) in agent space\n");
    } else {
        put_str("LEAK: kernel user-accessible in agent space\n");
    }
    if app_entry_is_user_x86() == 1 {
        put_str("CONFINED: agent entry is ring-3 accessible\n");
    } else {
        put_str("LEAK: agent entry not user-accessible\n");
    }

    let entry: u64 = app_entry_x86();
    put_str("qjs: entering confined QuickJS agent\n");

    load_cr3(cr3);
    enter_user(entry, entry);

    put_str("QJS-X86-BAD (enter_user returned)\n");
    qemu_exit(1);
    halt_forever();
}
