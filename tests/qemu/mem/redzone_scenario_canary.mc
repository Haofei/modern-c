// Stack-canary scenario unit for the redzone runtime (PURE MC). Linked beside
// tests/qemu/mem/redzone_runtime.mc, it DEFINES `rt_scenario` to smash a stack guard
// whose check must trap -> DETECTED. If the canary check fails to fire, canary_demo
// returns and we print CANARY-MISSED over the runtime's bare-UART `uputs`. Its own
// import-free linked unit (the demo export + the runtime's `uputs` are declared
// `extern fn` here). The (region, len) params are unused — the canary path needs no
// heap pool.

// Defined in the redzone runtime (writes a NUL-terminated string over the bare UART).
extern fn uputs(s: *const u8) -> void;

// Arm + smash a stack guard; guard_check must trap (-> the runtime's trap vector).
extern fn canary_demo() -> u32;

export fn rt_scenario(region: usize, len: usize) -> void {
    uputs("canary: smashing guard...\n");
    let _r: u32 = canary_demo();
    uputs("CANARY-MISSED\n"); // only reached if the canary check FAILED to fire
}
