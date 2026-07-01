// SPEC: section=14,22
// SPEC: milestone=generic-tagged-unions
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass
// SPEC: check=generic-union-monomorphize-accept

// Generic tagged unions (§14 tagged unions × §22 monomorphization, language gap
// G18): `union Name<T> { some: T, none }` is a template. Each concrete use
// `Name<U>` is monomorphized to a distinct non-generic tagged union `Name__U`
// with the type parameter substituted in the case payload types, and the generic
// declaration is dropped — exactly the generic-struct pipeline reused for unions.
// This fixture must COMPILE CLEAN: payload cases (`some: T`) and payload-less
// cases (`none`, `ready`/`idle`) both work, `switch`/pattern-binding types the
// payload as the substituted concrete type, constructors resolve against the
// concrete target union, and two instantiations (`Opt<u32>` / `Opt<u64>`)
// produce distinct deduped concrete unions.

union Opt<T> {
    some: T,
    none,
}

// A payload-less-only generic union still monomorphizes per concrete argument.
union Sig<T> {
    ready,
    idle,
}

// Type-generic constructor: `some(x)` / `none()` resolve against the concrete
// return union after monomorphization.
fn wrap(comptime T: type, x: T) -> Opt<T> {
    return some(x);
}

fn empty(comptime T: type) -> Opt<T> {
    return none();
}

// switch-binding types the payload `v` as the substituted concrete type.
fn unwrap_u32(o: Opt<u32>, fallback: u32) -> u32 {
    switch o {
        some(v) => { return v; },
        .none => { return fallback; },
    }
}

fn unwrap_u64(o: Opt<u64>, fallback: u64) -> u64 {
    switch o {
        some(v) => { return v; },
        .none => { return fallback; },
    }
}

fn sig_ready(s: Sig<u32>) -> u32 {
    switch s {
        .ready => { return 1; },
        .idle => { return 0; },
    }
}

// Two instantiations of the same generic union plus a payload-less one, all in
// one function — the concrete unions dedup on their mangled names.
fn use_all() -> u32 {
    let a: Opt<u32> = wrap(u32, 7);
    let b: Opt<u64> = empty(u64);
    let s: Sig<u32> = ready();
    return unwrap_u32(a, 0) + (unwrap_u64(b, 5) as u32) + sig_ready(s);
}
