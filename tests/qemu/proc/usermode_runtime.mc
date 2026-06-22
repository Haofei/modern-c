// Shared M-mode user-mode bring-up — in PURE MC (replaces kernel/arch/riscv64/usermode_runtime.c).
// The M-mode trap vector that routes `ecall` to the MC syscall table, the privilege drop into
// U-mode, the kernel trap stack, and the UART-RX IRQ ring the shell drains. UART/mc_halt/_start
// come from context_runtime.c (extern); the syscall table from the MC syscall demo.

const ECALL_FROM_U: u64 = 8;
const ECALL_FROM_M: u64 = 11;
const SYS_EXIT: u64 = 3;
const MCAUSE_INT_BIT: u64 = 0x8000_0000_0000_0000;

const UART_RBR: usize = 0x10000000;
const UART_LSR: usize = 0x10000005;
const PLIC_CLAIM: usize = 0x0C200004; // hart 0, M-mode context
const UART_IRQ: u32 = 10;
const RX_CAP: u32 = 64;

// Frame layout (Frame struct): ra@0, t0..t6 @8..56, a0@64 a1@72 a2@80 ... a7@120, s0@128 ...
const F_A0: usize = 64;
const F_A1: usize = 72;
const F_A2: usize = 80;
const F_A7: usize = 120;

extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;
extern fn syscall_setup() -> void;
extern fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64;

global rx_buf: [64]u8;
global rx_head: u32 = 0;
global rx_tail: u32 = 0;
global kernel_stack: [8192]u8;

fn uart_rx_push(ch: u8) -> void {
    let next: u32 = (rx_head + 1) % RX_CAP;
    if next != rx_tail { // drop on overflow
        rx_buf[rx_head as usize] = ch;
        rx_head = next;
    }
}

// Pop one received byte, or 0x100 if the ring is empty (called from SYS_GETC).
export fn uart_rx_pop() -> u64 {
    if rx_head == rx_tail { return 0x100; }
    let ch: u8 = rx_buf[rx_tail as usize];
    rx_tail = (rx_tail + 1) % RX_CAP;
    return ch as u64;
}

fn read_mcause() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrr %0, mcause" out("r") v: u64, clobber("memory") } } }
    return v;
}
fn read_mepc() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrr %0, mepc" out("r") v: u64, clobber("memory") } } }
    return v;
}
fn write_mepc(v: u64) -> void {
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrw mepc, %0" in("r") v: u64, clobber("memory") } } }
}

// Dispatcher: an interrupt (high bit set) services the UART-RX IRQ; an ecall from U/M routes
// SYS_EXIT here and everything else through the MC syscall table. Any other trap fails closed.
export fn trap_entry(f: usize) -> void {
    let mcause: u64 = read_mcause();
    if (mcause & MCAUSE_INT_BIT) != 0 {
        if (mcause & 0xff) == 11 { // machine external interrupt
            var irq: u32 = 0;
            unsafe { irq = raw.load<u32>(phys(PLIC_CLAIM)); } // claim
            if irq == UART_IRQ {
                while true {
                    var lsr: u8 = 0;
                    unsafe { lsr = raw.load<u8>(phys(UART_LSR)); }
                    if (lsr & 0x01) == 0 { break; }
                    var b: u8 = 0;
                    unsafe { b = raw.load<u8>(phys(UART_RBR)); }
                    uart_rx_push(b); // drain the FIFO
                }
                unsafe { raw.store<u32>(phys(PLIC_CLAIM), irq); } // complete
            }
        }
        return; // an interrupt resumes the interrupted instruction (no mepc bump)
    }
    if mcause == ECALL_FROM_U || mcause == ECALL_FROM_M {
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
            puts_("\nUSER-EXIT from ");
            if mcause == ECALL_FROM_U { putc_(85); } else { putc_(77); } // 'U' / 'M'
            putc_(10);
            mc_halt();
        }
        let res: u64 = mc_syscall(a7, a0, a1, a2);
        unsafe { raw.store<u64>(phys(f + F_A0), res); }
        write_mepc(read_mepc() + 4);
    } else {
        mc_halt();
    }
}

// Trap vector. mscratch holds the kernel stack top; swap to it on entry. The `.balign 4` keeps
// the symbol 4-aligned so mtvec's low-2 MODE bits stay 0 (Direct) — else the kernel boot-loops.
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        ".balign 4\ncsrrw sp, mscratch, sp\n addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n mv a0, sp\n call trap_entry\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n csrrw sp, mscratch, sp\n mret"
    }
}

// A U-mode program makes a syscall through this (number a7, args a0/a1/a2, result a0).
export fn do_ecall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv a7, %1\n mv a0, %2\n mv a1, %3\n mv a2, %4\n ecall\n mv %0, a0"
                out("t0") result: u64,
                in("t1") number: u64,
                in("t2") arg0: u64,
                in("t3") arg1: u64,
                in("t4") arg2: u64,
                clobber("a0"), clobber("a1"), clobber("a2"), clobber("a7"),
                clobber("memory")
            }
        }
    }
    return result;
}

// Drop to U-mode: set mepc + user sp, clear MPP (U), enable the FPU (FS=Initial), mret.
#[naked]
export fn enter_user(entry: usize, user_sp: usize) -> void {
    asm opaque volatile {
        "csrw mepc, a0\n mv sp, a1\n li t0, 0x1800\n csrc mstatus, t0\n li t1, 0x2000\n csrs mstatus, t1\n mret"
    }
}

fn write_csr_pmpaddr0(v: u64) -> void {
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrw pmpaddr0, %0" in("r") v: u64, clobber("memory") } } }
}
fn write_csr_pmpcfg0(v: u64) -> void {
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrw pmpcfg0, %0" in("r") v: u64, clobber("memory") } } }
}
fn write_csr_mtvec(v: usize) -> void {
    let a: u64 = v as u64;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrw mtvec, %0" in("r") a: u64, clobber("memory") } } }
}
fn write_csr_mscratch(v: usize) -> void {
    let a: u64 = v as u64;
    #[unsafe_contract(precise_asm)] { unsafe { asm precise volatile { "csrw mscratch, %0" in("r") a: u64, clobber("memory") } } }
}

// Install PMP (U-mode access to all memory), the trap vector, the kernel trap stack, and the
// syscall table. Call once before enter_user.
export fn usermode_setup() -> void {
    write_csr_pmpaddr0(0xFFFF_FFFF_FFFF_FFFF);
    write_csr_pmpcfg0(0x1F); // NAPOT | R|W|X
    write_csr_mtvec((&trap_vector) as usize);
    write_csr_mscratch((&kernel_stack[0]) as usize + 8192);
    syscall_setup();
}
