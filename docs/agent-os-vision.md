# Agent OS — Vision & Change List

> North-star document. An OS whose **only** workload is AI agents — semi-trusted,
> long-running, communication-heavy, non-deterministic principals. We optimize for
> **safely hosting many agents**, not general computing.

Linux is the wrong shape for this: most of it serves general-purpose, multi-user,
hardware-owning, backward-compatible computing — none of which agents need. A
capability microkernel + a thin agent-runtime layer can be a fraction of the size,
and lean on isolation/IPC/capabilities that Linux bolts on awkwardly.

This kernel (an MC-language capability microkernel in the MINIX/seL4 lineage) already
has the hard isolation primitives — capabilities, kernel-mediated IPC, address-space
and linear-move type safety — plus the first agent-governance layer. The remaining work
is turning that gated prototype surface into a production appliance: comprehensive
resource charging, durable policy/audit, isolated tool-server transport, and a fixed
platform profile.

> **Implementation status:** much of the original agent-OS backlog has landed:
> resource-accounting primitives, live OOM reclaim, provenance/audit, capability
> attenuation, checkpoint/restore/migrate seeds, pause/fair scheduling hooks, and
> brokered FS/network demonstrations are gated. The table below now lists the remaining
> current gaps; see [`todo.md`](todo.md) for the short operational roadmap.

---

## Threat model — what "semi-trusted" means

This word carries the whole security argument, so pin it down. Three tiers, in
increasing difficulty:

1. **Buggy agents** — unintentional resource exhaustion, crashes, malformed messages.
2. **Adversarial agents** — code you didn't write, actively trying to escape, escalate,
   or exfiltrate.
3. **Hijacked agents** — an agent you *did* trust, whose behavior is steered by
   attacker-controlled input (prompt injection, poisoned tool output). Its *intended*
   actions become the attack; it wields its **legitimate** capabilities maliciously.

These map onto three security functions — and onto the three roadmap pillars:

| Function | Bounds… | Pillar | Strong against |
|----------|---------|--------|----------------|
| **Reachability** | what an agent can name/touch | **Capabilities** (have) | tiers 1, 2 |
| **Blast radius** | how much it can consume/damage *within* its authority | **Resource governance** (P0) | tier 1 runaway, tier 3 |
| **Detect & respond** | notice anomalous behavior → revoke caps → kill | **Observability** (P1) | tier 3 (the only real answer) |

The key insight: **capabilities alone do not stop tier 3.** A prompt-injected agent
acts within its granted authority, so reachability bounds don't fire. The defenses that
*do* matter against the hardest threat are governance (bound the damage) and
observability (see it, revoke, kill). The kernel has prototype mechanisms for both;
production still requires comprehensive coverage, persistence, and policy actuation.

---

## BUILD — what agents need that this kernel lacks (prioritized)

| P | Feature | Why agents need it | State today |
|---|---------|--------------------|-------------|
| **P0** | **Resource governance completion** — allocator charging + CPU / IPC / accelerator budgets | A runaway or hijacked agent must not OOM/starve the host. The safety keystone. | Memory accounts, live OOM reclaim, and fault containment are gated; allocator-to-charge wiring and non-memory budgets remain. |
| **P0** | **Durable policy and audit** — persist decisions, audit trails, and reboot explanations | Tier-3 defense needs evidence that survives crashes and policy changes that can act on live agents. | Provenance/audit and policy seeds are gated; production persistence and full revoke/throttle/kill integration remain. |
| **P1** | **Production tool surface** — isolated tool server + stable catalog + JS network fetch | Agents should have no ambient FS/network authority; every external effect must be brokered and attributable. | Real FS broker, JS `host_net_fetch`, real TCP-backed network broker demos, and promoted TCP-backed JS net-tool gates exist; out-of-process transport, stable tool catalog, and durable policy/audit remain. |
| **P1** | **Full-context agent lifecycle** — checkpoint / restore / pause / migrate | Agents are long-lived; snapshot for fault-tolerance, upgrade, scaling, "fork an agent." | Fd/account checkpoint/restore/migrate seeds exist; full execution context and production persistence remain. |
| **P1-** | **Durable agent state** — checkpoint sink + small object/KV store | Checkpoint/restore needs somewhere durable; an agent that cannot survive restart is less useful. | Blob/KV/filesystem pieces exist; product-shaped persistent state and retention policy remain. |
| **P2** | **Rich agent memory store** — content-addressed / KV for agent context | Persistent agent memory beyond checkpoints | — |
| **P2** | **Fast agent↔agent / agent↔tool transport** — zero-copy, batched IPC | IPC is the hot path (tool calls, sub-agents) | Functional IPC, not optimized |
| **P2** | **Admission & fair-share scheduling** — throttle/deprioritize misbehaving agents | Keep one agent from starving others | Fair-pick and pause hooks exist; production CPU budgets and admission control remain. |
| **P3** | **Deterministic record/replay** | Debug non-deterministic agents | Durable recorder seed exists; deterministic replay remains absent. |

