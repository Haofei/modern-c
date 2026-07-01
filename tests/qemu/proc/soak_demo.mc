// SOAK — a representative production workload run for MANY iterations in a SINGLE boot,
// asserting the kernel's core lifecycle + accounting invariants return to baseline with no
// leak and no counter-overflow trap (production-readiness §4.7 hardening polish, P6).
//
// Where the unit gates (proc-supervisor-test, ledger-test) each prove one primitive once, a soak
// proves that thousands of repetitions of the FULL churn leave no residue: every spawned process
// is reclaimed, every charged resource is released, and no monotonic counter (generation, ledger
// `used`, restart budget) ever wraps into a checked-arithmetic trap.
//
// One iteration models the steady-state agent lifecycle WITHOUT context switches (this is pure
// scheduling/accounting logic — there is no timer, no real thread to switch into, so a `proc_exit`
// that mc_switch_context'd into a bodyless worker would be unsound here; the OOM/fault reclaim path
// is the production terminate-and-reclaim that runs NO context switch, so we exercise that instead):
//
//   1. spawn PER_ITER agent processes (reusing reaped Unused slots — never growing unbounded);
//   2. charge each agent's memory against the unified ledger (overflow-safe, near a real limit);
//   3. enroll each under supervision, heartbeat it, and fold a supervisor scan over the table;
//   4. forcibly terminate + reclaim each agent via the SAME death-cleanup path proc_exit runs
//      (proc_oom_kill: fds + memory account + IPC + waiters released), releasing its ledger charge;
//   5. reap every zombie back to a free (Unused) slot.
//
// After each iteration the invariant MUST hold: zero live non-bootstrap processes, zero zombies,
// and ledger `used == 0` on every dimension. If any spawn/reclaim/reap ever leaked a slot, or any
// charge/release ever went unmatched, the invariant breaks and the run reports SOAK-FAIL. Completing
// all ITERS iterations with the invariant intact at the end (and never trapping) is the property.

import "kernel/core/process.mc";
import "kernel/core/proc_sched.mc";
import "kernel/core/ledger.mc";
import "tests/qemu/lib/test_report.mc";

const ITERS: u32 = 4000;           // single-boot repetitions; bounded so QEMU finishes in the gate
const PER_ITER: usize = 3;         // agents spawned+reclaimed per iteration (slots 1..3; 0 = boot)
const INTERVAL: u64 = 10;          // supervision heartbeat budget
const MAX_RESTARTS: u32 = 2;       // crash-loop budget for the supervisor scan
const MEM_LIMIT: u64 = 0x100000;   // per-dimension ledger ceiling (Memory)
const PER_AGENT_MEM: u64 = 4096;   // memory charged per agent per iteration (matched on release)

global g_t: ProcTable;
global g_led: Ledger;

fn worker() -> void {}

// Live (Ready/Running/Blocked -> state codes 1/2/3) non-bootstrap processes. Slot 0 is the boot
// context and is excluded. This is the leak sensor: it must read 0 at the end of every iteration.
fn live_nonboot() -> u32 {
    var n: u32 = 0;
    let c: usize = proc_count(&g_t);
    var i: usize = 1;
    while i < c {
        let s: u32 = proc_state_code(&g_t, i);
        if s == 1 { n = n + 1; }
        if s == 2 { n = n + 1; }
        if s == 3 { n = n + 1; }
        i = i + 1;
    }
    return n;
}

// Zombie (state code 4) slots awaiting reap. Must read 0 at the end of every iteration.
fn zombie_count() -> u32 {
    var n: u32 = 0;
    let c: usize = proc_count(&g_t);
    var i: usize = 1;
    while i < c {
        if proc_state_code(&g_t, i) == 4 { n = n + 1; }
        i = i + 1;
    }
    return n;
}

// true iff the ledger charge succeeded (agent memory reserved within its limit).
fn charge_mem(amount: u64) -> bool {
    switch ledger_charge(&g_led, .Memory, amount) {
        ok(v) => { return true; }
        err(e) => { return false; }
    }
}

// true iff the ledger release succeeded (agent memory returned on reclaim).
fn release_mem(amount: u64) -> bool {
    switch ledger_release(&g_led, .Memory, amount) {
        ok(v) => { return true; }
        err(e) => { return false; }
    }
}

