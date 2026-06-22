// Bare-metal riscv64 M-mode test entry + ecall trap wiring for the syscall skeleton
// (tests/qemu/lang/syscall_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/syscall_runtime.c: it installs the naked M-mode trap vector
// that routes `ecall` to the MC dispatcher, then `test_main` issues a few ecalls and
// checks the results.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object): `_start` sets
// the stack and calls `test_main`. This unit declares mc_halt `extern fn`, drives
// the demo's `syscall_setup`/`mc_syscall` exactly as the C did, and prints over the
// bare 16550 UART through mmio_console.
//
// M-mode `ecall` traps to mtvec with mcause = 11 (RT_MCAUSE_M_ECALL). The trap vector
// saves a full integer frame, hands its address to `trap_entry`, restores (a0 now
// holds the syscall result), and `mret`s past the 4-byte ecall.

import "tests/qemu/lib/test_report.mc";
import "kernel/arch/riscv64/csr.mc";

const RT_MCAUSE_M_ECALL: u64 = 11;
const RT_SYS_ADD: u64 = 1;
const RT_SYS_PUTC: u64 = 2;
const RT_SYS_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF; // (u64)-1 returned on failure

// Defined in the shared M-mode bring-up runtime (context_runtime.c): stop the
// machine via the SiFive test finisher.
extern fn mc_halt() -> void;

// The syscall demo (tests/qemu/lang/syscall_demo.mc): registers the dispatch table,
// and routes (number, arg0, arg1, arg2) through it back to a result in a0.
extern fn syscall_setup() -> void;
extern fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64;

// The saved integer frame (matches the trap vector's layout below): ra, t0-t6,
// a0-a7, s0-s11. The syscall ABI lives in a0 (arg0/return), a1 (arg1), a7 (number).
struct Frame {
    ra: u64,
    t0: u64, t1: u64, t2: u64, t3: u64, t4: u64, t5: u64, t6: u64,
    a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64,
    s0: u64, s1: u64, s2: u64, s3: u64, s4: u64, s5: u64, s6: u64, s7: u64,
    s8: u64, s9: u64, s10: u64, s11: u64,
}

// Read mcause (the trap cause CSR).
fn read_mcause() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrr %0, mcause"
                out("r") v: u64
            }
        }
    }
    return v;
}

// Read mepc (the trapped instruction's PC).
fn read_mepc() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrr %0, mepc"
                out("r") v: u64
            }
        }
    }
    return v;
}

// Write mepc (where `mret` resumes).
fn write_mepc(v: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw mepc, %0"
                in("r") v: u64
            }
        }
    }
}

// Dispatcher invoked by the trap vector. On an environment call, route it to the MC
// syscall dispatcher (number in a7, args in a0/a1, result back to a0) and step mepc
// past the 4-byte ecall so mret resumes after it. Anything else fails closed.
export fn trap_entry(f: *mut Frame) -> void {
    if read_mcause() == RT_MCAUSE_M_ECALL {
        f.a0 = mc_syscall(f.a7, f.a0, f.a1, f.a2);
        write_mepc(read_mepc() + 4);
    } else {
        mc_halt();
    }
}

// M-mode trap vector: save the integer frame, pass its address to trap_entry, then
// restore (a0 now holds the syscall result) and mret. 4-byte aligned via its own
// `.text.mtrap` section (virt.ld pins it; mtvec's low 2 bits are the trap MODE).
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n mv a0, sp\n call trap_entry\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n mret"
    }
}

// Issue an M-mode `ecall` with the SBI-style integer ABI: number in a7, args in
// a0/a1, result back from a0. Place the values into the ABI registers in the
// template, ecall, then read a0 back — and clobber a0/a1/a7 so the allocator picks
// caller-saved temporaries for the operands (MC precise-asm operands are generic
// "r", not pinned; see kernel/arch/riscv64/sbi.mc).
fn do_ecall(number: u64, arg0: u64, arg1: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv a7, %1\n mv a0, %2\n mv a1, %3\n ecall\n mv %0, a0"
                out("t0") result: u64,
                in("t1") number: u64,
                in("t2") arg0: u64,
                in("t3") arg1: u64,
                clobber("a0"), clobber("a1"), clobber("a7"),
                clobber("memory")
            }
        }
    }
    return result;
}

export fn test_main() -> void {
    uputs("syscall booting\n");
    write_trap_vector((&trap_vector) as usize);
    syscall_setup();

    let sum: u64 = do_ecall(RT_SYS_ADD, 3, 4);      // -> 7
    let _putc: u64 = do_ecall(RT_SYS_PUTC, 'X' as u64, 0); // prints 'X' via the demo's console
    let bad: u64 = do_ecall(99, 0, 0);           // unregistered -> ENOSYS

    uputs("\nSYS-ADD=");
    uputc((48 + (sum % 10)) as u8); // '0' + sum%10
    uputs(" ENOSYS=");
    if bad == RT_SYS_ERR {
        uputc('Y');
    } else {
        uputc('N');
    }
    uputs("\nSYSCALL-OK\n");
    mc_halt();
}
