import "kernel/core/tlb_shootdown.mc";

global g_sd: Shootdown;

export fn tlb_shootdown_run() -> u32 {
    var pass: u32 = 1;

    // 4 cores, core 1 initiates -> cores 0, 2, 3 must flush (the initiator never targets itself).
    shootdown_begin(&g_sd, 1, 4, 0x4000, 0x1000);
    if shootdown_pending(&g_sd) != 3 { pass = 0; }
    if shootdown_complete(&g_sd) { pass = 0; }

    // acking the initiator (a non-target) does nothing.
    shootdown_ack(&g_sd, 1);
    if shootdown_pending(&g_sd) != 3 { pass = 0; }

    // a duplicate ack from the same target counts once.
    shootdown_ack(&g_sd, 0);
    shootdown_ack(&g_sd, 0);
    if shootdown_pending(&g_sd) != 2 { pass = 0; }

    // ack the remaining targets -> complete.
    shootdown_ack(&g_sd, 2);
    if shootdown_complete(&g_sd) { pass = 0; } // core 3 still outstanding
    shootdown_ack(&g_sd, 3);
    if shootdown_pending(&g_sd) != 0 { pass = 0; }
    if !shootdown_complete(&g_sd) { pass = 0; }

    // the range provenance is preserved for the target cores to flush.
    if g_sd.va != 0x4000 { pass = 0; }
    if g_sd.len != 0x1000 { pass = 0; }

    // a single-core system: the initiator has no targets, so the shootdown is trivially complete.
    shootdown_begin(&g_sd, 0, 1, 0x8000, 0x2000);
    if shootdown_pending(&g_sd) != 0 { pass = 0; }
    if !shootdown_complete(&g_sd) { pass = 0; }

    return pass;
}
