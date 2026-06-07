// demo/timer — a device state machine as linear typestate.
//
// A timer is Stopped or Running, never ambiguous. Each transition consumes the
// handle in one state and produces it in the next, so the compiler rejects:
//   - configuring or starting a Running timer (those take a TimerStopped)
//   - reading elapsed from a Stopped timer (that takes a TimerRunning)
//   - dropping a timer handle without closing it (linear)
// The transitions are platform primitives (the MMIO pokes live behind them).

move struct TimerStopped { id: u32 }
move struct TimerRunning { id: u32 }

extern fn mc_timer_open(id: u32) -> TimerStopped;
extern fn mc_timer_configure(t: TimerStopped, reload: u32) -> TimerStopped;
extern fn mc_timer_start(t: TimerStopped) -> TimerRunning;
extern fn mc_timer_elapsed(t: *TimerRunning) -> u32;
extern fn mc_timer_stop(t: TimerRunning) -> TimerStopped;
extern fn mc_timer_close(t: TimerStopped) -> void;

export fn configure(t: TimerStopped, reload: u32) -> TimerStopped {
    return mc_timer_configure(t, reload);
}
export fn start(t: TimerStopped) -> TimerRunning {
    return mc_timer_start(t);
}
export fn elapsed(t: *TimerRunning) -> u32 {
    return mc_timer_elapsed(t);
}
export fn stop(t: TimerRunning) -> TimerStopped {
    return mc_timer_stop(t);
}

// One full lifecycle, each transition in the only state where it is legal.
export fn measure(id: u32, reload: u32) -> u32 {
    let stopped: TimerStopped = mc_timer_open(id);
    let armed: TimerStopped = configure(stopped, reload);
    let running: TimerRunning = start(armed);
    let ticks: u32 = elapsed(&running);
    let done: TimerStopped = stop(running);
    mc_timer_close(done);
    return ticks;
}

// what the types forbid:
//   start(start(armed))     // E_NO_IMPLICIT_CONVERSION: start() wants Stopped, got Running
//   elapsed(&armed)         // E_NO_IMPLICIT_CONVERSION: elapsed() wants *Running
//   (omitting mc_timer_close) // E_RESOURCE_LEAK: the handle is never closed
