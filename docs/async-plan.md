# Async/await roadmap

Status: **Phases A, B, C landed**; D (syntax) — **ALL of straight-line + LAZY dependent-await
construction + CANCELLATION + BRANCHES + LOOPS landed** (steps 1–7). The transform handles
straight-line awaits, an `await` inside an `if`/`else` (each arm a state range joining a common
continuation), and an `await` inside a `while` loop (the poll wrapped in `while true` for the
back-edge). Plus follow-ups: the kernel vectored drain `async_poll_many`; `#[irq_context]`
enforcement on the whole `async_complete` wake chain; UFCS on generated future types
(`f__Fut.poll(&x)`); and the backend-parity fix so a `*dyn` dispatch call lowers directly as an
if/switch subject on both backends. **Phase D is feature-complete for the v0 scope.**

**Step 6 (cancellation) + lazy construction — DONE.** `kernel/lib/async.mc` gains `async_cancel(b,
t, id)` (free the inflight slot + release any parked waiter, idempotent; a late `async_complete`
on the canceled id is then a no-op), and `std/task.mc`'s `SlotFuture` gains an injected `cancel:
fn(u64)->void` + `slot_future_cancel`. The transform (`src/async_lower.zig`) now builds child0 in
the constructor and each LATER child LAZILY at the transition ending the prior step — so a later
awaited call MAY reference an earlier `await` result (`let t = await login(); let d = await
fetch(t);`), lifting the old `E_ASYNC_AWAIT_DEPENDS_ON_PRIOR` (fixture deleted). It also generates
a free `f__Fut_cancel(self)` that walks the CURRENT state's child via `<childFutType>_cancel` then
marks DONE (idempotent, no double-free). The leaf Future ABI is now uniform: `__poll` +
`_take_result` + `_cancel`. Soundness of leaving later child fields unbuilt in the constructor:
sema def-init tracks only SCALAR `uninit` vars, so a partially-built aggregate is accepted and each
`__cN` is written before its first poll. Gates (both backends): host `fuzz-async-cancel-lowering-test`
(hand-lowered acceptance target) + `fuzz-async-syntax-test` (real syntax: dependent await + cancel)
in diff-backend (129/129 agree); kernel `async-cancel-test` / `llvm-async-cancel-test` (QEMU, in m0:
fill the quota, cancel one, reuse the reclaimed slot — FXR, ASYNC-CANCEL-OK).

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
  complete (idempotent). Typed results are read from the concrete future via a per-type accessor
  (today `?T`, `race2_winner`, `timeout_timed_out`); a generic-over-`T` poll return is
  intentionally avoided (MC has no generic tagged unions, and type-erased results would force
  heap/unsafe). Phase D generalizes this to a uniform once-only `take_result() -> T` (see the
  Phase D typed-result ABI) — the trait stays `poll() -> bool`.
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

1. `async_await_irq(b, t, id, irq_off, irq_on, wfi)` — the IRQ-safe await. Interrupts stay OFF
   across the readiness check, the enqueue-and-park (`wq_prepare_wait`, split out of `wq_wait`),
   AND the idle `wfi`. RISC-V `wfi` resumes on a locally-enabled *pending* interrupt regardless of
   the global enable, and `irq_off` clears only the global bit — so a completion can be neither
   lost between check-and-park nor "taken-and-serviced just before we idle" (the lost-idle race).
   The await briefly enables interrupts only to *take* the pending ISR, then disables and
   re-checks `proc_current_blocked`. `irq_off`/`irq_on`/`wfi` are injected (riscv passes
   `disable_interrupts_global`/`enable_interrupts_global`/`wait_for_interrupt`) so
   `kernel/lib/async.mc` stays arch-neutral. (Precondition: entered with interrupts enabled; it
   uses plain disable/enable, not save/restore. Single waiter per id; `wfi`-idles rather than
   yielding to other runnable tasks — integrating with preemptive multi-task scheduling is broader
   scheduler work.)
2. The ISR wake path stays IRQ-safe by construction — `async_complete` only marks the slot and
   `wq_wake_one` (`proc_unblock`, an atomic bit-clear). No heap, no blocking, no dynamic dispatch;
   the loops are bounded. NOTE: this is not yet *enforced* with `#[irq_context]` — the wake reaches
   `endpoint_slot`, which returns a `Result`, and the MIR irq-context verifier currently rejects
   `Result` construction; closing that (relax the verifier, or a sentinel-returning irq-safe
   endpoint lookup) is a tracked follow-up.

