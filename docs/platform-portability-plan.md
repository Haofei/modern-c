# Plan: S-mode RISC-V platform and multi-architecture kernel support

Status: **milestone chain M1–M9 delivered** (see *Implementation status* below), plus
several §12 follow-ups since landed (R0b arch seam, M5b vector-poll + real broker, x86
X4/X5 devices, S-mode timer interrupts, TLS-under-S-mode, the UART driver). This was the
concrete path from the original RISC-V M-mode/QEMU kernel and agent prototype to a portable
OS substrate; it is implemented and Docker-gated across three architectures. **§12 is the
authoritative list of what is done vs. still open.**

```
RV64GC + S-mode + OpenSBI + QEMU virt + Sv39 + virtio
then x86_64 and AArch64 QEMU targets
then real board ports
```

The QuickJS agent work remains valid. The platform work below changes the layer below it:
boot, privilege mode, traps, timers, interrupts, device discovery, and device drivers.

## Implementation status (milestone chain M1–M9 + R0b + M5b + x86/S-mode device layer)

The §10 milestone chain is delivered and Docker-gated, and several §12 follow-ups have since
landed (R0b arch seam, M5b vector-poll + real broker, x86 X4/X5 devices, S-mode timer
interrupts, TLS-under-S-mode, the UART driver). **§12 is the authoritative remaining-work
list** — consult it for what is done vs. open. Each item below corresponds to a gate in
`build.zig`. The phase sections further down (§3–§7) describe the original design; read them
as the rationale for code that now exists, not as outstanding work.

**Implemented and gated:**

- RISC-V S-mode under real OpenSBI: FDT `/memory` + device discovery (`kernel/core/fdt.mc`,
  `kernel/core/bootinfo.mc`), supervisor trap path, `SYS_WRITE` + bad-pointer `-E_FAULT`
  U-mode hello (`kernel/arch/riscv64/smode_user_runtime.c`), confined QuickJS agent
  sync+async (`qjs_smode_confined_runtime.c`), virtio-blk and virtio-net revalidated under
  OpenSBI (`blk_smode_runtime.c`, `net_smode_runtime.c`).
- x86_64 multiboot→long mode: 4-level paging (`kernel/arch/x86_64/paging.mc`), ring-3 user
  hello + `-E_FAULT` (`user_runtime.c`), confined QuickJS agent (`qjs_user_runtime.c`).
- AArch64 EL1/EL0: stage-1 4 KB paging (`kernel/arch/aarch64/paging.mc`), EL0 user hello +
  `-E_FAULT` (`user_runtime.c`), confined QuickJS agent (`qjs_user_runtime.c`).
- The confined QuickJS agent runs on all three architectures with one identical syscall ABI
  and the same confinement model (kernel is mapped but supervisor/privileged-only — no user
  PTE permission — so it is not user-accessible).
- Structured broker ABI **(M5 + M5b, delivered):** `SYS_SUBMIT(req_ptr)` +
  `SYS_POLL(events_ptr, max, timeout)` (vector drain) carry real `ToolReq`/`ToolEvent`
  structs (copy-in/out + size validation), Promise-based in JS. Both the mock smoke ops AND a
  REAL capability-checked FS op family (`agent_fs_call`: allowlist→budget→path-cap, audited)
  run end-to-end from pure JS — `qjs-realtool-test` (`fs: read=hi`, `fs: mkdir denied
  EDENIED`).
