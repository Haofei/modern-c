// kernel/core/aspace — the portable handle to an architecture's MMU address-space root.
//
// An architecture's MMU address-space root, opaque to portable core. Core holds,
// passes, and stores it; only an arch backend interprets its bits (riscv64: a satp
// value; x86_64: cr3; aarch64: TTBR). Constructor-only (opaque) so core cannot
// fabricate or decode one — the encoding lives in the arch backend, never here.
//
// This is a leaf type: it has NO arch imports. The arch helper that builds one from a
// page-table root (e.g. riscv_aspace_of) lives in the arch backend and calls
// AddressSpace.from_root; portable core only threads the opaque value around and, at a
// C-FFI boundary, unwraps it to its raw u64 via AddressSpace.raw.
opaque struct AddressSpace {
    root: u64,
}

impl AddressSpace {
    // Mint an address-space handle from an arch-encoded root word. The only construction
    // path (opaque), so the arch encoding is the only thing that can produce one.
    fn from_root(root: u64) -> AddressSpace {
        return .{ .root = root };
    }
    // Unwrap to the raw arch-encoded root word — for crossing a C-FFI/arch boundary only.
    fn raw(a: AddressSpace) -> u64 {
        return a.root;
    }
    // The "share the kernel map" handle (root 0): a process with this handle runs in the
    // kernel's address space rather than a private one.
    fn kernel() -> AddressSpace {
        return .{ .root = 0 };
    }
    // True iff this handle shares the kernel map (root 0).
    fn is_kernel(a: AddressSpace) -> bool {
        return a.root == 0;
    }
}
