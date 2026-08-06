# Security review: MC capability microkernel

Status: first written 2026-06-30 (production-readiness-plan.md §4.7 hardening polish, P6).
Scope: the production kernel that runs untrusted edge-AI agents — RISC-V S/U-mode the
reference target, aarch64/x86_64 secondary. This is a *structured, code-grounded* review
of the actual enforcers, meant to be read alongside [`docs/threat-model.md`](threat-model.md)
(assets, trust boundaries, guarantees G1–G5). It is deliberately honest about gaps; where a
mitigation is partial or a primitive is a stand-in, that is called out as a residual risk
rather than glossed over.

This document does **not** claim the kernel is audited or production-hardened. It enumerates
what exists, points an external auditor at the files that matter, and lists the open items a
real audit must close.

---

## 1. Trusted computing base (TCB)

Everything in this list is *assumed correct*; a bug in any of it can break every guarantee.
Minimizing and pinning this set is the core of the security posture.

| TCB component | Files | Notes |
| --- | --- | --- |
| Compiler / codegen + emitted runtime checks | `src/*.zig` (lower_c*, lower_llvm*, sema*, mir*) | Emits bounds, checked-arithmetic, move/typestate, `irq_context` checks. A miscompile is a TCB bug; mitigated by C/LLVM differential gates + `mcfuzz`. |
| Syscall dispatch + ABI envelope | `kernel/core/agent_abi.mc`, `kernel/core/syscall*.mc` | Frozen 6-op surface (READ/WRITE/MKDIR/NET_FETCH/SLEEP/CANCEL), `AGENT_ABI_VERSION`. |
| User-pointer boundary | `kernel/core/uaccess.mc` | Page-table-aware `copy_to/from_user`; the single trusted path for agent-supplied pointers. |
| Loader | `kernel/core/elf_loader.mc` | Parses untrusted ELF images; segment bounds + overflow checks. |
| Scheduler + process lifecycle | `kernel/core/process.mc`, `proc_sched.mc` | Spawn/exit/reap, supervision, OOM/fault reclaim, least-privilege masks. |
| Brokers (the only path to external effect) | `kernel/net/net_broker.mc`, `kernel/fs/treefs.mc`, `kernel/agent/mcp.mc` | Capability + budget checks before any FS/net effect. |
| Resource accounting | `kernel/core/ledger.mc`, `kernel/lib/resacct.mc` | Overflow-safe charge/release; fail-closed over-limit. |
| Audit trail | `kernel/core/ipc_trace.mc`, `cap_audit` in `process.mc` | Kernel-side allow/deny + capability-use record, out of agent reach. |
| Vendored engines in the TCB | WAMR (agent wasm), QuickJS (JS-on-wasm), BearSSL (TLS/crypto) | A bug here is a TCB bug; defense is vendoring discipline + gates, not runtime containment. |
| Firmware / platform | OpenSBI (RISC-V), QEMU virt / real board | Below the kernel; assumed correct. |

**Untrusted (attacker-controlled):** the agent payload (arbitrary wasm/JS) and every
argument/pointer/length it passes across the syscall ABI; all network input
(DNS/TCP/TLS/raw frames); and agent-supplied filesystem contents. Product OTA
bundles are outside the current kernel scope. See threat-model §2.

---

## 2. Attack surface and mitigations

Each surface below lists the concrete enforcer (with file), then the residual risk. Where a
gate pins the property, it is named; run core gates via `zig build m0` and the
full security/runtime matrix via `zig build m0-full` or `tools/m0-parallel.sh`.

### 2.1 Syscall ABI (the primary agent → kernel boundary)

The *only* non-faulting path from agent to kernel is the frozen syscall envelope
(`kernel/core/agent_abi.mc`), reached by `ecall`/`svc`/`int 0x80`. Everything else faults.

- **Pointer/length arguments** are copied through the page-table-aware boundary in
  `kernel/core/uaccess.mc` (`copy_to/from_user`); a bad address returns `-EFAULT` via a
  software page-table walk, never a kernel fault.
- **Integer arguments** ride MC's checked arithmetic + explicit `fits_within`/bounds checks,
  so a length/offset overflow yields a typed `EINVAL`/`TooLarge`, not a trap or wild access.
- **ABI stability** is pinned by `abi-consistency-test` (syscall numbers vs `user/abi.mc`).

