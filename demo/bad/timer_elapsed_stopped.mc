// EXPECT: E_NO_IMPLICIT_POINTER_CONVERSION — reading elapsed from a stopped timer.
import "demo/timer/timer.mc";
fn bad(id: u32) -> u32 {
    var s: TimerStopped = mc_timer_open(id);
    let e: u32 = elapsed(&s);
    mc_timer_close(s);
    return e;
}
