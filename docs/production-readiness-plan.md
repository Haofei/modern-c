# Kernel validation workload plan

Status: **language-validation workload document**.

This file keeps its historical name for link stability. It does not define a
kernel product roadmap, secure-update plan, hardware qualification plan, or
release-readiness bar.

The kernel exists in this repository to exercise Modern C under low-level
conditions that ordinary compiler fixtures do not cover:

- freestanding startup and linker boundaries;
- C/LLVM backend parity;
- syscall and user/kernel ABI boundaries;
- ownership/drop behavior around handles, mappings, pages, locks, and tokens;
- raw pointer, MMIO, interrupt, and unsafe boundary checks;
- async submit/poll paths;
- QEMU/OpenSBI boot and driver smoke coverage.

## Current scope

The retained kernel validation target is intentionally narrow:

```text
QEMU/OpenSBI first
+ selected RISC-V board metadata as an FDT/resource-discovery fixture
+ small fixed CPU/interrupt/device classes required by tests
+ narrow syscall ABI
+ brokered FS/network/tool effect fixtures
+ storage persistence only where required by retained demos
+ watchdog/recovery smoke coverage where it exposes language/backend behavior
```

The StarFive VisionFive 2 files under
`kernel/platform/starfive_visionfive2/` are metadata fixtures. They document
expected FDT resources and keep the adapter path honest through QEMU surrogate
tests. They are not a hardware release target.

## Validation levels

| Level | Meaning | Required evidence |
|---|---|---|
| K0: QEMU smoke workload | Kernel fixtures compile and run under retained QEMU paths | Existing `m0` / QEMU gates |
| K1: language stress workload | Kernel fixtures exercise ownership, ABI, MMIO, user-copy, async, syscall, and backend boundaries | Deterministic C/LLVM gates and focused QEMU tests |
| K2: optional board metadata fixture | A board profile documents FDT/resource expectations without becoming a product claim | Profile parser/adapters and QEMU surrogate gates |

No calendar maturity ladder is maintained here. Product pilots, operations,
secure-update policy, release images, and hardware qualification belong in a
separate product profile if one is ever created.

## In scope

- Keep QEMU/OpenSBI validation green.
- Keep the narrow syscall, broker, async, virtio, UART, FDT, interrupt, and
  user-copy fixtures useful for compiler/language validation.
- Add kernel tests when they expose language, MIR, ownership, backend, ABI, or
  unsafe-boundary defects.
- Keep C and LLVM backend evidence separate from architecture evidence.
- Keep product-scope wording out of kernel docs unless it is explicitly marked
  outside current scope.

## Out of scope

- Linux/POSIX compatibility.
- Broad desktop/server workloads.
- General hardware support.
- Outside current scope: product broker/runtime parity.
- Outside current scope: product observability, replay, or fleet operations.
- Outside current scope: kernel OTA/live-update.
- Outside current scope: signed images or signed bundles.
- Outside current scope: secure boot, verified boot, anti-rollback, or recovery-slot policy.
- Outside current scope: real-board soak or release qualification.

## Current evidence anchors

- `zig build m0-full` remains the broad current-subset validation target.
- `zig build riscv-qemu-validation` aggregates retained RISC-V QEMU/OpenSBI
  evidence.
- `visionfive2-readiness-test` and `llvm-visionfive2-readiness-test` validate
  the retained board metadata adapter against QEMU surrogate input.
- `kernel-scope-inventory-test` rejects reintroduced kernel product-scope
  wording unless the line clearly marks it outside current scope.

## Completion criteria for this document

This validation workload is complete when:

- retained QEMU/OpenSBI kernel gates stay green;
- the optional board metadata fixture remains documented and tested without
  becoming a release claim;
- storage/network/interrupt/user-copy/syscall fixtures continue to expose
  language and backend bugs;
- product operations and hardware qualification stay outside this repository's
  current kernel scope.

Until those conditions are enforced by gates, this document remains active.
