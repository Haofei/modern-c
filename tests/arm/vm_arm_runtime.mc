// tests/arm/vm_arm_runtime — the AArch64 EL1 `kmain` for the paging proof, in PURE MC.
//
// The MC replacement for kernel/arch/aarch64/vm_runtime.c. There is NO boot.S: QEMU 'virt'
// -kernel loads this flat image at RAM base 0x40000000 and enters at the load address (EL1,
// or EL2 from which we drop). The naked `_start` below (`.text.boot`, leading the image) sets
// SP, drops EL2->EL1 if needed via `eret`, and `bl`s into this MC `kmain`. We:
//
//   1. enable EL0/EL1 FP/SIMD (CPACR_EL1.FPEN) so the LLVM backend's SIMD struct-init/copy
//      does not trap, then print over the PL011 UART (kernel/arch/aarch64/pl011 — pure MC);
//   2. install a VBAR_EL1 exception vector (the naked `arm_vectors` table) whose common
//      trampoline prints a marker + ESR/ELR/FAR and halts, so a paging fault is DIAGNOSED,
//      not a silent loop;
//   3. set MAIR_EL1 + TCR_EL1 (Attr0 Normal WB / Attr1 Device-nGnRE; T0SZ=16 4 KiB granule,
//      inner-shareable WB, TTBR1 disabled, 48-bit PA);
//   4. call the MC `vm_arm_build` (tests/arm/vm_arm_demo) — fresh table, identity low RAM as
//      2 MiB blocks + the UART page Device + a translation-only sentinel VA, with a software
//      walk asserting the translation BEFORE any MMU enable;
//   5. load TTBR0_EL1, dsb/isb, invalidate the TLB, enable the MMU (SCTLR_EL1.M/C/I), isb
//      (the kernel stays mapped via the identity blocks, so the next fetch survives);
//   6. read the sentinel back THROUGH the test VA — reachable only via translation — and
//      compare to the known sentinel.
//
// Print ARM64-VM-OK iff the software walk AND the live readback both match; else ARM64-VM-BAD.
//
// AArch64 asm notes: msr/mrs take a plain GPR, so an MC precise-asm `"%0"` generic-`"r"`
// operand binds it directly (no fixed-register pinning, unlike x86 port I/O). The MMU-enable
// path needs the dsb/isb barriers spelled out in the templates.

import "tests/arm/vm_arm_demo.mc";
import "kernel/arch/aarch64/pl011.mc";

const RT_TEST_VA: usize = 0x10_0000_0000;   // 64 GiB — translation-only (matches vm_arm_demo)
const RT_TEST_VALUE: u32 = 0xCAFE_BABE;
const HEAP_BYTES: usize = 4 * 1024 * 1024;  // page-table backing store: 4 MiB, under low RAM id-map

// System-register bit fields as typed u64 constants. Inline `(1 << n)` in operand position is
// a targetless checked shift over untyped literals, which the C backend cannot lower; naming
// the mask gives it a u64 type so `reg = reg | MASK` lowers cleanly on both backends.
const CPACR_FPEN: u64 = 0x30_0000;          // FPEN = 0b11 at bit 20
const SCTLR_M: u64 = 0x1;                    // bit 0:  MMU enable
const SCTLR_A: u64 = 0x2;                    // bit 1:  alignment check (we CLEAR this — see below)
const SCTLR_C: u64 = 0x4;                    // bit 2:  data cache
const SCTLR_I: u64 = 0x1000;                 // bit 12: instruction cache

// MAIR_EL1: Attr0 = 0xFF (Normal, WB non-transient RW-alloc, inner+outer),
//           Attr1 = 0x04 (Device-nGnRE).
const MAIR_VALUE: u64 = 0xFF | (0x04 << 8);

// TCR_EL1: T0SZ=16 (48-bit VA), TG0=4 KiB (0), IRGN0/ORGN0=WB, SH0=inner-shareable,
// EPD1=1 (no TTBR1 walks), IPS=0b101 (48-bit PA).
const TCR_VALUE: u64 =
    (16 << 0)  |   // T0SZ = 16
    (1  << 8)  |   // IRGN0 = WB
    (1  << 10) |   // ORGN0 = WB
    (3  << 12) |   // SH0 = inner shareable
    (1  << 23) |   // EPD1 = 1 (no TTBR1 walks)
    (5  << 32);    // IPS = 48-bit PA

