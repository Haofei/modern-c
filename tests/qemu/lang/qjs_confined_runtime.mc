// Kernel-side runtime that loads the CONFINED QuickJS agent (the qjs_agent U-mode ELF,
// embedded as app_image[]) into an ISOLATED Sv39 space and runs it in U-mode — in PURE MC.
// The all-MC replacement for kernel/arch/riscv64/qjs_confined_runtime.c. Modeled on the
// existing agent_confined_runtime.mc; the difference is the embedded image comes from the
// harness-generated app_image[] blob (read via `extern global`) and the frame pool is sized
// for QuickJS (16 MiB: 8 MiB heap arena + ~1.5 MiB engine + 512 KiB stack + page tables).
//
// `_start`/mc_halt come from context_runtime.c; the U-mode trap path + enter_user from
// usermode_runtime.c; the ELF loader + confinement (app_build/app_entry/...) from the MC
// demo app_run_demo.mc. The kernel is UNMAPPED in the agent's space — the MMU is the
// confinement boundary; the agent reaches the kernel only via ecall.

import "tests/qemu/lib/test_report.mc";
const RT_KERNEL_VA: usize = 0x8000_0000;
const RT_PAGE: usize = 4096;
const RT_REGION_LEN: usize = 16 * 1024 * 1024; // 16 MiB usable

// The embedded agent ELF, emitted by the harness as `const unsigned char app_image[]` +
// `const unsigned int app_image_len`. We only need the base address + the length.
extern global app_image: u8;
extern global app_image_len: u32;

// Shared bring-up: _start + mc_halt (context_runtime.c); trap vector + enter_user
// (usermode_runtime.c); ELF load + isolated-space build + confinement checks (app_run_demo.mc).
extern fn mc_halt() -> void;
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn app_build(image_base: usize, image_len: usize, region_base: usize, region_len: usize) -> u64;
extern fn app_build_status() -> u32;
extern fn app_entry() -> u64;
extern fn app_kernel_unmapped(kernel_va: usize) -> u32;

// Backing store for the agent's page tables + per-page frames. Over-allocated by a page so
// the base rounds up to 4 KiB (MC has no compile-time global-align attr).
global g_region: [16781312]u8; // 16 MiB + 4 KiB

// §0 ingress (SYS_READ) default: no embedded agent source. WEAK so a source-serving test
// (qjs-agent-test) that links a STRONG mc_agent_source with its embedded JS overrides it —
// exactly the weak-default semantics the C runtime had. Referenced by app_run_demo.mc's
// SYS_READ handler, so the symbol must resolve in every gate.
#[weak]
export fn mc_agent_source(out_len: *mut usize) -> usize {
    unsafe { raw.store<u64>(phys(out_len as usize), 0); }
    return 0;
}

fn page_align(base: usize) -> usize {
    return (base + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}
fn print_load_status(s: u32) -> void {
    if s == 1 { uputs("APP-LOAD-FAIL: BadElf\n"); }
    else { if s == 2 { uputs("APP-LOAD-FAIL: TooManyPages\n"); }
    else { if s == 3 { uputs("APP-LOAD-FAIL: NoFrame\n"); }
    else { if s == 4 { uputs("APP-LOAD-FAIL: BadSegment\n"); }
    else { uputs("APP-LOAD-FAIL: unknown\n"); } } } }
}

// Activate the agent's isolated address space. M-mode ignores satp for its own fetches, so
// the kernel keeps running physically up to `mret` (enter_user); satp takes effect for the
// U-mode agent. sfence.vma flushes stale TLB entries. (Identical to agent_confined_runtime.mc.)
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

export fn test_main() -> void {
    uputs("kernel: loading confined QuickJS agent\n");
    usermode_setup(); // trap vector (ecall dispatch + SYS_EXIT) + PMP

    let image_base: usize = (&app_image) as usize;
    let image_len: usize = app_image_len as usize;
    let region: usize = page_align((&g_region[0]) as usize);

    let satp: u64 = app_build(image_base, image_len, region, RT_REGION_LEN);
    if satp == 0 {
        print_load_status(app_build_status());
        mc_halt();
    }

    if app_kernel_unmapped(RT_KERNEL_VA) == 1 {
        uputs("CONFINED: kernel unmapped in agent space\n");
    } else {
        uputs("LEAK: kernel mapped in agent space\n");
    }

    uputs("kernel: entering confined QuickJS agent\n");
    let entry: u64 = app_entry();
    activate_satp(satp);
    enter_user(entry as usize, entry as usize);
    mc_halt(); // not reached
}
