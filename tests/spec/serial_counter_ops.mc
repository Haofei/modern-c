// SPEC: section=5.4,5.5
// SPEC: milestone=serial-counter-operations
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_SERIAL_OPERATION,E_COUNTER_OPERATION,E_CALL_ARG_COUNT

type TcpSeq = serial<u32>;
type Ticks = counter<u64>;

// Serial numbers use domain-specific window comparisons (section 5.4).
fn seq_before(a: TcpSeq, b: TcpSeq) -> bool {
    return TcpSeq.before(a, b);
}

fn seq_after(a: TcpSeq, b: TcpSeq) -> bool {
    return TcpSeq.after(a, b);
}

// distance yields a modular representative.
fn seq_distance(a: TcpSeq, b: TcpSeq) -> wrap<u32> {
    return TcpSeq.distance(a, b);
}

// Windowed comparison returns a Result over an ambiguity error (section 5.4).
fn seq_compare(a: TcpSeq, b: TcpSeq) -> Result<Order, AmbiguousSerialOrder> {
    return TcpSeq.compare(a, b);
}

// Free-running counters expose the fully defined modular delta (section 5.5).
fn tick_delta(now: Ticks, start: Ticks) -> wrap<u64> {
    return Ticks.delta_mod(now, start);
}

// Interpreting a delta as elapsed time needs an external temporal invariant.
fn tick_elapsed(now: Ticks, start: Ticks, max: Duration<u64>) -> Duration<u64> {
    return Ticks.elapsed_assume_within(now, start, max);
}

// A checked variant validates representability and local bounds (section 5.5).
fn tick_elapsed_bounded(now: Ticks, start: Ticks, max: Duration<u64>) -> Result<Duration<u64>, AmbiguousCounterInterval> {
    return Ticks.elapsed_bounded(now, start, max);
}

// Unknown serial operations are rejected.
fn reject_unknown_serial_op(a: TcpSeq, b: TcpSeq) -> bool {
    // EXPECT_ERROR: E_SERIAL_OPERATION
    return TcpSeq.between(a, b);
}

// Serial operands must share the serial domain type.
fn reject_serial_arg_domain(a: TcpSeq, x: wrap<u32>) -> bool {
    // EXPECT_ERROR: E_SERIAL_OPERATION
    return TcpSeq.before(a, x);
}

// Domain operations take exactly two operands.
fn reject_serial_arity(a: TcpSeq) -> bool {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return TcpSeq.before(a);
}

// MC deliberately does not provide a plain elapsed() on counters (section 5.5).
fn reject_unknown_counter_op(now: Ticks, start: Ticks) -> wrap<u64> {
    // EXPECT_ERROR: E_COUNTER_OPERATION
    return Ticks.elapsed(now, start);
}
