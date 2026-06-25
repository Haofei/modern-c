// S-mode-safe process context primitives for flat OpenSBI device IRQ demos.
//
// The IRQ demos import kernel/core/process.mc only for ProcTable/waitqueue ownership
// and wake bookkeeping, but that module exports the full scheduler surface. Linking this
// object satisfies the context-switch symbols those unused scheduler functions reference.

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

#[naked]
#[align(4)]
export fn mc_switch_context(old: *mut Context, new: *Context) -> void {
    asm opaque volatile {
        "sd ra,0(a0)\n sd sp,8(a0)\n sd s0,16(a0)\n sd s1,24(a0)\n sd s2,32(a0)\n sd s3,40(a0)\n sd s4,48(a0)\n sd s5,56(a0)\n sd s6,64(a0)\n sd s7,72(a0)\n sd s8,80(a0)\n sd s9,88(a0)\n sd s10,96(a0)\n sd s11,104(a0)\n ld ra,0(a1)\n ld sp,8(a1)\n ld s0,16(a1)\n ld s1,24(a1)\n ld s2,32(a1)\n ld s3,40(a1)\n ld s4,48(a1)\n ld s5,56(a1)\n ld s6,64(a1)\n ld s7,72(a1)\n ld s8,80(a1)\n ld s9,88(a1)\n ld s10,96(a1)\n ld s11,104(a1)\n ret"
    }
}

#[naked]
#[align(4)]
export fn mc_switch_context_vm(old: *mut Context, new: *Context, new_satp: u64) -> void {
    asm opaque volatile {
        "sd ra,0(a0)\n sd sp,8(a0)\n sd s0,16(a0)\n sd s1,24(a0)\n sd s2,32(a0)\n sd s3,40(a0)\n sd s4,48(a0)\n sd s5,56(a0)\n sd s6,64(a0)\n sd s7,72(a0)\n sd s8,80(a0)\n sd s9,88(a0)\n sd s10,96(a0)\n sd s11,104(a0)\n csrw satp, a2\n sfence.vma\n ld ra,0(a1)\n ld sp,8(a1)\n ld s0,16(a1)\n ld s1,24(a1)\n ld s2,32(a1)\n ld s3,40(a1)\n ld s4,48(a1)\n ld s5,56(a1)\n ld s6,64(a1)\n ld s7,72(a1)\n ld s8,80(a1)\n ld s9,88(a1)\n ld s10,96(a1)\n ld s11,104(a1)\n ret"
    }
}

#[naked]
#[align(4)]
fn trampoline() -> void {
    asm opaque volatile { "jr s0" }
}

export fn mc_thread_init(ctx: *mut Context, stack_top: usize, entry: fn() -> void) -> void {
    ctx.ra = (&trampoline) as usize as u64;
    ctx.sp = stack_top as u64;
    ctx.s0 = entry as usize as u64;
    ctx.s1 = 0;
    ctx.s2 = 0;
    ctx.s3 = 0;
    ctx.s4 = 0;
    ctx.s5 = 0;
    ctx.s6 = 0;
    ctx.s7 = 0;
    ctx.s8 = 0;
    ctx.s9 = 0;
    ctx.s10 = 0;
    ctx.s11 = 0;
}
