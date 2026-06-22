# Future kernel plan: capability-native edge agent runtime

Status: **roadmap / direction document**.

This document summarizes the intended future of the kernel: a small, portable,
capability-native OS/runtime for sandboxed edge AI agents. It is not a plan to replace
Linux as a general-purpose OS. It is a plan to build a focused kernel where **agents are
the primary workload**, and every external effect is mediated, quota-bound, and audited.

Related detailed plans:

- `docs/quickjs-agent-plan.md` — how QuickJS runs as a confined U-mode agent.
- `docs/platform-portability-plan.md` — how the platform moves to
  `RV64GC + S-mode + OpenSBI + virtio`, then x86_64 and AArch64.
- `docs/agent-sandbox-milestone.md` — current sandbox milestone notes.

## 1. Core thesis

Linux can run agents today, but it is a broad general-purpose system. To run a tightly
limited edge agent on Linux, the system usually needs to combine many mechanisms:

```
Linux kernel
+ distro/userland
+ init/system service manager
+ container runtime or process supervisor
+ namespaces
+ cgroups
+ seccomp
+ AppArmor/SELinux
+ nftables/iptables
+ audit/eBPF
+ filesystem permissions
+ language runtime
+ agent process
```

This kernel aims for a different shape:

```
small kernel
+ U-mode JS/WASM agent runtime
+ capability broker
+ quota manager
+ audit log
+ minimal storage/network/device drivers
```

The key distinction:

```
Linux model:    general process first, then restrict it
This model:     restricted agent is the native execution model
```

The system should make it easy to state and enforce:

- This agent may read this script.
- This agent may call these tools.
- This agent may fetch these network destinations.
- This agent may use this much memory.
- This agent may have this many in-flight operations.
- This agent may emit this much output.
- Every external effect is recorded with agent identity and policy result.

## 2. Non-goals

The kernel should not become a small Linux clone.

Explicit non-goals:

- Full POSIX compatibility.
- Shell-first multi-user environment.
- General-purpose process tree with arbitrary `fork`/`exec`.
- Raw socket access for agents by default.
- Generic `ioctl`-style escape hatches.
- Broad device access from user agents.
- Complex dynamic package management.
- Large unmediated filesystem namespace.
- Supporting every application workload.

The main workload is:

```
confined agent -> brokered tools/network/files/devices -> audited results
```

## 3. Current starting point

The current implementation is a working RISC-V M-mode/QEMU kernel with strong
agent-sandbox pieces:

- U-mode entry and return.
- Ecall-based syscall path.
- Sv39 page tables.
- Isolated user address spaces.
- Kernel intentionally unmapped from agent page tables.
- Page-table-aware user copies.
- Multi-segment ELF loader.
- Freestanding QuickJS build.
- Fixed C host that runs pure JavaScript agents.
- `SYS_READ` script ingress.
- `SYS_WRITE` console output.
- Structured async tool/net I/O through `SYS_SUBMIT(req_ptr)` (copies in + validates a `ToolReq`,
  returns a request id) and vector `SYS_POLL(events_ptr, max, timeout)` (drains up to `max`
  `ToolEvent`s), with real brokered FS ops on the RISC-V path (`user/abi.mc`, the reference broker,
  `examples/apps/qjs_host.c`).
- Backpressure and negative errno conventions for important paths.
- A partial core/arch/platform split.
- FDT parsing primitives.
- QEMU-oriented PLIC, CLINT, PCI, virtio-blk, virtio-net, and virtio-rng pieces.
- A real `kernel/net/` stack with Ethernet, ARP, IPv4, UDP, TCP, DNS, and TLS-oriented
  demos through BearSSL.
- x86_64 (multiboot boot, 4-level paging, ring-3 user via `int 0x80`, LAPIC timer + PCI IRQ,
  confined QuickJS) and AArch64 (EL1 boot, stage-1 4 KB paging, EL0 user via `svc #0`, confined
  QuickJS) — boot/paging/user gated on **both** backends. QuickJS gating is narrower: x86 **sync**
  is C+LLVM-gated, x86 **async** is C-gated (the LLVM-x86 async case is tracking-only/ungated);
  AArch64 QuickJS sync **and** async are C-gated, with LLVM tracking-only/ungated. The ungated LLVM
  cases fault inside the QuickJS workload (known LLVM-backend codegen issues). Not full-kernel
  parity with riscv64 (AArch64 IRQ controller still pending).
