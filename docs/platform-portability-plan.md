# Platform portability plan

Status: **current portability roadmap**.

This file tracks the remaining work to turn the current QEMU-gated multi-architecture
prototype into a production-shaped platform. The old M1-M9 migration history has been
folded into this summary because that milestone chain is delivered. Use
[`todo.md`](todo.md) for the short repo-wide roadmap and
[`production-readiness-plan.md`](production-readiness-plan.md) for the appliance release
bar.

## 1. Scope

The platform goal is intentionally narrow:

```text
RISC-V S-mode + OpenSBI + QEMU virt first
then StarFive VisionFive 2 as the first real RISC-V board profile
with x86_64 and AArch64 kept as portability and backend parity targets
```

The project is not trying to become a broad hardware OS. Board profiles should remain
explicit, device sets should stay small, and new portability work should serve the agent
kernel target.

## 2. Current baseline

These are implemented and represented by build steps in the current tree:

| Area | Current evidence |
|---|---|
| RISC-V QEMU surrogate validation | `riscv-qemu-validation` aggregates the RISC-V QEMU/OpenSBI S-mode boot, PLIC/timer, virtio-blk/net, confined QuickJS, brokered FS/network, real TCP-backed `host_net_fetch`, and IRQ-backed production `SYS_POLL` gates across C and LLVM backends. |
| RISC-V S-mode boot and user path | OpenSBI S-mode boot, U-mode syscall/fault path, and confined QuickJS S-mode gates. |
| Architecture selection seam | `arch-emit-test` emits portable core modules under `--arch=riscv64`, `--arch=x86_64`, and `--arch=aarch64`. |
| Structured async broker ABI | `qjs-realtool-test` / `llvm-qjs-realtool-test` drive real capability-checked FS ops from pure JS over `SYS_SUBMIT` / `SYS_POLL`; `qjs-nettool-test` / `llvm-qjs-nettool-test` expose the brokered network fetch control plane through the same production JS/tool surface; `qjs-net-realtool-test` / `llvm-qjs-net-realtool-test` prove the TCP-backed transport variant with a guest HTTP fetch over virtio-net; `qjs-smode-net-irq-tool-test` / `llvm-qjs-smode-net-irq-tool-test` prove a JS `host_net_fetch` completion through production `SYS_POLL` from a real S-mode virtio-net PLIC interrupt; `qjs-smode-blk-irq-tool-test` / `llvm-qjs-smode-blk-irq-tool-test` prove a JS `host_fs_read` completion through production `SYS_POLL` from a real S-mode virtio-blk PLIC interrupt. |
| Real brokered network transport | `agent-net-real-test` / `llvm-agent-net-real-test` exercise the real TCP-backed network broker on the RISC-V reference path. |
| RISC-V S-mode interrupts | `smode-timer-test`, `smode-plic-test`, and `smode-plic-multishot-test` pass on both C and LLVM backends. |
| S-mode TLS/network stack reuse | `bearssl-smode-test` and `https-smode-test` run under OpenSBI. |
| UART driver | `uart-driver-test` / `llvm-uart-driver-test` use the FDT-discovered NS16550 driver. |
| x86_64 user/VM/device seeds | x86 user/QuickJS gates exist; `x86-timer-test` and `x86-pci-test` cover LAPIC timer and PCI/virtio discovery. |
| AArch64 user/VM/agent seeds | AArch64 EL0 user and C-backend QuickJS sync/async gates are in `m0`. |

## 3. Architecture support matrix