- **Arch-selection seam (R0b, delivered):** a compiler `--arch` flag resolves
  `kernel/arch/active/...` imports; one generic `elf_loader.mc`/`uaccess_pt.mc` serve all
  three arches (per-arch PTE bits via each paging module's `pte_flags_for_user` hook); core
  no longer hard-imports `kernel/arch/riscv64`. `arch-emit-test` machine-checks portability.
  Plus opaque `AddressSpace`, arch-neutral `panic_trap`, `BootInfo`.
- **x86 device layer (X4/X5):** real LAPIC timer interrupts (`x86-timer-test`, PIC-masked)
  and PCI-CAM enumeration → virtio-blk-pci discovery + legacy handshake (`x86-pci-test`).
- **S-mode interrupts:** real S-mode timer-interrupt delivery under OpenSBI via the SBI TIME
  extension (`smode-timer-test`).
- **TLS under S-mode:** BearSSL SHA-256 + a full TLS 1.2 handshake with cert-chain validation
  under real OpenSBI (`bearssl-smode-test`, `https-smode-test`).
- **First-class UART driver:** FDT-discovered, LSR-polled NS16550 (`uart-driver-test`).
- A genuine compiler fix landed: `va_list` argument copy emits `__builtin_va_copy`
  (`src/lower_c.zig`), required by the x86-64 SysV array-typed `va_list` (the C backend; the
  analogous LLVM-backend fix is open — §12 item 3).

**Known-incomplete / open (see §12 for the authoritative list):**

- Three LLVM-backend tracking gates (`llvm-x86-qjs-async-test`, `llvm-arm-qjs-test`,
  `llvm-arm-qjs-async-test`) — **root-caused** (RISC-V-only `va_list`/`va_arg` model in
  `emit-llvm`; garbage across the QuickJS FFI on x86/arm) but the target-aware varargs fix is
  not yet landed (§12 item 3). C backend passes on all three arches; LLVM passes fully on
  RISC-V.
- The agent async broker is still duplicated 3× across the arch fixtures; the real FS op
  family + `net_fetch` are wired on the RISC-V reference path only.
- Device depth: the full virtio-pci data path (virtqueue sector read over PCI) on x86; and on
  RISC-V S-mode the PLIC external-interrupt path, SBI HSM/IPI, and the shared `s_trap_vector`
  SPP/nested-trap rework (the timer-interrupt core is done).
- `cow.mc`/`demand.mc` remain RISC-V-only (deferred until an x86/ARM kernel needs them).

## 0. Current implementation snapshot

The current codebase is best understood as a **working RISC-V M-mode/QEMU kernel** with
strong agent-sandbox substrate. It is not a thin blank slate. The main missing piece is the
privilege/platform migration to a normal S-mode kernel under OpenSBI.

Already present:

- U-mode entry/exit exists.
- Syscalls from U-mode into the kernel exist.
- Sv39 page tables and isolated user address spaces exist.
- The kernel is intentionally not user-accessible from the agent address space (mapped
  supervisor/privileged-only — no user PTE permission).
- User buffers go through page-table-aware `copy_from_user_pt` / `copy_to_user_pt`.
- A real multi-segment ELF loader exists for confined user apps.
- QuickJS can be built freestanding and run as a confined U-mode ELF.
- A fixed C host can load pure JavaScript through `SYS_READ`.
- JS can call `print(...)` and `host_async(...)`.
- `host_async(...)` maps to the original toy `SYS_SUBMIT` / `SYS_POLL` path (since replaced
  by the structured single-event ABI — see *Implementation status*).
- `kernel/core/`, `kernel/arch/riscv64/`, `kernel/platform/qemu_virt/`, and driver
  directories already provide a partial core/arch/platform split.
- `kernel/core/fdt.mc` already provides FDT parsing primitives.
- `kernel/drivers/virtio/virtio_blk.mc` and `kernel/drivers/virtio/virtio_net.mc` already
  exist, along with virtio RNG support.
- `kernel/net/` already contains Ethernet/ARP/IPv4/ICMP/UDP/TCP/DNS pieces, and BearSSL
  is used for TLS-oriented demos.
- `kernel/drivers/pci.mc`, `kernel/drivers/e1000.mc`, PLIC, CLINT, and QEMU-oriented
  virtio drivers exist.
- `kernel/arch/x86_64/` contains boot/context scaffolding. `kernel/arch/aarch64/` has a
  minimal boot runtime stub. These are not full ports, but they are not zero.
- Multi-hart/SMP-related pieces exist in demo form (`hart.mc`, SMP runtimes,
  `tlb_shootdown.mc`, IPI runtime).

> **Note (historical):** the snapshot above and the list below describe the *starting
> point* before the M1–M9 milestone chain. Several items are now done — see *Implementation
> status* above for the current state. Kept here as the design's point of departure.

What was **not** present at the start, and where it stands now:

- ~~A full S-mode kernel entry under OpenSBI.~~ **Done** (S-mode boot, traps, U-mode hello).
- A general SBI wrapper layer for timer, reset, IPI/HSM, and firmware services — partial
  (console + shutdown + `rdtime`; full HSM/IPI layer still pending).
- ~~Integrated supervisor trap handling for the U-mode syscall/fault path.~~ **Done.**
- ~~FDT-driven S-mode boot memory/device discovery.~~ **Done** (`fdt.mc` + `BootInfo`).
- S-mode PLIC/ACLINT/SBI-timer integration for the interrupt/timer model — partial
  (timer via `rdtime`; PLIC interrupt integration still pending).
- ~~Revalidation of virtio-blk and virtio-net under S-mode.~~ **Done** (network-stack TLS
  gates not yet re-run under S-mode).
- x86_64 and AArch64 user-mode/VM/QuickJS parity — **done at the user/VM/agent level**;
  device-level interrupts (APIC) and virtio-pci still pending on x86.
- A finished architecture-neutral boundary — **done** (opaque `AddressSpace`, neutral
  `panic_trap`, `BootInfo`, and the R0b `--arch` seam: generic `elf_loader`/`uaccess_pt`,
  core no longer hard-imports `kernel/arch/riscv64`).

## 1. Target architecture

### 1.1 RISC-V target

Initial real platform target:

```
CPU:        RV64GC
Firmware:   OpenSBI in M-mode
Kernel:     S-mode
Agents:     U-mode
VM:         Sv39
Machine:    QEMU virt first
Devices:    UART, PLIC, SBI timer, virtio-mmio blk/net
Later:      real board port
```

Boot chain:

```
QEMU / hardware
  -> OpenSBI, M-mode
      -> kernel, S-mode
          -> user apps / QuickJS agent, U-mode
```

M-mode should become firmware territory. The kernel should not own machine traps, machine
timer CSRs, or machine interrupt routing in the final RISC-V platform.

### 1.2 Multi-architecture target

Long-term QEMU-supported matrix:

| Architecture | First platform | Kernel mode | Firmware/interface | Interrupts | Devices |
|---|---|---|---|---|---|
| riscv64 | QEMU `virt` | S-mode | OpenSBI + FDT | PLIC + SBI timer | virtio-mmio |
| x86_64 | QEMU `q35` or `pc` | long mode ring 0 | Limine/UEFI or Multiboot2 + ACPI | APIC/x2APIC | PCI + virtio-pci |
| aarch64 | QEMU `virt` | EL1 | PSCI + FDT/UEFI | GICv3 | virtio-mmio or virtio-pci |

The agent ABI should be identical on all targets:

```
syscall number + fixed register arguments -> isize return
negative values are -errno
```

Only the architecture trap entry changes.

### 1.3 Migration safety rule

The current M-mode/QEMU target is the working system. Keep it green while S-mode lands.
Until the S-mode path reaches QuickJS-agent parity, every platform phase must preserve:

- existing M-mode QEMU gates,
- existing QuickJS confined-agent gates,
- existing driver/network gates,
- existing emit-c / emit-llvm parity.

S-mode is an additional target during the migration, not a flag day replacement.

## 2. Core design rule

Split the system into two layers:

```
kernel/core
  scheduler, VM objects, ELF loader, syscall ABI, VFS, broker, agent runtime,
  capability checks, audit, generic virtio core

kernel/arch + kernel/platform
  boot, trap entry, context switch, page-table format, CSR/register details,
  interrupt controller, timer source, device discovery, early console
```

`kernel/core` must not know about:

- RISC-V `satp`, `sstatus`, `stvec`, `scause`, `sepc`, PLIC, SBI.
- x86_64 `cr3`, IDT, GDT, MSRs, APIC, ACPI.
- AArch64 `TTBR`, `TCR`, `MAIR`, `SCTLR`, `VBAR`, `ESR`, GIC.

The core should speak in generic concepts:

- `AddressSpace`
- `VmFlags`
- `TrapFrame`
- `ThreadContext`
- `IrqLine`
- `ClockDeadline`
- `BootInfo`
- `Device`
- `UserCopy`

## 3. Platform abstraction contracts

### 3.1 BootInfo

Every architecture should normalize firmware input into one structure:

```
BootInfo {
  memory_map
  kernel_image_range
  initrd_or_modules
  fdt_pointer
  acpi_pointer
  command_line
  boot_cpu_id
  cpu_count
  platform_name
}
```

RISC-V and AArch64 QEMU `virt` can populate this from FDT. x86_64 can populate it from
Limine/UEFI/Multiboot2 and ACPI.

Acceptance:

- Kernel can print parsed memory ranges.
- Kernel can identify usable RAM without hardcoded ranges.
- Kernel can find console and virtio devices from firmware tables.

### 3.2 ArchOps

Minimum architecture API:

```
arch_early_init(boot_info)
arch_trap_init()
arch_irq_enable()
arch_irq_disable()
arch_wait_for_interrupt()
arch_current_cpu()
arch_enter_user(user_entry, user_sp, address_space)
arch_context_switch(old, new)
arch_start_secondary(cpu_id, entry, stack)   // optional after single-hart S-mode works
arch_tlb_flush_all()
arch_tlb_flush_addr(address_space, va)
arch_shutdown_or_reboot()
```

Trap entry must normalize into:

```
Trap {
  kind: syscall | page_fault | illegal_instruction | timer | external_irq | unknown
  user_pc
  fault_addr
  syscall_number
  args[6]
  raw_cause
}
```

The syscall dispatcher should not care whether the trap came from RISC-V `ecall`, x86_64
`syscall`, or AArch64 `svc`.

Initial S-mode migration scope is **single-hart**. Existing M-mode SMP/IPI/TLB-shootdown
demos must remain green, but S-mode secondary-hart bring-up can follow after the S-mode
user/agent path works. When enabled, RISC-V should use SBI HSM for secondary harts; AArch64
should use PSCI `CPU_ON`.

### 3.3 VM interface

Core VM flags:

```
VM_READ
VM_WRITE
VM_EXEC
VM_USER
VM_GLOBAL
VM_DEVICE
VM_UNCACHED
```

Architecture backends translate these to hardware PTE bits:

- RISC-V: `V/R/W/X/U/G/A/D` under Sv39/Sv48.
- x86_64: `P/RW/US/NX/G/PCD/PWT` under 4-level or 5-level paging.
- AArch64: AP bits, UXN/PXN, AttrIndx, SH, AF under TTBR/TCR/MAIR.

Minimum VM API:

```
vm_space_new()
vm_map(space, va, pa, len, flags)
vm_unmap(space, va, len)
vm_translate(space, va)
vm_is_mapped(space, va)
vm_activate(space)
vm_destroy(space)
```

RISC-V already has useful Sv39 pieces. The work is to wrap them behind a portable VM
contract instead of letting core call RISC-V-specific page-table functions directly.

### 3.4 User copy

Keep the existing design principle:

- Never dereference user pointers directly in kernel code.
- Resolve every user pointer through the target address space.
- Return `-E_FAULT` on bad user memory.

Generic contract:

```
copy_from_user(space, kernel_dst, user_src, len) -> Result
copy_to_user(space, user_dst, kernel_src, len) -> Result
copy_string_from_user(space, user_src, max_len) -> Result
```

RISC-V can initially keep the current page-table-walk implementation. x86_64 and AArch64
can implement equivalent software page walks or temporary safe mappings.

## 4. RISC-V S-mode migration plan

### Phase R0: prepare boundaries in current code

Goal: make the existing mostly-separated M-mode code easier to port without changing
behavior. This is targeted cleanup, not a greenfield split.

Tasks:

- Move any remaining direct RISC-V CSR/trap concepts behind `kernel/arch/riscv64`.
- Replace architecture-specific trap naming in core APIs with normalized names. Concrete
  example: `kernel/core/panic.mc` exposes `panic_trap(mcause, mepc, mtval)`, which should
  become a generic trap report (`cause`, `pc`, `fault_addr`) before S-mode/x86/AArch64 use
  the same path.
- Keep `kernel/core` free of `mstatus`, `mtvec`, `mcause`, `mepc`, `satp`, PLIC, SBI,
  `cr3`, APIC, GIC, and TTBR concepts.
- Define `BootInfo`, `Trap`, `VmFlags`, and syscall argument structs.
- Keep current QEMU tests passing.

Acceptance:

- No direct `mstatus`, `mtvec`, `mcause`, `mepc`, `mtval`, `satp`, or PLIC references from
  architecture-independent core code or core API names.
- Existing QuickJS confined tests still build.

### Phase R1: OpenSBI S-mode boot

Goal: grow the existing SBI boot smoke path into a real S-mode kernel entry under OpenSBI
on QEMU `virt`.

Tasks:

- Reuse or replace the current `sbi_boot_runtime.c` smoke path with the real kernel entry.
- Accept OpenSBI-provided boot hart id and FDT pointer.
- Set up early stack.
- Add a reusable SBI call wrapper:

```
sbi_call(ext, fid, arg0..arg5)
sbi_console_putchar()       // early only, if available
sbi_set_timer()
sbi_system_reset()
```

- Print a boot banner through SBI console or UART.

Acceptance:

- `qemu-system-riscv64 -machine virt -bios default -kernel kernel.elf` reaches S-mode
  kernel code.
- Kernel prints hart id, FDT pointer, and memory summary.
- Existing M-mode boot gates remain green.

### Phase R2: supervisor traps

Goal: replace M-mode trap assumptions with S-mode trap handling.

Tasks:

- Install `stvec`.
- Handle `ecall from U-mode`.
- Handle illegal instruction and page fault traps.
- Preserve/restore user registers in a supervisor trap frame.
- Return syscall values in the correct user return register.
- Advance `sepc` after syscalls.

Acceptance:

- A tiny U-mode hello app can call `SYS_WRITE`.
- Bad user pointers return `-E_FAULT`, not a kernel trap.
- Illegal user instruction terminates only the user task.

### Phase R3: Sv39 kernel/user mapping

Goal: run kernel and user spaces with a clean Sv39 model in S-mode.

Tasks:

- Build kernel address-space mapping.
- Map kernel text read/execute, rodata read-only, data/bss read/write.
- Map MMIO regions as device memory.
- Keep user address spaces separate.
- Ensure kernel is not mapped into user page tables unless deliberately using a trampoline,
  and if a trampoline exists, keep it minimal and non-writable.
- Add `sfence.vma` paths behind `arch_tlb_flush_*`.
- Add `page_table_try_new()` or equivalent so root page-table allocation can fail with a
  typed error on hostile/low-memory paths.

Acceptance:

- Kernel runs with paging enabled.
- U-mode app runs in its own page table.
- Kernel-not-user-accessible confinement check passes (supervisor-only, no user PTE).

### Phase R4: timer and interrupts

Goal: add scheduler-ready timer and external interrupt handling.

Tasks:

- Use SBI timer for supervisor timer events.
- Add supervisor external interrupt path.
- Add PLIC driver for QEMU `virt`.
- Route UART/virtio interrupts through PLIC.
- Keep a polling fallback for early bring-up.

Acceptance:

- Periodic timer interrupt fires in S-mode.
- External interrupt can be acknowledged/complete through PLIC.
- A timer-driven yield demo works under S-mode.

### Phase R5: FDT and platform discovery

Goal: wire the existing FDT parser into the S-mode boot path and remove hardcoded QEMU
memory/device addresses from that path.

Tasks:

- Extend/use `kernel/core/fdt.mc`.
- Parse `/memory`.
- Parse `/chosen`.
- Discover UART.
- Discover PLIC.
- Discover virtio-mmio nodes.
- Build a platform device list.

Acceptance:

- Kernel can boot with memory/device addresses taken from FDT.
- Device list is printed at boot.

### Phase R6: UART console

Goal: replace SBI console dependency for normal operation.

Tasks:

- Add NS16550A UART driver for QEMU `virt`.
- Support polling output first.
- Add interrupt-driven input later if needed.
- Keep SBI console as early fallback only.

Acceptance:

- Kernel console works through UART.
- Panic path can print after normal console initialization.

### Phase R7: virtio-mmio core

Goal: port and revalidate the existing virtio transport/device code under the S-mode
interrupt, FDT, and DMA path.

Tasks:

- Discover virtio-mmio devices from FDT.
- Reuse the existing virtio initialization, feature negotiation, descriptor rings, and
  used/available ring handling where possible.
- Keep polling mode as the first S-mode validation path.
- Add interrupt mode once the S-mode PLIC path is stable.
- Keep the M-mode virtio gates green while adding S-mode equivalents.

Acceptance:

- Existing virtio smoke/self-tests pass under the S-mode target.
- Existing M-mode virtio gates still pass.

### Phase R8: virtio-blk

Goal: revalidate the existing virtio-blk driver under S-mode and then use it for script
ingress, logs, and future FS work.

Tasks:

- Reuse `kernel/drivers/virtio/virtio_blk.mc`.
- Revalidate read/write sector requests under S-mode.
- Keep the synchronous block API first.
- Add async request completion later.
- Add simple smoke test reading a known sector.

Acceptance:

- Kernel reads a block from QEMU virtio-blk under S-mode.
- A staged agent script can come from a block-backed source instead of a compiled array.
- Existing M-mode block gates still pass.

### Phase R9: virtio-net

Goal: revalidate existing virtio-net and `kernel/net/` under S-mode as the transport for
future brokered `net_fetch`.

Tasks:

- Reuse `kernel/drivers/virtio/virtio_net.mc` for TX/RX.
- Reuse `kernel/net/` for Ethernet, ARP, IPv4, UDP, TCP, DNS, and broker integration.
- Swap only the bottom driver/interrupt/timer path where possible.
- Start with polling under S-mode, then move to interrupt/completion driven operation.

Acceptance:

- Kernel sends and receives basic packets under QEMU.
- Existing network-stack gates can run over the S-mode virtio-net path.
- Brokered network tests can use virtio-net instead of a mock path.
- Existing M-mode network gates still pass.

### Phase R10: port QuickJS agent to S-mode substrate

Goal: run the existing confined QuickJS agent unchanged at the JS/syscall level.

Tasks:

- Reuse ELF loader.
- Reuse user address-space setup.
- Reuse `SYS_READ`, `SYS_WRITE`, `SYS_SUBMIT`, `SYS_POLL`.
- Move trap entry from M-mode user trap to S-mode user trap.
- Keep the fixed C host and pure JS agent unchanged where possible.

Acceptance:

- `qjs-agent-test` equivalent passes on S-mode/OpenSBI.
- `qjs-async-agent-test` equivalent passes on S-mode/OpenSBI.
- Kernel remains not user-accessible from the agent (supervisor-only, no user PTE).

## 5. Agent runtime evolution on the real platform

The current async syscall path is a mechanism test. The production-shaped version should
be request/event based.

> **Status:** the broker/policy/audit/capability substrates referenced by phases A1/A2
> already exist (`kernel/fs/agent_fs.mc`, `kernel/agent/mcp.mc`, `kernel/core/policy.mc`,
> `kernel/net/net_broker.mc`). **A1 (brokered FS/tools) seed is delivered:** a pure-JS agent
> already drives real FS ops through `agent_fs_call` over the structured async ABI
> (`qjs-realtool-test`; see the gate notes above). **Still pending:** A2 — making
> **`net_fetch` completion-driven** over the same ABI (today's transport is blocking
> poll-mode) — and **native tool-catalog breadth** (`grep/find/edit/exec`). That remaining
> work is adapting the existing code to the structured request/event ABI, not building it
> from scratch.

### Phase A0: structured async ABI — **delivered (single-event)**

Replaced toy `SYS_SUBMIT(op, arg)` with request structs (`ToolReq`/`ToolEvent`, copy-in/out
+ size validation):

```
SYS_SUBMIT(req_ptr) -> handle | -errno
SYS_POLL(ev_ptr)    -> 1 (delivered) | 0 (none) | -E_FAULT   # one completion per call
```

### Phase A0b: vector poll + timeout — **delivered (= M5b)**

The draining form is implemented on top of the single-event ABI:

```
SYS_POLL(events_ptr, max, timeout) -> count delivered (0..max) | -E_FAULT
```

Request structs (the actual fields — see `user/abi.mc`; the C host mirrors them byte-for-byte):

```
ToolReq {            ToolEvent {
  op:      u32          id:       u64   // request id this completes
  flags:   u32          status:   i32   // 0 | -errno
  arg:     u64          result:   i32   // scalar result
  in_ptr:  u64          out_len:  u32   // result-payload bytes written to out_ptr
  in_len:  u32          reserved: u32
  out_cap: u32        }
  out_ptr: u64
}
```

Rules:

- Submit snapshot-copies the `ToolReq` and all `in_ptr`/`in_len` request data into
  kernel-owned bounded buffers (`<= MAX_REQ_BYTES`), so the request is TOCTOU-safe.
- The kernel never dereferences a user pointer it holds. It may RETAIN `out_ptr` (and
  `out_cap`) as **opaque data** — an output address to deliver the result to later — but it is
  validated per-page through the agent's page table and copied via `copy_to_user_pt` at POLL
  time, never trusted or touched at submit time.
- Poll copies the result payload (`<= out_cap`) to `out_ptr` and the `ToolEvent` metadata into
  poll-time-validated user buffers; a copy fault keeps the completion (it is re-deliverable).
- Bad user pointer returns `-E_FAULT`; full queue returns `-E_AGAIN`; policy denial returns
  `-E_DENIED`.

### Phase A1: brokered tools

Tasks (adapt existing substrate — `kernel/agent/mcp.mc`, `policy.mc`, `agent_fs.mc` — to the
structured async ABI; do not rebuild):

- Wire the existing mock deterministic tool broker to the `SYS_SUBMIT`/`SYS_POLL` path.
- Apply the existing allow/deny policy at submit time.
- Emit an audit event per submitted request and completion.
- Enforce per-agent quotas:
  - max in-flight requests
  - max request bytes
  - max result bytes
  - max CPU/event-loop ticks

Acceptance:

- JS can call `tool(name, input)` and receive a Promise.
- Denied tools reject with a structured JS error.
- Audit log records allow/deny/complete.

### Phase A2: brokered network fetch

Tasks (route through the existing `kernel/net/net_broker.mc` + `NetCap`, not a new stack):

- Expose the existing `net_fetch` broker as a structured-ABI operation.
- Do not expose raw sockets to JS by default.
- Enforce destination policy through `NetCap`.
- Attribute all network events to agent id.
- Use virtio-net backend once available.

Acceptance:

- JS can perform an allowed fetch.
- Disallowed destination rejects.
- Audit log contains request metadata and result status.

### Phase A3: script ingress

Progression:

1. Kernel-staged JS buffer through `SYS_READ`.
2. Read-only capability FS path.
3. Block-backed script store through virtio-blk.

Acceptance:

- Fixed C host remains unchanged.
- Changing agent JS does not require changing host C.
- Script source is covered by capabilities/audit in the long-term path.

## 6. x86_64 support plan

> **Status:** the user/VM/agent path is **implemented** via multiboot→long mode (4-level
> paging, ring-3 hello + `-E_FAULT`, confined QuickJS agent). The boot protocol below
> proposes Limine; the shipped path uses multiboot. Device-level X4/X5 (APIC, virtio-pci)
> remain. Read the phases as design rationale.

### Phase X0: choose boot protocol

Recommended: Limine first, Multiboot2 as optional later.

Tasks:

- Add x86_64 cross build target.
- Add Limine boot files and linker script.
- Normalize Limine memory map/modules into `BootInfo`.

Acceptance:

- QEMU x86_64 boots kernel and prints through early console.

### Phase X1: long mode platform

Tasks:

- Set up GDT/TSS if bootloader does not provide final layout.
- Install IDT.
- Add exception handlers.
- Add basic serial console.
- Add panic backtrace if practical.

Acceptance:

- Divide-by-zero/invalid-op/page-fault exceptions are handled and reported.

### Phase X2: x86_64 VM

Tasks:

- Implement 4-level page table backend.
- Map kernel high-half or chosen direct-map layout.
- Implement `vm_map`, `vm_unmap`, `vm_translate`.
- Implement TLB flush with `invlpg` / CR3 reload.

Acceptance:

- Kernel runs with its own x86_64 page tables.
- A software page-table walk can support user-copy validation.

### Phase X3: syscall/user mode

Tasks:

- Enter ring 3 with an initial user app.
- Add syscall entry via `syscall/sysret` or `int 0x80` first for simplicity.
- Normalize syscall args into the shared dispatcher.
- Add user pointer validation.

Acceptance:

- Same user hello app syscall ABI works on x86_64.
- Bad user pointer returns `-E_FAULT`.

### Phase X4: interrupts and time

Tasks:

- Add local APIC or x2APIC.
- Add timer source: APIC timer, HPET, or PIT initially.
- Parse ACPI MADT.
- Add interrupt routing.

Acceptance:

- Periodic timer interrupt works.
- Scheduler tick works.

### Phase X5: PCI and virtio-pci

Tasks:

- Parse PCI ECAM via ACPI MCFG or use legacy config IO for QEMU first.
- Enumerate virtio-pci devices.
- Implement virtio PCI transport.
- Reuse generic virtqueue and blk/net drivers.

Acceptance:

- virtio-blk works on x86_64 through virtio-pci.
- virtio-net works on x86_64 through virtio-pci.

### Phase X6: QuickJS agent

Tasks:

- Build freestanding QuickJS for x86_64 user mode.
- Reuse same host C and JS.
- Reuse syscall ABI.

Acceptance:

- Pure JS agent test passes on x86_64 QEMU.

## 7. AArch64 support plan

> **Status:** the user/VM/agent path is **implemented** on QEMU virt — stage-1 4 KB paging
> + MMU enable, EL0 hello + `-E_FAULT`, confined QuickJS agent. Read the phases as design
> rationale for the shipped code.

### Phase ARM0: QEMU virt boot

Tasks:

- Add AArch64 cross build target.
- Boot at EL1 under QEMU `virt`, or transition to EL1 if entered higher.
- Accept FDT pointer.
- Add early console.

Acceptance:

- Kernel boots on `qemu-system-aarch64 -machine virt`.
- Kernel prints FDT and memory summary.

### Phase ARM1: EL1 traps

Tasks:

- Set `VBAR_EL1`.
- Handle sync exceptions, IRQ, SVC.
- Normalize trap frame into shared `Trap`.
- Add PSCI calls for reset/shutdown and later SMP.

Acceptance:

- User SVC reaches shared syscall dispatcher.
- Faulting user program does not kill kernel.

### Phase ARM2: AArch64 VM

Tasks:

- Configure `TCR_EL1`, `MAIR_EL1`, `SCTLR_EL1`.
- Implement TTBR0/TTBR1 split or a simpler first-stage layout.
- Implement PTE backend for `VmFlags`.
- Implement TLB invalidation.

Acceptance:

- Kernel runs with MMU enabled.
- User app runs in separate address space.
- User-copy validation works.

### Phase ARM3: GICv3 and timer

Tasks:

- Add architectural timer.
- Add GICv3 distributor/redistributor setup.
- Route virtio interrupts.

Acceptance:

- Timer tick works.
- External IRQ from virtio device is received.

### Phase ARM4: virtio

Tasks:

- Reuse FDT discovery.
- Reuse virtio-mmio transport from RISC-V where possible.
- Reuse virtio-blk/net core.

Acceptance:

- virtio-blk and virtio-net pass the same smoke tests as RISC-V.

### Phase ARM5: QuickJS agent

Tasks:

- Build freestanding QuickJS for AArch64 user mode.
- Reuse host C, JS, syscall ABI, and broker model.

Acceptance:

- Pure JS agent test passes on AArch64 QEMU.

## 8. Shared driver model

### 8.1 Discovery

Discovery is platform-specific:

- RISC-V: FDT.
- AArch64: FDT first, UEFI/ACPI later if needed.
- x86_64: ACPI + PCI.

Normalize discovered devices into:

```
Device {
  kind
  mmio_base
  mmio_len
  irq
  pci_bdf
  dma_constraints
  compatible_string
}
```

### 8.2 Board-profile strategy

This kernel should not chase Linux-style hardware breadth. Edge products usually have a
fixed board and fixed bill of materials, so the right model is:

```
small common driver framework
+ board profile / BSP
+ selected vendor backend
```

The kernel should provide common interfaces:

- interrupt abstraction
- timer abstraction
- DMA buffer API
- MMIO helpers
- `NetIf`
- `BlockDevice`
- `WifiOps`
- `BtOps`
- firmware object loader
- driver lifecycle (`init`, `start`, `stop`, `suspend`, `resume`)

The board profile selects the tiny hardware set:

```
board/qemu-riscv64-virt
  uart0 = ns16550a
  irq0 = plic
  timer0 = sbi-timer
  blk0 = virtio-blk-mmio
  net0 = virtio-net-mmio

board/router-x
  uart0 = ...
  eth0 = ...
  wifi0 = vendor-backend
```

Rules:

- Only drivers selected by the board profile are included for a product image.
- Unsupported hardware is invisible.
- Agents cannot enumerate or open arbitrary hardware.
- Wi-Fi/BT are board backends behind `NetCap`/`DeviceCap`, not agent-visible raw drivers.
- Prefer Ethernet or virtio-net for first real hardware.
- Prefer Wi-Fi/BT vendors with RTOS/bare-metal SDKs, documented host protocols, or clean
  OS abstraction layers.
- Avoid Linux-only `.ko` drivers as a board-selection failure, not a kernel feature request.
- If a vendor SDK must be ported, wrap it behind `WifiOps`/`BtOps`; do not build a general
  Linux driver compatibility promise.

### 8.3 virtio layering

Use three layers:

```
virtio core
  feature negotiation helpers
  virtqueue
  descriptor allocation
  available/used ring handling

virtio transport
  mmio transport
  pci transport

virtio device drivers
  blk
  net
  rng later
```

Only the transport should know whether the device came from MMIO or PCI.

### 8.4 DMA safety

Initial QEMU path can use identity/direct DMA mappings. Long-term:

- Add DMA allocation API.
- Track physical ranges safe for devices.
- Add bounce buffers if needed.
- Prepare for IOMMU later, but do not require it for QEMU bring-up.

## 9. Testing strategy

### 9.1 Per-architecture smoke tests

Every architecture target should have:

- boot prints banner
- trap smoke test
- timer smoke test
- VM map/translate test
- user hello syscall test
- bad user pointer test
- ELF loader test
- QuickJS smoke test
- async agent test

### 9.2 Cross-architecture conformance tests

These should run the same logical test on all supported architectures:

- syscall ABI numbers and return convention
- `SYS_WRITE` / `SYS_READ` / `SYS_SUBMIT` / `SYS_POLL`
- `-E_FAULT` on bad user buffers
- ELF loader hostile inputs
- user/kernel isolation
- JS `Promise.all` overlap
- async backpressure rejection

### 9.3 CI requirements

Required local/CI tools:

- `qemu-system-riscv64`
- `qemu-system-x86_64`
- `qemu-system-aarch64`
- `clang`
- `ld.lld`
- `lld`
- `zig`

Milestone gates should not silently pass when toolchain pieces are missing. Local developer
targets may skip, but CI milestone targets should fail with a clear missing-tool message.

## 10. Milestones

### M1: RISC-V S-mode hello

Done when:

- OpenSBI boots the real kernel entry in S-mode, not only the SBI smoke runtime.
- Kernel prints through early console.
- FDT memory is parsed.
- Existing M-mode boot gates remain green.

### M2: RISC-V S-mode user hello

Done when:

- S-mode traps work.
- U-mode app calls `SYS_WRITE`.
- Bad user pointer returns `-E_FAULT`.

### M3: RISC-V S-mode QuickJS

Done when:

- Existing QuickJS confined agent runs under S-mode.
- Kernel remains not user-accessible from agent (supervisor-only, no user PTE).
- Existing M-mode QuickJS confined-agent gates remain green.
- Async-agent backpressure test passes.

### M4: RISC-V virtio storage/network

Done when:

- Existing virtio-blk driver passes under S-mode.
- Existing virtio-net driver passes under S-mode.
- Existing `kernel/net/` stack gates pass over the S-mode net path.
- Agent script ingress can come from a block-backed path.
- Existing M-mode driver/network gates remain green.

### M5: structured broker ABI — **delivered** (with M5b below)

- `SYS_SUBMIT(req_ptr)` / `SYS_POLL(...)` replace the toy op — both carry real
  `ToolReq`/`ToolEvent` structs copied in/out and size-validated (`user/abi.mc`,
  `user/sys.mc`).
- JS tool calls are Promise based.

### M5b: vector poll + real broker — **delivered**

Done:

- `SYS_POLL` gained the vector/timeout form (`events_ptr, max, timeout`) draining multiple
  completions per call.
- A REAL capability-checked FS op family runs alongside the mock ops, dispatched through
  `agent_fs_call`; deny/allow/audit are exercised end-to-end from pure JS (`qjs-realtool-test`).
  (Net `net_fetch` and applying the op family on x86/arm remain follow-ups — §12.)

### M6: x86_64 user hello

Done when:

- x86_64 QEMU boots.
- VM/traps/syscalls work.
- Same user hello ABI passes.

### M7: x86_64 QuickJS

Done when:

- Same pure JS agent runs under x86_64 QEMU.

### M8: AArch64 user hello

Done when:

- AArch64 QEMU boots.
- VM/traps/SVC/syscalls work.
- Same user hello ABI passes.

### M9: AArch64 QuickJS

Done when:

- Same pure JS agent runs under AArch64 QEMU.

## 11. Main risks

### Risk: M-mode assumptions leak into S-mode

Mitigation:

- Audit all CSR access.
- Keep machine-mode code out of core.
- Add build-time arch separation.

### Risk: page-table abstractions become too generic

Mitigation:

- Keep generic VM flags small.
- Let each architecture own its real PTE format.
- Avoid designing for every page-size feature at first.

### Risk: virtio transport and driver logic get tangled

Mitigation:

- Separate virtqueue core, transport, and device driver.
- Test virtio-mmio and virtio-pci against the same block/net driver code.
- Treat the S-mode work as revalidation of existing virtio drivers, not a rewrite.

### Risk: driver breadth turns the project into a Linux clone

Mitigation:

- Use board profiles and fixed BSPs.
- Include only selected drivers per product image.
- Keep Wi-Fi/BT behind broker/backend interfaces.
- Prefer open or RTOS-friendly wireless modules.
- Use a small vendor shim or sidecar before considering broad Linux compatibility.

### Risk: QuickJS port hides kernel bugs

Mitigation:

- Keep small user hello and syscall-fault tests.
- Do not rely on QuickJS as the first test for a new architecture.

### Risk: CI skips look like success

Mitigation:

- Add explicit toolchain preflight.
- Make milestone gates fail on missing required tools in CI.

## 12. Remaining next actions

The §10 milestone chain is delivered and gated, and items 1–7 below (R0b, M5b, the LLVM
root-cause, x86 X4/X5, the S-mode timer-interrupt core, TLS-under-S-mode, and the UART
driver) have since landed. What remains is captured in the marked-up items and the
"beyond §12" note at the end:

1. ~~**R0b — arch-selection seam.**~~ **Done.** A compiler `--arch` flag rewrites
   `import "kernel/arch/active/..."` to the chosen arch (default riscv64). One generic
   `uaccess_pt.mc` and one generic `elf_loader.mc` (arch PTE bits via each paging module's
   `pte_flags_for_user` hook) now serve all three arches; the per-arch `elf_loader_*`/
   `uaccess_*` copies are deleted. The portable core modules (`elf_loader`, `uaccess_pt`,
   `uaccess`, `mmap`) compile under all three arches — enforced by the `arch-emit-test` host
   gate. `cow.mc`/`demand.mc` remain **RISC-V-specific** (Sv39 gigapage + satp encoding) and
   import the riscv paging module directly, marked as such; making them portable needs
   arch-neutral large-page + address-space-encode hooks (a follow-up).
2. ~~**M5b — vector poll + real broker.**~~ **Done.** `SYS_POLL(events_ptr, max, timeout)`
   drains up to `max` ToolEvents/call with a virtual-clock timeout (`poll_many`; the C host
   batches 4/poll); and the RISC-V reference broker now dispatches real `TOOL_OP_FS_WRITE/
   READ/MKDIR` ops through `agent_fs_call` (capability front door: allowlist → budget →
   path-cap, audited) against a kernel treefs — a pure-JS agent writes/reads a file back and
   is denied an un-allowlisted op (`fs: read=hi`, `fs: mkdir denied EDENIED`). Gated by
   `qjs-realtool-test`/`llvm-` in m0. (Net `net_fetch` through `net_broker.mc` and applying
   the same op family on x86/arm — the broker is still duplicated 3× — remain follow-ups.)
3. **Fix the three ungated LLVM-backend QuickJS gates** (`llvm-x86-qjs-async-test`,
   `llvm-arm-qjs-test`, `llvm-arm-qjs-async-test`). **Root-caused:** `mcc emit-llvm` models C
   `va_list` as a single `ptr` and emits the LLVM `va_arg` instruction — correct only for the
   RISC-V lp64 ABI (which is why LLVM-on-RISC-V passes). On AArch64/x86-64 `va_list` is a
   multi-field register-save-area aggregate and `llc`'s `va_arg` lowering ignores the
   `__gr_offs`/`__gr_top` walk, so every `va_list` crossing the C-FFI boundary (QuickJS calls
   the mcc-emitted `vsnprintf`/`vfprintf` constantly) reads garbage → near-null deref → data
   abort (`ESR=0x92000006`, `FAR=0x1` on ARM). Proven with a minimal `vsum(n, ap)` reproducer
   (C backend = correct, LLVM backend = garbage) and a hand-written correct-IR fix.
   **Fix (in `src/lower_llvm.zig`, target-aware varargs):** thread the target arch into the
   emitter (emit `target triple`); emit the target's real `va_list` aggregate type (riscv
   `ptr`; aarch64 `{ptr,ptr,ptr,i32,i32}`; x86-64 `[1 x {i32,i32,ptr,ptr}]`); copy a `va_list`
   with `llvm.va_copy` (not `store ptr`); and on aarch64/x86-64 expand `va.arg` inline as the
   AAPCS/SysV register-save-area walk instead of the `va_arg` instruction. Also pass the arch
   when the harnesses emit `user/libc/libc.mc`. High regression surface (vararg/llvm-trap/
   host-llvm + the riscv qjs gates that pass *because* of the simple-pointer model) — verify
   against the full `fast` corpus.
