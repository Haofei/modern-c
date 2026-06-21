// S-mode bring-up for the CONFINED QuickJS agent under REAL OpenSBI (the M3a path) — in
// PURE MC. The all-MC replacement for kernel/arch/riscv64/qjs_smode_confined_runtime.c.
// Like the M-mode qjs_confined_runtime.mc, but: OpenSBI enters us in S-mode at 0x80200000;
// console + power go through SBI ecalls (sbi.mc), not the bare UART/finisher; and satp IS
// effective in S-mode, so the agent's space ALSO maps the kernel as a supervisor-only
// gigapage (the trap path + this code keep running after satp activation) while the kernel
// stays unreachable from U (no PTE_U).
//
// The S-mode trap vector + ecall dispatch + enter_user come from smode_usermode_runtime.c;
// the loader/ABI/confinement (qjs_smode_build/...) from qjs_smode_demo.mc; QuickJS stays
// vendored. This runtime owns `_start` (no context_runtime.c on the S-mode path).

// SBI console/power via local `ecall` shims (NOT importing sbi.mc — that pulls in std/addr,
// whose helpers would clash with qjs_smode_demo.mc's copy at link). Same ecall idiom as sbi.mc:
// values are placed into the ABI regs IN the template (MC precise-asm operands are generic
// "r", not pinned), then the hard ABI regs are clobbered so the allocator avoids them.
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
    let _ignore: u64 = sbi_ecall(1, 0, c as u64, 0); // legacy console putchar (EID 1)
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
fn sbi_shutdown() -> void {
    let _ignore: u64 = sbi_ecall(8, 0, 0, 0); // legacy system shutdown (EID 8)
}

const RT_KERNEL_VA: usize = 0x8000_0000;
const RT_PAGE: usize = 4096;
const RT_REGION_LEN: usize = 16 * 1024 * 1024; // 16 MiB usable

// The embedded agent ELF, emitted by the harness as `const unsigned char app_image[]` +
// `const unsigned int app_image_len` — read via `extern global`.
extern global app_image: u8;
extern global app_image_len: u32;

// S-mode trap bring-up (smode_usermode_runtime.c) + the loader/confinement (qjs_smode_demo.mc).
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn qjs_smode_build(image_base: usize, image_len: usize, region_base: usize, region_len: usize) -> u64;
extern fn qjs_smode_kernel_not_user(satp: u64, kernel_va: usize) -> u32;
extern fn app_entry() -> u64;
extern fn app_build_status() -> u32;

// Backing store for the agent's page tables + per-page frames. Over-allocated by a page so
// the base rounds up to 4 KiB (MC has no compile-time global-align attr).
global g_region: [16781312]u8; // 16 MiB + 4 KiB

// §0 ingress (SYS_READ) default: no embedded agent source. WEAK so a source-serving test that
// links a STRONG mc_agent_source overrides it. Referenced by the demo's SYS_READ handler.
#[weak]
export fn mc_agent_source(out_len: *mut usize) -> usize {
    unsafe { raw.store<u64>(phys(out_len as usize), 0); }
    return 0;
}

fn page_align(base: usize) -> usize {
    return (base + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}
fn print_load_status(s: u32) -> void {
    if s == 1 { sbi_puts("APP-LOAD-FAIL: BadElf\n"); }
    else { if s == 2 { sbi_puts("APP-LOAD-FAIL: TooManyPages\n"); }
    else { if s == 3 { sbi_puts("APP-LOAD-FAIL: NoFrame\n"); }
    else { if s == 4 { sbi_puts("APP-LOAD-FAIL: BadSegment\n"); }
    else { sbi_puts("APP-LOAD-FAIL: unknown\n"); } } } }
}

// Activate the agent's isolated address space. In S-mode satp IS effective immediately; the
// kernel's supervisor gigapage (added by qjs_smode_build) keeps this code + the trap path
// running. sfence.vma flushes stale TLB entries.
fn activate_satp(satp: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw satp, %0\n sfence.vma"
                in("t0") satp: u64,
                clobber("memory")
            }
        }
    }
}

export fn s_entry() -> void {
    sbi_puts("kernel up in S-mode under OpenSBI: loading confined QuickJS agent\n");
    usermode_setup(); // S-mode trap vector (ecall dispatch + SYS_EXIT) + syscall table

    let image_base: usize = (&app_image) as usize;
    let image_len: usize = app_image_len as usize;
    let region: usize = page_align((&g_region[0]) as usize);

    let satp: u64 = qjs_smode_build(image_base, image_len, region, RT_REGION_LEN);
    if satp == 0 {
        print_load_status(app_build_status());
        sbi_shutdown();
    }

    // Confinement proof (S-mode): the kernel is mapped (so the trap path survives satp) but is
    // NOT user-accessible — a direct kernel touch from U-mode would fault.
    if qjs_smode_kernel_not_user(satp, RT_KERNEL_VA) == 1 {
        sbi_puts("CONFINED: kernel not user-accessible in agent space\n");
    } else {
        sbi_puts("LEAK: kernel user-accessible in agent space\n");
    }

    sbi_puts("kernel: entering confined QuickJS agent\n");
    let entry: u64 = app_entry();
    activate_satp(satp);
    enter_user(entry as usize, entry as usize);
    sbi_shutdown(); // not reached
}

// OpenSBI enters here in S-mode (a0=hartid, a1=dtb). Set the stack and call s_entry.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
