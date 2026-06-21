// Bare-metal M-mode KMSAN shadow runtime for the D2.2 uninitialized-heap-use demo — in PURE MC
// (no C). The all-MC replacement for kernel/arch/riscv64/kmsan_runtime.c + its shared shadow.h.
//
// EXTENDS the D2.1 ksan per-byte shadow to track INITIALIZED-ness with three states:
//   SHADOW_CLEAN  (0x00) — addressable AND initialized: a normal valid read.
//   SHADOW_UNINIT (0xAA) — addressable but NEVER WRITTEN since allocation: uninitialized use.
//   SHADOW_POISON (0xFF) — freed / redzone / not-yet-allocated: UAF/OOB.
//
// The MC compiler, under `--checks=msan`, wraps every raw.store with mc_ksan_check THEN
// mc_ksan_store, and every raw.load with mc_ksan_check. mc_ksan_store marks the written bytes
// CLEAN (initialized); mc_ksan_check traps if any covered shadow byte is NOT CLEAN (UNINIT under
// KMSAN, or POISON). So a load of a freshly-allocated, never-written byte hits UNINIT and traps
// BEFORE the dereference. kmsan_alloc is a bump allocator that marks the returned region UNINIT.
//
// Built UN-instrumented (no MC_CHECKS): its own shadow reads/writes must never recurse through
// the hooks. It DEFINES mc_ksan_check / mc_ksan_store (the compiler yields its weak stubs to
// these strong definitions). The demo (kmsan_demo.mc, --checks=msan) links beside this object.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

const POOL_BYTES: usize = 64 * 1024;

const SHADOW_CLEAN: u8 = 0x00;   // addressable + initialized
const SHADOW_UNINIT: u8 = 0xAA;  // addressable but never written
const SHADOW_POISON: u8 = 0xFF;  // freed / redzone / not-yet-allocated

global pool: [65536]u8;
global shadow: [65536]u8;
global shadow_base: usize;
global shadow_end: usize;
global shadow_armed: u32;
global kmsan_bump: usize; // next free byte in the bump allocator

// MC entry points (defined in kmsan_demo.mc, compiled with --checks=msan).
extern fn kmsan_clean() -> u32;
extern fn kmsan_uninit() -> u32;
extern fn kmsan_field_load() -> u32;
extern fn kmsan_global_address() -> usize;
extern fn kmsan_global_load() -> u32;
extern fn kmsan_freed_write(p: usize) -> u32;

fn scenario_id() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "la %0, mc_scenario"
                out("r") v: u64
            }
        }
    }
    return v;
}

fn pool_base() -> usize {
    return (&pool) as usize;
}

fn shadow_byte(i: usize) -> usize {
    return (&shadow) as usize + i;
}

fn shadow_ld(i: usize) -> u8 {
    var b: u8 = 0;
    unsafe { b = raw.load<u8>(phys(shadow_byte(i))); }
    return b;
}

fn shadow_st(i: usize, val: u8) -> void {
    unsafe { raw.store<u8>(phys(shadow_byte(i)), val); }
}

// Arm the shadow for [base, base+len): every shadow byte set to `fill`. KMSAN fills POISON
// (nothing allocated yet) and carves out UNINIT regions in kmsan_alloc; stores mark them CLEAN.
fn shadow_arm(base: usize, len: usize, fill: u8) -> void {
    shadow_base = base;
    var span: usize = len;
    if span > POOL_BYTES { span = POOL_BYTES; }
    shadow_end = base + span;
    var i: usize = 0;
    while i < POOL_BYTES {
        shadow_st(i, fill);
        i = i + 1;
    }
    shadow_armed = 1;
}

// Set the shadow to `val` for exactly the bytes [addr, addr+size) inside the armed pool.
fn shadow_set(addr: usize, size: usize, val: u8) -> void {
    if shadow_armed == 0 || size == 0 {
        return;
    }
    var lo: usize = addr;
    var hi: usize = addr + size;
    if lo < shadow_base { lo = shadow_base; }
    if hi > shadow_end { hi = shadow_end; }
    if lo >= hi {
        return;
    }
    var i: usize = lo - shadow_base;
    let last: usize = hi - 1 - shadow_base;
    while i <= last && i < POOL_BYTES {
        shadow_st(i, val);
        i = i + 1;
    }
}

// KMSAN init-tracking hook the compiler emits AFTER each raw.store: mark exactly the written
// bytes initialized (CLEAN). Byte-exact, so a sub-word store cleans only the bytes it wrote.
export fn mc_ksan_store(addr: usize, size: usize) -> void {
    shadow_set(addr, size, SHADOW_CLEAN);
}

