# Agent OS — Vision & Change List

> North-star document. An OS whose **only** workload is AI agents — semi-trusted,
> long-running, communication-heavy, non-deterministic principals. We optimize for
> **safely hosting many agents**, not general computing.

Linux is the wrong shape for this: most of it serves general-purpose, multi-user,
hardware-owning, backward-compatible computing — none of which agents need. A
capability microkernel + a thin agent-runtime layer can be a fraction of the size,
and lean on isolation/IPC/capabilities that Linux bolts on awkwardly.

This kernel (an MC-language capability microkernel in the MINIX/seL4 lineage) is
already ~70% of the way there. The missing 30% is **resource governance →
observability → agent lifecycle**, in that order.

---

## BUILD — what agents need that this kernel lacks (prioritized)

| P | Feature | Why agents need it | State today |
|---|---------|--------------------|-------------|
| **P0** | **Resource governance** — real memory reclaim + per-agent accounting + quotas (mem / CPU / IPC) | One runaway agent must not OOM the host. *The* safety keystone for multi-agent hosting. | **Absent** — `heap_free` is a no-op (bump allocator), no accounting, no quotas |
| **P1** | **IPC observability / provenance** — kernel records the full agent message graph | Distributed tracing / audit / replay for a multi-agent system; the kernel already mediates every message | Not present (but uniquely easy here) |
| **P1** | **Capability delegation & attenuation** — spawn sub-agents with revocable, *reduced* authority | Agents orchestrate sub-agents; must hand off least-privilege and revoke on misbehavior | Partial (grant tables exist — lean in) |
| **P1** | **Agent lifecycle** — checkpoint / restore / pause / migrate | Agents are long-lived; snapshot for fault-tolerance, upgrade, scaling, "fork an agent" | Partial (service liveupdate only) |
| **P2** | **Durable agent memory/state** — a simple object/KV store | Agents need persistent context/memory — *not* a POSIX FS zoo | Has FS, but not agent-shaped |
| **P2** | **Fast agent↔agent / agent↔tool transport** — zero-copy, batched IPC | IPC is the hot path for agents (tool calls, sub-agents) | Functional IPC, not optimized |
| **P2** | **Admission & fair-share scheduling** — throttle/deprioritize misbehaving agents | Keep one agent from starving others | RR + priority + SMP (no fair-share/limits) |
| **P3** | **Deterministic record/replay** | Debug non-deterministic agents | Not present |

**P0 first slice (one PR, host-testable):** per-process physical-page accounting +
reclaim-all-on-`proc_exit` + a memory-quota field on `Process` enforced at
allocation, returning a typed `MemError` instead of exhausting the heap.

---

## KEEP — already better than Linux for agents

- **Capability security** (endpoints, grants, least-privilege masks) → *replaces*
  namespaces + seccomp + SELinux + cgroup-security with one native model.
- **Kernel-mediated IPC** → a built-in observation & control point Linux can't match.
- **Linear `move` + address-space types** → memory/aliasing safety the kernel enforces.
- **Supervisor + manifests (privileges-as-data)** → the agent-orchestration substrate;
  just add resource policy.
- **Small microkernel** → small TCB, auditable — which matters when the workload is
  semi-trusted code.

---

## SKIP — Linux generality agents don't need

- **Hundreds of POSIX syscalls / legacy ABI** → a tiny, clean, capability-passing ABI.
- **Multi-user / login / tty / desktop / X11** → agents aren't interactive humans.
- **Broad driver ecosystem** → run under a hypervisor; need only virtio + one NIC + a
  clock. Let the host own hardware.
- **Filesystem zoo** (ext4/btrfs/xfs/zfs, full VFS POSIX semantics) → one durable
  object/KV store.
- **Full netfilter / traffic-shaping / protocol zoo** → RPC transport + minimal egress
  TCP/IP.
