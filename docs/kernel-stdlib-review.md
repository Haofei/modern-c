# Kernel review: what to migrate into the language / stdlib

A review of the kernel (`kernel/`, the demos, the runtimes) for recurring patterns
that should move down into the MC language or `std/`, so the kernel stops hand-rolling
them. Ordered by impact. Items marked **[done]** were migrated as part of this review;
the rest are recommendations with evidence.

## 1. Raw byte moves → `std/mem` + `std/bytes`  **[done]**

**Pattern.** Eight `while i < n { unsafe { raw.store<u8>(…, …) } }` loops scattered
across `uaccess`, `elf`, `ramfs`, `udp_socket`, `net_rx`, `console` — each with its own
`unsafe` block. This violates "keep unsafe minimal, encapsulated behind safe typed
APIs": the unsafe edge was duplicated, not centralized.

**Migration.** Added to `std/mem`: `mem_copy(dst: PAddr, src: PAddr, len)` and
`mem_set(dst: PAddr, value, len)`; to `std/bytes`: `br_copy_to(reader, off, dst, n)`
(bounds-checked read → raw store). `uaccess.copy_{from,to}_user` and
`elf.elf_load_segment` now call these — **4 hand-rolled unsafe loops removed**, the
raw load/store now lives in exactly two audited stdlib helpers. (Follow-up: the
MC-array-backed pool copies in `ramfs`/`udp_socket` want an analogous `ByteArena`
copy — see §4.)

## 2. `Result` error propagation → the `?` operator  **[done, partial]**

**Pattern.** ~22 `switch r { ok(v) => {} err(e) => { return err(e); } }` sites — pure
forward-the-error boilerplate. The language **already has** the postfix `?` operator
(`let v = expr?;` propagates the error, binds the ok value), but it was **unused** in
the kernel.

**Migration.** `uaccess.copy_{from,to}_user` now use `check_range(...)?` instead of the
4-line switch. The remaining sites that *map* the error (`err(e) => return
err(.OtherError)`) can't use `?` directly — see §3.

## 3. Capturing function values (closures) — **language gap**

**Pattern.** The driver framework encodes callbacks as `fn(u64, …)` + a separate
`ctx: u64` word (`CharDevice{putc: fn(u64,u8)->void, ctx}`, `BlockDevice{read:
fn(u64,u64,usize)->bool, ctx}`), and the backends take a `ctx: u64` they immediately
cast back to a pointer. This is a hand-rolled closure: the `ctx` word *is* the captured
environment.

**Recommendation.** A capturing function value (closure) would let a driver register
`||{ self.putc(b) }` and drop the `ctx: u64` plumbing + the `u64`↔pointer casts. It
would also unblock §5. (Today's fn-pointers are non-capturing, which is why the ctx
word exists.) Until then, a typed `Context` newtype instead of bare `u64` would at least
remove the casts.

## 4. Flat byte arena → `std/` container — **stdlib gap (rooted in a compiler gap)**

**Pattern.** `ramfs`, `udp_socket` store data in `pool: [N]u8` + per-record offsets,
and copy in/out with index loops, *because* nested `arr[i].field[j]` doesn't lower
(documented in `kernel-todo.md`). They re-implement the same flat-arena bookkeeping.

**Recommendation.** Either fix the nested-array lowering (removes the need for flat
pools), or add a `std` `ByteArena` (bump-allocate + `arena_copy_in/out`) that
centralizes the pattern. The former is the real fix.

## 5. Bounded poll/timeout → `std/time` helper — **stdlib gap, blocked on §3**

**Pattern.** Six `let start = read_ticks(); while !timed_out(start, read_ticks(),
TIMEOUT) { if <cond> { … } }` loops in `trap`, `virtio_blk`, `virtio_net`. The brief
lists "timeout/poll helpers" explicitly.

**Recommendation.** A `poll_until(deadline, predicate) -> bool` would collapse them —
but the predicate needs context (`vq_has_used(vq)`), so it depends on closures (§3) or
a `poll_until(ctx, fn(ctx)->bool, deadline)` form. Worth adding once §3 lands.

## 6. Fixed-capacity ring buffer → generic `std` container — **language gap (generics)**

**Pattern.** `trace` (event ring), `udp_socket` (datagram queue), `tcp_reasm` (segment
queue), and the virtqueue free-list all hand-roll a fixed-size ring with
`head/tail/count` + `% CAP`. 

**Recommendation.** A monomorphized `Ring<T, N>` (needs generic types over a value type
+ const size) would unify them. This is the largest single de-duplication available but
needs generics.

## 7. C runtime boilerplate — **shared platform layer (C-side)**

Every `*_runtime.c` redefines `memset`/`memcpy`, the UART, `_start`, the M→S drop, the
context-switch asm, the single-slot DMA pool, and the vring C structs. Not a
language/stdlib item, but a single shared `platform.c` (or generating these from the MC
`Machine`/`Context` definitions) would remove ~hundreds of duplicated lines.

---

### Summary of what landed this review
- `std/mem`: `mem_copy`, `mem_set`; `std/bytes`: `br_copy_to` — raw byte moves
  centralized, 4 scattered `unsafe` loops removed (§1).
- `uaccess` adopts the `?` operator for error propagation (§2).
- All 62 `m0` gates + the language fixtures stay green.

### Highest-leverage next steps (not yet done)
Closures (§3) — unblocks the driver `ctx` word and the poll helper (§5); generics for a
`Ring<T,N>` (§6); and the nested-array lowering fix (§4).