// The instrumented-access hook the compiler emits before each raw.load/raw.store: trap if any
// covered shadow byte is NOT CLEAN (UNINIT under KMSAN, or POISON).
export fn mc_ksan_check(addr: usize, size: usize) -> void {
    if shadow_armed == 0 || size == 0 {
        return;
    }
    if addr < shadow_base || addr >= shadow_end {
        return;
    }
    var hi: usize = addr + size;
    if hi > shadow_end { hi = shadow_end; }
    var i: usize = addr - shadow_base;
    let last: usize = hi - 1 - shadow_base;
    while i <= last && i < POOL_BYTES {
        if shadow_ld(i) != SHADOW_CLEAN {
            unreachable; // uninit/poisoned access -> M-mode trap -> KMSAN-DETECTED
        }
        i = i + 1;
    }
}

// Arm the shadow for [base, base+len): whole pool POISON (not yet allocated). kmsan_alloc carves
// out UNINIT regions; stores mark them CLEAN.
fn kmsan_arm(base: usize, len: usize) -> void {
    shadow_arm(base, len, SHADOW_POISON);
    kmsan_bump = shadow_base;
}

// Bump-allocate `size` bytes (rounded up to 8) and mark the region UNINIT. The MC demo calls
// this; reading the region before a store traps in mc_ksan_check.
export fn kmsan_alloc(size: usize) -> usize {
    let aligned: usize = (size + 7) & ~(7 as usize);
    if kmsan_bump + aligned > shadow_end {
        return 0; // out of pool
    }
    let p: usize = kmsan_bump;
    kmsan_bump = kmsan_bump + aligned;
    shadow_set(p, aligned, SHADOW_UNINIT);
    return p;
}

export fn m_main() -> void {
    install_trap_vector();

    put_str("kmsan demo booting (M-mode)\n");

    let sc: u64 = scenario_id();

    if sc == 2 {
        // UNINIT: allocate, then read a never-written byte -> UNINIT shadow -> trap.
        kmsan_arm(pool_base(), POOL_BYTES);
        put_str("uninit: reading never-written heap memory...\n");
        let _u: u32 = kmsan_uninit();
        put_str("UNINIT-MISSED\n");
    } else if sc == 3 {
        // FIELD_LOAD: pointer struct-field LOAD of UNINIT heap (doc claims DETECT).
        kmsan_arm(pool_base(), POOL_BYTES);
        put_str("field-load: reading UNINIT node.value (struct-field load)...\n");
        let _u: u32 = kmsan_field_load();
        put_str("FIELD-LOAD-MISSED\n");
    } else if sc == 4 {
        // GLOBAL_LOAD: scalar GLOBAL load of poisoned shadow. Arm+poison &kmsan_global -> trap.
        let g: usize = kmsan_global_address();
        shadow_arm(g, POOL_BYTES, SHADOW_POISON); // whole window poisoned
        put_str("global-load: reading poisoned global (mc_race_load)...\n");
        let _u: u32 = kmsan_global_load();
        put_str("GLOBAL-LOAD-MISSED\n");
    } else if sc == 5 {
        // FREED_WRITE: freed-WRITE under msan (doc claims NOT caught — the store path uses
        // mc_ksan_store only, no mc_ksan_check). Poison [p,p+8) then write it -> expected NOT
        // to trap (a documented MISS).
        kmsan_arm(pool_base(), POOL_BYTES);
        let p: usize = pool_base();
        shadow_set(p, 8, SHADOW_POISON); // simulate a freed/poisoned block
        put_str("freed-write: writing poisoned (freed) memory under msan...\n");
        let _u: u32 = kmsan_freed_write(p);
        put_str("FREED-WRITE-MISSED\n");
    } else {
        // Default (sc == 1): clean path — write-before-read of a fresh allocation -> all CLEAN.
        kmsan_arm(pool_base(), POOL_BYTES);
        let clean: u32 = kmsan_clean();
        if clean == 1 {
            put_str("KMSAN-OK\n"); // every read was of an initialized (written) byte
        } else {
            put_str("KMSAN-BAD\n");
        }
    }
    halt();
}

fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

export fn on_trap() -> void {
    put_str("KMSAN-DETECTED\n");
    halt();
}

#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "call on_trap"
    }
}

fn install_trap_vector() -> void {
    unsafe {
        asm opaque volatile {
            "la t0, trap_vector\n csrw mtvec, t0"
            clobber("t0")
        }
    }
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
