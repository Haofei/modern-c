// UB class: out-of-bounds array/slice access.  MC handling: CHECKED + TRAP — every
// indexed access lowers through mc_check_index_usize(index, len), which traps
// (mc_trap_Bounds) when index >= len.  In-bounds accesses pass through unchanged.  This
// fixture indexes only within bounds, so the guard is present but never fires; the OOB
// access that would trap is shown in the matrix, not exercised here (it would abort the
// process and fail the sanitizer gate, which is exactly the point of the guard).
global g_arr: [4]u32;

export fn ub_out_of_bounds_run() -> u32 {
    var pass: u32 = 1;
    g_arr[0] = 10; g_arr[1] = 20; g_arr[2] = 30; g_arr[3] = 40;
    var i: usize = 0;
    var sum: u32 = 0;
    while i < 4 {                 // bounded by len; mc_check_index_usize never trips
        sum = sum + g_arr[i];
        i = i + 1;
    }
    if sum != 100 { pass = 0; }
    if g_arr[3] != 40 { pass = 0; }   // last valid index, in bounds
    return pass;
}
