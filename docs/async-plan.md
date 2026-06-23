# Async/await roadmap

Status: **Phase A landed**; B/C/D pending.

MC already has most of the async *runtime* and is missing the *vocabulary* and the *syntax*.
Rather than start with `async`/`await` keywords, we start with the runtime semantics production
needs, in four phases. A→B→C is the product feature; **D (syntax) is ergonomics and a separate
compiler project.**

## What already exists (do not reinvent)

- **Vectored, id-tagged broker**: `SYS_SUBMIT`/`SYS_POLL` with `ToolReq`/`ToolEvent`, request-id
  correlation, `MAX_INFLIGHT`/`MAX_REQ_BYTES`/`MAX_RES_BYTES` quotas (`user/abi.mc`).
- **Context switch + cooperative scheduler**: `mc_switch_context`, `sched_yield`
  (`kernel/core/sched.mc`, `kernel/arch/*/context.mc`).
- **Block/wake**: `WaitQueue` (FIFO, endpoint-based), `block_reasons` mask, `proc_block`/
  `proc_unblock` (`kernel/lib/waitqueue.mc`, `kernel/core/proc_sched.mc`).
- **Missing**: a `Future`/executor vocabulary, an interrupt→wake path for device completions
  (everything is polled today), and `async`/`await` syntax.

## Phase A — Task vocabulary (DONE)

`std/task.mc` — **pure**: it knows nothing about `ProcTable`, IRQs, wait queues, broker slots,
or syscalls. Fixed-size, no hidden heap.

- `trait Future { fn poll(self: *mut Self) -> bool }` — `poll` advances; returns true once
  complete (idempotent). Typed results are read from the concrete future (`?T` by convention:
  null = pending, value = ready); a generic-over-`T` poll return is intentionally avoided (MC has
  no generic tagged unions, and type-erased results would force heap/unsafe).
- `SlotFuture { id, done: fn(u64)->bool, ready }` — "a request id maps to a pending future",
  with the completion source **injected** so std stays pure (the kernel supplies a `done` backed
  by the inflight table in Phase B). One per in-flight request → callers keep live count ≤
  `MAX_INFLIGHT`.
- Combinators as `Future`s over `*mut dyn Future`: `Join2` (both), `Race2` (either, records
  `winner`), `Timeout` (inner-or-budget, records `timed_out`).
- `run_to_completion(f, idle)` executor — polls to completion, calling `idle` between non-completing
  polls (Phase A: a yield/step hook; Phase B: park / `wfi`).

Gate: `fuzz-task-test` (entry mode, both backends, in diff-backend) — a mock injected completion
source completes each future at a deterministic tick; join2/race2/timeout (both outcomes) +
nested composition verified. The **vectored drain** (`poll_many`) is deliberately deferred to
Phase B because in pure std it needs pointer arithmetic over `*dyn` fat pointers; in the kernel it
iterates the fixed inflight-slot table (typed, bounded).

## Phase B — Park/wake broker (the real production feature)

`kernel/lib/async.mc` (or `kernel/core/task.mc`) — the scheduler/broker integration std must not
contain. Replace "poll until ready" with: submit → park the task on the request/inflight slot →
broker completion marks ready → wake the task; idle path uses `wfi`. The current `WaitQueue` is
FIFO endpoint-based, not request-id keyed — so add either one wait queue per inflight slot, or a
`CompletionWait { id, endpoint }` table keyed by request id. Stackful: one kernel/user stack per
parked task, **quota-bound by `MAX_INFLIGHT`**. The kernel-side `poll_many` (vectored drain over
the inflight table) lives here.

## Phase C — IRQ-backed completion (production-readiness milestone)

A virtio-blk/net interrupt completes the inflight op and wakes the awaiting task — no steady-state
polling. Unblocked by the `#[align]`/naked-vector fix (the former "C-backend async-IRQ reset").
The IRQ wake path must stay **IRQ-safe**: no heap, no blocking, no dynamic dispatch — the ISR only
claims/completes and marks/defers a wake.

## Phase D — Optional syntax

`async fn` lowers to a fixed-size, stackless state machine (live locals across `await` become
fields; the body splits at each `await`; the fn becomes a `poll`), pure sugar over the Phase-A
`Future`. Forbidden in `#[irq_context]`; no hidden heap; **move/borrow across `await` must be
checked** (the subtle part — a value moved before an `await` cannot survive it). Both-backend
parity. A separate compiler project, greenlit only after A→C prove the semantics.

## Backend follow-up found while building Phase A

The LLVM backend does not yet lower a **`*dyn` dispatch call used directly as an `if`-condition
whose body terminates** (`if self.inner.poll() { return ... }`) — the C backend does. The
parity-clean form is to hoist the dispatch result into a local first (`let r = self.inner.poll();
if r { ... }`), which `std/task.mc` does. Worth fixing in the LLVM `if`/switch lowering so the
hoist isn't required.
