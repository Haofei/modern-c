// AArch64 EL1 runtime for the CONFINED QuickJS agent — PURE MC (replaces
// kernel/arch/aarch64/qjs_user_runtime.c). Reuses M8's EL0 machinery VERBATIM from
// tests/arm/user_arm_runtime.mc — CPACR FPEN, the full EL1 vector table (VBAR_EL1), the
// "Lower EL AArch64 sync" save/dispatch trampoline, MAIR/TCR/SCTLR + MMU bring-up, and the
// eret-to-EL0 entry — but instead of a hand-assembled program it: (1) loads the REAL
// multi-segment QuickJS EL0 ELF (embedded as app_image[], read via `extern global`) into an
// ISOLATED stage-1 space via app_build_aarch64 (the MC fixture qjs_arm_demo.mc), which also
// maps the kernel RAM EL1-only + the PL011 UART Device page so EL1 + the SVC trap path survive
// the TTBR0 switch; (2) installs VBAR_EL1, loads TTBR0_EL1, enables the MMU, and erets into the
// QuickJS entry. Syscalls (except SYS_EXIT=3, the qjs ABI) dispatch through the SAME MC table
// the riscv/x86 paths use (mc_syscall). There is NO boot.S — `_start` (EL2->EL1 drop) is MC.
// mc_console_putc is exported for the MC SYS_WRITE handler; QuickJS stays vendored.

import "kernel/arch/aarch64/pl011.mc"; // console_putc / put_str / put_hex64 (pure MC, no imports)

// The MC fixture (qjs_arm_demo.mc) — linked separately, so declared extern (importing duplicates).
extern fn app_build_aarch64(image_base: usize, image_len: usize, region_base: usize, region_len: usize, out_ttbr0: *mut u64) -> u32;
extern fn app_build_status_aarch64() -> u32;
extern fn app_entry_aarch64() -> u64;
extern fn app_kernel_not_user_aarch64(kernel_va: usize) -> u32;
extern fn app_entry_is_user_aarch64() -> u32;
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

// The console sink the MC SYS_WRITE handler (qjs_arm_demo.mc's syscall table) calls per byte.
export fn mc_console_putc(c: u8) -> void { console_putc(c); }

const SYS_EXIT: u64 = 3;                  // qjs agent ABI (user/abi.mc), NOT M8's 2
const KERNEL_VA: usize = 0x4000_0000;     // RAM base / kernel image load address
const PAGE: usize = 4096;
const REGION_LEN: usize = 16 * 1024 * 1024; // 16 MiB

const CPACR_FPEN: u64 = 0x30_0000;
const MAIR_VALUE: u64 = 0xFF | (0x04 << 8);
const TCR_VALUE: u64 =
    (16 << 0)  |
    (1  << 8)  |
    (1  << 10) |
    (3  << 12) |
    (1  << 23) |
    (5  << 32);
const SCTLR_M: u64 = 0x1;
const SCTLR_C: u64 = 0x4;
const SCTLR_I: u64 = 0x1000;
const SPSR_EL0T: u64 = 0x3c0;

const TF_X0: usize = 0;
const TF_X1: usize = 8;
const TF_X2: usize = 16;
const TF_X8: usize = 64;
const TF_X29: usize = 29 * 8;
const TF_X30: usize = 30 * 8;

#[noinline]
fn halt_forever() -> void {
    while true {
        #[unsafe_contract(precise_asm)] {
            unsafe { asm precise volatile { "wfe" clobber("memory") } }
        }
    }
}

fn read_currentel() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "mrs %0, CurrentEL" out("r") v: u64, clobber("memory") } }
    }
    return (v >> 2) & 3;
}
fn read_esr() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "mrs %0, esr_el1" out("r") v: u64, clobber("memory") } }
    }
    return v;
}
fn read_elr() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "mrs %0, elr_el1" out("r") v: u64, clobber("memory") } }
    }
    return v;
}
fn read_far() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "mrs %0, far_el1" out("r") v: u64, clobber("memory") } }
    }
    return v;
}
fn read_spsr() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "mrs %0, spsr_el1" out("r") v: u64, clobber("memory") } }
    }
    return v;
}
fn read_sp_el0() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "mrs %0, sp_el0" out("r") v: u64, clobber("memory") } }
    }
    return v;
}

