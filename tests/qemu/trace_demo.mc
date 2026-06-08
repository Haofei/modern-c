// Test wrappers around the trace ring buffer for the host driver.

import "kernel/core/trace.mc";

global g_trace: TraceBuffer;

export fn t_init() -> void {
    trace_init(&g_trace);
}
export fn t_record(id: u32, value: u64) -> void {
    trace_record(&g_trace, id, value);
}
export fn t_total() -> u64 {
    return trace_total(&g_trace);
}
export fn t_len() -> u64 {
    return trace_len(&g_trace) as u64;
}
export fn t_seq(i: usize) -> u64 {
    return trace_seq(&g_trace, i);
}
export fn t_id(i: usize) -> u32 {
    return trace_id(&g_trace, i);
}
export fn t_value(i: usize) -> u64 {
    return trace_value(&g_trace, i);
}