// --- low-level CPU primitives (the bits that genuinely need asm) ---

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
            asm precise volatile {
                "mrs %0, CurrentEL"
                out("r") v: u64,
                clobber("memory")
            }
        }
    }
    return (v >> 2) & 3;
}

// Enable EL0/EL1 FP/SIMD (CPACR_EL1.FPEN = 0b11) so SIMD-using codegen does not trap.
fn enable_fpsimd() -> void {
    var cpacr: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mrs %0, cpacr_el1"
                out("r") cpacr: u64,
                clobber("memory")
            }
        }
    }
    cpacr = cpacr | CPACR_FPEN;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "msr cpacr_el1, %0\n isb"
                in("r") cpacr: u64,
                clobber("memory")
            }
        }
    }
}

// Install the EL1 exception vector base (VBAR_EL1) and synchronise.
fn install_vbar(base_addr: usize) -> void {
    let base: u64 = base_addr as u64;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "msr vbar_el1, %0\n isb"
                in("r") base: u64,
                clobber("memory")
            }
        }
    }
}

// Program MAIR_EL1 + TCR_EL1, then isb so the new translation regime is in effect.
fn config_mair_tcr(mair: u64, tcr: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "msr mair_el1, %0"
                in("r") mair: u64,
                clobber("memory")
            }
        }
    }
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "msr tcr_el1, %0\n isb"
                in("r") tcr: u64,
                clobber("memory")
            }
        }
    }
}

// Load TTBR0_EL1 with the table root, barrier, invalidate the EL1 TLB.
fn load_ttbr0(ttbr0: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "msr ttbr0_el1, %0\n dsb ish\n isb\n tlbi vmalle1\n dsb ish\n isb"
                in("r") ttbr0: u64,
                clobber("memory")
            }
        }
    }
}

// Set SCTLR_EL1.M (MMU) | .C (data cache) | .I (instruction cache), isb. After this the
// next fetch is translated; the kernel stays mapped via the identity blocks.
fn enable_mmu() -> void {
    var sctlr: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mrs %0, sctlr_el1"
                out("r") sctlr: u64,
                clobber("memory")
            }
        }
    }
    // Enable MMU + caches, and explicitly CLEAR SCTLR_EL1.A: do not inherit the firmware/entry
    // alignment-check state. With A=1 every unaligned Normal-memory access (which MC codegen may
    // emit) faults with a data abort (ESR DFSC=0x21) once the MMU is on — and whether A is set at
    // EL1 entry varies by qemu version/boot path, making the fault environment-specific. Clearing it
    // makes the translated regime deterministic (unaligned Normal access allowed, as the code assumes).
    sctlr = (sctlr | SCTLR_M | SCTLR_C | SCTLR_I) & ~SCTLR_A;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "msr sctlr_el1, %0\n isb"
                in("r") sctlr: u64,
                clobber("memory")
            }
        }
    }
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

// --- exception handling (the naked vector table + an MC reporter) ---

// Called by the vector trampoline with the entry `kind` in x0. Print a marker + the syndrome
// registers and halt, so a paging fault is diagnosed rather than silently looping.
export fn arm_on_exception(kind: u64) -> void {
    put_str("\nARM64-VM-BAD exception kind=");
    put_hex64(kind);
    put_str(" ESR=");
    put_hex64(read_esr());
    put_str(" ELR=");
    put_hex64(read_elr());
    put_str(" FAR=");
    put_hex64(read_far());
    console_putc(10);
    halt_forever();
}

// Common trampoline: each vector entry stashes its kind in x0 and branches here; we call the
// MC reporter (which never returns) and wfe-loop as a backstop.
#[naked]
#[noinline]
export fn arm_exc_common() -> void {
    asm opaque volatile {
        "bl arm_on_exception\n 1: wfe\n b 1b"
    }
}

