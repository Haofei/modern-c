// tests/arm/user_arm_runtime — the AArch64 EL1 `usermain` for the M8 "EL0 user hello", PURE MC.
//
// The MC replacement for kernel/arch/aarch64/user_runtime.c. There is NO boot.S: QEMU 'virt'
// -kernel loads this flat image at RAM base 0x40000000 and enters at the load address (EL1, or
// EL2 from which the naked `_start` below drops). Mirroring tests/arm/vm_arm_runtime.mc, this
// whole boot/trap/EL0-drop seam is MC. We:
//
//   1. enable EL0/EL1 FP/SIMD (CPACR_EL1.FPEN) so the LLVM backend's SIMD struct-init/copy does
//      not trap, then print over the PL011 UART (kernel/arch/aarch64/pl011 — pure MC);
//   2. install a full EL1 exception vector table at a 2 KiB-aligned VBAR_EL1 (the naked
//      `arm_user_vectors` table in `.text.vectors`); the "Lower EL using AArch64, synchronous"
//      entry (offset 0x400 — where an EL0 `svc`/abort lands) saves the EL0 GP regs + ELR_EL1 +
//      SPSR_EL1 into a frame on SP_EL1 and calls the MC dispatcher; the rest report-and-halt;
//   3. set MAIR_EL1 + TCR_EL1 (Attr0 Normal WB / Attr1 Device-nGnRE; T0SZ=16 4 KiB granule);
//   4. hand-assemble a tiny EL0 program (raw AArch64 words) into a physical landing frame:
//      SYS_WRITE(valid "HELLO-FROM-EL0\n"), SYS_WRITE(bad 0xDEAD0000), and — iff the bad call
//      returned x0<0 — SYS_WRITE("EFAULT-OK\n"), then SYS_EXIT;
//   5. build a confined EL0 address space via the MC fixture user_arm_demo.mc (kernel 2 MiB
//      blocks EL1-only + UART Device + user code/stack EL0 pages), load TTBR0_EL1, enable MMU;
//   6. `eret` into EL0 (enter_user: SP_EL0=user_sp, ELR_EL1=entry, SPSR_EL1=EL0t).
//
// The synchronous-exception dispatcher decodes ESR_EL1.EC: EC=0x15 (SVC from AArch64) -> read
// x8/x0/x1 from the saved frame, route SYS_WRITE through sys_write_copyin (software-walks the
// user pointer, -EFAULT for the bad one WITHOUT dereferencing it) and SYS_EXIT -> print
// USER-EXIT and halt; the return value is written back into the saved x0. An UNEXPECTED abort
// prints a marker (ESR/FAR) + halts, so a bug is diagnosed rather than silently looping.
//
// Syscall convention: x8 = syscall number, x0/x1 = args; x0 = return value (Linux-AArch64 style).

import "tests/arm/user_arm_demo.mc";
import "kernel/arch/aarch64/pl011.mc";

const SYS_WRITE: u64 = 1;
const SYS_EXIT: u64 = 2;

// CPACR_EL1.FPEN = 0b11 at bit 20 — enable EL0/EL1 FP/SIMD so SIMD-using codegen does not trap.
const CPACR_FPEN: u64 = 0x30_0000;

// MAIR_EL1: Attr0 = 0xFF (Normal WB), Attr1 = 0x04 (Device-nGnRE).
const MAIR_VALUE: u64 = 0xFF | (0x04 << 8);

// TCR_EL1: T0SZ=16 (48-bit VA), TG0=4 KiB, IRGN0/ORGN0=WB, SH0=inner-shareable, EPD1=1, IPS=48-bit.
const TCR_VALUE: u64 =
    (16 << 0)  |   // T0SZ = 16
    (1  << 8)  |   // IRGN0 = WB
    (1  << 10) |   // ORGN0 = WB
    (3  << 12) |   // SH0 = inner shareable
    (1  << 23) |   // EPD1 = 1 (no TTBR1 walks)
    (5  << 32);    // IPS = 48-bit PA

// SCTLR_EL1: M (MMU) | C (data cache) | I (instruction cache). SCTLR_A (alignment check) is CLEARED.
const SCTLR_M: u64 = 0x1;
const SCTLR_A: u64 = 0x2;
const SCTLR_C: u64 = 0x4;
const SCTLR_I: u64 = 0x1000;

// SPSR_EL1 for an EL0t return: D,A,I,F masked (0x3c0) + mode EL0t (M[3:0]=0).
const SPSR_EL0T: u64 = 0x3c0;

