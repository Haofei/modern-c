// Test wrappers around the leveled logger for the host driver. Levels cross the
// boundary as small integers (0=Debug, 1=Info, 2=Warn, 3=Error).

import "kernel/core/log.mc";

global g_log: Logger;

fn level_of(ord: u32) -> LogLevel {
    if ord == 0 {
        return .Debug;
    }
    if ord == 1 {
        return .Info;
    }
    if ord == 2 {
        return .Warn;
    }
    return .Error;
}

export fn lg_init(threshold: u32) -> void {
    log_init(&g_log, level_of(threshold));
}
export fn lg_set(threshold: u32) -> void {
    log_set_threshold(&g_log, level_of(threshold));
}
export fn lg_event(level: u32, id: u32, value: u64) -> u32 {
    if log_event(&g_log, level_of(level), id, value) {
        return 1;
    }
    return 0;
}
export fn lg_dropped() -> u64 {
    return log_dropped(&g_log);
}
export fn lg_count() -> u64 {
    return log_count(&g_log) as u64;
}
export fn lg_level(i: usize) -> u32 {
    return log_level_at(&g_log, i);
}
export fn lg_id(i: usize) -> u32 {
    return log_id_at(&g_log, i);
}
export fn lg_value(i: usize) -> u64 {
    return log_value_at(&g_log, i);
}
