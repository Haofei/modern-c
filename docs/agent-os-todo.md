# Agent OS — Actionable Backlog

Derived from [agent-os-vision.md](agent-os-vision.md). Each item is sized for one PR,
host-testable on **both backends** (the discipline we've been using: a fixture + driver
in `tools/lib/host-tests.tsv`, validated via `host-harness.sh` (C) and
`llvm-host-suite-test.sh` (LLVM), plus `diff-backend`). `[ ]` = todo.

**Start here:** `P0.1`. **The safety milestone is `P0.5` (live reclaim) — not the
groundwork before it.**

---

## D — Decisions that gate scope (do first, they're cheap)

- [x] **D.1 — Deployment lane: hypervisor-hosted first.** Host/hypervisor owns
  hardware+drivers; the agent OS sees virtio + NIC + clock. (Bare-metal edge is a later
  target with its own driver set.)
- [x] **D.2 — Inference: remote-API first.** Governance is mem/CPU/IPC only for now;
  **accelerator accounting (`P0.6`) is deferred** until an on-host/on-device lane is
  taken.

---

## P0 — Resource governance (the keystone)

> Groundwork (`P0.1`–`P0.4`) is necessary but NOT the milestone. The runaway that OOMs
> the host is the agent that never exits, so cleanup-on-exit doesn't defend against it —
> `P0.5` (live reclaim) does.

- [x] **P0.1 — `ResourceAccount` primitive** (DONE — b3012a4) *(first PR; pure unit, like slotmap/fdspace)*
  - **What:** a struct `{ used, limit }` with `charge(n) -> Result<void, MemError>`
    (fails `OverQuota` without charging when `used+n > limit`), `uncharge(n)`,
    `available()`, `reset()`. New enum `MemError { OverQuota }`.
  - **Where:** new `kernel/lib/resacct.mc`.
  - **Test:** new `resacct-test` fixture — charge up to limit, over-limit fails closed
    (no partial charge), uncharge restores, reset clears.
  - **Depends on:** none.

- [x] **P0.2 — Per-process account + reclaim-on-exit** (DONE — a3acea6)
  - **What:** add a `ResourceAccount` (mem) to `Process`; `proc_table_init`/`proc_spawn`
    init it; `proc_death_cleanup` calls `uncharge`/`reset` (mirrors the `fd_init`
    on-exit we already added). Accessor `proc_macct(t, slot) -> *mut ResourceAccount`.
  - **Where:** `kernel/core/process.mc`.
  - **Test:** extend `forkfd_demo`-style driver — charge a process, `proc_exit`, assert
    its account is reset (released on exit).
  - **Depends on:** P0.1.

- [x] **P0.3 — Real reclamation in the allocator** (DONE — 472bb1a) *(load-bearing, not cosmetic)*
  - **What:** `heap_free` is currently a no-op (`heap_free_noop`). Replace the bump heap
    with a freeing allocator (free-list / buddy) **or** add per-process page-list
    tracking so reclaim actually returns memory. Without this, accounting drifts and
    even well-behaved agents exhaust the heap.
  - **Where:** `kernel/core/heap.mc` (+ page allocator / vmspace as needed).
  - **Test:** alloc/free cycles; `heap_available` returns to baseline after free; a
    long alloc/free loop does not monotonically shrink available memory.
  - **Depends on:** none (parallel to P0.1/2) — but P0.5 needs it.

- [x] **P0.4 — Quota enforcement at allocation** (DONE — acc8c46)
  - **What:** the per-process allocation path consults `proc_macct` and `charge`s;
    over-quota returns a typed `MemError` to the caller instead of exhausting the heap.
    Decide the seam: an allocator wrapper that carries the current process/domain.
  - **Where:** `kernel/core/heap.mc` + the allocator interface (`std/alloc.mc`) + the
    process allocation sites.
  - **Test:** a process with a small quota gets `OverQuota` at the limit; another
    process is unaffected (isolation).
  - **Depends on:** P0.2, P0.3.

- [x] **P0.5 — ⭐ LIVE reclaim (DONE — acc8c46) / OOM-kill-an-agent (THE SAFETY MILESTONE)**
  - **What:** under memory pressure or persistent over-quota, the kernel reclaims from /
    throttles / **kills a live agent that won't yield** — the runaway that never calls
    `proc_exit`. Reuse `proc_exit`/`proc_death_cleanup` for the kill path; add a
    pressure trigger and a victim-selection policy (most-over-quota first).
  - **Where:** `kernel/core/heap.mc` (pressure signal) + `kernel/core/process.mc`
    (forced termination) + `kernel/core/proc_sched.mc` (throttle).
  - **Test:** a runaway fixture that allocates in a loop without exiting is killed (or
    throttled) at its quota; other agents survive; the killed agent's memory + fds are
    reclaimed (ties to P0.2/P0.3).
  - **Depends on:** P0.2, P0.3, P0.4. **This closes the thesis threat.**

