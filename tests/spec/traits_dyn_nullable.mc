// SPEC: section=32.7
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema,lower-c,lower-ir
// SPEC: expect=pass
// SPEC: check=traits-tier2-nullable-dyn

// Nullable trait objects (docs/spec/MC_0.7_Final_Design.md §32.7, §10): `?*dyn Trait`
// is a trait object whose `none` is the niche `data == null` — same two-word
// {data, vtable} layout, no extra storage. A registry slot is `?*dyn Trait`
// initialized to `null` (absent); registering coerces a `*T` in; dispatch goes through
// `if let` / switch narrowing (you cannot dispatch a possibly-absent device). This
// replaces the parallel `present: [N]bool` flag the non-nullable `*dyn` array needed.

trait CharDevice {
    fn putc(self: *Self, b: u8) -> void;
}

struct Uart {
    base: usize,
}

impl CharDevice for Uart {
    fn putc(self: *Uart, b: u8) -> void {}
}

struct Registry {
    devs: [4]?*dyn CharDevice, // each slot: a trait object or `null` (absent)
    count: usize,
}

export fn registry_init(r: *mut Registry) -> void {
    var i: usize = 0;
    while i < 4 {
        r.devs[i] = null; // none = zero fat pointer
        i = i + 1;
    }
    r.count = 0;
}

// Register a device: the checked coercion `*Uart -> ?*dyn CharDevice` synthesizes the
// shared rodata vtable; the slot is now `some`.
export fn registry_add(r: *mut Registry, u: *Uart) -> void {
    r.devs[r.count] = u;
    r.count = r.count + 1;
}

// Dispatch only after narrowing: `if let` proves the slot is present, then the bound
// `d` is a non-null `*dyn CharDevice` dispatched through its vtable.
export fn registry_fire(r: *Registry, id: usize, b: u8) -> void {
    if let d = r.devs[id] {
        d.putc(b);
    } else {}
}

// switch narrowing is the dual: the bind arm is `some`, the wildcard is `none`.
export fn registry_count(r: *Registry) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < 4 {
        switch r.devs[i] {
            d => {
                n = n + 1;
            }
            _ => {}
        }
        i = i + 1;
    }
    return n;
}
