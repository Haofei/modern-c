# Threat model: confined edge-AI agent kernel

Status: first written 2026-06-30 (production-readiness-plan.md §4.7 / §3.1 item 11).
Scope: the MC capability microkernel running untrusted edge-AI agents under QEMU
(RISC-V S-mode the reference; aarch64/x86_64 secondary). This document states what
is trusted, what is attacker-controlled, the guarantees we intend to hold, and the
failure modes we accept. It is the frame for the security-hardening work in §4.7.

## 1. Assets to protect

1. **Kernel integrity** — the supervisor's code, page tables, capability/broker state,
   and audit trail must not be modifiable by an agent.
2. **Confidentiality + integrity between agents** — one agent must not read or corrupt
   another agent's memory, files, or in-flight tool results.
3. **The capability boundary** — an agent may cause an external effect (FS, network)
   ONLY through a broker that holds an explicit capability for it; no ambient authority.
4. **Resource availability** — no agent may starve the system of CPU, memory, or I/O
   to the point of denying service to the kernel or other agents (best-effort; see §6).
5. **Audit truth** — allow/deny decisions and effects are recorded faithfully and an
   agent cannot suppress or forge audit records.

## 2. Trust boundaries

**Trusted computing base (TCB), assumed correct:**
- The MC compiler/codegen and the runtime checks it emits (bounds, overflow, the
  move/typestate and `irq_context` static checks).
- The microkernel: loader, page-table/uaccess paths, syscall dispatch, the brokers
  (FS/net), the scheduler, the capability registries.
- The vendored engines linked into the kernel/host TCB where used: WAMR (agent wasm),
  QuickJS, BearSSL. A bug in these is a TCB bug.
- The boot firmware (OpenSBI on RISC-V) and the platform (QEMU virt / a real board).

**Untrusted, attacker-controlled:**
- The agent payload itself: arbitrary wasm (WAMR) or JS (QuickJS-on-wasm), and the
  arguments/pointers/lengths it passes across the syscall ABI.
- All network input (DNS/TCP/TLS records, raw frames) — fully hostile.
- Agent-supplied filesystem contents within its sandbox.

**Out of scope (explicitly NOT defended here):**
- Physical attacks, side channels (timing/cache/Spectre-class), and rowhammer.
- A malicious board/firmware below OpenSBI.
- Supply-chain compromise of the vendored engines or the toolchain.

## 3. The isolation boundary (what actually enforces it)

- **Address-space isolation.** A confined agent runs in U-mode (RISC-V) / ring-3
  (x86_64) / EL0 (aarch64) in its own Sv39/4 KiB-granule page table with the kernel
  **unmapped** (or mapped supervisor-only). The agent cannot name kernel memory.
  Gated by the confined-agent family (markers "CONFINED: kernel unmapped/…", "USER-EXIT").
- **Only path to the kernel is the syscall ABI** — a frozen 6-syscall surface
  (`kernel/core/agent_abi.mc`) reached by `ecall`/`svc`/`int 0x80`. Everything else
  faults.
- **User-pointer validation.** Every pointer/length an agent hands the kernel is
  copied through page-table-aware `copy_to/from_user` (`kernel/core/uaccess.mc`); a
  bad address returns `-EFAULT` via a software page-table walk, never a kernel fault.
- **wasm sandbox-in-sandbox.** WAMR runs the agent's wasm with bounds-checked linear
  memory and **deterministic instruction-count fuel** (the runaway bound wasm3 lacked).
- **No ambient authority.** An agent has no FS/network handles by default; all effects
  go through the FS/net brokers, which check a per-agent capability + budget first.

## 4. Per-area threats and mitigations

| Threat | Mitigation (code) | Residual / gap |
| --- | --- | --- |
| Agent reads/writes kernel memory | kernel unmapped in agent AS; uaccess validates every user ptr | — |
| Agent forges a syscall arg (ptr/len overflow) | checked arithmetic + `fits_within`/bounds checks; EFAULT/EINVAL not trap (recent hardening) | audit syscall-facing index routes (plan §4.7) |
| Hostile network frame corrupts socket state | bounds-checked frame parser + IPv4/TCP checksum validation (`tcp_tx.mc`) | larger hostile-packet corpus |
| Agent exfiltrates via network | net broker egress allowlist (`NetCap.allowed`) + budget; denied attempts audited (`NET_DENY_TAG`) | persistent policy load/revocation (§4.2) |
| Cross-transport confusion in broker | endpoint transport-kind tag checked before dispatch (`net_broker.mc`) | — |
| Runaway CPU (DoS) | WAMR instruction fuel; cooperative scheduler + timer watchdog kill; preemption-decision layer (`proc_preempt_*`) | full timer-driven preemption (§3.1 #1) |
| Memory exhaustion (DoS) | confined arena + fixed pools with overflow-safe fit checks | typed `NoMem` on broker/device paths (§3.1 #5); per-agent memory budget enforcement everywhere |
| Agent crash takes down kernel | fault-confinement: agent faults are contained to its AS | per-agent crash cleanup/reap (§3.1 #4) |
| Agent forges/suppresses audit | audit written kernel-side (`ipc_trace`/`cap_audit`), agent cannot reach it | persist-across-reboot (§4.3) |
| Hostile ELF traps the loader | segment bounds + pre-align overflow check → `BadSegment`, not trap (`elf_loader.mc`) | — |
| Untrusted agent image | agent signature verify (`kernel/crypto/rsa_verify.mc`, BearSSL i31) | signed kernel images, reproducible builds, rollback (§4.4) |

## 5. Guarantees we intend to hold

- **G1 Memory isolation:** a confined agent cannot read/write kernel or peer-agent
  memory; the only kernel entry is the syscall ABI. (Enforced; gated.)
- **G2 No ambient authority:** every external effect requires an explicit capability +
  budget checked by a broker, and is audited. (Enforced for the gated paths; production
  policy persistence/revocation pending.)
- **G3 Fail-closed:** on hostile or malformed input the kernel returns a typed error
  (EFAULT/EINVAL/BadSegment/TooLarge) rather than trapping or corrupting state. (Largely
  enforced; the remaining `unreachable`-on-exhaustion paths are tracked.)
- **G4 Deterministic bound on agent CPU:** an agent cannot run unbounded (fuel +
  watchdog today; preemptive timeslice in progress).
- **G5 Audit truth:** allow/deny + effects are recorded kernel-side beyond agent reach.

## 6. Accepted failure modes (non-goals, for now)

- **Availability under a determined local DoS is best-effort**, not guaranteed, until
  full preemption + uniform per-agent memory/CPU budgets land. A misbehaving agent may
  currently degrade throughput (it cannot escape isolation or forge authority).
- **A TCB bug (WAMR/QuickJS/BearSSL/compiler) can break any guarantee** — these are
  trusted. Defense is vendoring discipline + the test gates, not runtime containment.
- **Trapping (controlled halt) is an acceptable last resort** for "must not happen"
  invariants in the kernel itself; it is NOT acceptable on attacker-reachable input
  paths (those must fail closed with a typed error — see G3).
- **Side channels and physical attacks are out of scope.**

## 7. How this is validated

The guarantees above are pinned by the gated test families (run via `zig build m0` or
`tools/m0-parallel.sh`): the confined-agent family (G1/G2), the FS/net broker
allow+deny audit gates (G2/G5), the hostile-input gates — ELF bounds, syscall ptr/len,
TCP checksums, pool overflow (G3) — and the fuel/watchdog/scheduler gates (G4). New
security work in §4.7 should land with a gate that asserts the property it claims.
