// kernel/core/capability — capability-based least privilege (the MINIX lesson, made
// stronger by MC's linear types). A `Cap<R>` is an *unforgeable, linear* grant of
// access to a resource R (e.g. a device's MMIO base, an IRQ line, a memory region):
//
//   - unforgeable: `cap_mint` is the only constructor — the kernel grants caps at
//     setup, so possession is the audit point;
//   - linear (`move`): a cap has exactly one owner and cannot be copied, so a process
//     without the cap simply cannot name the resource — it must ask the server that
//     holds it (via IPC). Transfer is explicit (move into a spawn or an IPC handoff).
//
// This is least privilege enforced by the type system: in MINIX the kernel checks a
// privilege table at runtime; here a driver that doesn't hold `Cap<Mmio>` can't even
// express the access.

move struct Cap<R> {
    resource: R,
}

// Grant a capability over `resource` (the kernel's setup-time primitive).
export fn cap_mint(comptime R: type, resource: R) -> Cap<R> {
    return .{ .resource = resource };
}

// Use the capability: borrow it to read the granted resource. Does not consume it.
export fn cap_resource(comptime R: type, c: *Cap<R>) -> R {
    return c.resource;
}

// Revoke the capability, consuming it (its linear end of life).
export fn cap_revoke(comptime R: type, c: Cap<R>) -> void {
    unsafe { forget_unchecked(c); } // husk: a capability owns nothing to release
}