// Reap every zombie child of the bootstrap process (pid 0) back to Unused. Returns the count reaped.
fn reap_all() -> u32 {
    var reaped: u32 = 0;
    var reaping: bool = true;
    while reaping {
        switch proc_reap(&g_t, 0) {
            ok(info) => { reaped = reaped + 1; }
            err(e) => { reaping = false; } // NoZombieYet / NoChildren -> nothing left to reap
        }
    }
    return reaped;
}

export fn soak_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    ledger_init(&g_led);
    ledger_set_limit(&g_led, .Memory, MEM_LIMIT);

    // Baseline: a fresh table has only the bootstrap; nothing live, nothing charged.
    if live_nonboot() != 0 { pass = 0; }
    if zombie_count() != 0 { pass = 0; }
    if ledger_used(&g_led, .Memory) != 0 { pass = 0; }

    var total_spawns: u64 = 0;
    var total_reaped: u64 = 0;

    var iter: u32 = 0;
    while iter < ITERS {
        // ----- (1)+(2)+(3) spawn agents, charge memory, enroll + heartbeat under supervision -----
        var spawned: u32 = 0;
        var k: usize = 0;
        while k < PER_ITER {
            let pid: u32 = proc_spawn(&g_t, 0x1000, worker);
            if pid == 0 { pass = 0; } // 0 is the bootstrap slot; a real spawn never returns it
            let slot: usize = pid as usize;
            if !charge_mem(PER_AGENT_MEM) { pass = 0; }
            proc_supervise(&g_t, slot, 0, INTERVAL);
            proc_heartbeat(&g_t, slot, INTERVAL / 2); // beat within budget -> healthy, no restart
            spawned = spawned + 1;
            total_spawns = total_spawns + 1;
            k = k + 1;
        }
        if spawned != PER_ITER as u32 { pass = 0; }
        if live_nonboot() != PER_ITER as u32 { pass = 0; }
        if ledger_used(&g_led, .Memory) != PER_AGENT_MEM * (PER_ITER as u64) { pass = 0; }

        // Fold a supervisor scan over the live table (churns the supervision verdict logic). All
        // agents beat within budget, so a healthy scan restarts/gives-up nothing.
        let summary: u32 = proc_supervisor_scan(&g_t, INTERVAL / 2, MAX_RESTARTS);
        if proc_supervisor_scan_restarts(summary) != 0 { pass = 0; }
        if proc_supervisor_scan_giveups(summary) != 0 { pass = 0; }

        // ----- (4) terminate + reclaim each agent (same death-cleanup path proc_exit runs), and
        // release its ledger charge. proc_oom_kill terminates a NON-current live slot with no
        // context switch — exactly the reclaim path for a runaway/OOM-killed agent. -----
        var j: usize = 1;
        let c: usize = proc_count(&g_t);
        while j < c {
            let s: u32 = proc_state_code(&g_t, j);
            if s == 1 { // Ready/live agent -> reclaim it
                proc_oom_kill(&g_t, j);
                if !release_mem(PER_AGENT_MEM) { pass = 0; }
            } else {
                if s == 2 { proc_oom_kill(&g_t, j); if !release_mem(PER_AGENT_MEM) { pass = 0; } }
                if s == 3 { proc_oom_kill(&g_t, j); if !release_mem(PER_AGENT_MEM) { pass = 0; } }
            }
            j = j + 1;
        }

        // ----- (5) reap every zombie back to a free slot -----
        let reaped: u32 = reap_all();
        if reaped != PER_ITER as u32 { pass = 0; }
        total_reaped = total_reaped + (reaped as u64);

        // ----- per-iteration invariant: everything returned to baseline (leak sensor) -----
        if live_nonboot() != 0 { pass = 0; }
        if zombie_count() != 0 { pass = 0; }
        if ledger_used(&g_led, .Memory) != 0 { pass = 0; }

        iter = iter + 1;
    }

    // ----- final invariants across the whole soak -----
    if total_spawns != (ITERS as u64) * (PER_ITER as u64) { pass = 0; }
    if total_reaped != total_spawns { pass = 0; }          // every spawn was reclaimed (no leak)
    if ledger_used(&g_led, .Memory) != 0 { pass = 0; }     // ledger fully released
    // The slot table never grew unbounded: reuse kept it at bootstrap + at most PER_ITER slots.
    if proc_count(&g_t) > (PER_ITER + 1) { pass = 0; }
    if live_nonboot() != 0 { pass = 0; }
    if zombie_count() != 0 { pass = 0; }

    return pass;
}
