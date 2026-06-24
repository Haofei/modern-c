import "std/sync/rwlock.mc";
import "std/sync/seqlock.mc";

global g_rw: RwLock;
global g_seq: SeqLock;

// Single-threaded logic check of the rwlock + seqlock state machines (real concurrency is a
// QEMU/SMP concern; here we verify the counter/sequence transitions and that an uncontended
// acquire never spins).
export fn synclock_run() -> u32 {
    var pass: u32 = 1;

    // ----- RwLock: reader count, then an uncontended writer -----
    rwlock_init(&g_rw);
    if rwlock_readers(&g_rw) != 0 { pass = 0; }

    read_lock(&g_rw);
    read_lock(&g_rw);
    if rwlock_readers(&g_rw) != 2 { pass = 0; }   // two concurrent readers
    read_unlock(&g_rw);
    if rwlock_readers(&g_rw) != 1 { pass = 0; }
    read_unlock(&g_rw);
    if rwlock_readers(&g_rw) != 0 { pass = 0; }

    // with no readers, the writer acquires without spinning, then releases
    write_lock(&g_rw);
    write_unlock(&g_rw);
    // and a reader can acquire again afterwards
    read_lock(&g_rw);
    if rwlock_readers(&g_rw) != 1 { pass = 0; }
    read_unlock(&g_rw);

    // ----- SeqLock: a read snapshot detects an overlapping write -----
    seqlock_init(&g_seq);
    let s0: u32 = seq_read_begin(&g_seq);          // even, == 0
    if (s0 & 1) != 0 { pass = 0; }                 // begin never returns mid-write

    seq_write_begin(&g_seq);                        // seq -> 1 (odd, in progress)
    seq_write_end(&g_seq);                          // seq -> 2 (even)
    if !seq_read_retry(&g_seq, s0) { pass = 0; }    // a write happened since s0 -> must retry

    let s1: u32 = seq_read_begin(&g_seq);          // == 2, stable
    if seq_read_retry(&g_seq, s1) { pass = 0; }     // no write since s1 -> no retry

    // a second write advances the sequence again
    seq_write_begin(&g_seq);
    seq_write_end(&g_seq);
    if !seq_read_retry(&g_seq, s1) { pass = 0; }

    return pass;
}