- **Swap / NUMA-balancing / huge-pages / KSM** → simple per-agent page accounting +
  reclaim.
- **Signals / ptrace / pthreads / real-time classes** → agents are coarse principals.
- **Backward-compat / stable-ABI burden** → fresh, evolvable design.

---

## Will it be faster than Linux, or use far less resource? (edge devices)

Short answer: **much lighter — yes, decisively. Faster — only on the axes that
matter for agents, and only if IPC is engineered well. Raw general-purpose
throughput — not automatically, possibly slower.** Be precise about what's claimed.

### Footprint / resource use — a real, decisive win
- **Memory & boot:** a microkernel + minimal services is KB-to-low-MB and boots in
  milliseconds, versus a Linux kernel (tens of MB) plus a userland (hundreds of MB to
  GBs) and a long boot. Demonstrated repeatedly by seL4, MINIX, and unikernels.
- **TCB / attack surface:** orders of magnitude smaller — which matters precisely
  because the workload is semi-trusted agent code.
- **Idle overhead:** no daemon zoo, no general-purpose subsystems running in the
  background.
- **→ Edge fit is strong.** A small, secure, deterministic kernel running a few local
  agents (and small on-device models) on constrained hardware is a niche where Linux
  is genuinely heavyweight. This is one of the most defensible claims for the project.

### Speed — the honest, nuanced picture
- **The classic microkernel tax:** services (FS, net, drivers) live in userspace, so an
  operation crossing service boundaries costs **IPC** (context switches + message
  copies) where a monolithic kernel does an in-kernel function call. Naively, this makes
  a microkernel *slower* on syscall/IO-throughput benchmarks. (This sank Mach; seL4
  fixed it with sub-microsecond IPC — but it takes deliberate fast-path engineering,
  which this kernel's IPC does **not** yet have.)
- **But agent workloads are not throughput-bound.** An agent's wall-clock is dominated
  by **LLM inference and external/network latency (seconds)**. Kernel syscall overhead
  (nanoseconds–microseconds) is in the noise. "Faster kernel" is largely the **wrong
  metric** for the agent workload.
- **Where the agent OS *can* win on speed — the agent-relevant axes:**
  - **Cheap agent spawn / checkpoint / kill** — lightweight processes, small saved
    state → fork/snapshot an agent far cheaper than a Linux process or container.
  - **Optimized agent↔agent / agent↔tool IPC** — the kernel mediates every message, so
    a tuned fast path can beat Linux's general pipe/socket/shmem for *this specific
    pattern*.
  - **Predictable, low tail latency** — simple scheduler, no background noise, small
    state → more deterministic orchestration than a CFS-scheduled, daemon-heavy Linux.

### Verdict
- **Footprint / edge:** clear win — small, fast-booting, small-TCB, runs on constrained
  hardware. Lead with this.
- **Throughput vs Linux:** do **not** claim "faster" in general; a tuned microkernel
  *matches* Linux on the paths that matter and loses on raw syscall throughput it
  doesn't optimize. Linux is decades-optimized.
- **For agents specifically:** OS speed is dominated by inference, so the wins are
  **footprint, cheap spawn/checkpoint, optimized agent-IPC, predictable latency, and
  safety (resource isolation)** — not raw benchmark speed.

**The honest pitch:** not "a faster Linux," but **"a tiny, safe, predictable host
purpose-built for agents — small enough for the edge, with isolation and resource
control as native primitives instead of bolted-on cgroups/seccomp/namespaces."**

---

## The shape that falls out

A **tiny capability microkernel + thin "agent runtime"**: spawn / checkpoint / kill
agents · bound their resources · route + observe their IPC · delegate/attenuate
capabilities · persist their state. Anything Linux does that isn't in service of *that*
is out of scope.

**Roadmap order:** resource governance (P0) → IPC observability (P1) → agent lifecycle
(P1) → durable state + fast transport (P2). Start with the P0 first slice above.