**Dependency edges the linear order hides:** *checkpoint/restore (P1) → durable sink
(P1‑)*; *observability (P1) ⇄ fast transport (P2)* are a co-design pair, not
independent (see below).

### P0 in detail — the remaining milestone is comprehensive enforcement

Be precise about what closes the threat. The thesis opens with "one runaway agent must
not OOM the host" — and **the runaway is precisely the agent that never calls
`proc_exit`.** The live reclaim/OOM-kill mechanism exists now; the remaining production
gap is making every relevant resource path feed it:

- **Comprehensive memory enforcement:** every allocator path charges the owning agent,
  with typed quota failure instead of exhausting the heap.
- **Non-memory enforcement:** IPC volume, request/result buffers, CPU/event-loop time, and
  **accelerator/compute** if inference is on-host — see Deployment.
- **Production actuation:** policy decisions can throttle, revoke, pause, or kill a live
  agent and leave durable audit evidence.

Do not treat a demo gate as a production claim until the coverage is complete across the
first appliance workload.

---

## KEEP — already better than Linux for agents

- **Capability security** (endpoints, grants, least-privilege masks) → *replaces*
  namespaces + seccomp + SELinux + cgroup-security with one native model. (Bounds
  reachability — see Threat model for what it does *not* cover.)
- **Kernel-mediated IPC** → a built-in observation & control point Linux can't match.
- **Linear `move` + address-space types** → memory/aliasing safety the kernel enforces.
- **Supervisor + manifests (privileges-as-data)** → the agent-orchestration substrate;
  add resource + observability policy here.
- **Small microkernel** → small TCB, auditable — which matters when the workload is
  semi-trusted code.

---

## SKIP — Linux generality agents don't need

- **Hundreds of POSIX syscalls / legacy ABI** → a tiny, clean, capability-passing ABI.
- **Multi-user / login / tty / desktop / X11** → agents aren't interactive humans.
- **Broad driver ecosystem** → see Deployment; under a hypervisor you need only virtio +
  one NIC + a clock. (This *relocates* the driver burden to the host — it does not
  vanish, and on bare-metal edge it returns.)
- **Filesystem zoo** (ext4/btrfs/xfs/zfs, full VFS POSIX semantics) → one durable
  object/KV store.
- **Full netfilter / traffic-shaping / protocol zoo** → RPC transport + minimal egress
  TCP/IP.
- **Swap / NUMA-balancing / huge-pages / KSM** → simple per-agent page accounting +
  reclaim.
- **Signals / ptrace / pthreads / real-time classes** → agents are coarse principals.
- **Backward-compat / stable-ABI burden** → fresh, evolvable design.

---

## Deployment — two lanes with different driver answers

"Runs on constrained hardware" and "requires a hypervisor" are in tension; they are
**two targets**, and the driver problem has a different answer in each:

- **Hypervisor-hosted (server / cloud edge):** the host or hypervisor owns hardware and
  drivers; the agent OS sees only virtio + a NIC + a clock. The driver burden is
  **relocated, not eliminated.** This is the near-term target and where the
  small-footprint story is cleanest.
- **Bare-metal edge (smallest devices):** no hypervisor underneath, so **the driver
  problem returns** — you must own real drivers for one chosen device family. Footprint
  and determinism still win, but "tiny" now includes a driver set. Pick a target device
  class deliberately; don't assume virtio.

**Where the agent's work runs** shapes P0 directly and is currently missing from BUILD:

- **Remote inference (API calls):** governance is mostly network/IPC budget. Simplest.
- **On-host accelerator (GPU/NPU):** governance **must account compute/VRAM** — a
  *different beast* than page accounting, with its own reclaim and preemption story.
- **On-device small model:** governance accounts compute + memory tightly on a budget.

If inference is on-host or on-device, accelerator accounting belongs **inside P0**, not
as an afterthought.

---

## Will it be faster than Linux, or use far less resource? (edge devices)

Short answer: **much lighter — yes, decisively. Faster — only on the axes that matter
for agents, and only if IPC is engineered well. Raw general-purpose throughput — not
automatically, possibly slower.**

