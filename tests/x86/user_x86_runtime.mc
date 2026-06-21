// M6 "x86-64 ring-3 user hello" — PURE MC (replaces kernel/arch/x86_64/user_runtime.c).
//
// In 64-bit long mode (reached from boot.S, which identity-maps the low 1 GiB and runs us at
// 1 MiB) this builds a GDT (ring0/ring3 code+data + TSS), an IDT (#GP/#PF + an int-0x80 syscall
// gate at DPL3), hand-assembles a tiny ring-3 program into a user page, builds the confined user
// address space via the MC fixture user_x86_demo.mc, loads CR3, and iretq's into ring 3. The
// int-0x80 ISR copies+validates the user pointer (sys_write_copyin), printing HELLO-FROM-RING3,
// rejecting a bad pointer with -EFAULT, and SYS_EXITing.
//
// Reuses the landed x86 template: port_io.mc (COM1 console + outb/inb) and the vm_x86_runtime.mc
// idioms (packed IdtEntry + raw.store, naked stubs that `call` exported handlers, precise-asm for
// lidt/lgdt/ltr/cr3). boot.S (the 32-bit multiboot/long-mode trampoline MC cannot target) is the
// only C that remains; it `call kmain`s into this object.

import "kernel/arch/x86_64/port_io.mc"; // serial_init/console_putc/put_str/put_hex64 + outb/inb

// The MC fixture (user_x86_demo.mc) — linked as a separate object, so declared extern here
// (importing it would duplicate its definitions: E_DUPLICATE_DECLARATION).
extern fn user_x86_build(region_base: usize, region_len: usize, code_phys: usize, code_len: usize, stack_phys: usize, stack_len: usize, out_cr3: *mut u64) -> u32;
extern fn user_code_va() -> u64;
extern fn user_stack_top_va() -> u64;
extern fn kernel_not_user(kernel_va: usize) -> u32;
extern fn user_code_is_user() -> u32;
extern fn sys_write_copyin(user_ptr: usize, len: usize, kdst: usize) -> i64;

const SYS_WRITE: u64 = 1;
const SYS_EXIT: u64 = 2;
const QEMU_EXIT_PORT: u16 = 0xf4;

// Selectors (index<<3 | RPL). GDT: [0]null [1]kcode [2]kdata [3]ucode [4]udata [5..6]TSS.
const SEL_KCODE: u16 = 0x08;
const SEL_KDATA: u16 = 0x10;
// (user/TSS selectors are hardcoded in the asm templates below: ucode=0x1B udata=0x23 tss=0x28)

// Segment-descriptor bit fields (module-const shifts are const-folded; inline `1<<n` in a fn body
// would crash emit-c, so the runtime values are named consts).
const SEG_S: u64 = (1 as u64) << 44;   // code/data (not system)
const SEG_P: u64 = (1 as u64) << 47;   // present
const SEG_EX: u64 = (1 as u64) << 43;  // executable (code)
const SEG_L: u64 = (1 as u64) << 53;   // 64-bit code segment
const SEG_W: u64 = (1 as u64) << 41;   // writable (data)

const IDT_LIMIT: u16 = 0x0FFF;            // 256 gates * 16 - 1
const GATE_PRESENT_INT64: u64 = 0x8E;     // P=1, DPL=0, type=0xE (64-bit interrupt gate)
const GATE_DPL3_INT64: u64 = 0xEE;        // P=1, DPL=3, type=0xE (ring-3 int 0x80 allowed)
const KCODE_SEL64: u64 = 0x08;

const USER_VA: u64 = 0x4000_0000;
const HELLO_LEN: usize = 17;              // "HELLO-FROM-RING3\n"
const EFOK_LEN: usize = 10;               // "EFAULT-OK\n"
const CODE_LEN: usize = 63;               // analytic instruction length (see build_user_program)
const BAD_PTR: u64 = 0xDEAD_0000;

const HEAP_BYTES: usize = 1024 * 1024;
const PAGE: usize = 4096;

// One long-mode interrupt-gate descriptor (16 bytes; packed so the array stride is exactly 16).
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
global idtr: [10]u8;          // 2-byte limit + 8-byte base, packed
global gdt: [7]u64;           // 5 seg descriptors + a 16-byte TSS descriptor (2 quadwords)
global gdtr: [10]u8;
global tss: [104]u8;          // packed tss64: rsp0@4, iomap_base@102
global kbuf: [256]u8;         // syscall copy-in landing buffer
global user_code: [128 + HELLO_LEN + EFOK_LEN]u8;
global g_code_len: usize;
// Backing stores: over-allocated by a page so the base can be rounded up to 4 KiB (no global-align).
global heap_region: [HEAP_BYTES + PAGE]u8;
global user_page: [PAGE + PAGE]u8;
global user_stack: [8192 + PAGE]u8;
global kernel_trap_stack: [8192 + PAGE]u8;

