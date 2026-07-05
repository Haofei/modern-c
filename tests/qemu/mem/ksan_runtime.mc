// Bare-metal M-mode KASAN shadow runtime for the D2.1 access-time UAF/OOB demo — in PURE MC
// (no C). The all-MC replacement for kernel/arch/riscv64/ksan_runtime.c + its shared shadow.h.
//
// KASAN shadow scheme (per-byte 1:1): one shadow byte per managed-pool byte. A shadow byte of
// SHADOW_CLEAN (0) means the byte is addressable; SHADOW_POISON (0xFF) means freed/redzone/
// not-yet-allocated. The MC compiler, under `--checks=ksan`, wraps every raw.load/raw.store
// (and instrumented field/global accesses) with `mc_ksan_check(addr, size)`, which this module
// DEFINES: it maps `addr` to its shadow byte(s) and traps (via the M-mode trap path ->
// "KASAN-DETECTED") if any covered byte is poisoned. The KASAN heap (`heap_new_ksan`) calls
// mc_ksan_poison on free / mc_ksan_unpoison on alloc, so a read of freed memory hits a poisoned
// shadow byte and traps BEFORE the dereference — genuine access-time use-after-free detection.
//
// This runtime is built UN-instrumented (no MC_CHECKS): its own shadow reads/writes must never
// recurse through mc_ksan_check. It DEFINES the sanitizer hooks (mc_ksan_check/poison/unpoison);
// the compiler now yields its auto weak no-op stub to these strong MC definitions. The boot seam
// + console are the shared M-mode template modules; the demo (ksan_demo.mc, compiled WITH
// --checks=ksan) links beside this object and supplies the ksan_* entry points below.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// 1:1 byte-granular shadow over a 64 KiB managed pool.
const POOL_BYTES: usize = 64 * 1024;

const SHADOW_CLEAN: u8 = 0x00;   // addressable
const SHADOW_POISON: u8 = 0xFF;  // freed / redzone / not-yet-allocated

global pool: [65536]u8;     // POOL_BYTES; the managed pool the demo allocates from
global shadow: [65536]u8;   // SHADOW_BYTES == POOL_BYTES (1:1)
global shadow_base: usize;  // mem_base for the shadow mapping
global shadow_end: usize;   // mem_base + min(len, POOL_BYTES)
global shadow_armed: u32;

// MC entry points (defined in ksan_demo.mc, compiled with --checks=ksan).
extern fn ksan_clean(region: usize, len: usize) -> u32;
extern fn ksan_uaf(region: usize, len: usize) -> u32;
extern fn ksan_oob(region: usize, len: usize) -> u32;
extern fn ksan_field_uaf(region: usize, len: usize) -> u32;
extern fn ksan_field_store(region: usize, len: usize) -> u32;
extern fn ksan_arr_load(region: usize, len: usize) -> u32;
extern fn ksan_arr_store(region: usize, len: usize) -> u32;
extern fn ksan_global_address() -> usize;
extern fn ksan_global_load() -> u32;
extern fn ksan_global_store() -> u32;
extern fn ksan_stack_local() -> u32;
extern fn ksan_outside_pool(region: usize, len: usize) -> u32;

// Scenario selector. The harness links each scenario with `--defsym=mc_scenario=N`; reading the
// symbol's ADDRESS (via `la`) yields N — the MC analogue of the C runtime's `#if defined(...)`.
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

// Address of a shadow byte for pool byte `i`, as a raw phys usize.
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

// Arm the shadow for [base, base+len): every shadow byte set to `fill`. KASAN fills CLEAN
// (everything addressable) and poisons as it runs.
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
    var hi: usize = addr + size; // [lo, hi)
    if lo < shadow_base { lo = shadow_base; }
    if hi > shadow_end { hi = shadow_end; }
    if lo >= hi {
        return;
    }
    var i: usize = lo - shadow_base;
    let last: usize = hi - 1 - shadow_base; // inclusive
    while i <= last && i < POOL_BYTES {
        shadow_st(i, val);
        i = i + 1;
    }
}

export fn mc_ksan_poison(addr: usize, size: usize) -> void {
    shadow_set(addr, size, SHADOW_POISON);
}

export fn mc_ksan_unpoison(addr: usize, size: usize) -> void {
    shadow_set(addr, size, SHADOW_CLEAN);
}

// The instrumented-access hook the compiler emits before each raw.load/raw.store. Consult the
// shadow byte(s) covering [addr, addr+size); if any is NOT clean (poisoned), trap.
export fn mc_ksan_check(addr: usize, size: usize) -> void {
    if shadow_armed == 0 || size == 0 {
        return;
    }
    if addr < shadow_base || addr >= shadow_end {
        return; // not shadow-tracked memory
    }
    var hi: usize = addr + size;
    if hi > shadow_end { hi = shadow_end; }
    var i: usize = addr - shadow_base;
    let last: usize = hi - 1 - shadow_base;
    while i <= last && i < POOL_BYTES {
        if shadow_ld(i) != SHADOW_CLEAN {
            unreachable; // poisoned access -> M-mode trap -> KASAN-DETECTED
        }
        i = i + 1;
    }
}

// Arm the shadow for [base, base+len): everything addressable (clean) to start.
fn ksan_arm_shadow(base: usize, len: usize) -> void {
    shadow_arm(base, len, SHADOW_CLEAN);
}

