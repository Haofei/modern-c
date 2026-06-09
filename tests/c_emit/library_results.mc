type S = serial<u32>;
type T = counter<u64>;

fn seq_compare(a: S, b: S) -> Result<Order, AmbiguousSerialOrder> {
    return S.compare(a, b);
}

fn tick_bounded(now: T, start: T, max: Duration<u64>) -> Result<Duration<u64>, AmbiguousCounterInterval> {
    return T.elapsed_bounded(now, start, max);
}

fn narrow_try(x: u32) -> Result<u8, ConversionError> {
    return u8.try_from(x);
}

fn widen_try(x: u8) -> Result<u64, ConversionError> {
    return u64.try_from(x);
}