// The EL1 exception vector table: 16 entries x 0x80 bytes, each stashing a kind id and
// branching to the common trampoline. VBAR_EL1 requires 2 KiB alignment; MC has no function-
// alignment attribute, so the table lives in its own `.text.vectors` section that the linker
// script pins to a 2 KiB boundary (and which leads .text after `.text.boot`).
#[naked]
#[section(".text.vectors")]
export fn arm_vectors() -> void {
    asm opaque volatile {
        ".balign 0x80\n mov x0, #0\n b arm_exc_common\n.balign 0x80\n mov x0, #1\n b arm_exc_common\n.balign 0x80\n mov x0, #2\n b arm_exc_common\n.balign 0x80\n mov x0, #3\n b arm_exc_common\n.balign 0x80\n mov x0, #4\n b arm_exc_common\n.balign 0x80\n mov x0, #5\n b arm_exc_common\n.balign 0x80\n mov x0, #6\n b arm_exc_common\n.balign 0x80\n mov x0, #7\n b arm_exc_common\n.balign 0x80\n mov x0, #8\n b arm_exc_common\n.balign 0x80\n mov x0, #9\n b arm_exc_common\n.balign 0x80\n mov x0, #10\n b arm_exc_common\n.balign 0x80\n mov x0, #11\n b arm_exc_common\n.balign 0x80\n mov x0, #12\n b arm_exc_common\n.balign 0x80\n mov x0, #13\n b arm_exc_common\n.balign 0x80\n mov x0, #14\n b arm_exc_common\n.balign 0x80\n mov x0, #15\n b arm_exc_common"
    }
}

// Page-table backing store: 4 MiB, 4 KiB-aligned, well within the identity-mapped low RAM.
global heap_region: [HEAP_BYTES]u8;

export fn kmain() -> void {
    enable_fpsimd();
    put_str("aarch64 VM demo boot\n");

    let el: u64 = read_currentel();
    put_str("vm: CurrentEL=");
    put_hex64(el);
    console_putc(10);

    let vbar: usize = (&arm_vectors) as usize;
    install_vbar(vbar);
    put_str("vm: VBAR_EL1 installed\n");

    config_mair_tcr(MAIR_VALUE, TCR_VALUE);
    put_str("vm: MAIR/TCR configured\n");

    var ttbr0: u64 = 0;
    var test_phys: u64 = 0;
    let region: usize = (&heap_region[0]) as usize;
    let sw_ok: u32 = vm_arm_build(region, HEAP_BYTES, &ttbr0, &test_phys);
    put_str("vm: table built, ttbr0=");
    put_hex64(ttbr0);
    put_str(" test_phys=");
    put_hex64(test_phys);
    put_str(" sw_ok=");
    put_hex(sw_ok);
    console_putc(10);

    if sw_ok != 1 {
        put_str("ARM64-VM-BAD (software walk)\n");
        halt_forever();
    }

    load_ttbr0(ttbr0);
    enable_mmu();
    put_str("vm: MMU enabled (SCTLR_EL1.M=1)\n");

    // Read the sentinel back THROUGH the test VA — reachable only via translation.
    var got: u32 = 0;
    unsafe { got = raw.load<u32>(phys(RT_TEST_VA)); }
    put_str("vm: readback through TEST_VA ");
    put_hex(got);
    console_putc(10);

    if got == RT_TEST_VALUE {
        put_str("ARM64-VM-OK\n");
    } else {
        put_str("ARM64-VM-BAD (readback)\n");
    }
    halt_forever();
}

// QEMU 'virt' -kernel enters the flat image at its load address (0x40000000). `#[section]`
// pins `_start` to `.text.boot` (aarch64-vm.ld: leads .text, ENTRY(_start)). Set SP from the
// linker `_stack_top`; if we boot at EL2 drop to EL1 via `eret` (HCR_EL2.RW=1, SPSR EL1h with
// interrupts masked); then `bl kmain`. This whole boot seam is now MC — there is no boot.S.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "ldr x1, =_stack_top\n mov sp, x1\n mrs x0, CurrentEL\n lsr x0, x0, #2\n and x0, x0, #3\n cmp x0, #2\n b.ne 2f\n mov x0, #(1 << 31)\n msr hcr_el2, x0\n mov x0, #0x3c5\n msr spsr_el2, x0\n adr x0, 1f\n msr elr_el2, x0\n isb\n eret\n1:\n ldr x1, =_stack_top\n mov sp, x1\n2:\n bl kmain\n3: wfe\n b 3b"
    }
}