Gate: `async-irq-test` / `llvm-async-irq-test` (both backends, in m0). A single task submits a
request, arms a **single-shot M-mode CLINT timer**, and `async_await_irq` PARKS it in `wfi`. The
timer fires; the M-mode trap vector (a `#[naked]` full-frame handler, 4-byte aligned by the
`#[align]`/naked default — the fix that unblocked this whole interrupt path) disarms the timer and
calls `async_complete` from interrupt context, waking the task. Trace `W I R` (await / completion
in ISR / resume) + `ASYNC-IRQ-OK` (result 42). This is the production shape: a task sleeps until a
device/timer interrupt resumes it.

The same wiring generalizes to a virtio-blk/net completion interrupt — the ISR calls
`async_complete(id, result)` for the finished op instead of a timer; the await side is identical.

## Phase D — `async`/`await` syntax (design contract + build order)

`async fn` lowers to a fixed-size, **stackless** state machine — pure sugar over the Phase-A
`Future`. It is a separate compiler project, greenlit only after A→C (done) prove the semantics.

**The first dependency is the CONTRACT, not the parser.** The parser sugar is the *last* step.
Before any transform we must (a) make the future/result/cancel contract precise, then (b) write
the exact MC the compiler should generate — by hand — as the acceptance fixtures, so "the
transform is correct" means "it emits ordinary MC that matches the hand-written state machines"
on both backends.

### The contract

**1. Typed-result ABI.** Phase A's `Future::poll` returns only readiness (`bool`) — it
deliberately does NOT carry `T` (MC has no generic tagged unions, so a generic `Poll<T>` return
would force heap/unsafe). So `async fn f(..) -> T` has nowhere standard to store/return the `T`
*unless we fix the protocol*. The protocol: **`poll() -> bool` + a generated once-only
`take_result() -> T`** per concrete future:

```
// generated for `async fn f(..) -> T`
struct FFuture { state: u8, /* captured live locals + child futures */ , result: T }
impl Future for FFuture { fn poll(self: *mut FFuture) -> bool { /* state machine */ } }
fn f_take_result(self: *mut FFuture) -> T   // valid EXACTLY ONCE, only after poll() == true
```

