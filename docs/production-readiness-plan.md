# Production readiness plan: agent kernel

Status: **roadmap / readiness document**.

This document turns the kernel roadmap into a production-readiness plan. The target is
not a general-purpose Linux replacement. The realistic production target is a focused
edge/appliance kernel for sandboxed agents on a fixed hardware profile.

Related documents:

- `docs/future-kernel-plan.md` — overall capability-native edge agent OS direction.
- `docs/platform-portability-plan.md` — platform work for RISC-V S-mode, x86_64, and AArch64.
- `docs/quickjs-agent-plan.md` — QuickJS as a confined U-mode agent.
- `docs/agent-sandbox-milestone.md` — sandbox, broker, policy, and MCP milestones.
- `docs/todo.md` — consolidated current roadmap.
- `docs/hardening-todo.md` — historical compiler/kernel hardening campaign record.
- `docs/test-architecture.md` — test-system direction.

## 1. Definition of production

Production-ready must be scoped. This kernel can become production-ready much sooner for
one fixed appliance than for broad hardware and workload compatibility.

### 1.1 In scope

The first production target is:

```text
One board family
+ fixed boot chain
+ fixed CPU/interrupt/device set
+ one agent runtime
+ narrow syscall ABI
+ brokered FS/network/tool effects
+ persistent policy and audit
+ signed updates
+ watchdog/recovery
```

The first hardware target is now selected as:

```text
StarFive VisionFive 2 (JH7110)
64-bit RISC-V
S-mode kernel
OpenSBI firmware
Sv39 virtual memory
QEMU virt first
then VisionFive 2 hardware validation
FDT-described UART + timer + interrupt controller + storage + network
```

The machine-readable profile lives in `kernel/platform/starfive_visionfive2/profile.mc`.
When VisionFive 2 hardware is unavailable, `zig build riscv-qemu-validation` is the
repeatable QEMU/OpenSBI surrogate gate. It validates the RISC-V S-mode platform,
interrupt, virtio storage/network, confined QuickJS, broker, real TCP-backed
`host_net_fetch`, and IRQ-backed production `SYS_POLL` paths across both backends,
but it remains emulator evidence rather than real-board release evidence.

### 1.2 Out of scope

The first production target should not try to provide:

- Linux/POSIX compatibility.
- Broad desktop/server workloads.
- Arbitrary process trees and shell-first operation.
- Broad hardware driver coverage.
- Raw device or raw network access for agents.
- A general package manager.
- Untrusted third-party runtimes inside the kernel trust boundary.

## 2. Readiness levels

| Level | Estimated timing | Meaning | Required evidence |
|---|---:|---|---|
| L0: Development kernel | current | QEMU-gated kernel with real confinement and agent substrate | Existing `m0`/QEMU gates; confined QuickJS; broker ABI; S-mode path |
| L1: Alpha appliance kernel | 1-3 months | One reference target with production-shaped I/O and agent loop | interrupt-driven virtio, brokered net fetch, stable async agent loop |
| L2: Field pilot | 3-6 months | Runs on one real board under controlled deployment | board boot, UART/net/storage, watchdog, persistent audit/policy |
| L3: Fixed-device production | 9-18 months | Safe to ship on one device class with rollback and operations | signed bundles, OTA, secure boot story, soak/fault tests, recovery |
| L4: Multi-board platform | 18-36+ months | Reusable platform across several boards/architectures | board profiles, BSP matrix, cross-arch parity, sustained CI |

These estimates assume focused engineering, a narrow product target, and no attempt to
match Linux hardware breadth.

## 3. Current baseline

The kernel is already beyond a toy prototype:

- RISC-V S-mode under OpenSBI is implemented and gated.
- Confined U-mode agents exist.
- QuickJS can run as a confined agent.
- The kernel has page-table-aware user-copy paths.
- A multi-segment ELF loader exists.
- Virtio-blk and virtio-net have QEMU gates.
- The broker ABI supports structured submit/poll.
- The RISC-V reference path can run real FS broker operations from pure JS.
- TLS, DNS, TCP/HTTP, virtio-rng, FDT, UART, and multiple architecture paths exist in test form.
- x86_64 and AArch64 have user/VM/agent-level parity, with some device-level gaps.

The remaining work is not "invent an OS from nothing." It is turning a strong gated
prototype into a reliable appliance runtime.

### 3.1 External review reconciliation (2026-06-30)

An independent review proposed a 12-area "production Agent OS" gap list. It maps almost 1:1
onto §4 below (independent re-derivation — validating). Grounding each against the tree shows
several areas it called "missing" already exist and are better characterized as "exists, needs
hardening"; a few are genuinely thin. Current state, with evidence:

| Area | Status | Evidence / gap |
| --- | --- | --- |
| 1. Preemptive scheduling | **Mostly done** | Correction (review and my first pass both understated this): **real timer-driven preemption already exists and is gated** — `preempt_demo`/`preempt-test` (both backends) runs three never-yielding threads that the timer ISR (`timer_preempt` → `sched_yield` from the trap, full frame preserved by the asm vector) rotates through; **per-agent CPU budget** is enforced (`wasm-watchdog-test`: the machine-timer watchdog preempts + KILLS a runaway agent); priorities/quantum/fair-share/throttle (`proc_sched.mc`, gated `scheduler-test`/`fairsched`); cancellation (`AGENT_OP_CANCEL`, `qjs-cancel-test`). **Added (2026-06-30):** a process-level (ProcTable) quantum→`need_resched` decision layer (`proc_preempt_tick`/`_pending`/`_clear`/`_point`) so the agent scheduler has a voluntary-preemption-point path tied to quantum (gated `scheduler-test`). **Remaining (narrow):** drive `proc_preempt_tick` from a timer ISR in a multi-AGENT (ProcTable) runtime gate — the thread-level preemption gate uses the kernel-thread `Scheduler`, not the agent `ProcTable`. |
| 2. Stable agent ABI | Mostly done | Correction: it IS versioned — `AGENT_ABI_VERSION`, `version` fields on req/event structs, `agent_abi_validate_req` rejects a mismatch with `badver` (gated: `agent_abi_demo.mc`), typed `AgentAbiError` status codes, a `CANCEL` op, `abi-consistency-test` guards syscall-number drift across kernel/userspace, and `liveupdate_demo` exercises a version transition. **Landed (2026-06-30):** the versioning/compat policy is now written in `agent_abi.mc` (single monotonic wire version; what forces a bump; status/op-set rules; the pair-kernel-with-agents deployment model). |
| 3. Durable storage | Exists, weak | KV/blob/fs + `persistent_audit.mc`, `block_persistent_audit.mc`, blockdev checkpoint seed. Gap: **persist-across-reboot for policy+audit** (checklist `[ ]`), journaling/CRC, compaction, migration. |
| 4. Isolation boundary | **Most mature** | Confined U-mode Sv39 (kernel unmapped) + WAMR sandbox + deterministic fuel, S-mode + cross-arch. Gap: **per-agent crash cleanup/reap**. (Review overstates this as missing.) |
| 5. Resource accounting | Mostly done | Per-dimension budgets are enforced AND gated: CPU (`wamr-fuel-test`, `wasm-watchdog-test`), memory (`wasm-memcap-test`), network requests (`NetCap.requests_left`), tool/output quota (`quota-probe-test`, `qjs/wasm-quota-agent-test`) — multiple backends. Gap: a **single unified accounting/quota model** spanning all dimensions (incl. file handles + spawned tasks) and typed `NoMem` on the broker/device paths (§3.1 #5 detail). |
| 6. Broker hardening | Exists, weak | `net_broker` policy+budget+audit; back-pressure (async `ok=8 rejected=4`); revoke/throttle/kill actuation gated. Gap: **persistent policy load, revocation propagation, retries, tracing**. |
| 7. Networking | Mostly exists | **DNS exists** (`kernel/net/dns.mc`), TLS (BearSSL), TCP RX hardened (checksums + chunked drain). Gap: retransmit robustness, conn pooling, timeout control, hostile-packet corpus. (Review overstates DNS/TLS as needed.) |
| 8. Observability | Partial | Audit/trace + record/checkpoint exist (`ipc_trace.mc`, `cap_audit`, provenance, `kernel/lib/record.mc`, `kernel/lib/checkpoint.mc`). Gap: **structured metrics, per-agent event timelines, deterministic replay**. |
| 9. Update/packaging | Partial | Agent signature verify (`kernel/crypto/rsa_verify.mc`), `liveupdate.mc`. Gap: **signed kernel images, reproducible builds, OTA, rollback**. |
| 10. Platform contract | Partly documented | `platform-portability-plan.md`, `qemu-validation-checklist.md`; per-arch compiler-flag rules now explicit (aarch64 strict-align). Gap: **one frozen board profile**. |
| 11. Security model doc | **Landed (2026-06-30)** | `docs/threat-model.md` written: assets, trust boundaries (TCB vs attacker-controlled), the isolation boundary with enforcing code, per-area threats→mitigations, guarantees G1–G5, accepted failure modes, and how each is gated. Keep it updated as §4.7 work lands. |
| 12. Long-running lifecycle | Partial | Core lifecycle exists: `proc_spawn` / `proc_exit` / `proc_kill` (+ `proc_signals`) / `proc_reap` (parent reaps a dead child — crash cleanup) / pause/resume, and `liveupdate.mc` (version handoff). **Added (2026-06-30):** supervision mechanism — heartbeat-liveness detection (`proc_supervise`/`proc_heartbeat`/`proc_liveness_expired`/`proc_unsupervise`, per-slot deadline) AND a restart/crash-loop guard (`proc_restart_record`/`proc_restart_allowed`/`proc_restart_reset` — bound restarts so a slot that keeps dying is declared crash-looping instead of thrashing); both gated in `scheduler-test`. Gap: wiring these into an automatic **supervisor loop** + supervision trees + leases + persistent identity (policy on top of the now-present mechanism). |

Net (revised after grounding each row against the tree — the recurring finding is that items are
substantially more implemented + gated than first credited):

- **Landed this pass:** (11) threat model written; (2) ABI versioning policy written (the mechanism
  already existed + was gated); (1) a process-level quantum→`need_resched` preemption-decision layer
  added — and verified that real timer-driven preemption + per-agent CPU-budget kill **already
  exist and are gated**.
- **Genuinely remaining, narrow gaps:** (3) persist policy+audit **across a real reboot** (the
  block-backed seed uses an in-RAM disk; needs a two-boot disk-image gate); (12) the **supervision
  layer** (heartbeat/restart/crash-loop/leases) on top of the existing spawn/exit/kill/reap; (5) a
  **unified** resource-accounting model + typed `NoMem` on broker/device paths; (8) structured
  **metrics + deterministic replay**; (1-tail) drive `proc_preempt_tick` from a timer ISR in a
  multi-AGENT runtime gate; (9) reproducible builds / signed kernel images / OTA / rollback.

The point of this section: most "production blockers" are mechanism-complete and gated; the work is
finishing narrow tails and writing the policies — not building these subsystems from scratch.

## 4. Main production blockers

### 4.1 Interrupt-driven I/O

Current status:

- S-mode timer interrupt delivery is proven (`smode-timer-test`, both backends).
- S-mode external PLIC delivery is proven with a single-shot UART interrupt
  (`smode-plic-test`, both backends).
- A reusable S-mode PLIC dispatch shell exists at `kernel/drivers/irq/smode_plic.mc`;
  the single-shot and multishot S-mode PLIC demos now route claim/complete through it.
- Registered S-mode async IRQ completion gates pass on both backends for virtio-blk and
  virtio-net TX/RX: `blk-smode-irq-test`, `llvm-blk-smode-irq-test`,
  `net-smode-irq-test`, `llvm-net-smode-irq-test`, `net-smode-rx-irq-test`, and
  `llvm-net-smode-rx-irq-test`. They drain completed broker ids through
  `async_poll_many`, the kernel-side `SYS_POLL` shape, and are promoted into `m0`.
- The production JS `host_net_fetch` surface has an S-mode IRQ-backed proof:
  `qjs-smode-net-irq-tool-test` / `llvm-qjs-smode-net-irq-tool-test` complete the JS
  request through `SYS_POLL` from a real virtio-net PLIC interrupt, and are promoted into
  `m0`.
- The production JS `host_fs_read` surface has the storage counterpart:
  `qjs-smode-blk-irq-tool-test` / `llvm-qjs-smode-blk-irq-tool-test` complete the JS
  request through `SYS_POLL` from a real virtio-blk PLIC interrupt, and are promoted into
  `m0`.

- The steady-state, re-armed external-interrupt path is now proven on **both** backends
  (`smode-plic-multishot-test`, in m0): the handler re-arms the UART source and takes 3
  discrete S-mode external interrupts via the PLIC.

Former blocker (now resolved):

- What looked like a "C-backend async-IRQ reset" — a naked S-mode trap vector that
  reset-looped on the C backend while LLVM was clean — was **root-caused and fixed**. It was
  not a reset: the `#[naked]` vector could be placed 2-byte aligned, but a RISC-V
  `stvec`/`mtvec` base must be 4-byte aligned (its low two bits are the MODE field), so a
  misaligned vector trapped to the wrong PC. Fixed at the language level with the `#[align(N)]`
  attribute and a 4-byte alignment default for `#[naked]` functions. The repeated/preemptive
  S-mode interrupt path (R1b/R2) is therefore unblocked. See
  `docs/platform-portability-plan.md` §12 "Do now" item 2.

Production target:

- Virtio-blk and virtio-net interrupts routed through the reusable S-mode PLIC dispatch.
- Interrupt-driven virtio-blk completion.
- Interrupt-driven virtio-net TX and RX completion.
- Device interrupts integrated with the scheduler and async completion queue.
- No busy polling in steady-state agent I/O.

Acceptance gates:

- `smode-plic-test` remains green.
- `blk-smode-irq-test` reads a sector by sleeping until interrupt-backed completion.
- `net-smode-irq-test` sends a frame and sleeps until interrupt-backed TX completion.
- `net-smode-rx-irq-test` receives a frame by sleeping until interrupt-backed RX completion.
- The async broker can complete a request from an interrupt-backed event and drain it through
  `async_poll_many`, not from a polling loop.
- Production agent syscall/tool-surface gates show the same interrupt-backed completion through
  `SYS_POLL`: `qjs-smode-net-irq-tool-test` / `llvm-qjs-smode-net-irq-tool-test` for network
  and `qjs-smode-blk-irq-tool-test` / `llvm-qjs-smode-blk-irq-tool-test` for storage.
- QEMU tests assert that `wfi` is reached while waiting and that completion is interrupt-driven.

Why this matters:

- Power use matters on edge devices.
- Polling hides race conditions that appear on real hardware.
- Async agent I/O needs a real completion path.

### 4.2 Agent production surface

Current status:

- Confined QuickJS exists.
- Structured `SYS_SUBMIT` / `SYS_POLL` exists.
- Real FS broker operations exist on the RISC-V reference path.
- Real TCP-backed brokered network fetch is gated on the RISC-V reference path.
- Brokered network fetch is exposed as `host_net_fetch` through the production JS
  `SYS_SUBMIT` / `SYS_POLL` tool surface.
- TCP-backed `host_net_fetch` is proven by `qjs-net-realtool-test` /
  `llvm-qjs-net-realtool-test`: a pure-JS agent reaches a live HTTP server through
  `net_fetch_tcp` over virtio-net, with denied egress and budget exhaustion covered.
- The remaining production-surface gap is durable policy/audit semantics, out-of-process
  tool transport, stable version/error rules, and cross-arch real-broker parity.

Production target:

- Cross-arch real-FS broker parity.
- Native tool catalog for the first appliance workload.
- Out-of-process tool server transport.
- MCP-compatible JSON-RPC descriptors and envelope, with MC capabilities as the authority layer.

Initial tool catalog:

- `read`
- `list`
- `write`
- `mkdir`
- `grep`
- `find`
- `edit`
- `exec` only if the product actually needs it
- `checkpoint`
- `net_fetch` / `host_net_fetch`

Acceptance gates:

- A pure JS agent performs allowed FS operations and denied FS operations.
- A pure JS agent performs allowed network fetch and denied network fetch.
- Denials are audited and attributable to the agent.
- Tool budget exhaustion returns a typed error and produces policy-visible state.
- Tool server runs as a separate principal, not just an in-process mock.
- MCP descriptor output matches the actual capability surface.

### 4.3 Persistent policy and audit

Current status:

- Capability checks, audit rings, and policy decision logic exist.
- `persistent-audit-test` gates a BlobStore-backed checkpoint seed for policy metadata
  and drained audit events, including policy version and boot epoch metadata.
- `block-persistent-audit-test` gates the same policy/audit checkpoint shape through the
  generic `BlockDevice` trait, so the bytes survive a remount/reopen of block-backed storage
  instead of only BlobStore memory.
- `production-ops-test` gates watchdog/reboot-reason records and policy actuation state
  transitions for throttle, revoke, and kill.
- Production virtio-blk journal/reboot integration is still pending.
- Policy actuation against live running agents is still pending.

Production target:

- Policy is stored persistently.
- Audit survives reboot or crash.
- Audit records are bounded, structured, and replayable.
- Policy decisions can act on live agents.
- Audit records distinguish allowed, denied, throttled, revoked, and killed actions.

Acceptance gates:

- Policy is loaded during boot before untrusted agents run.
- Audit is flushed to storage with bounded memory use.
- A crash/reboot preserves enough audit state to explain the last agent actions.
- Policy can revoke a capability from a running agent.
- Policy can throttle or kill a noisy agent.
- Tests cover audit ring wraparound and storage-full behavior.

### 4.4 Update, rollback, and trust chain

Current status:

- The kernel has agent bundle and runtime direction, but production loader/update mechanics are
  not complete.
- The **signature-verification primitive exists**: `kernel/crypto/rsa_verify.mc` is a thin MC
  binding over the vendored constant-time BearSSL "i31" engine for RSA-PKCS#1/SHA-256. The
  `rsa-verify-test` gate (both backends, in m0) verifies a real RSA-2048 signature and rejects a
  tampered signature and a wrong message. Crypto stays in the audited BearSSL library; MC only
  marshals arguments.
- `production-ops-test` gates bundle admission metadata: bundle kind/version, ABI version,
  policy version, key id, signature presence/status, rejected bad ABI, rejected wrong key, and
  two-slot rollback state after failed boot.
- What remains for P4 is key management/rotation, auditing bundle identities, and wiring
  RSA verification plus bundle admission into the loader before untrusted bundles run.

Production target:

- Signed kernel images or verified boot chain.
- Signed agent bundles.
- Versioned policy bundles.
- OTA update with rollback.
- Recovery image or fallback slot.
- Clear compatibility rule between kernel ABI, broker ABI, policy schema, and agent bundle.

Acceptance gates:

- Unsigned or incorrectly signed agent bundle is rejected.
- Old-but-allowed bundle version can run if policy permits it.
- Update can be interrupted without bricking the device.
- Rollback works after a failed boot.
- Audit records include image and bundle identity.

### 4.5 Real board support

Current status:

- QEMU `virt` is the main reference.
- Real-board selection and BSP profile need to be made concrete.

Production target:

- One board profile with fixed memory map, interrupt controller, timer, UART, storage, and network.
- FDT/device discovery where useful, but product image includes only selected drivers.
- Ethernet first. Wi-Fi/Bluetooth only through a clean, documented vendor interface or a deliberately scoped compatibility layer.

Acceptance gates:

- Kernel boots on the board without QEMU-only assumptions.
- UART console works.
- Timer and external interrupts work.
- Storage read/write works.
- Network fetch works.
- Watchdog reset works.
- Power-cycle test passes repeatedly.

Board-selection criteria:

- Open boot documentation.
- Open interrupt/timer/device docs.
- Mainline-friendly Ethernet or virtio-like device path.
- Avoid Wi-Fi chips that require a large Linux-only SDK unless the product absolutely needs them.
- Prefer vendors with stable firmware interface, documented SDIO/PCIe/USB transport, and redistributable firmware.

### 4.6 Reliability and recovery

Production target:

- Watchdog integration.
- Panic capture.
- Controlled reboot.
- Agent crash containment.
- Resource reclamation on exit.
- Storage-full and memory-pressure handling.
- No single failed agent can wedge the device.

Acceptance gates:

- Agent page fault kills or restarts only that agent.
- Agent OOM is contained and audited.
- Kernel OOM path is deterministic.
- Tool server crash is detected and restarted or marked unavailable.
- Watchdog resets a deliberately hung kernel path in a board test.
- After reboot, the system can report why it restarted.

### 4.7 Security hardening

Current status:

- MC already has useful safety work: unsafe boundary, user-pointer type, parser primitives,
  capability opacity, IRQ-context discipline, and move/borrow checks.
- More security work is still needed before production claims.

Production target:

- Syscall fuzzing.
- Broker request fuzzing.
- Network parser fuzzing.
- ELF loader fuzzing.
- Capability forge/regression tests.
- User-copy fault injection.
- MMIO and DMA ownership checks.
- Security review of every unsafe boundary used by the kernel.

Acceptance gates:

- Fuzzers run in CI or scheduled jobs.
- Every syscall rejects malformed pointers and lengths without kernel fault.
- Every broker input has length bounds and structured parse errors.
- Every externally reachable parser has malformed-input coverage.
- Unsafe audit has no unexplained sites.

### 4.8 Operations and observability

Production target:

- Boot reason reporting.
- Kernel version, board profile, policy version, and agent bundle version visible in diagnostics.
- Bounded logs.
- Health endpoint or serial diagnostic command.
- Minimal crash dump or panic record.
- Test hooks that can be disabled in release images.

Acceptance gates:

- A field device can answer: what is running, what policy is active, what the last denied action was, and why it rebooted.
- Log storage cannot be exhausted by one agent.
- Diagnostic output does not leak secrets.

## 5. Suggested roadmap

### Phase P0: freeze the production target

Goal: define what "production" means for the first product.

Tasks:

- Pick one board family or one QEMU-to-board path.
- Decide whether Wi-Fi/Bluetooth are in v1 or deferred.
- Define the first agent workload.
- Define required tools.
- Define required network destinations.
- Define update and recovery expectations.
- Define release image profile.

Exit criteria:

- A one-page product profile exists.
- The allowed device list is fixed.
- The required broker tool list is fixed.
- Non-goals are explicitly written down.

### Phase P1: interrupt-driven reference platform

Goal: make the QEMU S-mode path behave like a real low-power kernel.

Prerequisite — DONE: the C-backend async-IRQ "reset" that gated this phase has been
root-caused and fixed (missing alignment on naked trap vectors; see §4.1 and
`docs/platform-portability-plan.md` §12 "Do now" item 2). The steady-state, re-armed interrupt path now passes on
both backends (`smode-plic-multishot-test`), so devices can be converted to interrupt-backed
wait. Reusable S-mode PLIC dispatch and async virtio-blk / virtio-net TX/RX IRQ demos now
exist, pass on both backends, and drain completed broker ids through `async_poll_many`; the
production JS network and storage tool surfaces now also have `SYS_POLL` completion proofs from
real S-mode virtio-net and virtio-blk PLIC interrupts.

Tasks:

- Keep `zig build riscv-qemu-validation` green as the focused QEMU/OpenSBI
  board-surrogate gate until hardware validation is available.
- Keep `blk-smode-irq-test`, `net-smode-irq-test`, `net-smode-rx-irq-test`, and their LLVM
  variants green as promoted `m0` evidence.
- Keep `qjs-smode-net-irq-tool-test`, `qjs-smode-blk-irq-tool-test`, and their LLVM variants
  green as promoted production `SYS_POLL` evidence.

Exit criteria:

- Storage and network tests can sleep while waiting for hardware.
- Async JS requests complete from device events.
- Polling remains only as a fallback or diagnostic mode.

### Phase P2: production agent broker

Goal: make the agent's external-effect model production-shaped.

Tasks:

- Keep the promoted TCP-backed network broker transport green through the production
  JS/tool-catalog surface.
- Add denied-network audit records.
- Move tool execution behind real IPC transport.
- Add MCP JSON-RPC envelope and descriptors.
- Add the first real tool catalog.
- Add per-agent quotas for in-flight requests and result buffers.

Exit criteria:

- A pure JS agent can complete a useful task using only brokered tools.
- Every allowed and denied external effect is attributed and policy-visible.
- No tool runs with the agent's ambient authority.

### Phase P3: persistence and recovery

Goal: survive reboot and explain behavior.

Tasks:

- Add persistent policy store. **Seed exists:** BlobStore and BlockDevice gates.
- Add persistent audit log. **Seed exists:** BlobStore and BlockDevice gates.
- Add watchdog integration. **State primitive exists:** `production-ops-test`.
- Add panic/reboot reason record. **State primitive exists:** `production-ops-test`.
- Add storage-full behavior for audit and policy.
- Add policy actuation for revoke/throttle/kill. **State primitive exists:** `production-ops-test`;
  live-agent wiring remains.

Exit criteria:

- Device can reboot and retain policy.
- Device can reboot and retain recent audit.
- Device can kill or throttle a misbehaving agent.
- Device can report last reboot reason.

### Phase P4: signed bundles and OTA

Goal: make update and trust-chain behavior shippable.

Tasks:

- Define bundle format for kernel, policy, and agent. **Header/admission seed exists.**
- Add signature verification. **Crypto primitive exists; loader wiring remains.**
- Add version compatibility checks. **Admission seed exists.**
- Add A/B or fallback update slot. **Two-slot rollback state exists.**
- Add rollback after failed boot. **State transition gate exists.**
- Add release manifest and reproducible image metadata.

Exit criteria:

- Unsigned bundles do not run.
- Failed update rolls back.
- Audit records identify exact kernel/policy/agent versions.

### Phase P5: real board pilot

Goal: move from QEMU confidence to hardware confidence.

Tasks:

- Bring up boot, UART, timer, interrupts.
- Bring up storage.
- Bring up Ethernet.
- Run brokered network fetch through the production agent surface.
- Run watchdog.
- Run power-cycle loop.
- Measure memory footprint and idle power.

Exit criteria:

- Board runs the reference agent workload for days.
- Power-cycle test passes.
- Network loss/recovery behaves predictably.
- Storage corruption tests do not brick the system.

### Phase P6: production hardening

Goal: make failures boring.

Tasks:

- Long soak tests.
- Fault injection.
- Fuzzing campaign for syscalls, brokers, parsers, and ELF loader.
- Security review of unsafe boundary.
- Release-mode feature audit.
- CI matrix for C and LLVM backends where supported.

Exit criteria:

- No known critical containment bug.
- No known kernel panic from malformed agent input.
- No known update/recovery brick path.
- CI and board soak are stable enough for release cadence.

## 6. Minimum production checklist

The first production claim should require all of these:

NOTE (2026-06-30): the software-capability items below are marked done where a QEMU gate
demonstrates them; the *board-hardware* items (real board profile, boot/interrupts on the board)
remain open — QEMU is the only validated platform today.

- [ ] One real board profile is selected and documented.
- [ ] Kernel boots on the board in the intended privilege mode.
- [ ] Timer and external interrupts work on the board. (QEMU: yes — `preempt-test`, CLINT/PLIC gates; board: pending.)
- [ ] Storage works with persistence tests. (Roundtrip via BlockDevice gated; across-reboot pending — see below.)
- [x] Network works through the production brokered tool surface. (QEMU-gated: `net-realtool`/`agent-net-real` over real TCP.)
- [x] Agent runs confined with no ambient FS/network authority. (QEMU-gated: the confined-agent family — kernel unmapped, syscall-only entry.)
- [x] All external effects go through brokers. (FS/net brokers; confined agents have no ambient handles.)
- [x] Allowed and denied broker decisions are audited. (QEMU-gated: net allow `NET_TAG` / deny `NET_DENY_TAG`, FS deny audit.)
- [x] Per-agent memory, request, output, and network budgets are enforced across the production paths. (QEMU-gated: `wasm-memcap`, `wamr-fuel`/`wasm-watchdog`, `quota`/`quota-agent`, `NetCap`.)
- [x] Policy can revoke/throttle/kill a running agent. (`proc_throttle` + `proc_kill` + machine-timer watchdog kill (`wasm-watchdog-test`) + gated revoke/throttle/kill actuation.)
- [x] Policy actuation state transitions for revoke/throttle/kill are gated.
- [x] BlockDevice-backed policy/audit checkpoint seed exists.
- [ ] Audit persists across reboot.
- [ ] Policy persists across reboot.
- [ ] Watchdog and reboot reason work.
- [x] Watchdog/reboot-reason state records are gated.
- [ ] Signed agent bundles exist.
- [x] Signed-bundle admission metadata and rejection semantics are gated.
- [ ] Update rollback works.
- [x] Two-slot rollback state transition is gated.
- [ ] Syscall and broker fuzz tests exist.
- [ ] Long QEMU soak passes.
- [ ] Real-board soak passes.
- [ ] Security review has no unresolved critical findings.

## 7. Timeline estimate

The practical estimate:

- **1-3 months:** alpha appliance kernel in QEMU with interrupt-driven I/O and production-shaped agent broker.
- **3-6 months:** controlled field pilot on one real board.
- **9-18 months:** production-ready for one fixed device class.
- **18-36+ months:** reusable multi-board / multi-architecture platform.

The schedule depends mostly on:

- How narrow the first hardware target is.
- Whether wireless is deferred.
- Whether the product requires `exec` or only brokered file/network tools.
- How much OTA/secure-boot infrastructure already exists outside the kernel.
- How strict the release bar is for certification, audit retention, and physical attack resistance.

## 8. Strategic guidance

The kernel should win by being narrow, inspectable, and agent-native.

Do:

- Keep the syscall ABI small.
- Keep agents untrusted by default.
- Keep every external effect brokered.
- Keep policy and audit mandatory.
- Keep board support explicit and profile-driven.
- Prefer Ethernet and documented devices for v1.
- Use Linux only as a reference or compatibility source, not as the shape of the system.

Avoid:

- Chasing POSIX.
- Chasing broad Wi-Fi/Bluetooth vendor SDKs too early.
- Adding generic escape hatches.
- Letting tools run in the agent's authority context.
- Calling QEMU success production readiness without real-board soak.

The production path is credible if the scope stays fixed-device and agent-first. The same
work becomes much harder if the project tries to become a small general-purpose OS.