fn enable_fpsimd() -> void {
    var cpacr: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "mrs %0, cpacr_el1" out("r") cpacr: u64, clobber("memory") } }
    }
    cpacr = cpacr | CPACR_FPEN;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "msr cpacr_el1, %0\n isb" in("r") cpacr: u64, clobber("memory") } }
    }
}

fn install_vbar(base_addr: usize) -> void {
    let base: u64 = base_addr as u64;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "msr vbar_el1, %0\n isb" in("r") base: u64, clobber("memory") } }
    }
}

fn config_mair_tcr(mair: u64, tcr: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "msr mair_el1, %0" in("r") mair: u64, clobber("memory") } }
    }
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "msr tcr_el1, %0\n isb" in("r") tcr: u64, clobber("memory") } }
    }
}

fn enable_mmu(ttbr0: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "msr ttbr0_el1, %0\n dsb ish\n isb\n tlbi vmalle1\n dsb ish\n isb"
                in("r") ttbr0: u64,
                clobber("memory")
            }
        }
    }
    var sctlr: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "mrs %0, sctlr_el1" out("r") sctlr: u64, clobber("memory") } }
    }
    sctlr = sctlr | SCTLR_M | SCTLR_C | SCTLR_I;
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "msr sctlr_el1, %0\n isb" in("r") sctlr: u64, clobber("memory") } }
    }
}

// Report-and-halt path for any UNEXPECTED exception (x0 carries the vector "kind").
export fn arm_qjs_unexpected(kind: u64) -> void {
    put_str("\nQJS-ARM64-BAD exception kind=");
    put_hex64(kind);
    put_str(" ESR=");
    put_hex64(read_esr());
    put_str(" EC=");
    put_hex64((read_esr() >> 26) & 0x3f);
    put_str(" ELR=");
    put_hex64(read_elr());
    put_str(" FAR=");
    put_hex64(read_far());
    put_str(" SPSR=");
    put_hex64(read_spsr());
    console_putc(10);
    halt_forever();
}

// The synchronous lower-EL (EL0) dispatcher. `frame` is the SP_EL1 trap-frame base (&x0). On an
// SVC (ESR_EL1.EC == 0x15): SYS_EXIT prints USER-EXIT + halts; everything else routes through the
// MC syscall table, writing the return value back into the saved x0.
export fn arm_qjs_syscall(frame: usize) -> void {
    let esr: u64 = read_esr();
    let ec: u64 = (esr >> 26) & 0x3f;
    if ec != 0x15 {
        unsafe {
            put_str(" frame.x0=");
            put_hex64(raw.load<u64>(phys(frame + TF_X0)));
            put_str(" x1=");
            put_hex64(raw.load<u64>(phys(frame + TF_X1)));
            put_str(" x2=");
            put_hex64(raw.load<u64>(phys(frame + TF_X2)));
            put_str(" x29=");
            put_hex64(raw.load<u64>(phys(frame + TF_X29)));
            put_str(" x30=");
            put_hex64(raw.load<u64>(phys(frame + TF_X30)));
            let usp: u64 = read_sp_el0();
            put_str(" sp_el0=");
            put_hex64(usp);
            if usp != 0 {
                put_str(" saved_lr=");
                put_hex64(raw.load<u64>(phys(usp as usize)));
            }
            console_putc(10);
        }
        arm_qjs_unexpected(0x100 | ec);
        return; // unreachable
    }
    var nr: u64 = 0;
    var a0: u64 = 0;
    var a1: u64 = 0;
    var a2: u64 = 0;
    unsafe {
        nr = raw.load<u64>(phys(frame + TF_X8));
        a0 = raw.load<u64>(phys(frame + TF_X0));
        a1 = raw.load<u64>(phys(frame + TF_X1));
        a2 = raw.load<u64>(phys(frame + TF_X2));
    }
    if nr == SYS_EXIT {
        put_str("\nUSER-EXIT from EL0\n");
        halt_forever();
    }
    let res: u64 = mc_syscall(nr, a0, a1, a2);
    unsafe { raw.store<u64>(phys(frame + TF_X0), res); }
}

