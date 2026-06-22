// Bare-metal riscv64 M-mode test entry that loads a REAL confined app ELF into an
// ISOLATED U-mode address space and runs it — in PURE MC (no C). The all-MC
// replacement for kernel/arch/riscv64/app_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c); `usermode_setup`/`enter_user` and the
// shared U-mode trap (ecall dispatch + SYS_EXIT) come from usermode_runtime.c — both
// linked beside this object. This unit drives the SAME existing MC loader/ABI
// (tests/qemu/proc/app_run_demo.mc): it builds the agent's isolated Sv39 space from
// the embedded `app_image[]` via the real elf_loader, proves the kernel is unmapped
// in the agent's space, activates the agent's satp, and drops to U-mode at the app
// entry. SYS_EXIT returns control to the kernel through the shared trap. Diagnostics
// go out the bare 16550 UART directly.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

// Kernel base VA: the kernel image + the agent's frame `region` live from here up;
// app_kernel_unmapped sweeps a handful of representative VAs across that range.
const RT_KERNEL_VA: usize = 0x8000_0000;

// Backing store for the agent's page tables + the per-page frames the loader
// allocates, page-aligned. A `[N]u8` global is .bss-resident (no file cost); the loader
// only needs a 4 KiB-aligned base, which app_build derives from the region pointer.
// Sized to 12 MiB so it can back a confined C app whose freestanding libc (user/libc, shared
// with the QuickJS host) carries an 8 MiB malloc arena in .bss — the loader maps the whole
// PT_LOAD memsz, so the region must exceed the app's largest segment plus its page tables.
const RT_REGION_LEN: usize = 12582912; // 12 MiB

// Write one byte to the bare 16550 UART transmit register.
fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

// Write a NUL-terminated string over the bare UART.
fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uputc(b);
        i = i + 1;
    }
}

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The shared U-mode trap bring-up (usermode_runtime.c): install the trap vector
// (ecall dispatch + SYS_EXIT) + PMP, then drop to U-mode at `entry` with `user_sp`.
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;

// The MC loader/ABI demo (tests/qemu/proc/app_run_demo.mc): builds the agent's
// isolated address space, returns the satp to activate (0 on a malformed image), and
// exposes the typed failure class + entry + a confinement probe.
extern fn app_build(image_base: usize, image_len: usize, region_base: usize, region_len: usize) -> u64;
extern fn app_build_status() -> u32; // typed LoadError class (LS_*) of the last app_build
extern fn app_entry() -> u64;
extern fn app_kernel_unmapped(kernel_va: usize) -> u32;

// The app ELF bytes are embedded by the harness as a generated C data array
// (od of build-app.sh's output); these two accessors expose its base + length to
// MC (MC has no `extern` data-symbol form, only `extern fn`). The accessors are
// trivial getters over harness-generated data, not hand-written runtime logic.
extern fn mc_app_image() -> usize;
extern fn mc_app_image_len() -> usize;

// 1 MiB physical region the kernel carves the agent's page tables + frames from.
global g_region: [12582912]u8;

// Map app_build's typed status (LS_*) to a human marker, so a load failure says WHY
// (not a bare fail).
fn report_load_status(s: u32) -> void {
    if s == 1 {
        uputs("APP-LOAD-FAIL: BadElf\n");
    } else if s == 2 {
        uputs("APP-LOAD-FAIL: TooManyPages\n");
    } else if s == 3 {
        uputs("APP-LOAD-FAIL: NoFrame\n");
    } else if s == 4 {
        uputs("APP-LOAD-FAIL: BadSegment\n");
    } else {
        uputs("APP-LOAD-FAIL: unknown\n");
    }
}

// Activate the agent's isolated address space. M-mode ignores satp for its own
// fetches, so the kernel keeps running physically up to `mret` (enter_user); the
// satp takes effect for the U-mode app. sfence.vma flushes stale TLB entries.
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
    uputs("kernel: loading confined app\n");
    usermode_setup(); // trap vector (ecall dispatch + SYS_EXIT) + PMP

    let image_base: usize = mc_app_image();
    let image_len: usize = mc_app_image_len();
    let satp: u64 = app_build(image_base, image_len, (&g_region) as usize, RT_REGION_LEN);
    if satp == 0 {
        report_load_status(app_build_status());
        mc_halt();
        return;
    }

    if app_kernel_unmapped(RT_KERNEL_VA) == 1 {
        uputs("CONFINED: kernel unmapped in app space\n");
    } else {
        uputs("LEAK: kernel mapped in app space\n");
    }

    uputs("kernel: entering confined app\n");
    let entry: u64 = app_entry();

    // crt0's _start sets the user sp (la sp, __user_stack_top), so the value passed
    // here is overwritten before any stack access — pass the entry VA, which is
    // mapped. Activate the agent's satp, then drop to U-mode at the app entry.
    activate_satp(satp);
    enter_user(entry as usize, entry as usize);
    mc_halt(); // not reached
}