### Footprint / resource — a real, decisive win
- **Memory & boot:** a microkernel + minimal services is KB-to-low-MB and boots in
  milliseconds, vs a Linux kernel (tens of MB) plus a userland (hundreds of MB to GBs)
  and a long boot. Demonstrated by seL4, MINIX, unikernels.
- **TCB / attack surface:** orders of magnitude smaller — which matters precisely
  because the workload is semi-trusted agent code.
- **Idle overhead:** no daemon zoo, no general-purpose background subsystems.
- **→ Edge fit is strong** in the hypervisor-hosted lane; on bare-metal edge it remains
  strong on footprint but you re-acquire a driver set (see Deployment).

### Speed — the honest, nuanced picture
- **The classic microkernel tax:** services (FS, net, drivers) live in userspace, so an
  operation crossing service boundaries costs **IPC** (context switches + copies) where
  a monolithic kernel does an in-kernel call. Naively this makes a microkernel *slower*
  on syscall/IO throughput. (This sank Mach; seL4 fixed it with sub-microsecond IPC —
  but it took deliberate fast-path engineering this kernel does **not** yet have.)
- **But agent workloads are not throughput-bound.** Wall-clock is dominated by **LLM
  inference + network latency (seconds)**; kernel overhead (ns–µs) is noise. "Faster
  kernel" is largely the **wrong metric**.
- **Where the agent OS *can* win on speed:** cheap agent **spawn / checkpoint / kill**
  (lightweight processes, small state); **optimized agent-IPC** for the specific
  message pattern agents use; **predictable, low tail latency** (simple scheduler, no
  background noise).

### A tension to design around: observability vs the IPC fast path
Recording the full message graph (P1 observability) is exactly the per-message work
that kills a fast path (P2 transport) — seL4's IPC is fast *because* the critical path
does almost nothing. These are **not independent features**; co-design them:
**sampling**, **asynchronous/off-critical-path provenance**, and **opt-out for
designated hot channels**. Decide the observability mechanism *before* committing to a
fast-path design, or one will invalidate the other.

### Verdict
- **Footprint / edge:** clear win — small, fast-booting, small-TCB. Lead with this.
- **Throughput vs Linux:** do **not** claim "faster" in general; a tuned microkernel
  *matches* Linux where it matters and loses on raw syscall throughput it doesn't
  optimize. Linux is decades-optimized.
- **For agents specifically:** the wins are **footprint, cheap spawn/checkpoint, tuned
  agent-IPC, predictable latency, and safety (resource isolation)** — not raw benchmark
  speed.

**The honest pitch:** not "a faster Linux," but **"a tiny, safe, predictable host
purpose-built for agents — small enough for the edge, with isolation and resource
control as native primitives instead of bolted-on cgroups/seccomp/namespaces."**

---

## The shape that falls out

A **tiny capability microkernel + thin "agent runtime"**: spawn / checkpoint / kill
agents · **bound and reclaim** their resources (including a live runaway) · route +
observe their IPC · delegate/attenuate capabilities · persist their state. Anything
Linux does that isn't in service of *that* is out of scope.

**Roadmap order from here:** finish comprehensive resource charging and non-memory
budgets → persist policy/audit → make the tool surface production-shaped and isolated
→ complete lifecycle persistence → rich state, fast transport, and production
admission control.

---

## Policy plane — the kernel/agent-runtime boundary

The kernel's job stops at *mechanism*; the *verdict* lives above it. Restating the
threat-model conclusion as an architectural seam so we don't overclaim:

- **The kernel provides** the mechanism for tamper-evident **provenance** (IPC,
  capability, FS, and network mediation paths) and cheap, decisive **levers**:
  revoke a capability, throttle, pause, OOM-kill, checkpoint/restore. Production work
  is making coverage and persistence complete for the chosen appliance surface.
- **The kernel does NOT decide** whether an agent is *misbehaving*. A prompt-injected
  (tier-3) agent acts **within** its granted authority, so no kernel rule fires —
  "this agent used a capability it was granted" is, by construction, allowed.
- **The verdict needs a behavioral baseline** ("is this agent doing what it should?"),
  which requires intent/policy the kernel can't have. That logic — anomaly detection,
  policy evaluation over the provenance stream, deciding *when* to pull a lever — is a
  **policy plane in the agent runtime, above the kernel.**

So the kernel is the **sensor + actuator**; the policy plane is the **controller**
(decide). Keeping them separate is deliberate: it keeps the kernel small and auditable,
and lets the policy plane evolve (or be swapped per deployment) without touching the
trusted base. The kernel's obligation is to make the controller *possible* with
bounded observability and cheap revocation/kill, not to be it.
