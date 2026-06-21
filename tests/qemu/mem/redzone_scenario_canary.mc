// Stack-canary scenario unit for redzone_runtime.mc. Import-free: declares the demo's
// canary entry `extern` and defines the `rt_scenario_run` the runtime calls. A smashed
// stack guard is caught by guard_check -> the check raises `unreachable` -> trap ->
// on_trap prints DETECTED (so this never returns in practice). The region/len are unused
// (the canary demo manages its own frame), matching the signature the runtime calls.
extern fn canary_demo() -> u32;

export fn rt_scenario_run(region: usize, len: usize) -> void {
    let _r: u32 = canary_demo();
}
