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

## Phase B — Park/wake broker (DONE)

`kernel/lib/async.mc` — the scheduler/broker integration std must not contain. A request-id-keyed
inflight table (`Inflight[MAX_INFLIGHT]`, **one `WaitQueue` per slot** — the first option), built
on the proven `wq_wait`/`wq_wake_all` + `proc_park`/`proc_unblock` primitives:

- `async_submit(b) -> id` — reserve a slot, monotonic id, or `ASYNC_NO_ID` if the `MAX_INFLIGHT`
  quota is full.
- `async_await(b, t, id) -> result` — PARK the current task (`wq_wait`) until the slot is ready;
  yields to the next runnable task or `wfi`, re-checks on wake. No busy-spin. **Single-consumer**
  (exactly one task awaits a given id — the submitter); it consumes and frees the slot.
- `async_complete(b, t, id, result)` — mark ready + `wq_wake_one` (matches single-consumer).
- `async_slot_ready(b, id)` — readiness predicate to inject into `std/task.mc`'s `SlotFuture`.

Stackful: one kernel/user stack per parked task, quota-bound by `MAX_INFLIGHT`. Gate: `async-test`
/ `llvm-async-test` (both backends, in m0) — two cooperative processes; a waiter parks on submitted
requests, a completer wakes it (out-of-order, one already-ready), `WCR` + `ASYNC-OK` (result 42).
The kernel-side `poll_many` (vectored drain over the inflight table) is a follow-up here.

**Scope: cooperative only.** `async_complete` is invoked from another *task*, so `async_await`'s
check-then-park is race-free (control only yields at `wq_wait`). It is NOT yet safe against a
completion from interrupt context — that is Phase C (see below), which must add the IRQ-off
wait-prepare. Do not wire `async_complete` to an ISR against this unchanged code.

**Backend parity fix made for this phase:** the LLVM backend emitted non-`export` module functions
with *external* linkage, so two objects that each inline a shared non-export helper (e.g.
`std/fmt_sink.mc`'s `fmt_put_*`) collided (`ld.lld: duplicate symbol`). It now emits `internal`
linkage for non-`export` functions (the analogue of the C backend's `static`) — MC inlines imports
per-object, so per-object copies are correct. This also fixed the pre-existing `llvm-ipc-test`.

## Phase C — IRQ-backed completion (DONE — production-readiness milestone)

A real interrupt completes the in-flight op and wakes the awaiting task — no steady-state polling.
Both requirements that were absent in Phase B are now in place:

1. `async_await_irq(b, t, id, irq_off, irq_on)` — the IRQ-safe await. It brackets the readiness
   check and the enqueue-and-park (`wq_prepare_wait`, split out of `wq_wait`) in an **interrupts-off
   critical section**, so a completion delivered from an ISR cannot land in the check-then-park
   window: by the time interrupts are re-enabled the task is already done, or enqueued+parked and
   reachable by the wake. `irq_off`/`irq_on` are injected (the riscv platform passes
   `disable_interrupts_global`/`enable_interrupts_global`) so `kernel/lib/async.mc` stays
   arch-neutral.
2. The ISR wake path stays IRQ-safe — `async_complete` only marks the slot and `wq_wake_one`
   (`proc_unblock`, an atomic bit-clear). No heap, no blocking, no dynamic dispatch.

Gate: `async-irq-test` / `llvm-async-irq-test` (both backends, in m0). A single task submits a
request, arms a **single-shot M-mode CLINT timer**, and `async_await_irq` PARKS it in `wfi`. The
timer fires; the M-mode trap vector (a `#[naked]` full-frame handler, 4-byte aligned by the
`#[align]`/naked default — the fix that unblocked this whole interrupt path) disarms the timer and
calls `async_complete` from interrupt context, waking the task. Trace `W I R` (await / completion
in ISR / resume) + `ASYNC-IRQ-OK` (result 42). This is the production shape: a task sleeps until a
device/timer interrupt resumes it.

The same wiring generalizes to a virtio-blk/net completion interrupt — the ISR calls
`async_complete(id, result)` for the finished op instead of a timer; the await side is identical.

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
