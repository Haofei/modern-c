// kernel/core/log — leveled, named tracepoints over the trace ring buffer.
//
// Each event carries a severity (Debug/Info/Warn/Error) and a tracepoint id. A
// runtime-settable threshold filters events below it (counted as `dropped`, never
// silently lost); the rest are recorded into the ring with the level packed into the
// event id. This is the "log levels + tracepoints" layer; the ring gives bounded,
// lock-free history (see [[trace]]).

import "kernel/core/trace.mc";

enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

struct Logger {
    sink: TraceBuffer,
    threshold: u32, // minimum level ordinal that is recorded
    dropped: u64,   // events filtered out below the threshold
}

fn level_ord(level: LogLevel) -> u32 {
    switch level {
        .Debug => {
            return 0;
        }
        .Info => {
            return 1;
        }
        .Warn => {
            return 2;
        }
        .Error => {
            return 3;
        }
    }
}

export fn log_init(l: *mut Logger, threshold: LogLevel) -> void {
    trace_init((&l.sink) as *mut TraceBuffer);
    l.threshold = level_ord(threshold);
    l.dropped = 0;
}

export fn log_set_threshold(l: *mut Logger, threshold: LogLevel) -> void {
    l.threshold = level_ord(threshold);
}

// Record an event at `level` for tracepoint `id`. Returns true if it met the
// threshold and was recorded, false if filtered out (and counted as dropped).
export fn log_event(l: *mut Logger, level: LogLevel, id: u32, value: u64) -> bool {
    let lo: u32 = level_ord(level);
    if lo < l.threshold {
        l.dropped = l.dropped + 1;
        return false;
    }
    let encoded: u32 = (lo << 28) | (id & 0x0FFF_FFFF); // level in the top nibble
    trace_record((&l.sink) as *mut TraceBuffer, encoded, value);
    return true;
}

export fn log_dropped(l: *mut Logger) -> u64 {
    return l.dropped;
}

export fn log_count(l: *mut Logger) -> usize {
    return trace_len((&l.sink) as *mut TraceBuffer);
}

export fn log_level_at(l: *mut Logger, i: usize) -> u32 {
    let id: u32 = trace_id((&l.sink) as *mut TraceBuffer, i);
    return id >> 28;
}

export fn log_id_at(l: *mut Logger, i: usize) -> u32 {
    let id: u32 = trace_id((&l.sink) as *mut TraceBuffer, i);
    return id & 0x0FFF_FFFF;
}

export fn log_value_at(l: *mut Logger, i: usize) -> u64 {
    return trace_value((&l.sink) as *mut TraceBuffer, i);
}