fn align_up(x: usize, a: usize) -> usize {
    let m: usize = a - 1;
    let s: usize = x + m;
    let inv: usize = ~m;
    return s & inv;
}

// ---- low-level CPU primitives (the bits that genuinely need asm) ----

fn qemu_exit(code: u8) -> void { outb(QEMU_EXIT_PORT, code); }

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

// Reload DS/ES/SS/FS/GS to the ring-0 data selector and CS via a far return (lretq). Selectors
// are hardcoded (kdata=0x10, kcode=0x08), so this is operand-free opaque asm.
fn reload_kernel_segments() -> void {
    unsafe {
        asm opaque volatile {
            "mov $0x10, %%ax\n mov %%ax, %%ds\n mov %%ax, %%es\n mov %%ax, %%ss\n mov %%ax, %%fs\n mov %%ax, %%gs\n lea 1f(%%rip), %%rax\n push $0x08\n push %%rax\n lretq\n 1:"
            clobber("rax")
            clobber("memory")
        }
    }
}

// Load the task register with the TSS selector (0x28). ltr needs a 16-bit reg, so hardcode.
fn load_tr() -> void {
    unsafe {
        asm opaque volatile { "mov $0x28, %%ax\n ltr %%ax" clobber("rax") clobber("memory") }
    }
}

// ---- fault handlers (exported so the naked stubs can `call` them by plain symbol) ----

export fn on_gp() -> void {
    put_str("\nX86-USER-BAD #GP\n");
    qemu_exit(1);
    halt_forever();
}

export fn on_pf() -> void {
    let cr2: u64 = read_cr2();
    put_str("\nX86-USER-BAD #PF at ");
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

// ---- int-0x80 syscall dispatch ----
// The naked stub pushes the GP registers (struct-regs order: rdi@0 rsi@8 rdx@16 rcx@24 rbx@32
// rax@40 rbp@48 r8..r15) and calls this with the frame pointer (rsp) in rdi. We read/modify the
// saved frame via raw.load/store at byte offsets — the LLVM backend does not support member
// assignment through a deref.
export fn syscall_dispatch(frame: usize) -> void {
    var nr: u64 = 0;
    unsafe { nr = raw.load<u64>(phys(frame + 40)); } // rax
    if nr == SYS_EXIT {
        put_str("\nUSER-EXIT from ring3\n");
        qemu_exit(0);
        halt_forever();
    }
    if nr == SYS_WRITE {
        var uptr: u64 = 0;
        var len: u64 = 0;
        unsafe {
            uptr = raw.load<u64>(phys(frame + 0));  // rdi = user pointer
            len = raw.load<u64>(phys(frame + 8));   // rsi = length
        }
        if len > 256 { len = 256; }
        let kdst: usize = (&kbuf[0]) as usize;
        let res: i64 = sys_write_copyin(uptr as usize, len as usize, kdst);
        if res >= 0 {
            let n: usize = res as usize;
            var i: usize = 0;
            while i < n {
                console_putc(kbuf[i]);
                i = i + 1;
            }
        }
        unsafe { raw.store<u64>(phys(frame + 40), res as u64); } // write back rax
        return;
    }
    put_str("BAD-SYSCALL nr=");
    put_hex64(nr);
    console_putc(10);
    qemu_exit(1);
    halt_forever();
}

// Saves the GP registers (struct-regs layout), passes &saved-regs in rdi to the dispatcher,
// restores, and iretq's back to ring 3. int 0x80 has no CPU error code, so none is popped.
#[naked]
#[noinline]
export fn syscall_stub() -> void {
    asm opaque volatile {
        "push %r15\n push %r14\n push %r13\n push %r12\n push %r11\n push %r10\n push %r9\n push %r8\n push %rbp\n push %rax\n push %rbx\n push %rcx\n push %rdx\n push %rsi\n push %rdi\n mov %rsp, %rdi\n call syscall_dispatch\n pop %rdi\n pop %rsi\n pop %rdx\n pop %rcx\n pop %rbx\n pop %rax\n pop %rbp\n pop %r8\n pop %r9\n pop %r10\n pop %r11\n pop %r12\n pop %r13\n pop %r14\n pop %r15\n iretq"
    }
}

// ---- ring-3 entry: push an iretq frame (SS/RSP/RFLAGS/CS/RIP) and iretq into ring 3 ----
// Naked: entry arrives in rdi (RIP), user_rsp in rsi (RSP). udata=0x23, ucode=0x1b, RFLAGS=0x202.
#[naked]
#[noinline]
export fn enter_user(entry: u64, user_rsp: u64) -> void {
    asm opaque volatile {
        "mov $0x23, %ax\n mov %ax, %ds\n mov %ax, %es\n mov %ax, %fs\n mov %ax, %gs\n push $0x23\n push %rsi\n push $0x202\n push $0x1b\n push %rdi\n iretq"
    }
}

// ---- GDT construction ----
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
    gdt[1] = make_seg(true, 0);   // ring-0 code
    gdt[2] = make_seg(false, 0);  // ring-0 data
    gdt[3] = make_seg(true, 3);   // ring-3 code
    gdt[4] = make_seg(false, 3);  // ring-3 data

    // 64-bit TSS descriptor (two quadwords, gdt[5] + gdt[6]).
    let base: u64 = (&tss[0]) as usize as u64;
    let limit: u64 = 103; // sizeof(tss) - 1
    let base_lo24: u64 = base & 0xFF_FFFF;
    let base_24_31: u64 = (base >> 24) & 0xFF;
    let limit_16_19: u64 = (limit >> 16) & 0xF;
    var lo: u64 = limit & 0xFFFF;
    lo = lo | (base_lo24 << 16);
    lo = lo | ((0x9 as u64) << 40);  // type = available 64-bit TSS
    lo = lo | ((1 as u64) << 47);    // present
    lo = lo | (limit_16_19 << 48);
    lo = lo | (base_24_31 << 56);
    gdt[5] = lo;
    gdt[6] = (base >> 32) & 0xFFFF_FFFF; // high 32 bits of the base

    // GDTR: 2-byte limit + 8-byte base.
    let gbase: u64 = (&gdt[0]) as usize as u64;
    let glimit: u16 = 55; // sizeof(gdt) - 1 = 7*8 - 1
    let gdtr_base: usize = (&gdtr[0]) as usize;
    unsafe {
        raw.store<u16>(phys(gdtr_base), glimit);
        raw.store<u64>(phys(gdtr_base + 2), gbase);
    }
    lgdt(gdtr_base);
    reload_kernel_segments();
    load_tr();
}

