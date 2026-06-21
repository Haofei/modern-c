// Bare-metal riscv64 M-mode runtime for the per-process-address-space scheduler —
// in PURE MC (no C). The all-MC replacement for kernel/arch/riscv64/sched_vm_runtime.c.
//
// M-mode builds the process table + per-process page tables (the SAME existing MC
// `sched_vm_setup`, linked beside this object as the demo `thread.o`), drops M->S with
// every trap delegated and a full-memory PMP window open (the shared `drop_to_smode`),
// activates the kernel map, and runs the scheduler — whose vm-aware context switch
// (mc_switch_context_vm) loads each process's satp so each worker, reading the same VA,
// sees its own frame.
//
// The context-switch primitives (mc_switch_context / mc_switch_context_vm /
// mc_thread_init) are provided HERE rather than reused from the shared M-mode bring-up
// runtime kernel/arch/riscv64/context_runtime.c: that shared runtime's thread
// trampoline enables interrupts with `csrsi mstatus, 8`, which is a MACHINE CSR — legal
// in the M-mode cooperative thread demo it was written for, but an ILLEGAL INSTRUCTION
// (scause 2) when the sched-vm workers run in S-mode. So the workers here start through
// a plain `jr s0` trampoline (no privileged CSR touch), exactly as the original C
// runtime did. The save/restore asm IS the same shared sequence; only the trampoline
// differs.
//
// This unit DEFINES symbols (mc_switch_context*, mc_thread_init) that the linked demo
// object declares `extern` via kernel/arch/riscv64/context.mc, so it must NOT import
// that module (E_DUPLICATE_DECLARATION) — it keeps a LOCAL copy of the Context layout
// and reaches the scheduler/process/paging work (sched_vm_setup / sched_vm_run /
// sched_vm_kernel_satp) through `extern fn`.

import "tests/qemu/mem/mmode_sdrop.mc"; // drop_to_smode + activate_satp

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register
const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;

// Local copy of the typed surface in kernel/arch/riscv64/context.mc: ra, sp, s0..s11.
struct Context {
    ra: u64,
    sp: u64,
    s0: u64,
    s1: u64,
    s2: u64,
    s3: u64,
    s4: u64,
    s5: u64,
    s6: u64,
    s7: u64,
    s8: u64,
    s9: u64,
    s10: u64,
    s11: u64,
}

// Defined in the separate demo object (tests/qemu/proc/sched_vm_demo.mc).
extern fn sched_vm_setup(region_base: usize, region_len: usize) -> void;
extern fn sched_vm_kernel_satp() -> u64;
extern fn sched_vm_run() -> u32;

// 512 KiB backing pool for the kernel heap (page tables + process stacks).
global g_heap_region: [524288]u8;
global g_rt_kernel_satp: u64;

// Save the current callee-saved registers into *old (a0), load *new (a1), return into
// new's saved ra. Naked: no prologue/epilogue touches the frame.
#[naked]
export fn mc_switch_context(old: *mut Context, new: *Context) -> void {
    asm opaque volatile {
        "sd ra,0(a0)\n sd sp,8(a0)\n sd s0,16(a0)\n sd s1,24(a0)\n sd s2,32(a0)\n sd s3,40(a0)\n sd s4,48(a0)\n sd s5,56(a0)\n sd s6,64(a0)\n sd s7,72(a0)\n sd s8,80(a0)\n sd s9,88(a0)\n sd s10,96(a0)\n sd s11,104(a0)\n ld ra,0(a1)\n ld sp,8(a1)\n ld s0,16(a1)\n ld s1,24(a1)\n ld s2,32(a1)\n ld s3,40(a1)\n ld s4,48(a1)\n ld s5,56(a1)\n ld s6,64(a1)\n ld s7,72(a1)\n ld s8,80(a1)\n ld s9,88(a1)\n ld s10,96(a1)\n ld s11,104(a1)\n ret"
    }
}

// As mc_switch_context, but also load new_satp (a2) into satp + sfence.vma between
// saving and restoring — so a context switch can change the address space. `csrw satp`
// is permitted in S-mode (unlike the shared trampoline's `csrsi mstatus`).
#[naked]
export fn mc_switch_context_vm(old: *mut Context, next: *Context, new_satp: u64) -> void {
    asm opaque volatile {
        "sd ra,0(a0)\n sd sp,8(a0)\n sd s0,16(a0)\n sd s1,24(a0)\n sd s2,32(a0)\n sd s3,40(a0)\n sd s4,48(a0)\n sd s5,56(a0)\n sd s6,64(a0)\n sd s7,72(a0)\n sd s8,80(a0)\n sd s9,88(a0)\n sd s10,96(a0)\n sd s11,104(a0)\n csrw satp, a2\n sfence.vma\n ld ra,0(a1)\n ld sp,8(a1)\n ld s0,16(a1)\n ld s1,24(a1)\n ld s2,32(a1)\n ld s3,40(a1)\n ld s4,48(a1)\n ld s5,56(a1)\n ld s6,64(a1)\n ld s7,72(a1)\n ld s8,80(a1)\n ld s9,88(a1)\n ld s10,96(a1)\n ld s11,104(a1)\n ret"
    }
}

// The trampoline a fresh thread starts on: jump straight to the real entry held in s0.
// No privileged CSR access (S-mode safe), unlike the shared M-mode trampoline.
#[naked]
fn trampoline() -> void {
    asm opaque volatile {
        "jr s0"
    }
}

// Prime a fresh context: the first switch into it `ret`s to the trampoline (with the
// entry in s0) on the given stack. Callee-saved slots start zeroed. Written through raw
// byte-offset stores (LLVM rejects `(*ptr).field = x`): ra@0, sp@8, s0@16, s1..s11@24..104.
export fn mc_thread_init(ctx: *mut Context, stack_top: usize, entry: fn() -> void) -> void {
    let base: usize = ctx as usize;
    var off: usize = 0;
    while off < 112 {
        unsafe { raw.store<u64>(phys(base + off), 0); }
        off = off + 8;
    }
    let tramp: u64 = (&trampoline) as usize as u64;
    let ent: u64 = entry as usize as u64;
    unsafe {
        raw.store<u64>(phys(base + 0), tramp);       // ra  = trampoline
        raw.store<u64>(phys(base + 8), stack_top as u64); // sp = stack_top
        raw.store<u64>(phys(base + 16), ent);        // s0  = entry
    }
}

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

// S-mode entry (reached via `mret`): activate the kernel address space, then run the
// scheduler over the per-process address spaces. Never returns.
export fn s_main() -> void {
    activate_satp(g_rt_kernel_satp);
    if sched_vm_run() == 1 {
        uputs("SCHED-VM-OK\n");
    } else {
        uputs("SCHED-VM-BAD\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// M-mode boot: build the process table + page tables (MC), then drop to S-mode.
export fn m_main() -> void {
    uputs("sched-vm booting (M-mode)\n");
    sched_vm_setup((&g_heap_region) as usize, 524288);
    g_rt_kernel_satp = sched_vm_kernel_satp();
    uputs("processes + page tables built, dropping to S-mode\n");
    drop_to_smode((&s_main) as usize);
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode; `.text.start` pins `_start` there.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