- Demo-scale SMP/IPI/TLB-shootdown infrastructure.

The current system proves an important point:

```
A real JavaScript runtime can run outside the kernel trust boundary as a confined U-mode
agent and reach the kernel only through a narrow syscall ABI.
```

The next platform step is therefore not "build all drivers from scratch." It is specifically
to move the working RISC-V path from M-mode/QEMU assumptions to a normal S-mode/OpenSBI
kernel while revalidating the existing loader, user-copy, virtio, and network pieces.

## 4. Target identity

Working description:

```
A small capability-native kernel/runtime for sandboxed edge AI agents.
```

More concrete:

```
A portable RISC-V/ARM/x86 kernel that runs JS/WASM agents in isolated user mode, exposes
only brokered tool/network/file/device operations, enforces capability policy and resource
budgets in the kernel, and records every external effect in an audit trail.
```

Primary use cases:

- Edge AI assistants.
- Sensor/device automation agents.
- Retail/industrial/local automation boxes.
- Local model gateways.
- Agent appliances.
- Constrained devices where full Linux plus containers is too heavy.
- Environments where auditability and default-deny policy matter more than POSIX breadth.

## 5. High-level architecture

End-state stack:

```
                 agent bundle
          JS/WASM code + manifest + policy
                         |
                         v
      isolated U-mode runtime: QuickJS or WASM engine
                         |
                         v
       narrow syscall ABI: submit, poll, read, write, exit
                         |
                         v
              kernel capability broker
        policy check + quota check + audit record
                         |
        +----------------+----------------+
        |                |                |
        v                v                v
    tool broker      net broker       fs/device broker
        |                |                |
        v                v                v
   local tools      virtio-net       virtio-blk / device
```

The agent should not directly own:

- raw network sockets
- raw block devices
- raw MMIO
- arbitrary filesystem paths
- unrestricted process creation
- unrestricted host syscalls

Instead, it submits structured requests:

```
SYS_SUBMIT(req_ptr) -> handle | -errno
SYS_POLL(events_ptr, max, timeout) -> n_ready | -errno
```

## 6. Capability model

Every meaningful external effect should require a capability.

Example capability types:

```
ToolCap
  allowed tool names
  input/output byte limits
  timeout
  max in-flight calls

NetCap
  allowed hosts/IP ranges
  allowed ports
  allowed protocols
  max request/response bytes
  timeout

PathCap
  root path or object id
  read/write/append flags
  max file size
  persistent or ephemeral

DeviceCap
  device class
  allowed operations
  rate limits
  safety policy

ModelCap
  local model id
  token/input/output limits
  privacy/export policy
```

Default policy:

```
no capability = no access
```

The kernel should treat prompt text as untrusted. Capabilities are enforced by kernel policy,
not by asking the model to behave.

## 7. Agent resource budgets

Agent-native quotas should be first-class:

- JS/WASM heap bytes.
- Kernel-owned request bytes.
- Kernel-owned result bytes.
- In-flight request count.
- Completion queue depth.
- CPU ticks or event-loop turns.
- Wall-clock deadlines.
- Network bytes in/out.
- Storage bytes read/written.
- Audit log bytes.
- Tool-call count.
- Denial count or suspicious behavior count.

Budget failures should return structured errors:

```
-E_AGAIN   temporary capacity/backpressure
-E_DENIED  policy denied
-E_NOCAP   no matching capability
-E_QUOTA   budget exceeded
-E_FAULT   bad user memory
-E_INVAL   malformed request
-E_TIMEOUT operation timed out
```

## 8. Audit model

Every external effect should produce an audit event.

Minimum event fields:

```
event_id
agent_id
request_id
capability_id
operation_kind
operation_name
policy_decision
deny_reason
input_size
output_size
start_time
end_time
status
error_code
destination summary, for network
path/object summary, for storage
```

Audit goals:

- Prove what the agent did.
- Prove what the kernel denied.
- Attribute resource use to an agent.
- Debug unexpected behavior.
- Support fleet-level policy monitoring later.

The audit log should be append-only from the agent's point of view. Agents may be able to
read their own limited audit view if granted, but they must not be able to rewrite history.

## 9. Platform roadmap

### 9.1 RISC-V real platform

Move from the current M-mode/QEMU system to:

```
RV64GC
S-mode kernel
OpenSBI for M-mode firmware/SBI calls
QEMU virt first
Sv39 virtual memory
FDT device discovery
PLIC external interrupts
SBI timer
UART console
virtio-mmio
virtio-blk
virtio-net
real board later
```