// The trap frame the synchronous-lower vector pushes (growing down): x0..x30 (31 dwords), then
// ELR_EL1, SPSR_EL1 — 33 dwords = 264 bytes. The dispatcher gets the frame base (=&x0). Field
// reads/writes go through raw.load/raw.store at byte offsets (no struct over a raw SP pointer).
const TF_X0: usize = 0;     // x0 at +0
const TF_X1: usize = 8;     // x1 at +8
const TF_X8: usize = 64;    // x8 at +64 (8*8)

// EFAULT (Linux-AArch64), returned negated so the EL0 app sees x0 < 0.
const UARM_EFAULT_RT: i64 = 14;

// --- low-level CPU primitives ---

#[noinline]
fn halt_forever() -> void {
    while true {
        #[unsafe_contract(precise_asm)] {
            unsafe {
                asm precise volatile {
                    "wfe"
                    clobber("memory")
                }
            }
        }
    }
}

fn read_currentel() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "mrs %0, CurrentEL" out("r") v: u64, clobber("memory") }
        }
    }
    return (v >> 2) & 3;
}

fn read_esr() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "mrs %0, esr_el1" out("r") v: u64, clobber("memory") }
        }
    }
    return v;
}

fn read_elr() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "mrs %0, elr_el1" out("r") v: u64, clobber("memory") }
        }
    }
    return v;
}

fn read_far() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "mrs %0, far_el1" out("r") v: u64, clobber("memory") }
        }
    }
    return v;
}

fn read_spsr() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "mrs %0, spsr_el1" out("r") v: u64, clobber("memory") }
        }
    }
    return v;
}

// Enable EL0/EL1 FP/SIMD (CPACR_EL1.FPEN = 0b11).
fn enable_fpsimd() -> void {
    var cpacr: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "mrs %0, cpacr_el1" out("r") cpacr: u64, clobber("memory") }
        }
    }
    cpacr = cpacr | CPACR_FPEN;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "msr cpacr_el1, %0\n isb" in("r") cpacr: u64, clobber("memory") }
        }
    }
}

// Install the EL1 exception vector base (VBAR_EL1) and synchronise.
fn install_vbar(base_addr: usize) -> void {
    let base: u64 = base_addr as u64;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "msr vbar_el1, %0\n isb" in("r") base: u64, clobber("memory") }
        }
    }
}

// Program MAIR_EL1 + TCR_EL1, then isb so the new translation regime is in effect.
fn config_mair_tcr(mair: u64, tcr: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "msr mair_el1, %0" in("r") mair: u64, clobber("memory") }
        }
    }
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "msr tcr_el1, %0\n isb" in("r") tcr: u64, clobber("memory") }
        }
    }
}

// Load TTBR0_EL1 with the table root, barrier, invalidate the EL1 TLB, then set the MMU bits.
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
        unsafe {
            asm precise volatile { "mrs %0, sctlr_el1" out("r") sctlr: u64, clobber("memory") }
        }
    }
    // Enable MMU + caches, and explicitly CLEAR SCTLR_EL1.A so we do not inherit the firmware/entry
    // alignment-check state: with A=1, unaligned Normal-memory accesses fault (ESR DFSC=0x21) once
    // the MMU is on, which is environment-specific (varies by qemu version/boot path). Deterministic.
    sctlr = (sctlr | SCTLR_M | SCTLR_C | SCTLR_I) & ~SCTLR_A;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile { "msr sctlr_el1, %0\n isb" in("r") sctlr: u64, clobber("memory") }
        }
    }
}

// Print n bytes from the kernel copy-in buffer over the PL011 UART.
fn put_n(base: usize, n: u64) -> void {
    var i: u64 = 0;
    while i < n {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + (i as usize))); }
        console_putc(b);
        i = i + 1;
    }
}

// --- exception handling ---

