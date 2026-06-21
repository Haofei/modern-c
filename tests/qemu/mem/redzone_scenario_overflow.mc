// Heap-redzone scenario unit for redzone_runtime.mc. Import-free: declares the demo's
// overflow entry `extern` and defines the `rt_scenario_run` the runtime calls. A real
// one-past-the-end write into the trailing redzone is caught on free -> the check raises
// `unreachable` -> trap -> on_trap prints DETECTED (so this never returns in practice).
extern fn redzone_overflow(region: usize, len: usize) -> u32;

export fn rt_scenario_run(region: usize, len: usize) -> void {
    let _r: u32 = redzone_overflow(region, len);
}
