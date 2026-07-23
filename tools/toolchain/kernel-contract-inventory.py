#!/usr/bin/env python3
"""Fail closed if the bounded kernel region/effect/FFI contract surface drifts."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

REQUIRED = {
    "src/mir_model.zig": (
        "ffi_param_contracts: []FfiParamContract",
        "is_extern: bool",
        "c_abi: bool",
    ),
    "src/mir.zig": (
        "fn buildFfiParamContracts(",
        "mir ffi_param_contract",
        "provenance=extern_unknown",
        ".extent = .extern_contract",
        "stable_until=call_return",
        'std.mem.eql(u8, name.text, "DmaAddr")',
    ),
    "src/mir_tests.zig": (
        'test "MIR dump exposes bounded FFI parameter contracts"',
        "nonnull=false access=read",
        "kind=slice nonnull=when_nonempty",
    ),
    "tests/spec/lock_guards_data.mc": (
        "reject_guarded_pointer_after_release",
        "E_USE_AFTER_MOVE",
    ),
    "tests/spec/kernel_region_tokens.mc": (
        "reject_rcu_reference_escape",
        "reject_callback_data_after_unregister",
        "reject_leaked_registration",
    ),
    "tests/spec/irq_atomic_context.mc": (
        "E_SLEEP_IN_ATOMIC",
        "E_IRQ_CONTEXT_CALL",
    ),
    "docs/kernel-region-and-ffi-contracts.md": (
        "qualified bounded kernel profile",
        "not a general borrow checker",
        "Machine-readable FFI metadata",
        "facts may not persist",
    ),
    "docs/virtio-rng-comparison-evidence.md": (
        "negative evidence for K2",
        "K2 remains unsatisfied",
        "run-contract-mutations.sh",
    ),
}


def main() -> int:
    missing: list[str] = []
    for relative, anchors in REQUIRED.items():
        path = ROOT / relative
        if not path.is_file():
            missing.append(f"missing file: {relative}")
            continue
        text = path.read_text(encoding="utf-8")
        for anchor in anchors:
            if anchor not in text:
                missing.append(f"{relative}: missing {anchor!r}")
    if missing:
        for item in missing:
            print(f"FAIL: kernel-contract-inventory - {item}", file=sys.stderr)
        return 1
    print("PASS: kernel-contract-inventory - region/effect/FFI boundary is anchored")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
