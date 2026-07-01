// Differential-coverage fixture (language gap G18: generic tagged unions).
// `union Name<T> { some: T, none }` is a template, monomorphized per concrete use
// exactly like a generic struct: each `Name<U>` becomes a distinct non-generic
// tagged union `Name__U` with the type parameter substituted in the case payload
// types (`some: T` → `some: U`), and the generic declaration is dropped. Payload
// cases and payload-less cases both work, `switch`/pattern-binding types the
// payload as the substituted type, constructors resolve against the concrete
// target type, and two instantiations (`Opt<u32>` / `Opt<u64>`) produce distinct
// deduped concrete unions. A payload-less-only generic union (`Sig<T>`) is also
// covered. The entry folds every observation into a status word; any divergence
// on EITHER backend makes it return 0.

union Opt<T> {
    some: T,
    none,
}

// Payload-less-only generic union: the type parameter never appears in a payload,
// but the declaration is still generic and monomorphizes per concrete argument.
union Sig<T> {
    ready,
    idle,
}

// Type-generic constructor: `some(x)` resolves against the concrete return union.
fn wrap(comptime T: type, x: T) -> Opt<T> {
    return some(x);
}

fn none_opt(comptime T: type) -> Opt<T> {
    return none();
}

// switch-binding types the payload `v` as the substituted concrete type.
fn unwrap_or_u32(o: Opt<u32>, fallback: u32) -> u32 {
    switch o {
        some(v) => { return v; },
        .none => { return fallback; },
    }
}

fn unwrap_or_u64(o: Opt<u64>, fallback: u64) -> u64 {
    switch o {
        some(v) => { return v; },
        .none => { return fallback; },
    }
}

fn is_some_u32(o: Opt<u32>) -> u32 {
    switch o {
        .some => { return 1; },
        .none => { return 0; },
    }
}

fn sig_is_ready(s: Sig<u32>) -> u32 {
    switch s {
        .ready => { return 1; },
        .idle => { return 0; },
    }
}

export fn generic_unions_run() -> u32 {
    // Opt<u32> present / absent
    if unwrap_or_u32(wrap(u32, 7), 99) != 7 { return 0; }
    if unwrap_or_u32(none_opt(u32), 99) != 99 { return 0; }
    if is_some_u32(wrap(u32, 3)) != 1 { return 0; }
    if is_some_u32(none_opt(u32)) != 0 { return 0; }

    // Opt<u64> — a SECOND instantiation, distinct concrete union (Opt__u64)
    if unwrap_or_u64(wrap(u64, 0xffff_ffff_0000_0001), 5) != 0xffff_ffff_0000_0001 { return 0; }
    if unwrap_or_u64(none_opt(u64), 5) != 5 { return 0; }

    // A THIRD use of Opt<u32> (dedup: reuses the Opt__u32 instance, not a new one)
    let again: Opt<u32> = wrap(u32, 42);
    if unwrap_or_u32(again, 0) != 42 { return 0; }

    // Payload-less-only generic union
    let r: Sig<u32> = ready();
    if sig_is_ready(r) != 1 { return 0; }
    let i: Sig<u32> = idle();
    if sig_is_ready(i) != 0 { return 0; }

    return 1;
}