Near-term RISC-V milestones — **delivered** (all under REAL OpenSBI S-mode, gated on both
backends; see `docs/platform-portability-plan.md` and the `*-smode-*` build steps):

1. ✓ Real S-mode kernel entry from the OpenSBI boot path (`sbi-boot-test`).
2. ✓ FDT parsing wired into boot memory + device discovery (`fdt-boot-test`, `fdt-devices-test`).
3. ✓ S-mode trap handler (`smode-user-test`, `smode-timer-test`).
4. ✓ Tiny U-mode hello app (`smode-user-test`).
5. ✓ Page-table-aware user copy (`copy_from_user_pt`, bad ptr → `-EFAULT`).
6. ✓ ELF loader + isolated user address spaces (`qjs-smode-confined-test`).
7. ✓ Confined QuickJS agent under S-mode, sync + async (`qjs-smode-{confined,agent,async-agent}-test`).
8. ✓ virtio-mmio / virtio-blk / virtio-net revalidated under S-mode (`blk-smode-test`, `net-smode-test`).
9. ✓ `kernel/net/` over the S-mode network path (`net-smode-test`; TLS via `bearssl-smode`/`https-smode`).
10. *Next:* a full brokered net-fetch tool (virtio-blk script/log storage already exercised; cross-arch
    real-FS broker parity is the remaining gap — the RISC-V broker has real FS ops, x86/AArch64 use a mock).

Migration safety rule:

```
M-mode QEMU remains green until S-mode reaches agent parity.
```

The S-mode port is an additional target during migration, not a flag-day replacement.

### 9.2 x86_64 support

First x86_64 target:

```
QEMU q35 or pc
long mode ring 0 kernel
Limine/UEFI or Multiboot2 boot
ACPI
APIC/x2APIC
PCI
virtio-pci
```

Goals:

- Same core kernel abstractions.
- Same syscall ABI.
- Same JS agent host.
- Same broker model.
- Different boot/trap/page-table/device backend.

Milestones:

1. ✓ Boot and print (multiboot → long mode).
2. ✓ Parse memory map (multiboot info).
3. ✓ Set up IDT/GDT/TSS.
4. ✓ Implement page tables (4-level; `x86-vm-test`).
5. ✓ Enter ring 3 user mode (`x86-user-test`).
6. ✓ Run user hello syscall test (`int 0x80`, bad ptr → `-EFAULT`).
7. ◐ Add PCI + virtio-pci — PCI CAM enumeration done (`x86-pci-test` discovers the virtio-pci
   device, vendor `0x1AF4`); a full virtio-pci **driver** (queue setup + DMA) is the next depth.
8. ✓ Run QuickJS agent (`x86-qjs-test`; C+LLVM sync, C async — LLVM async tracking-only).

### 9.3 AArch64 support

First AArch64 target:

```
QEMU virt
EL1 kernel
PSCI
FDT
GICv3
AArch64 MMU
virtio-mmio or virtio-pci
```

Milestones:

1. ✓ Boot and print (EL1 on QEMU virt).
2. ✗ Parse FDT — *next*; the bring-up currently hardcodes the QEMU-virt addresses
   (PL011 `0x0900_0000`, RAM `0x4000_0000`).
3. ✓ Set `VBAR_EL1` and handle traps (EL1 vector table; lower-EL sync → SVC dispatch).
4. ✓ Configure MMU through `TCR_EL1`, `MAIR_EL1`, `SCTLR_EL1` (`arm-vm-test`).
5. ✓ Enter EL0 user mode (`arm-user-test`).
6. ✓ Run user hello syscall test (`svc #0`, bad ptr → `-EFAULT`).
7. ✗ Add GICv3 timer/interrupt support — *next* (the one remaining per-arch gap vs riscv64/x86).
8. ✗ Reuse virtio-mmio core — *next* (no AArch64 virtio driver gate yet).
9. ✓ Run QuickJS agent (`arm-qjs-test`; C sync + async — both LLVM cases tracking-only).

## 10. Architecture split

The code should converge on this split:

```
kernel/core
  agent model
  syscall dispatch
  capability broker
  quota manager
  audit log
  ELF loader
  scheduler
  generic VM objects
  VFS/object store
  generic virtio core

kernel/arch/riscv64
  S-mode entry
  RISC-V trap frame
  CSR access
  Sv39 backend
  SBI wrappers
  context switch

kernel/arch/x86_64
  boot protocol glue
  IDT/GDT/TSS
  CR3/page-table backend
  syscall/sysret or interrupt syscall entry
  APIC

kernel/arch/aarch64
  EL1 entry
  exception vectors
  TTBR/TCR/MAIR/SCTLR backend
  PSCI
  GIC

kernel/drivers
  uart
  plic/gic/apic
  virtio core
  virtio-mmio
  virtio-pci
  virtio-blk
  virtio-net
```

Core rule:

```
kernel/core must not contain raw satp/cr3/ttbr, PLIC/APIC/GIC, or firmware-specific calls.
```

The existing split is already partially present. The first cleanup target is not directory
creation; it is API cleanup. One concrete example is the current core panic path using
RISC-V M-mode names (`mcause`, `mepc`, `mtval`). That should become an architecture-neutral
trap report before the same core path is shared by S-mode, x86_64, and AArch64.

## 10.1 Board-profile driver strategy

Edge hardware is usually fixed hardware, not a PC-style arbitrary device universe. The
driver strategy should therefore be board-profile driven:

```
common driver interfaces
+ fixed board profile / BSP
+ selected vendor backend
```

The kernel should keep common interfaces for:

- interrupts
- timers
- DMA buffers
- MMIO helpers
- `NetIf`
- `BlockDevice`
- `WifiOps`
- `BtOps`
- firmware loading
- driver lifecycle

Each product image should include only the drivers selected by its board profile. Agents
should not enumerate arbitrary hardware.

Wireless policy:

- Prefer Ethernet or virtio-net for first hardware.
- Prefer Wi-Fi/BT providers with RTOS/bare-metal SDKs, documented host protocols, or clean
  OS abstraction layers.
- Treat Linux-only wireless drivers as a hardware selection problem, not a reason to build
  broad Linux compatibility.
- If a vendor SDK must be ported, wrap it behind `WifiOps`/`BtOps`.
- Keep Wi-Fi/BT behind `NetCap`/`DeviceCap` brokers; agents never touch vendor drivers
  directly.

## 11. Runtime roadmap

### 11.1 QuickJS

QuickJS remains the first agent runtime because it is small enough to reason about and
already works as a freestanding C payload.

Planned support:

- Fixed host binary.
- Pure JS agent source.
- Script ingress through staged buffer, then capability FS.
- `print(...)`.
- Promise-based tool calls.
- Promise-based network fetch.
- Structured JS errors for denied/quota/fault cases.
- Event loop driven by `SYS_POLL`.

### 11.2 WASM

WASM should be considered a second runtime after the broker/syscall model is stable.

Reasons to add WASM:

- Stronger module boundary.
- Multi-language agent/tool components.
- Smaller deterministic execution profile for some workloads.
- Easier fuel/metering model.

Do not add WASM before the capability broker is solid. Otherwise the project risks
becoming "runtime collection" rather than an agent OS.

### 11.3 Local model gateway

Future edge devices may run local models or model accelerators. The kernel should not embed
the model runtime in kernel space. Instead:

```
agent -> ModelCap request -> model broker -> local model runtime/device -> result
```

Model broker should enforce:

- model id
- input token/byte limits
- output token/byte limits
- privacy policy
- export/network policy
- accelerator/device access policy

## 12. Storage and update plan

Storage should start simple:

1. Kernel-staged script buffers.
2. virtio-blk-backed object store.
3. Capability FS for scripts/config/logs.
4. Signed agent bundles.
5. OTA update support.

Agent bundle format should eventually contain:

```
manifest
agent code
runtime type: js | wasm
declared capabilities
resource budgets
signature
version
rollback policy
```

The kernel or trusted manager should verify signatures before running an agent bundle.

## 13. Networking plan

Do not expose raw sockets to agents by default.

Preferred model:

```
agent JS fetch/tool call
  -> SYS_SUBMIT(NetFetchReq)
  -> net broker
  -> NetCap policy
  -> DNS/connect/TLS/HTTP backend
  -> audit
  -> SYS_POLL(NetFetchEvent)
```

The first implementation can be simple HTTP/TCP in QEMU. Long term, decide whether TLS is:

- implemented inside the trusted broker,
- delegated to a small user-mode network service,
- or handled by a verified/minimal TLS library.

Policy should support:

- allowed hosts
- allowed IP ranges
- allowed ports
- max request/response bytes
- timeout
- redirect policy
- DNS policy
- certificate policy

## 14. Testing roadmap

Tests should prove both mechanism and policy.

### 14.1 Always-on low-level tests

- Boot smoke.
- Trap smoke.
- Timer smoke.
- VM map/translate.
- User hello syscall.
- Bad user pointer returns `-E_FAULT`.
- ELF loader valid image.
- ELF loader hostile overlap.
- ELF loader OOM returns typed error.

### 14.2 Agent tests

- QuickJS smoke eval.
- Pure JS agent loading.
- `print(...)`.
- `host_async(...)`.
- `Promise.all` overlap.
- Backpressure rejection.
- Denied tool rejection.
- Denied network rejection.
- Quota exceeded rejection.
- Audit event emitted for allow and deny.

### 14.3 Cross-architecture conformance

The same logical tests should run on:

- riscv64
- x86_64
- aarch64

Architecture-specific boot is allowed to differ. Syscall behavior, user-copy behavior,
agent behavior, and broker policy should match.

## 15. CI and tooling requirements

Required tools:

- Zig
- Clang
- `ld.lld`
- QEMU RISC-V
- QEMU x86_64
- QEMU AArch64

Developer local targets may skip when tools are missing. Milestone/CI targets should fail
with clear diagnostics if a required tool is absent. A skipped test should not be mistaken
for a green milestone.

Recommended targets:

```
zig build riscv64-smoke
zig build riscv64-agent
zig build riscv64-virtio
zig build x86_64-smoke
zig build x86_64-agent
zig build aarch64-smoke
zig build aarch64-agent
zig build conformance
```

## 16. Milestone sequence

### M0: current prototype stabilized

Done when:

- QuickJS confined agent runs.
- Async backpressure test passes.
- Loader hostile tests pass.
- Bad user pointer syscall tests exist.

### M1: architecture boundary

Done when:

- Core no longer depends directly on RISC-V M-mode details.
- `BootInfo`, `Trap`, `VmFlags`, and user-copy contracts exist.
- Existing RISC-V tests still pass.
- The core panic/trap report no longer exposes `mcause`/`mepc`/`mtval` names.

### M2: RISC-V S-mode boot

Done when:

- OpenSBI enters the real kernel in S-mode, not just the current SBI smoke runtime.
- Kernel parses FDT memory.
- Kernel prints through early console.
- Existing M-mode boot tests remain green.

### M3: RISC-V S-mode userland

Done when:

- S-mode trap handler handles U-mode syscalls and faults.
- Tiny U-mode hello app runs.
- Bad user pointer returns `-E_FAULT`.

### M4: RISC-V S-mode agent — ✓ DELIVERED (`qjs-smode-agent-test`, `qjs-smode-async-agent-test`)

Done when:

- ✓ Confined QuickJS agent runs under S-mode.
- Kernel remains unmapped from the agent.
- Async-agent test passes.
- Existing M-mode QuickJS tests remain green.

### M5: virtio storage/network — ✓ DELIVERED (`blk-smode-test`, `net-smode-test`)

Done when:

- ✓ Existing virtio-mmio/virtio-blk/virtio-net code works under S-mode.
- ✓ Existing `kernel/net/` stack works over the S-mode network path.
- ✓ Agent script/log/network paths can use virtio-backed services.
- ✓ Existing M-mode driver/network gates remain green.

### M6: structured broker — ✓ DELIVERED (`qjs-*-async-agent-test`, `qjs-realtool-test`)

Done when:

- ✓ Toy `arg + 2` async path is replaced by the structured request/event ABI
  (`SYS_SUBMIT(req_ptr)` + vector `SYS_POLL(events_ptr, max, timeout)`).
- ✓ Tool broker enforces capabilities (allowlist → budget → path-cap via `agent_fs_call`).
- ✓ Audit events are emitted (on both allow and deny).
- ✓ JS receives structured errors.

### M7: x86_64 userland — ✓ DELIVERED (`x86-user-test`, `llvm-x86-user-test`)

Done when:

- ✓ x86_64 QEMU boots (multiboot → long mode; 4-level paging via `x86-vm-test`).
- ✓ User hello app uses the same syscall ABI (ring-3, `int 0x80`).
- ✓ User-copy (bad ptr → `-EFAULT` software walk) and ELF loader tests pass.