| Architecture | Current support | Main remaining gap |
|---|---|---|
| `riscv64` | Primary path. M-mode legacy demos and S-mode/OpenSBI demos coexist. S-mode boot, user path, QuickJS, virtio-blk/net, TLS, timer, context-aware PLIC delivery, reusable S-mode PLIC dispatch, promoted S-mode async virtio-blk / virtio-net TX/RX IRQ completion gates draining through `async_poll_many`, production JS `SYS_POLL` completion gates from real S-mode virtio-net and virtio-blk PLIC interrupts, UART, real brokered network demos, and a StarFive VisionFive 2 profile are gated or compile-checked. | VisionFive 2 boot validation, SBI HSM/IPI, and shared S-mode trap-vector work. |
| `x86_64` | Multiboot to long mode, paging, ring-3 user path, C/LLVM-backed QuickJS sync/async gates, LAPIC timer, PCI discovery, and virtio-pci handshake are gated. | Full virtio-pci data path and production broker/runtime parity. |
| `aarch64` | QEMU virt EL1/EL0 paging/user path and C/LLVM-backed QuickJS sync/async gates are gated. | GIC/timer/device depth and production broker/runtime parity. |

## 4. Portability rules

- Keep `kernel/core` free of direct architecture imports unless the file is explicitly
  architecture-scoped.
- Prefer `kernel/arch/active/...` imports for code that must compile across
  architectures.
- Every new core portability claim needs either a build gate or a narrow source-level
  check like `arch-emit-test`.
- Do not broaden driver support without a product or test target. Prefer completing the
  selected virtio, UART, timer, interrupt, and board-profile paths.
- Treat "both backends" and "all architectures" as separate claims. A gate that passes
  on C and LLVM for RISC-V does not prove x86_64 or AArch64 platform parity.

## 5. Platform abstraction boundary

The stable core/arch split should remain:

| Layer | Owns |
|---|---|
| `kernel/core` | process, scheduler, IPC, VM objects, ELF loading, capabilities, brokers, governance, provenance, and generic user-copy contracts. |
| `kernel/arch/<arch>` | trap entry, syscall entry, context switch, page-table format, interrupt enable/disable, TLB flush, and address-space activation. |
| `kernel/platform` / drivers | board discovery, UART, interrupt controller, timer source, buses, virtio transports, and device-specific MMIO. |

Architecture-specific mechanisms that still need better generic hooks:

- large-page mapping and address-space encoding for `cow.mc` / `demand.mc`;
- shared real-board hooks for interrupt-backed storage/network completion handoff;
- SBI HSM/IPI or equivalent secondary-core startup and inter-processor interrupt APIs;
- keep target-aware LLVM varargs ABI lowering covered by the promoted non-RISC-V QuickJS gates.

## 6. Test policy

`zig build m0` is the required baseline for current platform claims. `zig build
riscv-qemu-validation` is the focused board-surrogate gate for the selected RISC-V
path when VisionFive 2 hardware is unavailable. Tracking gates that exist but are
intentionally outside `m0` are not release evidence until they are fixed and promoted.

Keep these distinctions explicit:

- **Required gates:** build steps in `build/tiers.zig` under `m0`.
- **RISC-V surrogate gate:** `riscv-qemu-validation`, also declared in
  `build/tiers.zig`, aggregates the QEMU/OpenSBI evidence for the selected
  board path.
- **Tracking gates:** build steps registered in `build/qemu.zig` but not required by
  `m0`.
- **Demo-scope gates:** tests that prove a mechanism in isolation but do not make a
  production claim, such as flat S-mode PLIC demos.

## 7. Current risks

| Risk | Mitigation |
|---|---|
| Completed migration history obscures live work | Keep this file limited to current status and open items. Use git history for old phase detail. |
| CI tracking gates look like parity | Call out which gates are outside `m0` and why. |
| Device breadth grows faster than depth | Finish one selected storage/network/interrupt path before adding more devices. |
| Broker parity is confused with broker duplication | The kernel broker is already shared; remaining work is runtime/tool-surface parity on each architecture. |
| LLVM backend fixes regress RISC-V | Verify varargs changes against RISC-V QuickJS gates and the full fast corpus before promoting x86/AArch64 LLVM agent gates. |

## 12. Current execution order

This section is the authoritative platform backlog and priority order.

### Do now

