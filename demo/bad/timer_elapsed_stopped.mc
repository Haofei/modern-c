// EXPECT: E_NO_IMPLICIT_CONVERSION — reading elapsed from a stopped timer.
import "demo/timer/timer.mc";
fn bad(id: u32) -> void {
    let s: TimerStopped = mc_timer_open(id);
    elapsed(move s);
}
