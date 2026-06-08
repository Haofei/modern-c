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

---

## Implementation status (items 3–7 of this review)

- **#4 (nested `arr[i].field[j]`) — DONE.** Compiler cure: `structTypeNameForExpr`
  gained an `.index` case (via `operandEmitType`) so a field-array of an array element
  lowers to `table[i].field.elems[j]`. Demonstrated by simplifying `udp_socket` to an
  **inline payload array** (`queue[k].payload[j]`), deleting the flat pool + offset +
  pool_used bookkeeping. (`socket-test`, `net-rx-test`, `net-fuzz-test` green.)
- **#5 (poll_until) — DONE.** `std/time.poll_until(probe, timeout)` (generic
  context-free predicate) + `std/virtqueue.vq_wait_used(vq, timeout)` (the typed form
  whose predicate needs the vq — the part that *would* use a closure). Migrated the
  `virtio_blk` + `virtio_net` (nic_transmit, tx_wait_reclaim) spin loops.
- **#6 (generic Ring) — DONE (in-place API), with a noted gap.** Generics already work
  (`Box<T>`, `Ring<T>`, the existing `stack-test`/`mono-test` gates). Added an
  **in-place mutable API** to the existing `std/ring` (`ring_init`/`push`/`pop`/`len`/
  `is_empty`/`is_full`) — a usable generic in-place container, gated by `ring-test`
  (FIFO/len/empty/full/wrap at `Ring<u32>`). **Gap:** unifying the kernel's
  *varying-capacity* rings (trace=64, socket=8) needs **const-generic struct params**
  (`Ring<T, N>`): the use site must accept an integer type-arg and the monomorphizer
  must substitute it into `[N]T`. The monomorphizer already substitutes `comptime N:
  usize` values into array sizes *for functions*, so it's a scoped extension (parser
  use-site + struct value-param + struct-instance subst), not a rewrite — deferred as
  it touches the core monomorphizer.
- **#7 (shared platform runtime) — DONE (shared layer + applied).** Created
  `kernel/arch/riscv64/platform.h` (mem/UART/finisher/CLINT time) and
  `platform_virtio.h` (vring + buffer structs + DMA transitions). Migrated
  `blk_runtime.c` (105→70 lines) and `net_runtime.c` (131→83 lines) to include them.
  Remaining standalone runtimes adopt the same two `#include`s mechanically.
- **#3 (closures) — DONE.** Added a first-class `closure(P...) -> R` type and a
  `bind(&obj, fn(*E, P...) -> R)` builtin that bundles a **typed** captured pointer with
  a function into a `{ code, env }` fat value; calling `c(args)` lowers to
  `c.code(c.env, args)`. The type-erasing casts (env → `void*`, fn-ptr → env-erased)
  are **compiler-generated**, so user code has no `ctx` word and no `u64`↔pointer casts.
  Threads through lexer/ast/parser/sema/mir/lower_c. Gated by `closure-test` (a closure
  captures a counter and mutates it across calls). **Applied:** `CharDevice` and
  `BlockDevice` dropped their `ctx: u64` word — backends now take a typed `*Uart` /
  `*Disk` captured by `bind(...)` (driver-test, kmain-test, blockfs-test green).
  (Lifetime of the captured object is the caller's responsibility — the closure stores
  a pointer to it; the kernel's captured objects are static/long-lived. A by-value
  inline-env form for escaping closures is a possible future extension.)

## 8. Type-erased allocator (`std/alloc`) — **DONE** (built on closures)

**Pattern.** The kernel has concrete allocators with different signatures (`Heap`'s
`heap_alloc`, the page allocator's `page_alloc`); generic code (containers, owning
closures, drivers) can't allocate without naming a specific backend.

**Migration.** Borrowed Zig's explicit-allocator idea: `std/alloc.Allocator` is a
type-erased handle `{ alloc, free }` whose ops are **closures that capture the concrete
allocator** — so the allocator abstraction is built *on* the closure feature (#3). Code
takes `*Allocator` and calls `alloc_bytes(a, size, align)` / `free_bytes(...)` without
naming the backend, and there is no implicit global heap — you pass the allocator in.
`kernel/core/heap.heap_allocator(&heap)` is the first adapter (`heap_alloc` is already
`(env, size, align) -> PAddr`, so it binds with no shim). Gated by `alloc-test`.
**Next:** an owning *move*-closure that takes an `Allocator`, allocates its env, and
frees it on `drop` (linear-checked) — turning the closure lifetime caveat above into a
compiler-enforced guarantee. The allocator feature is the dependency that unlocks it.

---

## Allocator framework — 5 phases (implemented)

A layered allocator framework built on closures (#3) + generics + `move`, gated in m0:

1. **`move Arena`** (`std/arena.mc`) — bump + bulk `reset`; the arena is the linear
   resource (forget `arena_destroy` → compile-time `E_RESOURCE_LEAK`, see
   `kernel/bad/arena_leak.mc`). Plugs into `Allocator` via `arena_allocator`. Gate
   `arena-test`.
2. **Generational handles** (`GenRef<T>` + `arena_resolve`) — `reset` bumps a
   generation; a handle held across a reset fails to resolve (`StaleHandle`). Runtime
   use-after-reset detection with no lifetimes. Gate `genref-test`.
3. **Typed owned allocation** (`std/alloc` `create<T> -> Owned<T>`, `own_free`) — a
   linear typed allocation, compile-time leak-checked (`kernel/bad/owned_leak.mc`).
   **Compiler change:** `sizeof(T)`/`alignof(T)` now work on a `comptime T: type`
   parameter (reflection deferred to monomorphization — `isKnownLayoutType` accepts an
   in-scope type param). Gate `owned-test`.
4. **Net RX on the arena** (`net_arena_demo`) — per-packet scratch is a `GenRef`, the
   frame is built + demuxed on arena memory, `reset` per packet; a handle across a
   reset is caught stale. Gate `net-arena-test`. (virtio_net's DMA ring stays on `move
   CpuBuffer` — already leak-checked through the device handoff.)
5. **Generational pool** (`std/pool.mc`) — per-slot generations make use-after-free,
   double-free, and stale-after-reuse fail closed (`StaleHandle`). Gate `pool-test`.

Net safety story (superset of Zig): compile-time leak detection (`move`), runtime
use-after-free/reset detection (generations), batch-free arenas.

**Remaining refinements (compiler):** const-generic struct params (`Pool<T, N>` /
`Ring<T, N>` with caller-chosen capacity — the pool is fixed-16 today); passing a
`comptime T` to a *nested* generic call (sidestepped by inlining in `std/pool`); and
the optional `as_ptr<T>` intrinsic for an ergonomic raw `*T` from `create<T>`.
