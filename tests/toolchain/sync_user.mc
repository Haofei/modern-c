// Imports std/sync and uses a spinlock guard around a critical section. The
// linear Guard makes "forgot to unlock" / "double unlock" compile errors.
import "../../std/sync.mc";

export fn guarded_add(l: *SpinLock, counter: *mut u32, delta: u32) -> void {
    let g: Guard = lock(l);
    counter.* = counter.* + delta; // critical section
    unlock(g);                     // g consumed exactly once
}