4. ~~**x86 device-level (X4/X5).**~~ **Done.** X4: the Local APIC timer fires real,
   non-polled interrupts (8259 PIC masked) at IDT vec 0x20 — `x86-timer-test`
   (`X86-TIMER TICKS=3`). X5: x86 PCI config-space enumeration via the legacy CAM port-I/O
   mechanism (`0xCF8`/`0xCFC`) discovers the QEMU virtio-blk-pci device
   (`vendor=1af4 device=1001 class=01`) and completes a legacy virtio handshake
   (`status=03`, capacity read) — `x86-pci-test`. Both gates pass on C + LLVM backends, in
   m0. (A full virtio-pci data path — virtqueue sector read over PCI — remains a follow-up.)
5. **S-mode interrupts.** *Core done:* real S-mode **timer-interrupt delivery** under OpenSBI
   via the SBI TIME extension (`sie.STIE`+`sstatus.SIE`, `rdtime`, re-armed per tick,
   `wfi`-parked) — `smode-timer-test` (`SMODE-TIMER TICKS=3`, both backends, in m0), proving
   genuine non-polled IRQ delivery (`MIDELEG` bit 5 confirms S-timer delegation). Real S-mode
   **external (PLIC) interrupt delivery** is now also proven — `smode-plic-test` (both backends,
   in m0): a flat S-mode kernel programs the PLIC **S-mode context** (context 1: enable @ +0x2080,
   threshold/claim @ +0x201000), opens `sie.SEIE`, and takes a real external interrupt from the
   16550 UART (line 10), claiming and completing it. It is **single-shot** — one claimed+completed
   external IRQ, which is the full integration proof (S-context routing, SEIE/SEIP, the claim
   returning the right source id, complete). *Remaining:* (a) a **reusable PLIC driver** + wiring
   an actual device (virtio/net) to be interrupt-driven instead of polled — generalizing
   `kernel/drivers/irq/plic.mc` (today M-context-only) to S-context and replacing the virtio-net
   poll loop; (b) the **SBI HSM/IPI** service layer (SMP hart start/stop + inter-hart IPIs); and
   (c) the **`s_trap_vector` SPP/nested-trap rework** on the shared confinement vector
   (`smode_usermode_runtime.mc`) so the confined-agent path can ALSO take interrupts. NOTE: (a)
   and (c) are gated by a **C-backend reset** seen when a naked S-mode vector services an *async*
   interrupt and resumes (PLIC re-arm or U-mode preemption) — LLVM is clean, the same vector
   passes on C for *synchronous* ecalls, and a handler-entry SBI ecall masks it (timing, not
   logic). That root-cause must land before multi-IRQ / preemptive S-mode paths ship parity-clean
   on C; an LLVM-only U-mode-preemption proof was built but not committed (parity).