// Report-and-halt path for any UNEXPECTED exception (x0 carries the vector "kind").
export fn arm_user_unexpected(kind: u64) -> void {
    put_str("\nARM64-USER-BAD exception kind=");
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

// Bounded copy-in landing buffer.
const KBUF_LEN: usize = 256;
global g_kbuf: [KBUF_LEN]u8;

// The synchronous lower-EL (EL0) dispatcher. `frame` is the SP_EL1 trap-frame base (&x0). On an
// SVC (ESR_EL1.EC == 0x15) read x8/x0/x1 from the frame, route SYS_WRITE/SYS_EXIT, and write the
// return value back into the saved x0. ELR_EL1 already points past the svc, so it is untouched.
export fn arm_user_syscall(frame: usize) -> void {
    let esr: u64 = read_esr();
    let ec: u64 = (esr >> 26) & 0x3f;
    if ec != 0x15 {
        // Not an SVC: an unexpected synchronous exception (e.g. a data/instr abort). Diagnose.
        arm_user_unexpected(0x100 | ec);
        return; // unreachable
    }
    var nr: u64 = 0;
    var a0: u64 = 0;
    var a1: u64 = 0;
    unsafe {
        nr = raw.load<u64>(phys(frame + TF_X8));
        a0 = raw.load<u64>(phys(frame + TF_X0));
        a1 = raw.load<u64>(phys(frame + TF_X1));
    }
    if nr == SYS_EXIT {
        put_str("\nUSER-EXIT from EL0\n");
        halt_forever();
    } else if nr == SYS_WRITE {
        var len: u64 = a1;
        if len > (KBUF_LEN as u64) { len = KBUF_LEN as u64; } // clamp to the bounded buffer
        let kdst: usize = (&g_kbuf) as usize;
        let res: i64 = sys_write_copyin(a0 as usize, len as usize, kdst);
        if res >= 0 {
            put_n(kdst, res as u64); // print the validated bytes
        }
        unsafe { raw.store<u64>(phys(frame + TF_X0), res as u64); } // negative -> -EFAULT
    } else {
        put_str("BAD-SYSCALL nr=");
        put_hex64(nr);
        console_putc(10);
        halt_forever();
    }
}

// The synchronous lower-EL entry trampoline: save the full EL0 GP state + ELR/SPSR onto SP_EL1,
// call the MC dispatcher with the frame pointer, restore, and `eret`.
#[naked]
#[noinline]
export fn arm_user_sync_lower() -> void {
    asm opaque volatile {
        "sub sp, sp, #(33*8)\n stp x0, x1, [sp, #(0*8)]\n stp x2, x3, [sp, #(2*8)]\n stp x4, x5, [sp, #(4*8)]\n stp x6, x7, [sp, #(6*8)]\n stp x8, x9, [sp, #(8*8)]\n stp x10, x11, [sp, #(10*8)]\n stp x12, x13, [sp, #(12*8)]\n stp x14, x15, [sp, #(14*8)]\n stp x16, x17, [sp, #(16*8)]\n stp x18, x19, [sp, #(18*8)]\n stp x20, x21, [sp, #(20*8)]\n stp x22, x23, [sp, #(22*8)]\n stp x24, x25, [sp, #(24*8)]\n stp x26, x27, [sp, #(26*8)]\n stp x28, x29, [sp, #(28*8)]\n mrs x1, elr_el1\n stp x30, x1, [sp, #(30*8)]\n mrs x2, spsr_el1\n str x2, [sp, #(32*8)]\n mov x0, sp\n bl arm_user_syscall\n ldr x2, [sp, #(32*8)]\n msr spsr_el1, x2\n ldp x30, x1, [sp, #(30*8)]\n msr elr_el1, x1\n ldp x0, x1, [sp, #(0*8)]\n ldp x2, x3, [sp, #(2*8)]\n ldp x4, x5, [sp, #(4*8)]\n ldp x6, x7, [sp, #(6*8)]\n ldp x8, x9, [sp, #(8*8)]\n ldp x10, x11, [sp, #(10*8)]\n ldp x12, x13, [sp, #(12*8)]\n ldp x14, x15, [sp, #(14*8)]\n ldp x16, x17, [sp, #(16*8)]\n ldp x18, x19, [sp, #(18*8)]\n ldp x20, x21, [sp, #(20*8)]\n ldp x22, x23, [sp, #(22*8)]\n ldp x24, x25, [sp, #(24*8)]\n ldp x26, x27, [sp, #(26*8)]\n ldp x28, x29, [sp, #(28*8)]\n add sp, sp, #(33*8)\n eret"
    }
}

// Report-and-halt trampoline for the non-syscall vectors (x0 carries the kind).
#[naked]
#[noinline]
export fn arm_user_exc_halt() -> void {
    asm opaque volatile {
        "bl arm_user_unexpected\n 1: wfe\n b 1b"
    }
}

// The EL1 exception vector table: 16 entries x 0x80 bytes. Only the "Lower EL AArch64 sync" entry
// (group 3, offset 0x400) takes the real syscall path; the rest stamp a kind id and halt. VBAR_EL1
// requires 2 KiB alignment; MC has no function-align attribute, so the table lives in its own
// `.text.vectors` section (kept by the linker script; here .text.boot leads and .text.vectors
// follows, naturally 2 KiB-aligned by the .balign in the boot stub being short — the .ld keeps it).
#[naked]
#[section(".text.vectors")]
export fn arm_user_vectors() -> void {
    asm opaque volatile {
        ".balign 0x80\n mov x0, #0\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #1\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #2\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #3\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #4\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #5\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #6\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #7\n b arm_user_exc_halt\n.balign 0x80\n b arm_user_sync_lower\n.balign 0x80\n mov x0, #9\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #10\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #11\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #12\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #13\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #14\n b arm_user_exc_halt\n.balign 0x80\n mov x0, #15\n b arm_user_exc_halt"
    }
}

// --- EL0 entry: SP_EL0=user_sp, ELR_EL1=entry, SPSR_EL1=EL0t, eret ---
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

// --- the EL0 program (hand-assembled AArch64) ---
// Layout: a block of instructions (32-bit words) followed by two strings, all in ONE EL0-mapped
// page so the strings are valid EL0 VAs the program passes to SYS_WRITE. The program's VA base is
// UARM_CODE_VA_RT (0x10000000, matching user_arm_demo.mc); string VAs are base + their byte offset.
const UARM_CODE_VA_RT: u64 = 0x1000_0000;
const HELLO_LEN: u64 = 15;   // "HELLO-FROM-EL0\n"
const EFOK_LEN: u64 = 10;    // "EFAULT-OK\n"
const BAD_PTR: u64 = 0xDEAD_0000;  // unmapped in the EL0 space -> software walk -> -EFAULT
const ENC_SVC0: u32 = 0xD400_0001; // svc #0
const BITS_PER_HW: u64 = 16;       // 16-bit halfword stride for movz/movk immediates
const TBZ_BASE: u32 = 0x3600_0000; // tbz Xt, #bit, off
const TBZ_B5: u32 = 0x8000_0000;   // bit31 = bit[5] of the test bit (1 for bit 63)
const TBZ_B40: u32 = 0x00F8_0000;  // bits[23:19] = low 5 bits of the test bit (31 for bit 63)

const MAX_WORDS: usize = 64;
const IMAGE_CAP: usize = MAX_WORDS * 4 + 32;

global g_user_words: [MAX_WORDS]u32;
global g_user_image: [IMAGE_CAP]u8;
global g_image_len: usize;

// movz xd, #imm16, lsl #(hw*16) — base 0xD2800000.
fn enc_movz(rd: u32, imm: u32, hw: u32) -> u32 {
    return 0xD280_0000 | (hw << 21) | ((imm & 0xFFFF) << 5) | (rd & 31);
}
// movk xd, #imm16, lsl #(hw*16) — base 0xF2800000.
fn enc_movk(rd: u32, imm: u32, hw: u32) -> u32 {
    return 0xF280_0000 | (hw << 21) | ((imm & 0xFFFF) << 5) | (rd & 31);
}

// Emit a full 64-bit immediate into xd via movz (hw0) + movk for any non-zero higher halfword.
// Returns the new word index. Word-count is value-dependent (callers use stable-shape values).
fn emit_mov_imm64(p_in: usize, rd: u32, imm: u64) -> usize {
    var p: usize = p_in;
    g_user_words[p] = enc_movz(rd, (imm & 0xFFFF) as u32, 0);
    p = p + 1;
    var hw: u32 = 1;
    while hw < 4 {
        let shift: u64 = (hw as u64) * BITS_PER_HW;
        let part: u32 = ((imm >> shift) & 0xFFFF) as u32;
        if part != 0 {
            g_user_words[p] = enc_movk(rd, part, hw);
            p = p + 1;
        }
        hw = hw + 1;
    }
    return p;
}

// Build the EL0 program. String VAs depend on the code byte length, so assemble in two passes:
// pass 0 lays out instructions to learn code_bytes, pass 1 re-emits with the now-known string VAs.
fn build_user_program() -> void {
    var code_bytes: u64 = 0;
    var pass: i32 = 0;
    while pass < 2 {
        var p: usize = 0;
        let hello_va: u64 = UARM_CODE_VA_RT + code_bytes;
        let efok_va: u64 = UARM_CODE_VA_RT + code_bytes + HELLO_LEN;

        // 1) SYS_WRITE(HELLO): x8=1, x0=&HELLO, x1=len ; svc #0
        p = emit_mov_imm64(p, 8, SYS_WRITE);
        p = emit_mov_imm64(p, 0, hello_va);
        p = emit_mov_imm64(p, 1, HELLO_LEN);
        g_user_words[p] = ENC_SVC0;
        p = p + 1;
        // 2) SYS_WRITE(BAD_PTR) -> x0<0: x8=1, x0=bad, x1=len ; svc #0
        p = emit_mov_imm64(p, 8, SYS_WRITE);
        p = emit_mov_imm64(p, 0, BAD_PTR);
        p = emit_mov_imm64(p, 1, HELLO_LEN);
        g_user_words[p] = ENC_SVC0;
        p = p + 1;
        // 3) tbz x0, #63, skip — skip the EFOK write iff x0 >= 0 (sign bit clear). Patched below.
        let tbz_pos: usize = p;
        g_user_words[p] = 0;
        p = p + 1;
        // 4) SYS_WRITE(EFOK): x8=1, x0=&EFOK, x1=len ; svc #0
        p = emit_mov_imm64(p, 8, SYS_WRITE);
        p = emit_mov_imm64(p, 0, efok_va);
        p = emit_mov_imm64(p, 1, EFOK_LEN);
        g_user_words[p] = ENC_SVC0;
        p = p + 1;
        let skip_target: usize = p; // tbz branches here when x0 >= 0
        // tbz x0, #63: base 0x36000000, b5=bit31 (test bit 63), b40=31, imm14=offset words, Rt=0.
        let off_words: u32 = (skip_target - tbz_pos) as u32;
        let imm14: u32 = (off_words & 0x3fff) << 5;
        let tbz: u32 = TBZ_BASE | TBZ_B5 | TBZ_B40 | imm14;
        g_user_words[tbz_pos] = tbz;
        // 5) SYS_EXIT: x8=2 ; svc #0
        p = emit_mov_imm64(p, 8, SYS_EXIT);
        g_user_words[p] = ENC_SVC0;
        p = p + 1;

        code_bytes = (p as u64) * 4;

        if pass == 1 {
            // Serialize words (little-endian) then append the strings.
            var i: usize = 0;
            while i < p {
                let w: u32 = g_user_words[i];
                g_user_image[i * 4 + 0] = (w & 0xFF) as u8;
                g_user_image[i * 4 + 1] = ((w >> 8) & 0xFF) as u8;
                g_user_image[i * 4 + 2] = ((w >> 16) & 0xFF) as u8;
                g_user_image[i * 4 + 3] = ((w >> 24) & 0xFF) as u8;
                i = i + 1;
            }
            let cb: usize = code_bytes as usize;
            write_hello(cb);
            write_efok(cb + (HELLO_LEN as usize));
            g_image_len = cb + (HELLO_LEN as usize) + (EFOK_LEN as usize);
        }
        pass = pass + 1;
    }
}

// "HELLO-FROM-EL0\n" written byte-by-byte into the image at offset `at`.
fn write_hello(at: usize) -> void {
    g_user_image[at + 0] = 72;   // H
    g_user_image[at + 1] = 69;   // E
    g_user_image[at + 2] = 76;   // L
    g_user_image[at + 3] = 76;   // L
    g_user_image[at + 4] = 79;   // O
    g_user_image[at + 5] = 45;   // -
    g_user_image[at + 6] = 70;   // F
    g_user_image[at + 7] = 82;   // R
    g_user_image[at + 8] = 79;   // O
    g_user_image[at + 9] = 77;   // M
    g_user_image[at + 10] = 45;  // -
    g_user_image[at + 11] = 69;  // E
    g_user_image[at + 12] = 76;  // L
    g_user_image[at + 13] = 48;  // 0
    g_user_image[at + 14] = 10;  // \n
}

// "EFAULT-OK\n" written byte-by-byte into the image at offset `at`.
fn write_efok(at: usize) -> void {
    g_user_image[at + 0] = 69;   // E
    g_user_image[at + 1] = 70;   // F
    g_user_image[at + 2] = 65;   // A
    g_user_image[at + 3] = 85;   // U
    g_user_image[at + 4] = 76;   // L
    g_user_image[at + 5] = 84;   // T
    g_user_image[at + 6] = 45;   // -
    g_user_image[at + 7] = 79;   // O
    g_user_image[at + 8] = 75;   // K
    g_user_image[at + 9] = 10;   // \n
}

// --- backing store (all within the identity-mapped low RAM) ---
// MC has no global-alignment attribute, so each region is OVER-ALLOCATED by one page and the
// usable base is rounded up to a 4 KiB boundary at runtime (page_table_map rejects a misaligned
// code/stack frame; the page-table heap must be page-aligned too).
const RT_PAGE: usize = 4096;
const RT_HEAP_BYTES: usize = 4 * 1024 * 1024;
const RT_USER_PAGE: usize = 4096;     // EL0 code/strings landing frame
const RT_USER_STACK: usize = 8192;    // EL0 stack frames

// Over-allocate by one page so the usable, page-aligned base + its length still fit.
global g_heap_region: [RT_HEAP_BYTES + RT_PAGE]u8;
global g_user_page: [RT_USER_PAGE + RT_PAGE]u8;
global g_user_stack: [RT_USER_STACK + RT_PAGE]u8;

// Round a raw region base up to the next 4 KiB boundary.
fn page_align(a: usize) -> usize {
    return (a + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}

export fn usermain() -> void {
    enable_fpsimd();
    put_str("aarch64 EL0 USER demo boot\n");

    let el: u64 = read_currentel();
    put_str("user: CurrentEL=");
    put_hex64(el);
    console_putc(10);

    let vbar: usize = (&arm_user_vectors) as usize;
    install_vbar(vbar);
    put_str("user: VBAR_EL1 installed (EL0 sync -> syscall dispatch)\n");

    config_mair_tcr(MAIR_VALUE, TCR_VALUE);
    put_str("user: MAIR/TCR configured\n");

    // Assemble the EL0 program into the physical landing frame (page-aligned).
    build_user_program();
    let page_base: usize = page_align((&g_user_page[0]) as usize);
    var k: usize = 0;
    while k < g_image_len {
        let b: u8 = g_user_image[k];
        unsafe { raw.store<u8>(phys(page_base + k), b); }
        k = k + 1;
    }
    put_str("user: EL0 program assembled, bytes=");
    put_hex64(g_image_len as u64);
    console_putc(10);

    // Build the confined EL0 address space and get TTBR0.
    var ttbr0: u64 = 0;
    let region: usize = page_align((&g_heap_region[0]) as usize);
    let user_page: usize = page_base;
    let user_stack: usize = page_align((&g_user_stack[0]) as usize);
    let _r: u32 = user_arm_build(region, RT_HEAP_BYTES,
                                 user_page, RT_USER_PAGE,
                                 user_stack, RT_USER_STACK, &ttbr0);
    put_str("user: address space built, ttbr0=");
    put_hex64(ttbr0);
    console_putc(10);

    if user_arm_kernel_not_user(0x4000_0000) == 1 {
        put_str("CONFINED: kernel mapped EL1-only (no EL0 access) in user space\n");
    } else {
        put_str("LEAK: kernel EL0-accessible in user space\n");
    }
    if user_arm_code_is_user() == 1 {
        put_str("CONFINED: user code page is EL0-accessible\n");
    } else {
        put_str("LEAK: user code not EL0-accessible\n");
    }

    enable_mmu(ttbr0);
    put_str("user: MMU enabled (TTBR0 active); entering EL0\n");

    enter_user(user_arm_code_va() as usize, user_arm_stack_top_va() as usize);
    // enter_user does not return (the program SYS_EXITs from EL0).
}

// QEMU 'virt' -kernel enters the flat image at its load address (0x40000000). `#[section]` pins
// `_start` to `.text.boot` (aarch64-user.ld: leads .text, ENTRY(_start)). Set SP from the linker
// `_stack_top`; if we boot at EL2 drop to EL1 via `eret`; then `bl usermain`. No boot.S.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "ldr x1, =_stack_top\n mov sp, x1\n mrs x0, CurrentEL\n lsr x0, x0, #2\n and x0, x0, #3\n cmp x0, #2\n b.ne 2f\n mov x0, #(1 << 31)\n msr hcr_el2, x0\n mov x0, #0x3c5\n msr spsr_el2, x0\n adr x0, 1f\n msr elr_el2, x0\n isb\n eret\n1:\n ldr x1, =_stack_top\n mov sp, x1\n2:\n bl usermain\n3: wfe\n b 3b"
    }
}