// Save the full EL0 GP state + ELR/SPSR onto SP_EL1, call the MC dispatcher, restore, eret.
#[naked]
#[noinline]
export fn arm_qjs_sync_lower() -> void {
    asm opaque volatile {
        "sub sp, sp, #(33*8)\n stp x0, x1, [sp, #(0*8)]\n stp x2, x3, [sp, #(2*8)]\n stp x4, x5, [sp, #(4*8)]\n stp x6, x7, [sp, #(6*8)]\n stp x8, x9, [sp, #(8*8)]\n stp x10, x11, [sp, #(10*8)]\n stp x12, x13, [sp, #(12*8)]\n stp x14, x15, [sp, #(14*8)]\n stp x16, x17, [sp, #(16*8)]\n stp x18, x19, [sp, #(18*8)]\n stp x20, x21, [sp, #(20*8)]\n stp x22, x23, [sp, #(22*8)]\n stp x24, x25, [sp, #(24*8)]\n stp x26, x27, [sp, #(26*8)]\n stp x28, x29, [sp, #(28*8)]\n mrs x1, elr_el1\n stp x30, x1, [sp, #(30*8)]\n mrs x2, spsr_el1\n str x2, [sp, #(32*8)]\n mov x0, sp\n bl arm_qjs_syscall\n ldr x2, [sp, #(32*8)]\n msr spsr_el1, x2\n ldp x30, x1, [sp, #(30*8)]\n msr elr_el1, x1\n ldp x0, x1, [sp, #(0*8)]\n ldp x2, x3, [sp, #(2*8)]\n ldp x4, x5, [sp, #(4*8)]\n ldp x6, x7, [sp, #(6*8)]\n ldp x8, x9, [sp, #(8*8)]\n ldp x10, x11, [sp, #(10*8)]\n ldp x12, x13, [sp, #(12*8)]\n ldp x14, x15, [sp, #(14*8)]\n ldp x16, x17, [sp, #(16*8)]\n ldp x18, x19, [sp, #(18*8)]\n ldp x20, x21, [sp, #(20*8)]\n ldp x22, x23, [sp, #(22*8)]\n ldp x24, x25, [sp, #(24*8)]\n ldp x26, x27, [sp, #(26*8)]\n ldp x28, x29, [sp, #(28*8)]\n add sp, sp, #(33*8)\n eret"
    }
}

#[naked]
#[noinline]
export fn arm_qjs_exc_halt() -> void {
    asm opaque volatile {
        "bl arm_qjs_unexpected\n 1: wfe\n b 1b"
    }
}

// The EL1 exception vector table: 16 entries x 0x80 bytes. Only the "Lower EL AArch64 sync" entry
// (group 3, offset 0x400) takes the real syscall path; the rest stamp a kind id and halt.
#[naked]
#[section(".text.vectors")]
export fn arm_qjs_vectors() -> void {
    asm opaque volatile {
        ".balign 0x80\n mov x0, #0\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #1\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #2\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #3\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #4\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #5\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #6\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #7\n b arm_qjs_exc_halt\n.balign 0x80\n b arm_qjs_sync_lower\n.balign 0x80\n mov x0, #9\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #10\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #11\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #12\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #13\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #14\n b arm_qjs_exc_halt\n.balign 0x80\n mov x0, #15\n b arm_qjs_exc_halt"
    }
}

