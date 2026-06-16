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
and linear-move type safety. What it lacks is the layer that turns "we can *isolate*
agents" into "we can *safely host* agents": **resource governance, observability, and
agent lifecycle.** That layer is the work.

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
*do* matter against the hardest threat are exactly the two things this kernel is
missing — governance (bound the damage) and observability (see it, revoke, kill). That
is why they are P0/P1, not nice-to-haves.

---

## BUILD — what agents need that this kernel lacks (prioritized)

| P | Feature | Why agents need it | State today |
|---|---------|--------------------|-------------|
| **P0** | **Resource governance** — accounting + quotas + **live reclaim** (mem / CPU / IPC / accelerator) | A runaway or hijacked agent must not OOM/starve the host. The safety keystone. | **Absent** — `heap_free` is a no-op (bump allocator), no accounting, no quotas |
| **P1** | **Observability / IPC provenance** — record the agent message + capability-use graph | Detect anomalous agents, audit, replay; the kernel mediates every message | Not present (but uniquely easy here) |
| **P1** | **Capability delegation & attenuation** — spawn sub-agents with revocable, *reduced* authority | Agents orchestrate sub-agents; hand off least-privilege, revoke on misbehavior | Partial (grant tables exist — lean in) |
| **P1** | **Agent lifecycle** — checkpoint / restore / pause / migrate | Agents are long-lived; snapshot for fault-tolerance, upgrade, scaling, "fork an agent" | Partial (service liveupdate only) |
| **P1‑** | **Durable state (minimal)** — a checkpoint sink + small object store | Checkpoint/restore (P1) *needs* somewhere durable; an agent that can't survive restart isn't useful | Has FS, but not agent-shaped |
| **P2** | **Rich agent memory store** — content-addressed / KV for agent context | Persistent agent memory beyond checkpoints | — |
| **P2** | **Fast agent↔agent / agent↔tool transport** — zero-copy, batched IPC | IPC is the hot path (tool calls, sub-agents) | Functional IPC, not optimized |
| **P2** | **Admission & fair-share scheduling** — throttle/deprioritize misbehaving agents | Keep one agent from starving others | RR + priority + SMP (no fair-share/limits) |
| **P3** | **Deterministic record/replay** | Debug non-deterministic agents | Not present |

**Dependency edges the linear order hides:** *checkpoint/restore (P1) → durable sink
(P1‑)*; *observability (P1) ⇄ fast transport (P2)* are a co-design pair, not
independent (see below).

### P0 in detail — the milestone is *live* reclaim, not cleanup

Be precise about what closes the threat. The thesis opens with "one runaway agent must
not OOM the host" — and **the runaway is precisely the agent that never calls
`proc_exit`.** So:

- **Groundwork (necessary, not sufficient):** per-agent accounting (pages, IPC volume,
  and **accelerator/compute** if inference is on-host — see Deployment), reclaim-all
  **on exit**, and a quota checked at `alloc`/`send` returning a typed error instead of
  exhausting the heap. *First host-testable slice.*
- **The actual safety milestone:** **reclaim from a live agent** — asynchronous reclaim
  under memory pressure, and **OOM-kill / throttle an over-quota agent that won't
  yield.** This is what defends against the tier-1 runaway and the tier-3 hijack. It
  touches the allocator, the process model, the scheduler, and failure semantics at
  once — i.e. it is most of the remaining engineering, not a small increment.

Reclaim-on-exit is the cleanup case and good groundwork; do not mistake shipping it for
solving the keystone threat.

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

**Roadmap order:** resource-governance groundwork → **live reclaim (the safety
milestone)** → observability (co-designed with the future fast path) → capability
attenuation + agent lifecycle (with a minimal durable sink) → rich state, fast
transport, fair-share. Start with the P0 groundwork slice; treat live reclaim, not
reclaim-on-exit, as "done."

---

## Policy plane — the kernel/agent-runtime boundary

The kernel's job stops at *mechanism*; the *verdict* lives above it. Restating the
threat-model conclusion as an architectural seam so we don't overclaim:

- **The kernel provides** complete, tamper-evident **provenance** (every IPC message
  and capability use, since it mediates them — P1.2/P1.3), and cheap, decisive
  **levers**: revoke a capability, throttle, pause, OOM-kill, checkpoint/restore.
- **The kernel does NOT decide** whether an agent is *misbehaving*. A prompt-injected
  (tier-3) agent acts **within** its granted authority, so no kernel rule fires —
  "this agent used a capability it was granted" is, by construction, allowed.
- **The verdict needs a behavioral baseline** ("is this agent doing what it should?"),
  which requires intent/policy the kernel can't have. That logic — anomaly detection,
  policy evaluation over the provenance stream, deciding *when* to pull a lever — is a
  **policy plane in the agent runtime, above the kernel.**

So the kernel is the **sensor + actuator** (see everything, act instantly); the policy
plane is the **controller** (decide). Keeping them separate is deliberate: it keeps the
kernel small and auditable, and lets the policy plane evolve (or be swapped per
deployment) without touching the trusted base. The kernel's obligation is to make the
controller *possible* — total observability + zero-cost revocation/kill — not to be it.