Residual: the *index-routed* syscall paths (dispatch tables keyed by an agent-supplied op/fd)
should get an explicit audit pass (threat-model §4.7). Fuel/timeslice DoS is separate (§2.5).

### 2.2 Address-space / memory isolation

A confined agent runs in U-mode / ring-3 / EL0 in its own page table with the kernel
**unmapped** (or supervisor-only), so it cannot name kernel or peer-agent memory. Gated by
the confined-agent family (markers `CONFINED: kernel unmapped`, `USER-EXIT`). This is
guarantee **G1**.

Residual: correctness of the page-table setup and TLB/`satp` switching is TCB; there is no
formal proof, only the gates.

### 2.3 Network broker (egress)

`kernel/net/net_broker.mc` splits **policy** (egress allowlist `NetCap.allowed` + per-agent
request budget) from **transport**. A destination not in the allowlist spends no budget,
sends no packet, and is recorded as a distinct DENY event (`NET_DENY_TAG`) — observable but
not counted as real egress. Budget exhaustion returns a typed `Budget` error. Hostile inbound
frames are handled by the bounds-checked parsers (§2.6).

Residual: product persistent policy load is outside the current language-oriented kernel scope;
today the allowlist is established in-boot. Larger hostile-packet corpus wanted.

### 2.4 Filesystem broker + agent runtime

Agents have **no ambient FS/net handles**; all effects route through brokers that check a
per-agent capability first (`kernel/fs/treefs.mc`, `kernel/agent/mcp.mc`). The MCP tool budget
is enforced (`kernel/agent/mcp.mc`). This is guarantee **G2** and is audited kernel-side (§2.7).

Residual: uniform per-agent memory/CPU budget enforcement on *every* broker/device path is
incomplete (threat-model §5, production-readiness-plan §4.7 / P6). Some exhaustion paths still
`unreachable` rather than returning a typed `NoMem` — those are tracked.

### 2.5 Availability / DoS

WAMR runs agent wasm with **deterministic instruction-count fuel** (the runaway bound wasm3
lacked) and bounds-checked linear memory. A cooperative scheduler plus a timer watchdog kill,
and the preemption-decision layer (`proc_preempt_*` in `proc_sched.mc`), bound agent CPU
(guarantee **G4**). Runaway memory is reclaimed by the OOM keystone: `proc_oom_victim` /
`proc_oom_kill` / `proc_oom_reclaim` in `process.mc` select the worst live offender and
forcibly reclaim it through the shared death-cleanup path, kernel and peers untouched.

Residual: timer-driven preemption of agent processes has **landed** (plan §3.1 #1,
`agent-preempt-test`), so a compute-bound agent is rotated off the hart. Availability under a
determined local DoS remains *best-effort* at finer grain: a misbehaving agent may still degrade
throughput (it cannot escape isolation or forge authority). This is an
explicitly **accepted** failure mode, not a claimed guarantee.

### 2.6 Untrusted-input parsers (network + ELF)

All attacker-controlled byte parsing routes through the total checked reader (`std/bytes`
`br_try_*`), so an over-read returns a typed error instead of trapping. The DNS + TCP parsers
and the RX path are fuzzed over >1M malformed/truncated buffers (`parser-fuzz-test`,
`net-fuzz-test`); the ELF loader rejects out-of-range/overflowing segments with `BadSegment`
(`elf_loader.mc`). This is guarantee **G3** (fail-closed).

Residual: parser coverage is empirical (fuzz), not proven-total. TLS record handling rides
BearSSL (TCB).

### 2.7 Audit truth

Allow/deny decisions and capability use are recorded **kernel-side** in ring buffers the agent
cannot reach: `kernel/core/ipc_trace.mc` (messages) and `cap_audit` / `g_cap_trace` in
`process.mc` (authority use — recorded *before* the permission decision, so denied attempts are
captured too). This is guarantee **G5**.

Residual: **persist-across-reboot** of the audit trail is not yet done (threat-model §4.3);
today it is in-memory.

### 2.8 Capability/right mint roots

`Cap` / `RCap` remain opaque linear capability tokens, but minting is no longer ambient:
`cap_mint` and `rcap_mint` require a `BootAuthority` token, while `rights_grant` and
`rights_single` require a `RightsAuthority` token. The source audit gate flags direct
capability/right mint calls and root-authority creation outside the approved TCB root files.