### M8: x86_64 agent — ✓ DELIVERED (`x86-qjs-test`, `x86-qjs-async-test`)

Done when:

- ✓ The same pure JS agent runs on x86_64 (confined ring-3 QuickJS).
- ✓ The same broker conformance tests pass (sync + async, back-pressure/denial).
  *(LLVM-backend x86 QuickJS-async is a known ungated codegen issue — see the portability notes.)*

### M9: AArch64 userland — ✓ DELIVERED (`arm-user-test`, `llvm-arm-user-test`)

Done when:

- ✓ AArch64 QEMU boots (EL1; stage-1 4 KB paging via `arm-vm-test`).
- ✓ User hello app uses the same syscall ABI (EL0, `svc #0`).
- ✓ User-copy (bad ptr → `-EFAULT` software walk) and ELF loader tests pass.

### M10: AArch64 agent — ✓ DELIVERED (`arm-qjs-test`, `arm-qjs-async-test`)

Done when:

- ✓ The same pure JS agent runs on AArch64 (confined EL0 QuickJS).
- ✓ The same broker conformance tests pass (sync + async).
  *(C-gated on both the sync and async agent; the LLVM-aarch64 cases — `llvm-arm-qjs-test`,
  `llvm-arm-qjs-async-test` — are tracking-only/ungated, excluded from `m0`: even a trivial JS
  eval faults inside the QuickJS workload under the LLVM backend on aarch64.)*

### M11: edge appliance runtime

Done when:

- Signed agent bundles exist.
- Persistent policy store exists.
- Audit log can persist to storage.
- OTA/update story exists.
- At least one real board port works.

## 17. Design constraints to protect the project

The project should repeatedly enforce these constraints:

1. Agents are untrusted.
2. The runtime is outside the kernel trust boundary.
3. User pointers are never raw-dereferenced.
4. External effects go through brokers.
5. Broker decisions are capability-checked.
6. Broker decisions are audited.
7. Resource use is budgeted.
8. Syscall ABI stays narrow.
9. Core stays architecture-independent.
10. The system does not chase full Linux/POSIX compatibility.

## 18. Why this is distinct from Linux

Linux is mature, powerful, and the right answer for many deployments. This kernel has a
different optimization target.

Linux is optimized for:

- broad hardware support
- broad application compatibility
- POSIX
- many users/processes
- mature networking/storage/filesystems
- existing operational tooling

This kernel should be optimized for:

- small trusted computing base
- default-deny agent permissions
- tiny syscall surface
- brokered external effects
- mandatory audit
- predictable resource budgets
- portable edge deployment
- simple reasoning about what an agent can do

Short version:

```
Linux runs an agent as a restricted process.
This kernel runs an agent as the central security object.
```

## 19. Recommended immediate next steps

**Delivered** (gated):
1. ✓ `BootInfo` (`kernel/core/bootinfo.mc`, `bootinfo-test`); core panic/trap report neutralized of
   RISC-V M-mode names (`AddressSpace` seam, `kernel/core/aspace.mc`).
2. ✓ Bad-user-pointer tests for `SYS_WRITE`/`SYS_READ`/`SYS_POLL` (`-EFAULT` via software walk).
3. ✓ Real S-mode kernel entry from the OpenSBI boot path; S-mode `SYS_WRITE` from a U-mode app.
4. ✓ QuickJS confined agent on the S-mode path (`qjs-smode-confined/agent/async-agent-test`).
5. ✓ FDT, virtio-blk, virtio-net, and `kernel/net/` revalidated under S-mode.
6. ✓ Structured request/event ABI (`SYS_SUBMIT`/vector `SYS_POLL`) replacing the toy async calls.
7. ✓ Capability broker + audit events (the RISC-V reference broker dispatches real FS ops through
   `agent_fs_call`: allowlist → budget → path-cap, with audit on allow + deny).

**Next:**
8. `net_fetch` as a first-class brokered tool (storage/log over virtio-blk already exercised).
9. Cross-arch real-FS broker parity — x86_64 / AArch64 still use a mock broker; bring them to the
   RISC-V path's real `agent_fs_call`.
10. An AArch64 IRQ controller (GIC + timer) to close the one remaining per-arch gap.
11. Board profiles / BSP selection for fixed edge hardware.

The near-term priority is not adding many agent features. The priority is making the
platform boundary real, keeping the sandbox narrow, and proving that the same agent ABI can
survive the move from prototype kernel to real S-mode platform.
