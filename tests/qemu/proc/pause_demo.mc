// Pause / resume an agent (P1.10), exercised on the host (the arch context primitives are
// stubbed by the C driver — only the scheduling bookkeeping runs). Runnability is DERIVED from a
// process's block-reason set: a process runs only when Ready/Running AND no block reason is set.
// Pausing sets a dedicated PAUSED reason (a process becomes non-runnable but stays alive — still
// Ready, just blocked); resuming clears it and restores runnability. This drives that contract:
//   * spawn two children A and B, both Ready and runnable;
//   * proc_pause(A): A is now paused and NON-runnable (the scheduler would skip it), B unaffected;
//   * proc_resume(A): A is no longer paused and runnable again.

import "kernel/core/process.mc";
import "kernel/core/proc_sched.mc";

global g_t: ProcTable;

fn child_a() -> void {}
fn child_b() -> void {}

export fn pause_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);

    // Two children, both Ready and runnable to start.
    let a: u32 = proc_spawn(&g_t, 0x1000, child_a);
    let b: u32 = proc_spawn(&g_t, 0x2000, child_b);
    let as_: usize = a as usize;
    let bs: usize = b as usize;

    // Baseline: both runnable, neither paused.
    if !proc_is_runnable_slot(&g_t, as_) { pass = 0; }
    if !proc_is_runnable_slot(&g_t, bs) { pass = 0; }
    if proc_is_paused(&g_t, as_) { pass = 0; }
    if proc_is_paused(&g_t, bs) { pass = 0; }

    // Pause A: it becomes non-runnable but stays alive (still Ready); B is unaffected.
    proc_pause(&g_t, as_);
    if !proc_is_paused(&g_t, as_) { pass = 0; }          // A reports paused
    if proc_is_runnable_slot(&g_t, as_) { pass = 0; }    // ... and the scheduler would skip it
    if g_t.procs[as_].state != .Ready { pass = 0; }      // ... but it is not killed — still Ready
    if !proc_is_runnable_slot(&g_t, bs) { pass = 0; }    // B still runnable
    if proc_is_paused(&g_t, bs) { pass = 0; }

    // Resume A: PAUSED clears, A runnable again exactly where it left off.
    proc_resume(&g_t, as_);
    if proc_is_paused(&g_t, as_) { pass = 0; }
    if !proc_is_runnable_slot(&g_t, as_) { pass = 0; }
    if !proc_is_runnable_slot(&g_t, bs) { pass = 0; }

    return pass;
}
