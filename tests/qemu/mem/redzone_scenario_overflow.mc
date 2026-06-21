// Heap-overflow scenario unit for the redzone runtime (PURE MC). Linked beside
// tests/qemu/mem/redzone_runtime.mc, it DEFINES `rt_scenario` to perform a REAL
// one-past-the-end write into the trailing redzone, caught on free -> DETECTED. If
// the redzone check fails to fire, redzone_overflow returns and we print
// OVERFLOW-MISSED over the runtime's bare-UART `uputs`. Its own import-free linked
// unit (the demo export + the runtime's `uputs` are declared `extern fn` here).

// Defined in the redzone runtime (writes a NUL-terminated string over the bare UART).
extern fn uputs(s: *const u8) -> void;

// A real one-past-the-end write into the trailing redzone, caught on free (-> trap).
extern fn redzone_overflow(region: usize, len: usize) -> u32;

export fn rt_scenario(region: usize, len: usize) -> void {
    uputs("overflow: writing past allocation...\n");
    let _r: u32 = redzone_overflow(region, len);
    uputs("OVERFLOW-MISSED\n"); // only reached if the redzone check FAILED to fire
}
