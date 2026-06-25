// S-mode trap vector + syscall dispatch + privilege drop for the CONFINED QuickJS agent under
// REAL OpenSBI — in PURE MC (replaces kernel/arch/riscv64/smode_usermode_runtime.c). The S-mode
// CSRs (stvec/sscratch/sepc/scause/stval, sstatus.SPP, sret) + the legacy SBI console. The SAME
// MC syscall table the M-mode path uses (syscall_setup / mc_syscall in app_run_demo.mc) is reused
// verbatim — only the privilege-mode asm/CSRs change. No PMP (OpenSBI configures it).
//
// Local SBI `ecall` shims (NOT importing sbi.mc — that pulls std/addr, which would duplicate the
// fixture's copy at link); same place-in-template + clobber-ABI-regs idiom as sbi.mc.

const ECALL_FROM_U: u64 = 8;
const SYS_EXIT: u64 = 3; // handled here (returns control to the kernel)
const SCAUSE_S_EXT: u64 = 0x8000_0000_0000_0009;
const SCAUSE_INSTR_PAGE_FAULT: u64 = 12;
const SCAUSE_LOAD_PAGE_FAULT: u64 = 13;
const SCAUSE_STORE_PAGE_FAULT: u64 = 15;

// Frame layout (Frame struct): ra@0, t0..t6 @8..56, a0@64 a1@72 a2@80 a3@88 ... a7@120, s0@128 ...
const F_A0: usize = 64;
const F_A1: usize = 72;
const F_A2: usize = 80;
const F_A7: usize = 120;

// The MC syscall table (app_run_demo.mc) — identical to the M-mode path.
extern fn syscall_setup() -> void;
extern fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64;

fn smode_external_irq_noop() -> void {}

global g_smode_external_irq: fn() -> void = smode_external_irq_noop;

export fn smode_external_irq_set(handler: fn() -> void) -> void {
    g_smode_external_irq = handler;
}

global kernel_stack: [8192]u8;

fn sbi_ecall(ext: u64, fid: u64, arg0: u64, arg1: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv a7, %1\n mv a6, %2\n mv a0, %3\n mv a1, %4\n ecall\n mv %0, a0"
                out("t0") result: u64,
                in("t1") ext: u64,
                in("t2") fid: u64,
                in("t3") arg0: u64,
                in("t4") arg1: u64,
                clobber("a0"), clobber("a1"), clobber("a6"), clobber("a7"),
                clobber("memory")
            }
        }
    }
    return result;
}
fn sbi_putchar(c: u8) -> void {
    sbi_ecall(1, 0, c as u64, 0);
}
fn sbi_puts(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 { break; }
        sbi_putchar(b);
        i = i + 1;
    }
}
fn sbi_puthex(v: u64) -> void {
    sbi_puts("0x");
    var s: i32 = 60;
    while s >= 0 {
        let nib: u64 = (v >> (s as u64)) & 0xF;
        if nib < 10 { sbi_putchar((48 + nib) as u8); } else { sbi_putchar((87 + nib) as u8); }
        s = s - 4;
    }
}
fn sbi_shutdown() -> void {
    sbi_ecall(8, 0, 0, 0);
    while true {}
}

fn read_csr_scause() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrr %0, scause" out("r") v: u64, clobber("memory") } } }
    return v;
}
fn read_csr_sepc() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrr %0, sepc" out("r") v: u64, clobber("memory") } } }
    return v;
}
fn read_csr_stval() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrr %0, stval" out("r") v: u64, clobber("memory") } } }
    return v;
}
fn write_csr_sepc(v: u64) -> void {
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrw sepc, %0" in("r") v: u64, clobber("memory") } } }
}

// Dispatcher: an ecall from U-mode (scause==8). SYS_EXIT ends the agent; everything else goes
// through the MC syscall table. Any other trap fails closed.
export fn s_trap_entry(f: usize) -> void {
    let scause: u64 = read_csr_scause();
    let sepc: u64 = read_csr_sepc();
    let stval: u64 = read_csr_stval();

    if scause == SCAUSE_S_EXT {
        g_smode_external_irq();
        return;
    }

    if scause == ECALL_FROM_U {
        var a7: u64 = 0;
        var a0: u64 = 0;
        var a1: u64 = 0;
        var a2: u64 = 0;
        unsafe {
            a7 = raw.load<u64>(phys(f + F_A7));
            a0 = raw.load<u64>(phys(f + F_A0));
            a1 = raw.load<u64>(phys(f + F_A1));
            a2 = raw.load<u64>(phys(f + F_A2));
        }
        if a7 == SYS_EXIT {
            sbi_puts("\nUSER-EXIT from U\n");
            sbi_shutdown();
        }
        let res: u64 = mc_syscall(a7, a0, a1, a2);
        unsafe { raw.store<u64>(phys(f + F_A0), res); }
        write_csr_sepc(sepc + 4); // advance past the ecall
        return;
    }

    sbi_puts("UNEXPECTED-TRAP scause=");
    sbi_puthex(scause);
    if scause == SCAUSE_INSTR_PAGE_FAULT || scause == SCAUSE_LOAD_PAGE_FAULT || scause == SCAUSE_STORE_PAGE_FAULT {
        sbi_puts(" stval=");
        sbi_puthex(stval);
    }
    sbi_putchar(10);
    sbi_shutdown();
}

// S-mode trap vector: swap to the kernel stack via sscratch, save a full integer frame, dispatch,
// restore, sret. (U-mode-trap only; SPP handling deferred — see the C original / plan §12.)
#[naked]
#[section(".text.strap")]
export fn s_trap_vector() -> void {
    asm opaque volatile {
        ".balign 4\ncsrrw sp, sscratch, sp\n addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n mv a0, sp\n call s_trap_entry\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n csrrw sp, sscratch, sp\n sret"
    }
}

// Drop to U-mode: set sepc + user sp, clear sstatus.SPP (U), enable the FPU (FS=Initial), sret.
#[naked]
export fn enter_user(entry: usize, user_sp: usize) -> void {
    asm opaque volatile {
        "csrw sepc, a0\n mv sp, a1\n li t0, 0x100\n csrc sstatus, t0\n li t1, 0x2000\n csrs sstatus, t1\n sret"
    }
}

fn write_csr_stvec(v: usize) -> void {
    let a: u64 = v as u64;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrw stvec, %0" in("r") a: u64, clobber("memory") } } }
}
fn write_csr_sscratch(v: usize) -> void {
    let a: u64 = v as u64;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrw sscratch, %0" in("r") a: u64, clobber("memory") } } }
}

// Install the S-mode trap vector + kernel trap stack, register the syscall table. Call before enter_user.
export fn usermode_setup() -> void {
    write_csr_stvec((&s_trap_vector) as usize);
    write_csr_sscratch((&kernel_stack[0]) as usize + 8192);
    syscall_setup();
}
