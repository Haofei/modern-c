import "kernel/lib/mutex.mc";

global g_m: Mutex;

// 0 = Acquired, 1 = Blocked.
fn lock_code(task: u32) -> u32 {
    switch mutex_lock(&g_m, task) {
        .Acquired => { return 0; }
        .Blocked => { return 1; }
    }
}

// The woken task id (0 = none / lock freed), or 0xFFFF on a NotOwner error.
fn unlock_woken(task: u32) -> u32 {
    switch mutex_unlock(&g_m, task) {
        ok(woken) => { return woken; }
        err(e) => { return 0xFFFF; }
    }
}

export fn mutex_run() -> u32 {
    var pass: u32 = 1;
    mutex_init(&g_m);
    if mutex_is_locked(&g_m) { pass = 0; }

    // task 10 acquires; task 20's non-blocking try fails while it is held.
    if !mutex_try_lock(&g_m, 10) { pass = 0; }
    if !mutex_is_locked(&g_m) { pass = 0; }
    if mutex_owner(&g_m) != 10 { pass = 0; }
    if mutex_try_lock(&g_m, 20) { pass = 0; }

    // tasks 20 and 30 block (enqueued as FIFO waiters).
    if lock_code(20) != 1 { pass = 0; }   // Blocked
    if lock_code(30) != 1 { pass = 0; }   // Blocked
    if mutex_waiters(&g_m) != 2 { pass = 0; }

    // owner 10 unlocks -> hands the lock DIRECTLY to waiter 20 (FIFO); lock stays held.
    if unlock_woken(10) != 20 { pass = 0; }
    if !mutex_is_locked(&g_m) { pass = 0; }
    if mutex_owner(&g_m) != 20 { pass = 0; }
    if mutex_waiters(&g_m) != 1 { pass = 0; }

    // a non-owner unlock is rejected.
    if unlock_woken(99) != 0xFFFF { pass = 0; }

    // owner 20 unlocks -> hands off to 30; then 30 unlocks -> nobody waiting, lock freed (woken 0).
    if unlock_woken(20) != 30 { pass = 0; }
    if mutex_owner(&g_m) != 30 { pass = 0; }
    if unlock_woken(30) != 0 { pass = 0; }
    if mutex_is_locked(&g_m) { pass = 0; }
    if mutex_waiters(&g_m) != 0 { pass = 0; }

    // an uncontended re-acquire works after the queue drains.
    if lock_code(40) != 0 { pass = 0; }   // Acquired
    if mutex_owner(&g_m) != 40 { pass = 0; }

    return pass;
}