Residual — **production blocker:** root-authority provenance is still a prototype seam.
Production kernel profiles still need a boot-time root lifecycle and delegation policy
before third-party kernel components can be treated as outside the
mint TCB.

### 2.9 Product update path

The previous prototype bundle metadata / OTA / rollback fixture has been removed from the current
kernel scope. Product update authentication, reboot recovery, and boot-chain policy are deliberately
not language features and should be reintroduced only behind a concrete product profile.

---

## 3. Residual risks and assumptions (summary)

1. **TCB bugs are undefended at runtime.** A defect in the compiler, WAMR, QuickJS, or BearSSL
   can break any guarantee. Defense is vendoring discipline + the differential/fuzz gates.
2. **Production boot-chain policy is out of current language scope** — the metadata/rollback gates
   remain prototype kernel fixtures, not a production trust chain (§2.9).
3. **Availability is best-effort** — agent preemption has landed (§2.5), so the remaining risk is
   finer-grained / uniform per-agent CPU/memory budget enforcement, not preemption itself.
4. **Product policy persistence + revocation** are out of the current language-oriented kernel scope (§2.3, §2.7).
5. **Residual `unreachable`-on-exhaustion paths** exist off the main attacker-reachable routes;
   they are tracked and must all become typed `NoMem`/errors to fully satisfy G3.
6. **Side channels, physical attacks, malicious firmware, and supply-chain compromise are out
   of scope** (threat-model §2, §6).
7. **No formal proofs.** Every guarantee is pinned by tests, not verification; a gate can only
   disprove, not prove, a property.

---

## 4. What this review delivered as gates (P6)

The hardening-polish work this document accompanies added two runnable, bounded, deterministic
CI gates plus this review:

- **`soak-test` / `llvm-soak-test`** (`tools/proc/soak-test.sh`, `tests/qemu/proc/soak_demo.mc`):
  a single-boot soak — thousands of spawn/charge/supervise/reclaim/reap cycles (12k spawns) —
  asserting the lifecycle + accounting invariants return to baseline (zero live agents, zero
  zombies, ledger `used == 0`, bounded slot table) with no leak and no counter-overflow trap.
  Runs on both backends under QEMU. Deterministic (no RNG, no wall-clock).
These extend, not replace, the existing security gates (confined-agent family, broker
allow+deny audit gates, `parser-fuzz-test`/`net-fuzz-test`, ELF/syscall hostile-input gates,
`ledger-test`, `proc-supervisor-test`).

---

## 5. External-audit checklist

An independent audit of the production kernel should cover, at minimum:

- [ ] **Codegen / TCB:** review the emitted bounds + checked-arithmetic + typestate checks in
      `src/lower_c*.zig` / `src/lower_llvm*.zig`; confirm the differential (C vs LLVM) and
      `mcfuzz` oracles have teeth (mutation-test them).
- [ ] **uaccess:** audit every `copy_to/from_user` call site and the software page-table walk in
      `kernel/core/uaccess.mc` for TOCTOU, overflow, and partial-copy leakage.
- [ ] **Syscall dispatch:** audit each index/fd/op-routed path (§2.1) for out-of-range routing
      and confused-deputy issues.
- [ ] **Address-space setup:** review page-table construction, kernel-unmapping, and `satp`/TTBR
      switching; confirm no agent-reachable window maps kernel/peer memory.
- [ ] **Brokers:** audit `net_broker.mc` / `treefs.mc` / `mcp.mc` capability + budget checks for
      bypass; confirm every external effect is gated and audited.
- [ ] **Parsers:** re-fuzz DNS/TCP/IP/TLS/ELF with a larger hostile corpus + a coverage-guided
      fuzzer; look for over-reads the current `br_try_*` routing missed.
- [ ] **Resource accounting:** confirm every allocation/broker/device path charges the ledger and
      that no path can leak or double-release; drive the soak gate longer.
- [ ] **Audit trail:** review for suppress/forge resistance on the in-boot audit path.
- [ ] **DoS:** timer-driven process preemption is gated by `agent-preempt-test`; re-evaluate once
      uniform budgets land and confirm no agent can starve the kernel.
- [ ] **Vendored engines:** track upstream CVEs for WAMR/QuickJS/BearSSL and the vendoring
      process.