// EL0 entry: SP_EL0=user_sp, ELR_EL1=entry, SPSR_EL1=EL0t (DAIF masked), eret.
fn enter_user(entry: usize, user_sp: usize) -> void {
    let entry_u: u64 = entry as u64;
    let sp_u: u64 = user_sp as u64;
    let spsr: u64 = SPSR_EL0T;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "msr sp_el0, %1\n msr elr_el1, %0\n msr spsr_el1, %2\n isb\n eret"
                in("r") entry_u: u64,
                in("r") sp_u: u64,
                in("r") spsr: u64,
                clobber("memory")
            }
        }
    }
}

// The agent's page tables + per-page frames (8 MiB arena + engine + 512 KiB stack + tables).
global g_region: [16781312]u8; // 16 MiB + a page for alignment

fn page_align(a: usize) -> usize {
    return (a + (PAGE - 1)) & ~(PAGE - 1);
}
fn print_load_status(s: u32) -> void {
    if s == 1 { put_str("APP-LOAD-FAIL: BadElf\n"); }
    else { if s == 2 { put_str("APP-LOAD-FAIL: TooManyPages\n"); }
    else { if s == 3 { put_str("APP-LOAD-FAIL: NoFrame\n"); }
    else { if s == 4 { put_str("APP-LOAD-FAIL: BadSegment\n"); }
    else { put_str("APP-LOAD-FAIL: unknown\n"); } } } }
}

export fn usermain() -> void {
    enable_fpsimd(); // CPACR_EL1.FPEN (QuickJS doubles + the LLVM backend's SIMD)
    put_str("aarch64 EL0: confined QuickJS agent boot OK\n");

    let el: u64 = read_currentel();
    put_str("qjs: CurrentEL=");
    put_hex64(el);
    console_putc(10);

    let vbar: usize = (&arm_qjs_vectors) as usize;
    install_vbar(vbar);
    put_str("qjs: VBAR_EL1 installed (EL0 sync -> syscall dispatch)\n");

    config_mair_tcr(MAIR_VALUE, TCR_VALUE);
    put_str("qjs: MAIR/TCR configured\n");

    syscall_setup(); // register the MC syscall table before any svc

    let image_base: usize = (&app_image) as usize;
    let image_len: usize = app_image_len as usize;
    let region: usize = page_align((&g_region[0]) as usize);

    var ttbr0: u64 = 0;
    let built: u32 = app_build_aarch64(image_base, image_len, region, REGION_LEN, &ttbr0);
    if built == 0 || ttbr0 == 0 {
        print_load_status(app_build_status_aarch64());
        halt_forever();
    }
    put_str("qjs: agent address space built, ttbr0=");
    put_hex64(ttbr0);
    console_putc(10);

    if app_kernel_not_user_aarch64(KERNEL_VA) == 1 {
        put_str("CONFINED: kernel mapped EL1-only (no EL0 access) in agent space\n");
    } else {
        put_str("LEAK: kernel EL0-accessible in agent space\n");
    }
    if app_entry_is_user_aarch64() == 1 {
        put_str("CONFINED: agent entry is EL0-accessible\n");
    } else {
        put_str("LEAK: agent entry not EL0-accessible\n");
    }

    let entry: u64 = app_entry_aarch64();
    enable_mmu(ttbr0);
    put_str("qjs: MMU enabled (TTBR0 active); entering confined QuickJS agent\n");

    enter_user(entry as usize, entry as usize);
    // enter_user does not return (the agent SYS_EXITs from EL0).
}

// QEMU 'virt' -kernel enters the flat image at its load address. `_start` sets SP, drops EL2->EL1
// if needed, then `bl usermain`. No boot.S.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "ldr x1, =_stack_top\n mov sp, x1\n mrs x0, CurrentEL\n lsr x0, x0, #2\n and x0, x0, #3\n cmp x0, #2\n b.ne 2f\n mov x0, #(1 << 31)\n msr hcr_el2, x0\n mov x0, #0x3c5\n msr spsr_el2, x0\n adr x0, 1f\n msr elr_el2, x0\n isb\n eret\n1:\n ldr x1, =_stack_top\n mov sp, x1\n2:\n bl usermain\n3: wfe\n b 3b"
    }
}