`await e` lowers to: poll `e` (suspend — `return false` — whenever `e.poll()` is `false`), then
read `e`'s value via its `*_take_result` accessor and advance. Leaf futures (`SlotFuture`, broker
readiness futures) get the same `take_result` shape, so typed results are uniform across
hand-written and generated futures. (Alternative the transform could adopt instead: a generic
`trait Future<T>` with `result(self) -> T` — same effect; the `take_result` form avoids generic
traits, which MC's procedural generics make awkward.)

**2. `poll()` must never block (the stackless invariant).** A generated `poll()` may ONLY poll
its child futures (Phase-A `Future`s / broker *readiness* futures) and `return false` when a
child is pending. It MUST NOT call the Phase-B/C **blocking** APIs `async_await` /
`async_await_irq` — those are stackful and park the current task. Blocking lives in exactly ONE
place: the *driver* of the top-level future — `run_to_completion` (cooperative) or the kernel
`async_await_irq` (park/wake). So `await` inside an `async fn` is a suspend point that returns
pending up the poll chain, never a park.

**3. Cancellation / drop — LANDED.** A started future that holds a `SlotFuture` owns a live
`MAX_INFLIGHT` slot (and an enqueued waiter) until it completes and its result is taken — and
`MAX_INFLIGHT` is tiny on an agent OS, so a leaked slot eventually wedges submission. This is now
fixed: the broker exposes `async_cancel(b, t, id)` (frees the slot, releases any parked waiter,
idempotent; a late completion on the canceled id is a no-op), `SlotFuture` carries an injected
`cancel`, and the transform GENERATES `f__Fut_cancel(self)` that walks the currently-active child
future down to the in-flight leaf and frees it, then marks DONE (idempotent — no double-free).
Because of LAZY construction at most one child is live at a time, so cancel only walks the current
state's child. This removes the v0 "must run to completion or leak" limitation.

**Broker integration + select/cancel-the-loser — LANDED.** `kernel/lib/async_future.mc` connects
the lowering to the real broker: `ReqFut` (a broker-backed `Future` leaf with the uniform
`__poll`/`_take_result`/`_cancel` ABI over `async_submit`/`async_slot_ready`/`async_take`/
`async_cancel_slot`), `drive_irq` (an IRQ-backed executor that generalizes `async_await_irq` from
one id to an arbitrary `*dyn Future`), and `ReqRace2` (race two requests, cancel the loser).
Gates: `async-future-test` (an `async fn`'s two awaits resolve against real timer-ISR completions)
and `async-select-test` (race two in-flight requests, complete the winner, cancel the loser, prove
`async_active_count` returns to 0) — both backends, in m0. **E1 — DONE (cancel in the `Future`
vtable).** `cancel(self: *mut Self) -> void` is now a second `Future` trait method, so a TYPE-ERASED
loser (`*mut dyn Future`) is cancelled through the vtable. The generic `std/task.mc` combinators were
upgraded: `Race2::poll` cancels the loser when a winner is decided, `Timeout::poll` cancels `inner`
on the timed-out edge, `Join2`/`Race2`/`Timeout` each gained a `cancel` that drops their children
(idempotent). Every `impl Future` now provides `cancel`: the hand-written leaves (`SlotFuture`,
`ReqFut`, `ToolFut`) and combinators, AND every TRANSFORM-GENERATED future — `src/async_lower.zig`
now routes the generated `f__Fut_cancel` free fn into the `impl Future` record's `cancel` vtable slot
(`cancelConfMethod`), mirroring how `poll` is wired, so generated futures satisfy the enlarged trait
on both backends. The trait-ABI/vtable-layout change was verified sound on C and LLVM
(`fuzz-dyn-ifcond-test`, the full `fuzz-task`/`fuzz-async-*` family, `async-select-test`). `ReqRace2`
is RETAINED — not because of the vtable gap (resolved) but as the TYPED-i32-RESULT convenience
(`req_race2_result` reads the winner's concrete `ReqFut`, which a type-erased `Race2` cannot, since
`poll` does not thread a typed value). `async-select-test` now exercises BOTH the generic dyn `Race2`
(phase 1, the E1 path) and the concrete `ReqRace2` (phase 2), each proving the loser is cancelled and
`async_active_count` returns to 0. Timeout is the same shape as race (race the operation against a
deadline request; whichever loses is cancelled).

**E2 — DONE (`await` of an arbitrary future-valued expression).** Until E2, `await e` required `e`
to be a plain named call `g(args)` — a lowering convenience, not a runtime limit, since an awaited
future just needs to be MATERIALIZED into the state machine's child slot and driven via its leaf
`__poll`/`_take_result`/`_cancel` ABI. `src/async_lower.zig` now generalizes the await operand: the
awaited future expression is evaluated by value into the child field (`self.__cN = <e>`) at the
transition that begins that await — exactly where the call used to be built — so the LAZY,
at-most-one-child-live invariant the E1 cancel walk depends on is preserved unchanged (child0 in the
constructor; each later child built at the prior transition; only `__cN` ever holds a live future),
and the `E_ASYNC_BORROW_ACROSS_AWAIT` check is unaffected (it still scans the generated constructor
for `&self.<field>`; a field/index await is a by-value copy, never an interior borrow). The future
type is resolved SYNTACTICALLY (no sema, since the transform runs pre-sema): a call's declared return
type, an awaited struct FIELD's declared type, or an array ELEMENT type — using a new struct-field
type map (`Lowerer.struct_fields`) and the current fn's param types (`Lowerer.param_types`).
**Supported await forms:** (a) call `g(args)` and `Owner.method(args)` (the parser pre-mangles a
static UFCS call to a plain ident call, so it already flowed through); (b) parenthesized such expr
`(g(args))` / `(ctx.fut)`; (c) struct-FIELD future `base.fut` where `base` resolves to a known struct
type (a param or a chain of struct fields); (d) array element `arr[i]` where `arr` is a param/field
of `[N]ElemFut`. **Deferred (later in Phase E):** `await` of a `*mut dyn Future` (the trait vtable
carries `poll`+`cancel` after E1 but NOT `take_result`, so the typed result is unreachable through
dispatch — dyn-await needs a result-typing story first), and any `e` whose future type is not
syntactically resolvable (a block expression, an inherent-impl method/UFCS call returning a future,
an arbitrary local of inferred type). These reject with `E_ASYNC_AWAIT_UNRESOLVED`. Gate:
`fuzz-async-await-expr-test` (field-future await `await ctx.fut` with a `+bias` tail, parenthesized
call await, and cancel-mid-await reclaiming the active child), both backends, in the diff-backend
parity set; the full `fuzz-async-*`/`fuzz-task` family and the QEMU `async-future`/`async-select`
gates stay green on C and LLVM.

**4. Ownership across `await` (the hard part — rules spelled out).** Capture analysis (which live
locals become state fields) must integrate with MC's move/borrow checker:
- a value **moved before an `await` cannot be used after it**;
- a **reference that spans an `await`** is allowed ONLY when the referent is itself captured into
  the future (proven to outlive the suspend) AND the borrow is formed at the future's STABLE address
  — i.e. inside the POLL machine, not the by-value constructor (see E4 below). All other
  cross-suspend interior borrows are forbidden (fail-closed);
- **no self-referential future fields** (a field pointing into the same future) unless pinning is
  introduced — unsupported. **ENFORCED** by `checkNoSelfBorrow`, which rejects
  `E_ASYNC_BORROW_ACROSS_AWAIT` when the generated **constructor** forms `&self.<field>`.
  - **E4 (v0.5 relaxation) — the soundness discriminator is WHERE the `&self.<field>` is formed:**
    - **CONSTRUCTOR-formed → REJECT (dangling).** The constructor builds `self` as a local and
      returns it BY VALUE, so any `&self.<field>` it forms points into the transient `self` and
      dangles after the move. The transform can place such a borrow in the constructor as a
      **first-await arg** `await g(&x)` (→ `self.__c0 = g(&self.x)`) or — in the LOOP lowering only —
      a **pre-loop** `let p = &x;` (→ `self.p = &self.x` in the constructor). Both stay rejected.
      Reject fixtures: `bad/async_borrow_across_await.mc` (pre-loop), `bad/async_borrow_pinning.mc`
      (self-referential / first-await-arg pinning).
    - **POLL-MACHINE-formed → ACCEPT (sound).** The driver owns the future by `*mut` and polls it
      IN PLACE (`run_to_completion`/`drive_irq` never move it between polls), so a `&self.<field>`
      taken in a poll state is at the future's STABLE address and stays valid across ANY number of
      subsequent suspends — including the loop back-edge. Two shapes are now allowed and pinned:
      a **loop-body** borrow `let p = &acc;` dereferenced across the back-edge into the next
      iteration's await, and a **pre-branch** borrow (the branch lowering REPLAYS the pre-branch
      straight-line into the poll dispatch, at stable `*mut self`, not the constructor) written
      through across an arm's await. Positive fixture: `fuzz_async_borrow_captured.mc`. The borrow
      used only in the tail (after all awaits) remains accepted: `fuzz_async_safe_borrow.mc`.
  - The check is made PRECISE, not weakened: it still scans only the constructor body (exactly the
    set of `&self.<field>` taken at the about-to-move address) — no false positives (poll-formed
    borrows never appear there) and no false negatives (the constructor never legitimately forms
    `&self.<field>`). The pre-loop case is conservatively rejected even though it COULD be made sound
    by replaying the borrow-init into the loop head (as the branch lowering already does); that
    relocation is deferred — E4 stays fail-closed there. Verified: the rejected pattern segfaulted on
    LLVM / lucked into copy-elision on C before the check;
- a captured local that owns a **resource / has a destructor** must be cleaned up on completion
  AND on cancellation (ties into rule 3).

**5. Control flow across `await` — scope v0 narrowly.** Straight-line and `if`/`else` first;
**loops are a later step.** Linear code maps to a simple state sequence; a loop with an `await`
creates a *re-enterable* state that must preserve the loop index/condition across suspension —
materially harder. Gate v0 with **straight-line + branches**, then add loops.

**E3a/E3b — DONE (`return`/`break`/`continue` inside an await-bearing loop or branch).** v0's loop/
arm bodies had to FALL THROUGH to the shared continuation / back-edge — a `return` in a branch arm
and `return`/`break`/`continue` in a loop body were rejected. E3a/E3b lift this by lowering each
non-fall-through edge to a state transition (`src/async_lower.zig`, `rewriteRegionStmt` /
`rewriteLoopBodyStmt`, recursing THROUGH non-await inner control flow so a conditional
`if c { return/break/continue; }` lowers too):
- `return v` (in a loop body, a branch arm, or the tail) → the terminal DONE transition
  `self.result = v; self.state = DONE; return true;`.
- `break` → `self.state = cont_state; continue;` (re-enter the `while true` poll wrapper → the
  continuation/tail state).
- `continue` → `self.state = 0; continue;` (re-enter → the loop-head state, which re-checks the
  condition).
The emitted `continue;` re-enters the while-true (which checks DONE then dispatches on the NEW
state), modelling the source edge exactly while skipping the rest of the body block + the back-edge.
**At-most-one-child-live + cancel-on-exit are preserved:** every such edge lives in a region's
straight-line code, which runs AFTER that region's await TOOK its result — so NO child is live at
the edge. Jumping to DONE is a clean exit (a later cancel finds DONE → no active child → no
double-free; a later poll early-returns true). `continue` re-enters the loop head, which rebuilds
`__c0` exactly ONCE per entry; `break` builds no child — so no leak and no double-build across the
back-edge/exit edge. The mid-flight child of a still-SUSPENDED await (the future dropped while
parked, NOT at a `return`/`break`) is still freed by the generated cancel. An INNER (await-free)
loop's own `break`/`continue` are NOT rewritten as the outer async loop's edges (the
`in_inner_loop` guard); a `return` inside it still exits the whole async fn. Gates (both backends,
in diff-backend): `fuzz-async-return-inregion-test` (early loop return, both-arm returns, normal
loop-exit return, cancel-mid-loop-before-return) and `fuzz-async-loop-breakcont-test` (break-on-cap,
never-break exit, continue-skip, cancel-mid-loop). The old `bad/async_loop_break.mc` and
`bad/async_branch_return_in_arm.mc` reject fixtures now COMPILE and were removed; a new
`bad/async_loop_nested_await.mc` keeps the still-illegal "await nested in inner control flow"
(= E3c) rejected with `E_ASYNC_LOOP_UNSUPPORTED`.

**E3c — DONE (nested awaits / multiple await-bearing constructs).** An `await` nested inside an `if`
inside a `while`, AND more than one await-bearing construct in one `async fn` (e.g. an await-bearing
`if`/`else` followed by an await-bearing `while`), now lower via a GENERAL structured-CFG path
(`src/async_lower.zig`, `lowerAsyncGeneralFn` + `lowerStmtsGen`). The whole fn body becomes ONE
`while true { if state==DONE return true; <if state==N {…}> } return false;` dispatch with a
per-suspend-point state numbering, replacing the flat "one contiguous range per construct" allocator
for these shapes. Routing: `needsGeneralLowering(body)` sends ONLY the previously-rejected shapes
(nested await, or >1 top-level await-bearing construct) to the general path; the two fast paths
(`lowerAsyncFn` linear/branch, `lowerAsyncLoopFn`) keep their byte-for-byte lowering for the shapes
they already handle, so the five pre-existing async shapes are untouched (zero regression).

The crux invariants hold BY CONSTRUCTION. **Each `await` is its OWN poll-state**, which only polls
`&self.__cN`, suspends while pending (`return false`), then takes the result into the binding field —
it NEVER builds a child. **A child is materialized on the ENTRY EDGE** (the predecessor block),
`self.__cN = <expr>; self.state = pollState; continue;` — so **build-once-per-entry**: a re-poll
re-enters the poll-state through the while-true dispatch (NOT the edge) and does not rebuild (it would
re-issue the awaited side effect / re-submit a broker slot); a loop back-edge re-runs the head, which
routes through the body-entry edge that rebuilds the loop child exactly once per iteration. Because
the build sits on the edge and the take happens inside the poll-state before control leaves it,
**at-most-one-child-live** holds: no edge builds two children, and the next await's child is built
only after the prior poll-state took its result and left. `if`/`else` arms each get an entry
trampoline + their own poll-states, converging on a fresh JOIN state; a `while` gets head/body-entry/
exit states with the body's fall-off as the back-edge to the head; `return`/`break`/`continue` lower
to state-edges (return→DONE; break→exit; continue→head) that run AFTER the region's await took its
result (no live child at the edge). The constructor builds NO child (every child is edge-built in
`poll`), so `checkNoSelfBorrow` over the constructor stays sound+complete UNCHANGED (it never had to
scan poll-formed borrows; the general path simply moves even more builds out of the constructor).
Generated `cancel` walks `if state==N { __cN_cancel }` per await poll-state then marks DONE
(cancel-on-every-exit + idempotent). Gates (both backends, in diff-backend):
`fuzz-async-nested-await-test` (await in an `if` in a `while`: full run, arm-not-taken,
cancel-parked-on-outer-await, cancel-parked-on-inner-nested-await — a leak/double-free/double-build
detector returns to 0 only if every child was built once and freed once) and
`fuzz-async-multi-construct-test` (leading await → await-`if`/`else` → await-`while`: both arms,
zero-iteration loop, cancel on the leading await, cancel parked in the loop after the if region
completed asserting exactly one live slot). The old `bad/async_loop_nested_await.mc` reject (the shape
is now legal) was removed; a new `bad/async_for_await_nested.mc` keeps an await inside a `for` loop
rejected with `E_ASYNC_GENERAL_UNSUPPORTED` (the general lowerer supports `let x = await e;`, bool
`if`/`else`, and `while` — a `for`'s iterator desugaring is not yet modelled).

**6. IRQ context.** `async fn` is forbidden in `#[irq_context]` (it suspends / uses `*dyn`).
Separately, polling an arbitrary `*dyn Future` from `#[irq_context]` stays forbidden (indirect
call). A generated `poll()` could in principle be called from IRQ context only if ALL its callees
are proven IRQ-safe — not worth supporting initially; treat generated futures as task-context only.

### Build order (do NOT start with syntax)

1. **Define the typed future ABI** — `poll()`/`take_result()` (or `Future<T>`); update `std/task.mc`
   leaf futures (`SlotFuture` etc.) to expose `take_result`.
2. **Hand-write the lowered examples** — the exact MC state machines for 2–3 `async fn`s, as
   differential fixtures (both backends). These are the spec and the acceptance target.
   *(Started: `tests/c_emit/fuzz_async_lowering.mc` / `fuzz-async-lowering-test` — pins the
   `poll()`/`take_result()` ABI with single-await and two-awaits-in-sequence, both backends
   agree. The transform's output must match fixtures of this shape; extend with branch/loop/
   moved-after-await cases as steps 4–6 land.)*
3. **Implement the transform for straight-line `await`** — emit MC that matches the fixtures. **DONE**
   (incl. LAZY per-state child construction, so a later await may read an earlier await's result).
4. **Add branches** (`if`/`else` with `await` on one side). **DONE** — each arm a state range
   joining a common continuation; spec `fuzz_async_branch_lowering.mc`, gate `fuzz-async-syntax`.
5. **Add loops** (preserve index/condition across suspension). **DONE** — poll wrapped in
   `while true` for the back-edge; spec `fuzz_async_loop_lowering.mc`. v0 loop scope: one `while`,
   body = leading await-run + straight-line. **E3a/E3b** then added `return`/`break`/`continue`
   inside the loop/branch body (each maps to a state transition; see §"Control flow across `await`").
   **E3c** then lifted the last restriction: nested awaits (await in an `if` in a `while`) and
   multiple await-bearing constructs in one fn now lower via the general structured-CFG path
   (`lowerAsyncGeneralFn`), routed only for those shapes so the fast paths stay byte-for-byte.
6. **Add cancellation / resource cleanup** (`cancel`/drop walking child futures + broker
   `async_cancel(id)`). **DONE.**
7. **Only then add the parser sugar** (`async fn` / `await` keywords). **DONE** (contextual
   `async`/`await`, applied alongside step 3).

Follow-ups beyond the 7 build-order steps, all **DONE**: kernel vectored drain `async_poll_many`
(`async-pollmany-test`); `#[irq_context]` enforcement on the `async_complete` wake chain (sentinel
`endpoint_slot_or` replaces the non-irq-safe `Result` lookup); UFCS on generated futures
(`f__Fut.poll(&x)` → `f__Fut__poll`); interior-borrow-across-await soundness
(`E_ASYNC_BORROW_ACROSS_AWAIT`); the backend-parity fix below; **broker integration** (`ReqFut`
leaf + `drive_irq` executor + `async-future-test`); **select/cancel-the-loser** (`ReqRace2` +
`async-select-test`, `MAX_INFLIGHT → 0`); the **capstone agent demo** (`async-agent-test`: an agent
in real async/await resolving tool calls over the broker + timing one out); and **try-await**
(`let x = (await e)?;` Result-propagation, `fuzz-async-try-test`). Spec: §33 of
`docs/spec/MC_0.7_Final_Design.md`.

### Acceptance gates (each both-backend, matching the hand-written state machine)

- `async fn` returning a scalar result; two `await`s in sequence; out-of-order child completion;
  branch with `await` on only one side; loop with multiple `await`s;
- a value moved-after-`await` is **rejected**; a reference spanning an `await` is rejected (or proven);
- C and LLVM generated code match the hand-written fixtures.

## Backend follow-up found while building Phase A — RESOLVED

A **`*dyn` dispatch call used directly as an `if`-condition whose body terminates**
(`if self.inner.poll() { return ... }`) now lowers cleanly on BOTH backends; the hoist workaround
in `std/task.mc` (Race2/Timeout) is removed. Root cause on both sides was that the dispatch call's
return type was not resolved, so the if/switch SUBJECT could not be typed: LLVM `callReturnType`
returned null → `emitScalarSwitch` bailed (`UnsupportedLlvmEmission`); C `callReturnTypeForExpr`
returned null → the bool subject was not cast to `(int)` → clang `-Wswitch-bool` under `-Werror`.
Both now resolve the trait method's return type. Gate: `fuzz-dyn-ifcond-test` (both backends).
