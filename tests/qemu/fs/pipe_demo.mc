// Pipe FIFO: write bytes, read them back in order, confirm full/empty backpressure.
import "kernel/core/pipe.mc";

global g_pipe: Pipe;

export fn pipe_run() -> u32 {
    var pass: u32 = 1;
    pipe_init(&g_pipe);
    if pipe_len(&g_pipe) != 0 { pass = 0; }

    // write "HI"
    if !pipe_write(&g_pipe, 0x48) { pass = 0; } // H
    if !pipe_write(&g_pipe, 0x49) { pass = 0; } // I
    if pipe_len(&g_pipe) != 2 { pass = 0; }

    // FIFO read order
    switch pipe_read(&g_pipe) {
        ok(b) => { if b != 0x48 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch pipe_read(&g_pipe) {
        ok(b) => { if b != 0x49 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    // empty pipe -> typed Empty error (no sentinel)
    switch pipe_read(&g_pipe) {
        ok(b) => { pass = 0; }
        err(e) => {}
    }

    // fill to capacity, then overflow rejected
    var i: u32 = 0;
    while i < 16 {
        if !pipe_write(&g_pipe, i as u8) { pass = 0; }
        i = i + 1;
    }
    if pipe_write(&g_pipe, 0xFF) { pass = 0; } // full -> rejected
    switch pipe_read(&g_pipe) {                 // FIFO: first byte written was 0
        ok(b) => { if b != 0 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    return pass;
}