- [~] **P0.6 — Accelerator/compute accounting** (DEFERRED per D.2 — remote inference first) *(conditional — only if D.2 ≠ remote)*
  - **What:** extend `ResourceAccount` to a compute/VRAM budget with its own reclaim;
    GPU/NPU accounting is a different beast than pages.
  - **Depends on:** D.2 (on-host/on-device inference), P0.1.

---

## P1 — Observability, capabilities, lifecycle

### Observability / IPC provenance (co-design with the future fast path, P2.1)

- [x] **P1.1 — Off-critical-path IPC event ring** (DONE — 043eceb)
  - **What:** a bounded event ring the kernel writes provenance into; a service drains
    it. Design for **async / sampling** so it doesn't sit on the IPC hot path.
  - **Where:** new `kernel/core/ipc_trace.mc` (or `kernel/lib/`), drained by a service.
  - **Test:** events enqueued/drained; ring wraps without blocking the producer.
- [x] **P1.2 — Emit IPC provenance** (DONE — 0a60f2b) at the mediation points (from, to, tag, size,
  causality id). **Where:** `kernel/core/proc_ipc.mc`. **Test:** a 3-agent message chain
  produces the expected provenance graph; **hot-channel opt-out** flag suppresses it.
- [x] **P1.3 — Emit capability-use events** (DONE — 43862cb) (grant / revoke / cap invocation) so the
  audit covers *authority*, not just messages. **Where:** grant path + `kcall`.
- [x] **P1.4 — Sampling + opt-out policy** (DONE — fe0da04) — the lever that keeps P1.* from invalidating
  the P2.1 fast path. Co-decide the mechanism **before** building P2.1.

### Capability delegation & attenuation

- [x] **P1.5 — Attenuated sub-grant.** (DONE — f67572d) An agent spawns a sub-agent whose authority is a
  **subset** of its own (intersect `allow_mask`/`kcall_mask`; sub-grant a subset of
  grants). **Where:** `proc_spawn` + grant tables (`kernel/lib/granttab.mc`,
  `std/grant.mc`). **Test:** child cannot exceed parent's authority; over-grant rejected.
- [x] **P1.6 — Revoke cascade.** (DONE — a792f6c) Revoking/parent-death revokes delegated chains.
  Generational grants already revoke-on-owner-death; extend to delegated descendants.

### Agent lifecycle (needs a durable sink first)

- [x] **P1.7 — Minimal durable sink (P1‑ prerequisite).** (DONE — b98e303) A place to write a checkpoint
  blob (block region / simple object store). **Where:** reuse `kernel/fs/blockdev` or a
  new minimal store. **Test:** write blob → read back identical across a remount.
- [x] **P1.8 — Checkpoint.** (DONE — 8710acd) Serialize an agent (context, fds, caps, mailbox, accounted
  pages) to the sink. **Where:** new `kernel/core/checkpoint.mc`. **Test:** checkpoint a
  live agent; blob is self-describing.
- [x] **P1.9 — Restore.** (DONE — 8710acd) Rebuild an agent from a checkpoint into a fresh slot, caps
  re-validated. **Test:** checkpoint → exit → restore → state matches.
- [x] **P1.10 — Pause / resume.** (DONE — e8cb178) Freeze/thaw scheduling for an agent. **Where:**
  `proc_sched.mc` (block reason) + process state. **Test:** paused agent doesn't run;
  resume continues.

---

## P2 — Performance & richer state (after P0/P1)

- [x] **P2.1 — IPC fast path** (DONE — 451f300) (zero-copy / batched for hot channels) — **co-designed
  with P1.1/P1.4**; do not build until the observability mechanism is fixed.
- [x] **P2.2 — Rich agent memory store** (DONE — a2de19f) (content-addressed / KV) — beyond P1.7's
  checkpoint sink.
- [x] **P2.3 — Fair-share scheduling + throttle** (DONE — b61af75) — bound CPU per agent; deprioritize
  misbehaving agents (extends the P0.5 throttle path).
- [x] **P2.4 — Migrate** (DONE — 781893d) — checkpoint on A, restore on B (builds on P1.8/P1.9).

---

## P3 — Debuggability

- [x] **P3.1 — Deterministic record** (first cut DONE — 960618f; full re-exec future) (leverages P1.2 provenance).
- [x] **P3.2 — Replay.** (first cut DONE — 5e84da6; full re-exec future)

---

## X — Boundary / docs (not kernel code)

- [x] **X.1 — "Policy plane" boundary note.** (DONE — in agent-os-vision.md) The kernel provides *complete,
  tamper-evident provenance + cheap revoke/kill*; the **verdict** "is this agent
  hijacked?" (tier-3) needs a behavioral baseline and lives in a policy layer **above**
  the kernel. Document the seam so we don't overclaim the kernel solves tier-3 alone.

---

## Critical path (one-line summary)

`D.1/D.2` → `P0.1` → `P0.2`+`P0.3` → `P0.4` → **`P0.5` (milestone)** → `P1.1`/`P1.2`
(co-designed w/ `P2.1`) → `P1.5` → `P1.7`→`P1.8`/`P1.9`. Everything else trails.
