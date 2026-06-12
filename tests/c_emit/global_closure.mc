// Regression: globals whose fields are closures or function pointers — the substrate for a
// driver/provider table (kernel/bus/device.mc, kernel/core/device.mc).
//
// Three lowerings were broken and are fixed here:
//   1. a whole-struct store into a global (`g = .{ … }`) must adopt the global's type so the
//      struct literal becomes a typed compound literal (was UnsupportedCEmission);
//   2. reading a closure field from a global is a plain aggregate read, and a function-pointer
//      field a scalar pointer load (was an undefined mc_race_load_unknown);
//   3. a whole-element store into a global *array* of such structs is likewise plain/pointer,
//      not a (nonexistent) per-type race helper.

struct Env { tag: u32 }

fn run_impl(e: *mut Env, x: u32) -> u32 { return x + e.tag; }
fn probe_impl(x: u32) -> bool { return x == 0; }

struct Slot {
    run: closure(u32) -> u32, // fat { code, env } value
    probe: fn(u32) -> bool,   // scalar function pointer
    active: bool,
}

global g_env: Env;
global g_slot: Slot;
global g_table: [4]Slot;

// (1) whole-struct store with closure + fn-pointer fields into a single global
fn install() -> void {
    g_slot = .{ .run = bind(&g_env, run_impl), .probe = probe_impl, .active = true };
}

// (2) read a closure field from a global and call it (extracted, then direct)
fn invoke(x: u32) -> u32 {
    let f: closure(u32) -> u32 = g_slot.run;
    return f(x);
}
fn invoke_direct(x: u32) -> u32 {
    return g_slot.run(x);
}
// read a function-pointer field from a global and call it
fn check(x: u32) -> bool {
    let p: fn(u32) -> bool = g_slot.probe;
    return p(x);
}

// (3) whole-element store into a global array, then read+call via the &elem pointer pattern
fn install_at(i: usize) -> void {
    g_table[i] = .{ .run = bind(&g_env, run_impl), .probe = probe_impl, .active = true };
}

// Field stores through a global-array element must still use each field's storage mode.
fn set_active_at(i: usize, active: bool) -> void {
    g_table[i].active = active;
}
fn set_run_at(i: usize) -> void {
    g_table[i].run = bind(&g_env, run_impl);
}
fn set_probe_at(i: usize) -> void {
    g_table[i].probe = probe_impl;
}

fn active_at(i: usize) -> bool {
    return g_table[i].active;
}
fn invoke_field_at(i: usize, x: u32) -> u32 {
    let f: closure(u32) -> u32 = g_table[i].run;
    return f(x);
}
fn invoke_field_direct_at(i: usize, x: u32) -> u32 {
    return g_table[i].run(x);
}
fn check_field_at(i: usize, x: u32) -> bool {
    let p: fn(u32) -> bool = g_table[i].probe;
    return p(x);
}

fn invoke_at(i: usize, x: u32) -> u32 {
    let s: *Slot = &g_table[i];
    let f: closure(u32) -> u32 = s.run;
    return f(x);
}
