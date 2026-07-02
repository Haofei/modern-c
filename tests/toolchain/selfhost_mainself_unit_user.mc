// selfhost_mainself_unit_user — the behavioral unit for selfhost-mainself-test. It exercises the
// language construct that had to land for mcc2 to compile its OWN CLI driver (selfhost/main.mc):
//
//   module-level `global` declarations (P5.20) — a MUTABLE file-scope variable, distinct from a
//   `const`. main.mc relies on them for its 1 MiB read buffer, the 4 MiB concat buffer, and the
//   import-path queue. This fixture covers all three shapes main.mc uses:
//     1. a SCALAR global WITH an initializer  (`global g_counter: u32 = 7;`  -> `static u32 = 7;`);
//     2. an ARRAY global with NO initializer   (`global g_arr: [4]u32;`      -> `static u32[4];`,
//        zero-initialized like every C file-scope static);
//     3. WRITES to a global — both a whole-variable assignment and an element `[i] =` store (a global
//        is a mutable assignment target), plus the address-of-a-global cast `(&g) as usize`.
//
// A C driver (in the gate) links these and asserts the results AT RUNTIME under `clang -Werror`.

// Scalar global with an initializer -> `static uint32_t g_counter = 7;`.
global g_counter: u32 = 7;

// Array global, no initializer -> `static uint32_t g_arr[4];` (zero-initialized C file-scope static).
global g_arr: [4]u32;

// Read + WRITE a global through a plain-identifier assignment: 7 -> 7 + delta.
export fn bump_counter(delta: u32) -> u32 {
    g_counter = g_counter + delta;
    return g_counter;
}

// Write a global ARRAY element (`[i] =`, a mutable global target) then read it back.
export fn arr_set_get(i: u32, v: u32) -> u32 {
    g_arr[i] = v;
    return g_arr[i];
}

// Address-of a global array, cast to usize (the sanctioned usize<->addr boundary main.mc uses): a
// real object address is non-zero.
export fn arr_addr_nonzero() -> u32 {
    let a: usize = (&g_arr) as usize;
    if a != 0 {
        return 1;
    }
    return 0;
}
