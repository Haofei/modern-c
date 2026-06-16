// Capability attenuation (kernel/core/process): proc_spawn_attenuated grants a child a SUBSET
// of the SPAWNING process's authority — never more. The child's masks are the intersection of
// the parent's mask and the requested subset, so a bit the parent lacks can never reach the
// child even when the subset asks for it. A plain proc_spawn still yields empty masks (least
// privilege, unchanged). The arch context primitives are stubbed by the C driver — only the
// mask bookkeeping path runs on the host.

import "kernel/core/process.mc";
import "std/mask.mc";

global g_t: ProcTable;

fn child_entry() -> void {}
fn plain_entry() -> void {}

fn mask_of3(a: u32, b: u32, c: u32) -> Mask32 {
    var m: Mask32 = mask32_zero();
    mask32_set(&m, a);
    mask32_set(&m, b);
    mask32_set(&m, c);
    return m;
}

fn mask_of2(a: u32, b: u32) -> Mask32 {
    var m: Mask32 = mask32_zero();
    mask32_set(&m, a);
    mask32_set(&m, b);
    return m;
}

export fn attenuate_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);

    // The bootstrap (slot 0, the current process) gets a restricted authority surface:
    //   allow_mask = {1,2,3}, kcall_mask = {0,1}. proc_table_init seeds slot 0 with all bits,
    //   so we deliberately narrow it here to make the intersection observable.
    var parent_allow: Mask32 = mask_of3(1, 2, 3);
    var parent_kcall: Mask32 = mask_of2(0, 1);
    proc_set_allow_mask(&g_t, 0, mask32_raw(&parent_allow));
    proc_set_kcall_mask(&g_t, 0, mask32_raw(&parent_kcall));

    // Attenuated spawn: request allow_subset = {2,3,4}, kcall_subset = {1,2}.
    let child: u32 = proc_spawn_attenuated(&g_t, 0x1000, child_entry,
        mask_of3(2, 3, 4), mask_of2(1, 2));
    let cs: usize = child as usize;

    // Expected child allow_mask = parent {1,2,3} AND subset {2,3,4} = {2,3}. Bit 4 is dropped
    // (the parent lacked it), bit 1 is dropped (the subset did not request it).
    var ca: Mask32 = proc_allow_mask(&g_t, cs);
    if mask32_contains(&ca, 0) { pass = 0; }
    if mask32_contains(&ca, 1) { pass = 0; }   // not in subset
    if !mask32_contains(&ca, 2) { pass = 0; }
    if !mask32_contains(&ca, 3) { pass = 0; }
    if mask32_contains(&ca, 4) { pass = 0; }   // parent lacked it — never granted
    if mask32_raw(&ca) != 0xC { pass = 0; }    // bits {2,3} = 0b1100

    // Expected child kcall_mask = parent {0,1} AND subset {1,2} = {1}. Bit 2 dropped (parent
    // lacked it), bit 0 dropped (subset did not request it).
    var ck: Mask32 = proc_kcall_mask(&g_t, cs);
    if mask32_contains(&ck, 0) { pass = 0; }   // not in subset
    if !mask32_contains(&ck, 1) { pass = 0; }
    if mask32_contains(&ck, 2) { pass = 0; }   // parent lacked it — never granted
    if mask32_raw(&ck) != 0x2 { pass = 0; }    // bit {1} = 0b10

    // A plain proc_spawn still produces empty masks — unchanged least-privilege behavior.
    let plain: u32 = proc_spawn(&g_t, 0x2000, plain_entry);
    let ps: usize = plain as usize;
    var pa: Mask32 = proc_allow_mask(&g_t, ps);
    var pk: Mask32 = proc_kcall_mask(&g_t, ps);
    if mask32_raw(&pa) != 0 { pass = 0; }
    if mask32_raw(&pk) != 0 { pass = 0; }

    return pass;
}