// ---- IDT construction (two 64-bit words per gate; type_attr carries DPL) ----
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
    idt_set(0x80, sc, GATE_DPL3_INT64); // ring-3 int 0x80 allowed

    let base: usize = (&idt[0]) as usize;
    let limit: u16 = IDT_LIMIT;
    let idtr_base: usize = (&idtr[0]) as usize;
    unsafe {
        raw.store<u16>(phys(idtr_base), limit);
        raw.store<u64>(phys(idtr_base + 2), base as u64);
    }
    lidt(idtr_base);
}

// ---- the ring-3 program (hand-assembled x86-64) ----
// `mov r32, imm32` (B8+rd) zero-extends to 64 bits (our values are < 2^32). rd: 0=rax,6=rsi,7=rdi.
fn emit_mov_imm32(p: usize, rd: u8, imm: u32) -> void {
    let op: u8 = 0xB8 + rd;
    user_code[p] = op;
    user_code[p + 1] = (imm & 0xFF) as u8;
    user_code[p + 2] = ((imm >> 8) & 0xFF) as u8;
    user_code[p + 3] = ((imm >> 16) & 0xFF) as u8;
    user_code[p + 4] = ((imm >> 24) & 0xFF) as u8;
}

// Copy the NUL-terminated literal `s` into user_code at offset `off`; return bytes copied.
fn copy_str(off: usize, s: *const u8) -> usize {
    let sbase: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(sbase + i)); }
        if b == 0 { break; }
        user_code[off + i] = b;
        i = i + 1;
    }
    return i;
}

