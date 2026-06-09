type S = serial<u32>;
type T = counter<u64>;

fn seq_before(a: S, b: S) -> bool {
    return S.before(a, b);
}

fn seq_after(a: S, b: S) -> bool {
    return S.after(a, b);
}

fn seq_distance(a: S, b: S) -> wrap<u32> {
    return S.distance(a, b);
}

fn tick_delta(now: T, start: T) -> wrap<u64> {
    return T.delta_mod(now, start);
}