6. ~~**Re-run the `kernel/net/` TLS gates under S-mode.**~~ **Done.** `bearssl-smode-test`
   (BearSSL SHA-256 vector + live virtio-rng entropy) and `https-smode-test` (a full BearSSL
   TLS 1.2 handshake — ECDHE-RSA-AES256-GCM — with X.509 cert-chain validation against the
   embedded trust anchor, decrypting a token over HTTP 200) both run under REAL OpenSBI in
   S-mode (boot-seam port: `rdtime` for time, goldfish-RTC reachable for X.509 validity).
   Both deterministic and in m0.
7. ~~**UART console driver (R6).**~~ **Done.** `kernel/drivers/uart/ns16550.mc` — an
   arch-neutral, first-class NS16550 driver: base taken from the FDT-discovered
   `bootinfo_console_pa` (not a hardcoded constant), proper init (8N1 + FIFO), and an
   LSR-THRE-polled `putc` (the correctness win over the old hardcoded, unpolled `console.mc`,
   which stays as the panic-safe fallback). `uart-driver-test` boots under OpenSBI, reads the
   base from the DTB, and emits through the driver. Both backends, in m0.

---

**Beyond §12 (follow-ups surfaced this round):** the agent async broker — NOTE: re-survey showed
the *kernel* broker (`agent.mc`/`net_broker.mc`) is already single-source; the only per-arch code
is riscv64 M-mode bring-up scaffolding, so "consolidate the broker" really means *building* the
x86/ARM confined-agent runtimes that reuse it; net `net_fetch` through `net_broker.mc` and the
real FS op family on x86/arm; the full virtio-pci data path (virtqueue sector read over PCI);
the **reusable S-mode PLIC driver + interrupt-driven device wiring** (delivery itself is now proven
by `smode-plic-test`) + SBI HSM/IPI + the shared `s_trap_vector` SPP/nested-trap rework — the last
two gated by the C-backend async-IRQ reset noted in item 5; the target-aware LLVM varargs fix
(item 3 above); and
cow/demand portability (deferred until an x86/ARM kernel needs COW/demand paging).

The sequencing principle still holds: the agent ABI stays stable while each architecture
learns how to boot, trap, map memory, copy user buffers, and drive devices.
