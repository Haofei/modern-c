import "std/mask.mc";
global g_m: Mask32;
export fn mask_run() -> u32 {
    var pass: u32 = 1;
    g_m = mask32_zero();
    if !mask32_is_empty(&g_m) { pass = 0; }

    mask32_set(&g_m, 1);
    mask32_set(&g_m, 5);
    mask32_set(&g_m, 31);
    mask32_set(&g_m, 99); // out of range -> ignored
    if !mask32_contains(&g_m, 1) { pass = 0; }
    if !mask32_contains(&g_m, 5) { pass = 0; }
    if !mask32_contains(&g_m, 31) { pass = 0; }
    if mask32_contains(&g_m, 0) { pass = 0; }
    if mask32_contains(&g_m, 99) { pass = 0; } // never set

    mask32_clear(&g_m, 5);
    if mask32_contains(&g_m, 5) { pass = 0; }

    // take_first returns ascending set bits, removing each
    if mask32_take_first(&g_m) != 1 { pass = 0; }
    if mask32_take_first(&g_m) != 31 { pass = 0; }
    if mask32_take_first(&g_m) != 32 { pass = 0; } // empty -> 32
    if !mask32_is_empty(&g_m) { pass = 0; }
    return pass;
}