export fn m_main() -> void {
    // Route traps (the mc_ksan_check `unreachable`) to on_trap -> KASAN-DETECTED.
    install_trap_vector();

    put_str("ksan demo booting (M-mode)\n");

    // 1. Clean path: alloc/use-in-bounds/free with the shadow armed -> no trap.
    ksan_arm_shadow(pool_base(), POOL_BYTES);
    let clean: u32 = ksan_clean(pool_base(), POOL_BYTES);
    if clean == 1 {
        put_str("KASAN-OK\n"); // clean in-bounds use, nothing poisoned was accessed
    } else {
        put_str("KASAN-BAD\n");
        halt();
    }

    let sc: u64 = scenario_id();

    if sc == 4 {
        // FIELD: UAF through a STRUCT FIELD (not raw.load): `node.value` of freed memory traps.
        ksan_arm_shadow(pool_base(), POOL_BYTES);
        put_str("field-uaf: reading freed node.value (struct-field load)...\n");
        let _u: u32 = ksan_field_uaf(pool_base(), POOL_BYTES);
        put_str("FIELD-UAF-MISSED\n");
    } else if sc == 5 {
        // FIELD_STORE: pointer struct-field STORE to freed memory. KASAN should trap
        // before the write; if it returns, the store path is uninstrumented.
        ksan_arm_shadow(pool_base(), POOL_BYTES);
        put_str("field-store: writing freed node.value (struct-field store)...\n");
        let _u: u32 = ksan_field_store(pool_base(), POOL_BYTES);
        put_str("FIELD-STORE-MISSED\n");
    } else if sc == 6 {
        // ARR_LOAD: array-index LOAD of freed memory (through a struct-field array).
        ksan_arm_shadow(pool_base(), POOL_BYTES);
        put_str("arr-load: reading freed a.cells[3] (array-index load)...\n");
        let _u: u32 = ksan_arr_load(pool_base(), POOL_BYTES);
        put_str("ARR-LOAD-MISSED\n");
    } else if sc == 7 {
        // ARR_STORE: array-index STORE to freed memory. KASAN should trap before
        // the write; if it returns, the store path is uninstrumented.
        ksan_arm_shadow(pool_base(), POOL_BYTES);
        put_str("arr-store: writing freed a.cells[3] (array-index store)...\n");
        let _u: u32 = ksan_arr_store(pool_base(), POOL_BYTES);
        put_str("ARR-STORE-MISSED\n");
    } else if sc == 8 {
        // GLOBAL_LOAD: scalar GLOBAL load. Arm+poison the shadow over &ksan_global, then read.
        let g: usize = ksan_global_address();
        ksan_arm_shadow(g, POOL_BYTES);
        mc_ksan_poison(g, 4); // poison the 4 bytes of the global
        put_str("global-load: reading poisoned global (mc_race_load)...\n");
        let _u: u32 = ksan_global_load();
        put_str("GLOBAL-LOAD-MISSED\n");
    } else if sc == 9 {
        // GLOBAL_STORE: scalar GLOBAL store. Arm+poison &ksan_global, then write.
        let g: usize = ksan_global_address();
        ksan_arm_shadow(g, POOL_BYTES);
        mc_ksan_poison(g, 4);
        put_str("global-store: writing poisoned global (mc_race_store)...\n");
        let _u: u32 = ksan_global_store();
        put_str("GLOBAL-STORE-MISSED\n");
    } else if sc == 10 {
        // STACK_LOCAL: stack local access (documented MISS).
        ksan_arm_shadow(pool_base(), POOL_BYTES);
        put_str("stack-local: read/write of an uninstrumented stack local...\n");
        let _u: u32 = ksan_stack_local();
        put_str("STACK-LOCAL-MISSED\n");
    } else if sc == 11 {
        // OUTSIDE_POOL: UAF on memory the shadow does NOT cover (documented fail-open). Arm the
        // shadow over the TOP half of the pool; the heap lives in the bottom half (the arg given).
        ksan_arm_shadow(pool_base() + (POOL_BYTES / 2), POOL_BYTES / 2);
        put_str("outside-pool: UAF read on memory outside the armed shadow...\n");
        let _u: u32 = ksan_outside_pool(pool_base(), POOL_BYTES / 2);
        put_str("OUTSIDE-POOL-MISSED\n");
    } else if sc == 3 {
        // OOB: a read one past the user region (a poisoned redzone byte) traps.
        ksan_arm_shadow(pool_base(), POOL_BYTES);
        put_str("oob: reading one past allocation...\n");
        let _u: u32 = ksan_oob(pool_base(), POOL_BYTES);
        put_str("OOB-MISSED\n");
    } else {
        // Default (sc == 2): use-after-free — a read of freed (poisoned) memory traps.
        ksan_arm_shadow(pool_base(), POOL_BYTES);
        put_str("uaf: reading freed memory...\n");
        let _u: u32 = ksan_uaf(pool_base(), POOL_BYTES);
        put_str("UAF-MISSED\n");
    }
    halt();
}

fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

// M-mode trap reporter: any trap here is the mc_ksan_check `unreachable` -> KASAN-DETECTED.
export fn on_trap() -> void {
    put_str("KASAN-DETECTED\n");
    halt();
}

// Naked M-mode trap vector: jump straight to on_trap (the demo only traps to report; it never
// resumes). 4-byte aligned via its own `.text.mtrap` section (virt.ld pins it).
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