fn build_user_program() -> void {
    // Fixed-size instruction stream (analytic CODE_LEN=63; see the C original): two WRITE
    // sequences (17 each), test+jns (5), WRITE EFOK (17), EXIT (7) = 63. Strings follow at
    // offset CODE_LEN, so their ring-3 VAs are USER_VA + CODE_LEN [+ HELLO_LEN].
    let hello_va: u32 = (USER_VA + (CODE_LEN as u64)) as u32;
    let efok_va: u32 = (USER_VA + (CODE_LEN as u64) + (HELLO_LEN as u64)) as u32;
    let wlen: u32 = HELLO_LEN as u32;

    var p: usize = 0;
    // 1) SYS_WRITE(HELLO)
    emit_mov_imm32(p, 0, SYS_WRITE as u32); p = p + 5;
    emit_mov_imm32(p, 7, hello_va);         p = p + 5;
    emit_mov_imm32(p, 6, wlen);             p = p + 5;
    user_code[p] = 0xCD; user_code[p + 1] = 0x80; p = p + 2; // int 0x80
    // 2) SYS_WRITE(BAD_PTR)
    emit_mov_imm32(p, 0, SYS_WRITE as u32); p = p + 5;
    emit_mov_imm32(p, 7, BAD_PTR as u32);   p = p + 5;
    emit_mov_imm32(p, 6, wlen);             p = p + 5;
    user_code[p] = 0xCD; user_code[p + 1] = 0x80; p = p + 2;
    // 3) test rax,rax ; jns +rel8 (skip EFOK if rax >= 0)
    user_code[p] = 0x48; user_code[p + 1] = 0x85; user_code[p + 2] = 0xC0; p = p + 3;
    user_code[p] = 0x79; p = p + 1;
    let jns_operand_pos: usize = p;
    user_code[p] = 0x00; p = p + 1;
    let after_jns: usize = p;
    // 4) SYS_WRITE(EFOK)
    emit_mov_imm32(p, 0, SYS_WRITE as u32); p = p + 5;
    emit_mov_imm32(p, 7, efok_va);          p = p + 5;
    emit_mov_imm32(p, 6, EFOK_LEN as u32);  p = p + 5;
    user_code[p] = 0xCD; user_code[p + 1] = 0x80; p = p + 2;
    let skip_target: usize = p;
    user_code[jns_operand_pos] = (skip_target - after_jns) as u8; // rel8 forward
    // 5) SYS_EXIT
    emit_mov_imm32(p, 0, SYS_EXIT as u32);  p = p + 5;
    user_code[p] = 0xCD; user_code[p + 1] = 0x80; p = p + 2;

    // Append the strings right after the code.
    let h: usize = copy_str(CODE_LEN, "HELLO-FROM-RING3\n");
    let e: usize = copy_str(CODE_LEN + HELLO_LEN, "EFAULT-OK\n");
    g_code_len = CODE_LEN + h + e;

    if p != CODE_LEN {
        put_str("X86-USER-BAD code-len mismatch\n");
        qemu_exit(1);
        halt_forever();
    }
}

export fn kmain() -> void {
    serial_init();
    put_str("x86-64 long mode: USER demo boot OK\n");

    gdt_install();
    put_str("user: GDT+TSS installed (ring0/ring3 segments, TR loaded)\n");
    idt_install();
    put_str("user: IDT installed (#GP=13, #PF=14, syscall=0x80 DPL3)\n");

    // TSS.rsp0 = top of the kernel trap stack (used on the ring3->ring0 trap entry); iomap_base
    // = sizeof(tss) (no I/O bitmap).
    let trap_base: usize = align_up((&kernel_trap_stack[0]) as usize, 16);
    let rsp0: u64 = (trap_base + 8192) as u64;
    let tss_base: usize = (&tss[0]) as usize;
    unsafe {
        raw.store<u64>(phys(tss_base + 4), rsp0);     // rsp0 @ offset 4
        raw.store<u16>(phys(tss_base + 102), 104);    // iomap_base @ offset 102
    }

    // Assemble the ring-3 program into the 4 KiB-aligned physical landing frame.
    build_user_program();
    let page_base: usize = align_up((&user_page[0]) as usize, PAGE);
    var i: usize = 0;
    while i < g_code_len {
        var b: u8 = 0;
        b = user_code[i];
        unsafe { raw.store<u8>(phys(page_base + i), b); }
        i = i + 1;
    }

    let heap_base: usize = align_up((&heap_region[0]) as usize, PAGE);
    let stack_base: usize = align_up((&user_stack[0]) as usize, PAGE);

    var cr3: u64 = 0;
    let _r: u32 = user_x86_build(heap_base, HEAP_BYTES, page_base, PAGE, stack_base, 8192, &cr3);
    put_str("user: address space built, cr3=");
    put_hex64(cr3);
    console_putc(10);

    if kernel_not_user(0x10_0000) == 1 {
        put_str("CONFINED: kernel mapped supervisor-only (no PTE_US) in user space\n");
    } else {
        put_str("LEAK: kernel user-accessible in user space\n");
    }
    if user_code_is_user() == 1 {
        put_str("CONFINED: user code is ring-3 accessible\n");
    } else {
        put_str("LEAK: user code not user-accessible\n");
    }

    load_cr3(cr3);
    put_str("user: CR3 reloaded; entering ring 3\n");

    enter_user(user_code_va(), user_stack_top_va());

    put_str("X86-USER-BAD (enter_user returned)\n");
    qemu_exit(1);
    halt_forever();
}