1. **Bring up the selected real RISC-V board profile.**
   The first hardware target is StarFive VisionFive 2, recorded in
   `kernel/platform/starfive_visionfive2/profile.mc`. The QEMU `virt` path is strong, but
   production now needs this profile validated on real hardware: DTB identity, UART, timer,
   interrupts, storage, network, boot chain, watchdog, and soak expectations. Until that
   hardware is available, keep `zig build riscv-qemu-validation` green as the repeatable
   surrogate.

2. **Complete S-mode interrupt and device wiring.**
   Core delivery is proven: timer interrupts, single-shot PLIC delivery, and re-armed PLIC
   delivery all pass on both backends. The old C-backend "reset" blocker is resolved; it was
   an alignment bug in naked trap-vector placement and is fixed by `#[align(N)]` plus the
   4-byte default for `#[naked]`.

   Remaining work:

   - keep `blk-smode-irq-test`, `net-smode-irq-test`, `net-smode-rx-irq-test`, and their LLVM
     variants green as promoted `m0` evidence;
   - keep the IRQ-backed production agent storage/network `SYS_POLL` gates green;
   - add the SBI HSM/IPI layer for hart start/stop and inter-hart interrupts;
   - rework the shared S-mode confinement trap vector so agent execution can also take and
     resume from interrupts.

### Do next

3. **Harden the real broker family in production agent runtimes.**
   RISC-V now has real FS broker, JS `host_net_fetch`, real TCP-backed network broker demos,
   and promoted TCP-backed JS net-tool gates. Keep the x86_64/AArch64 runtime story aligned,
   then add durable policy/audit semantics, stable error/versioning rules, and isolated
   out-of-process tool transport.

4. **Keep non-RISC-V LLVM QuickJS gates promoted.**
   Required gates now include `llvm-x86-qjs-async-test`, `llvm-arm-qjs-test`, and
   `llvm-arm-qjs-async-test`.

   Current evidence: `src/lower_llvm.zig` now threads target architecture into LLVM lowering,
   emits target triples/data layouts, gives `va_list` target-specific storage for RISC-V,
   x86_64, and AArch64, and lowers AArch64 general-register/stack `va_arg` explicitly instead
   of relying on LLVM's generic `va_arg` instruction. The wrapper
   `tools/toolchain/mcc-llvm-cc.sh` infers the MC arch from `-mtriple`, so user-libc and
   QuickJS objects no longer silently use RISC-V varargs lowering when built for x86_64 or
   AArch64. These gates should stay in `m0`; future work here is regression protection, not a
   tracking-only compiler bring-up item.

### Defer

5. **Finish the x86_64 virtio-pci data path.**
   `x86-pci-test` proves PCI enumeration and the legacy virtio handshake. It does not prove a
   sector read/write through a virtqueue over PCI. Defer this unless x86_64 becomes a
   near-term product target.

6. **Add AArch64 device interrupt depth.**
   AArch64 has useful EL0/user/QuickJS coverage, but GIC/timer and virtio device depth are not
   yet at the same level as the RISC-V reference path. Defer unless AArch64 becomes a
   near-term product target.

7. **Make COW and demand paging portable only when needed.**
   `kernel/core/cow.mc` and `kernel/core/demand.mc` remain RISC-V/Sv39-oriented. Do not force
   this abstraction early; add arch-neutral large-page and address-space hooks when an
   x86_64 or AArch64 kernel path actually needs COW/demand paging.

### Policy

8. **Promote tracking gates only after they prove the full claim.**
   A tracking gate can become required only when it covers the relevant architecture,
   backend, and runtime surface. Do not use a narrow host emit check or isolated demo to
   support a production parity claim.

## 13. Completion criteria

The platform portability plan can be called complete for the first production target when:

- one real board profile is selected and documented;
- the kernel boots there in the intended privilege mode;
- timer and external interrupts work on that board;
- storage and network complete through interrupt-backed paths;
- brokered FS/network effects run through the production agent surface;
- policy/audit and watchdog/reboot evidence survive the platform path;
- `zig build m0` remains green;
- any architecture-specific exceptions are explicitly scoped and not presented as parity.

Until then, this document remains active.
