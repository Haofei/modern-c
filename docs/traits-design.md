# Traits / interfaces — design note (proposal)

**Status: proposal, for review.** This describes how MC can gain declared, checked
trait/interface abstraction **without** weakening any existing kernel-profile
guarantee (no GC / no hidden allocation, move/linear types, IRQ-context
discipline, `secret<T>` constant-time, opaque-struct opacity, no-UB IR, C+LLVM
parity). Nothing here is implemented yet.

The guiding result: **almost every MC invariant is preserved by one decision —
static dispatch is the default, and dynamic dispatch is explicit and inherits the
restrictions that already apply to "calling an unknown function."** Traits do not
punch a new hole in any analysis; the dynamic path reuses restrictions MC already
enforces.

One honest caveat up front: the **memory-safety and linearity** invariants compose
cleanly, but MC is also an **effect/context** language, and dynamic dispatch erases
effects, not just the callee. The dimension that genuinely needs design is the
effect system, not the memory model (§9). v1 stays sound by **excluding `dyn` from
effect-restricted contexts** (IRQ); lifting that exclusion is a separate, harder
project (§9.1, §11).

Prior art: Rust traits (minus `Box<dyn>`, minus specialization), Zig's two
polymorphism mechanisms (comptime duck typing + the hand-rolled `std.mem.Allocator`
`{ptr, vtable}` fat pointer). MC's contribution over Zig is the *declared, checked*
layer: a signature-level bound instead of comptime duck typing, and a forge-safe
compiler-emitted vtable instead of a hand-written struct.

---

## 1. Core principle — two tiers, static by default

Polymorphism splits into two layers so the hard constraints only ever apply to the
small, opt-in part.

- **Tier 1 — generic bounds (static, zero-cost, the default).** A constraint on the
  `comptime T: type` generics MC already monomorphizes. After monomorphization the
  concrete type is known, so calls are **direct** and every existing analysis
  (move, IRQ-context, opacity, secret) sees a concrete callee. No new runtime
  concept. Covers the large majority of kernel needs.

- **Tier 2 — trait objects (`*dyn Trait`, explicit, opt-in).** A fat pointer
  `{ data, vtable }` with the vtable in **rodata** (`static const`, no heap). You
  pay for dynamic dispatch only where you literally write `dyn`. Reuses the existing
  closure fat-pointer machinery (`{ code, env }`).

---

## 2. Syntax

Chosen to fit MC's existing grammar — `comptime T: type` generics + a `where`
clause (no Rust-style `[T: Trait]` brackets, which would clash with the `[N]T`
array syntax), and `*dyn`/`*mut dyn` pointers (MC has `*T`/`*mut T` pointers and
`&expr` address-of, not Rust `&T` references).

**Trait declaration** — a set of method signatures:

```
trait BlockDevice {
    fn read(self: *Self, lba: u64, buf: *mut [512]u8) -> Result<(), IoError>;
    fn block_count(self: *Self) -> u64;
}
```

**Conformance** — extends inherent `impl Type { ... }` with `impl Trait for Type`:

```
impl BlockDevice for VirtioBlk {
    fn read(self: *Self, lba: u64, buf: *mut [512]u8) -> Result<(), IoError> { ... }
    fn block_count(self: *Self) -> u64 { ... }
}
```

**Tier 1 — bounded generic (static):**

```
fn mount(comptime T: type, dev: *mut T) -> Result<Fs, Error>
    where T: BlockDevice
{
    dev.read(0, buf)?;   // DIRECT call to VirtioBlk.read after monomorphization
}
```

**Tier 2 — trait object (dynamic, explicit):**

```
fn register(dev: *dyn BlockDevice) -> void { ... }   // fat pointer {data, vtable}

let d: *dyn BlockDevice = &vblk;   // checked coercion -> emits a static vtable
register(d);
```

---

## 3. Tier 1 — generic bounds (static)

A bound `where T: Trait` is a constraint resolved at instantiation: the compiler
verifies `impl Trait for T` exists. The body may call the trait's methods on `T`
values; each lowers to a **direct** call after monomorphization.

Why this composes with everything for free: post-monomorphization there is no
polymorphism left — the callee is a concrete function. So the move checker,
IRQ-context check, opacity gate, and `secret<T>` analysis all operate on concrete
calls exactly as they do today. Tier 1 adds **zero** new runtime or analysis
concept; it is pure compile-time name resolution plus a conformance check.

This is the default and the recommended form for anything performance- or
context-sensitive (anything reachable from `#[irq_context]`, anything on a hot
path).

---

## 4. Tier 2 — trait objects (`*dyn Trait`)

A `*dyn Trait` is a two-word fat pointer:

```
{ data: *<erased>, vtable: *const VTable_Trait }
```

- The **vtable** is a compiler-emitted `static const` in rodata — one per
  `(Trait, ConcreteType)` pair. **No heap, ever.**
- The **data** pointer borrows a concrete object the caller already owns (stack,
  static, arena, pool). A `dyn` is always behind a pointer; you never own a
  `dyn Trait` by value.
- Dispatch is `dev.vtable->method(dev.data, args...)`.

There is intentionally **no `Box<dyn>`** and no owned-by-value trait object:
ownership of the concrete object never moves into the trait object, so no
allocator is implied and the no-alloc rule holds.

Coercion to `*dyn` is the only way to build a trait object in safe code, and it is
checked (§7): the compiler confirms `impl Trait for typeof(x)` exists and emits the
matching vtable. Safe code cannot fabricate a vtable.

---

## 5. Object safety — what can be `dyn`

A trait is **object-safe** (usable as `*dyn`) only if every method:

1. takes `self` **by pointer** — `self: *Self` or `self: *mut Self` — **not**
   `move self` and **not** `self` by value;
2. is **not** itself generic (no `comptime` parameters) — a finite vtable cannot
   hold infinite monomorphizations;
3. returns by value / pointer / `Result` / `?T`, not a type whose size depends on
   the erased concrete `Self`.

Rule (1) is the MC-specific one: you cannot move out of a borrowed `*dyn`, so
**consuming (`move self`) methods are static-dispatch only.** This preserves
linearity through dynamic dispatch with no new move-checker rule.

A trait that is not object-safe is still fully usable via **Tier 1**; it just
cannot be made into a `*dyn`.

---

## 6. Invariant-compatibility — how each MC rule stays intact

This is the normative core. Each existing guarantee, and the rule that preserves it.

| MC invariant | How traits preserve it |
| --- | --- |
| **No GC / no hidden allocation** | Vtable is `static const` (rodata). Trait objects exist only behind a caller-owned pointer (`*dyn`/`*mut dyn`). No owned `dyn` by value, **no `Box<dyn>`**. Ownership of the concrete object never enters the trait object. Zero heap. |
| **Move / linear types** | Only **borrow-self** methods (`*Self`/`*mut Self`) are object-safe (§5.1). `move self` is static-dispatch only — you cannot move out of a `*dyn` borrow, so linearity cannot be violated through a vtable. No new move-checker rule. |
| **IRQ-context discipline** (and effects generally) | A virtual call **is** an indirect call, and `#[irq_context]` already rejects indirect calls (`E_IRQ_CONTEXT_CALL`). So `dyn` dispatch is forbidden in IRQ context **for free — no new hole.** This is one instance of a general fact: **dynamic dispatch erases the callee's *effects*, not just its identity** (§9). MC stays sound because `dyn` is *excluded* from the one context (IRQ) where the strict effects concentrate; re-admitting it there is the genuinely hard part (§9.1). Polymorphism in an IRQ handler uses Tier 1 (concrete callee, all effects propagated). |
| **`secret<T>` constant-time** | Vtable pointers are ordinary code pointers, never secret. A secret cannot index a vtable array without tripping `E_SECRET_INDEX`. Falls out for free. |
| **Opacity / no forging** | Vtables are constructed **only** by the compiler at a checked `*dyn` coercion (§7). Safe code cannot hand-build a vtable; forging a conformance is gated like opaque-struct declassification, with an `unsafe` escape hatch. |
| **C + LLVM parity, no-UB IR** | `*dyn T` -> C `struct { void* data; const VT_T* vt; }`; dispatch -> `d.vt->read(d.data, ...)`. Trivial in C, native in LLVM. Function-pointer types match by construction -> no UB to forbid. |
| **Explicit, no hidden control flow** | Static dispatch is the default; a virtual call happens only where `dyn` is written. No surprise vtables; consistent with MC's pay-for-what-you-write stance. |

---

## 7. Coherence and forge-safety

- **Coherence:** at most one `impl Trait for Type` per `(Trait, Type)` pair. A second
  conflicting impl is `E_TRAIT_INCOHERENT`. This guarantees a unique vtable and
  unambiguous dispatch. (No blanket impls in v1 — see §10.)
- **Conformance checking:** an `impl Trait for Type` must provide exactly the
  trait's methods, with matching `self`-mode and effect/context annotations.
  A missing or mismatched method is `E_TRAIT_MISSING_METHOD` /
  `E_TRAIT_SELF_MODE_MISMATCH`.
- **Bound satisfaction:** instantiating `where T: Trait` with a `T` that has no
  conformance is `E_TRAIT_NOT_SATISFIED` (reported at the instantiation site, with
  the unmet bound named — unlike Zig's comptime duck typing, which fails deep in
  the body).
- **Object-safety violation:** forming `*dyn Trait` for a non-object-safe trait, or
  calling a `move self` method through `*dyn`, is `E_TRAIT_NOT_OBJECT_SAFE` /
  `E_DYN_MOVE_SELF`.
- **Forge-safety:** building a `*dyn` fat pointer by hand (assembling
  `{data, vtable}` from raw parts) is only allowed in `unsafe`, gated the same way
  as opaque-struct value-`as` declassification (`E_OPAQUE_DECLASSIFY`-class). Safe
  code reaches `*dyn` exclusively through the checked coercion.

---

## 8. Lowering (both backends)

**C backend** (`lower_c.zig`):

```c
struct VT_BlockDevice {
    int      (*read)(void *self, uint64_t lba, uint8_t (*buf)[512]); /* Result */
    uint64_t (*block_count)(void *self);
};
static const struct VT_BlockDevice __vt_VirtioBlk_BlockDevice = {
    &VirtioBlk_read, &VirtioBlk_block_count,
};
typedef struct { void *data; const struct VT_BlockDevice *vt; } dyn_BlockDevice;
/* dispatch: d.vt->read(d.data, lba, buf); */
```

**LLVM backend** (`lower_llvm.zig`): the same as a `{ i8*, %VT* }` struct value, the
vtable as a `@__vt_*` global constant, dispatch as a load-through-vtable + indirect
`call`. This is exactly the shape MC already emits for closures (`{ code, env }`),
so the fat-pointer plumbing is largely in place.

Tier 1 emits **no** new runtime artifact — monomorphized direct calls only.

---

## 9. The effect system is what traits actually stress

The memory-safety and linearity invariants (§6) compose **cleanly**, because the
design *contains* dynamic dispatch behind explicit opt-in and borrow-only object
safety. The genuine strain is elsewhere: MC is not only a memory-safety language,
it is an **effect/context** language — `#[irq_context]`, may-sleep, bounded-loop /
termination, capability requirements. Tier 1 propagates **all** of these
automatically (concrete callee). **Tier 2 erases the callee, and with it every
effect the callee carries.** This is the dimension to design carefully.

### 9.1 Effects through dynamic dispatch — the general requirement

For dynamic dispatch to preserve MC's effect guarantees in general, a trait
declaration would have to carry its **full effect/context contract** (may-sleep,
may-alloc, termination, caps), verified once per `impl` at conformance and honored
at every `*dyn` call site. An `#[irq_safe]` trait is just **one instance** of this:

```
#[irq_safe]
trait IrqSink {
    fn signal(self: *Self) -> void;
}
```

with conformance checking that **every** `impl IrqSink` body is itself irq-safe (no
`may_sleep`, transitively), so a `*dyn IrqSink` call may be permitted inside
`#[irq_context]`. This is the one place traits would *extend* the effect system
rather than merely inheriting it — and it generalizes to every effect, not just
IRQ. **It is the hard frontier, not optional polish.**

**What makes v1 sound without any of this:** keep `dyn` **excluded from
effect-restricted contexts** — i.e., forbidden inside `#[irq_context]` (which is
free today: a virtual call is an indirect call → `E_IRQ_CONTEXT_CALL`). Because
`#[irq_context]` is precisely where MC's strict effects (no-sleep, no-alloc)
concentrate, `dyn`-allowed-everywhere-*except*-IRQ is **effect-sound by
exclusion** — you cannot launder a forbidden effect through a vtable into the one
place it is forbidden, because the vtable call is rejected there. The effect
contract obligation only *bites* the moment you add `#[irq_safe]` (or any
`#[effect]`-carrying trait) to re-admit `dyn` into a restricted context. So v1
ships **without** effect-carrying traits, and `#[irq_safe]` is a deliberate,
separately-scoped follow-up (§11).

### 9.2 Local reasoning and verification posture

Two honest consequences of admitting `dyn`, neither a rule violation but both real:

- **`dyn` is the first construct in MC where the callee is not locally knowable** —
  its cost, traps, and effects are opaque at the call site. MC's appeal is local,
  transparent reasoning; a virtual call is definitionally opaque. The full opt-in
  (`dyn` must be written) is the containment, but this *is* a new category in a
  language built on transparency, and should be acknowledged rather than hidden.
- **`dyn` shifts MC from "check at the use site" to "check each `impl` against the
  contract once, trust at the call site"** — *modular* verification. This is sound
  and standard, but a genuine extension of MC's current posture. Note the
  connection: **T1.3 (interprocedural / lifetimes) needs the exact same shift**
  (function summaries verified once, trusted at calls). Traits and T1.3 therefore
  share a verification-infrastructure need; building one lays groundwork for the
  other.

### 9.3 Linear / owning trait objects (defer)

v1 says "you do not consume a driver through a vtable" — borrow-self only. If a
real use case appears for *owning and consuming* a heterogeneous object by vtable,
that requires a linear owning fat pointer (a `move`-tracked `{data, vtable, ...}`)
and an answer for who frees the backing storage. Defer until a concrete need
arises; it is a clean additive extension.

### 9.4 Traits and comptime

Static traits are not merely *compatible* with comptime — **Tier 1 dispatch is a
comptime operation.** The bound check, conformance resolution, and method
selection all happen at compile time during monomorphization (`where T: Trait` is a
constraint on a `comptime T: type` parameter). Beyond that baseline there are four
interaction points and one clean boundary.

**Boundary first: comptime works with Tier 1, never with `dyn`.** A `*dyn Trait`
erases its concrete type, so you cannot comptime-query its conformance or
comptime-call through it. All comptime/trait interaction below is **Tier-1-only**.
The cut is consistent with the whole design: **static = comptime-transparent,
dynamic = comptime-opaque.**

The four interactions, by difficulty:

1. **Bounds on comptime generics** — `where T: Trait` on `comptime T: type`. This
   *is* Tier 1; trivially works. ✓ (easy)

2. **Associated comptime constants** — a trait may declare comptime constants each
   `impl` supplies, resolved per-instantiation:
   ```
   trait BlockDevice {
       const SECTOR_SIZE: usize;
       fn read(self: *Self, ...) -> Result<(), IoError>;
   }
   ```
   Usable in array sizes, alignments, capability masks. ✓ (easy, high-value)

3. **Comptime conformance reflection** — `comptime if T: Trait { ... } else { ... }`.
   Sound **only as reflection / code selection** (like Zig's `@hasDecl`); it must
   **not** become a back door to specialization (overlapping impls), which §10
   excludes. Pure comptime branching on conformance does not threaten coherence;
   providing different *behavior* per conformance does. A design line to hold. ⚠
   (medium)

4. **const trait methods** — calling a trait method during comptime evaluation
   requires every `impl`'s body to be comptime-evaluable. ⚠⚠ (hard — see below)

**The unification: "comptime-evaluable" is an effect.** Interaction (4) is hard for
*exactly the same reason* `#[irq_safe]` is (§9.1): const-ness is a **property of a
function that the trait must declare and every `impl` must be conformance-checked
against** — just like `may_sleep` / irq-safety. So const trait methods are **not a
second hard problem; they are another instance of the effect-carrying-trait
problem.** The §9.1 effect-contract machinery is the single unlock for both — once
a trait can declare and check an effect contract, `const`-evaluable is one more
effect in that contract alongside irq-safe. Sequence (4) with §11 step 3, not
before it.

Net: bounds (1) and associated consts (2) are easy and land with Tier 1;
reflection (3) needs a design line (reflection, not specialization); const methods
(4) ride the effect-contract work; and comptime through `dyn` is correctly
impossible.

---

## 10. Explicitly excluded (these would break MC)

- **No `Box<dyn>` / owned-by-value trait objects** — violates no-alloc.
- **No implicit coercion to `dyn`** — must be an explicit `*dyn` coercion; no
  surprise virtualization.
- **No specialization** — soundness hazard; conflicts with coherence.
- **No blanket impls and no multi-trait objects (`dyn A + B`) in v1** — coherence
  and vtable-layout complexity; revisit later if needed.
- **No default method bodies that allocate or may-sleep** — a default body inherits
  the trait's context contract.
- **No lifetime-parameterized associated types in v1** — that needs the
  interprocedural/lifetime machinery (T1.3). Method-only traits do **not** depend
  on T1.3 and can ship independently.

---

## 11. Sequencing

1. **Tier 1 first** — `trait` / `impl Trait for Type` / `where T: Trait`,
   monomorphized. Most of the value, no new runtime concept, composes with all
   existing analyses. Lands as a sema + name-resolution feature.
2. **Tier 2 next, but excluded from effect-restricted contexts** — `*dyn Trait`,
   vtable emission, the checked coercion; `dyn` calls **forbidden inside
   `#[irq_context]`** (free via the existing indirect-call rejection). This is
   effect-sound by exclusion (§9.1) and needs **no** effect-contract machinery.
   Reuses the closure fat-pointer lowering. Separable follow-up.
3. **Effect-carrying traits (`#[irq_safe]` and the general `#[effect]` contract,
   §9.1)** — the genuinely hard frontier: re-admitting `dyn` into restricted
   contexts requires traits to declare and conformance-check their full effect
   contract. Scope this as its own project, not a flag on step 2.
4. **Linear trait objects (§9.3)** and lifetime-parameterized associated types
   (post-T1.3) — deferred.

Relationship to the hardening backlog: method-only traits are **independent of
T1.3**. Only associated types that carry borrows wait on the lifetime work, so the
two frontiers (abstraction via traits, temporal safety via T1.3) can proceed in
parallel.

---

## 12. Regression-lock plan (spec fixtures)

Following the project's self-verifying-fixture discipline
(`tests/spec/*.mc` with inline `// EXPECT_ERROR: E_*`, harness `src/spec_tests.zig`):

**Accept (`expect=pass`):**
- `trait` decl + `impl Trait for Type` + a `where T: Trait` bounded generic that
  calls a trait method (Tier 1, direct dispatch).
- `*dyn Trait` coercion + dynamic call of a borrow-self method (Tier 2).
- Tier-1 polymorphic call reachable from `#[irq_context]` (concrete callee — must
  pass).

**Reject (`compile_error`, each with an `EXPECT_ERROR` code):**
- `where T: Trait` instantiated with a non-conforming `T` -> `E_TRAIT_NOT_SATISFIED`.
- `impl` missing a method / wrong self-mode -> `E_TRAIT_MISSING_METHOD` /
  `E_TRAIT_SELF_MODE_MISMATCH`.
- `*dyn` of a non-object-safe trait (generic method, or `move self`) ->
  `E_TRAIT_NOT_OBJECT_SAFE`.
- Calling a `move self` method through `*dyn` -> `E_DYN_MOVE_SELF`.
- A `dyn` call inside `#[irq_context]` (no `#[irq_safe]`) -> `E_IRQ_CONTEXT_CALL`
  (reuses the existing indirect-call rejection).
- Two conflicting `impl Trait for Type` -> `E_TRAIT_INCOHERENT`.
- Hand-forging a `*dyn` fat pointer in safe code -> opacity/declassify-class error.

Each closed guarantee becomes a committed fixture, so a regression (a guarantee
silently re-opening, or a new false positive) fails `zig build test`.

Add an **effect fixture** alongside step 2 of §11: a `dyn` call placed inside
`#[irq_context]` must reject (`E_IRQ_CONTEXT_CALL`) — this regression-locks the
"effect-sound by exclusion" property so a future change cannot silently let `dyn`
into a restricted context without going through the §9.1 effect-contract work.

---

## 13. Known gaps in this proposal

Honest open items this note does not fully solve; none block Tier 1, and the first
two are only implementation cost rather than design risk:

- **`*dyn` must be a compiler-protected type kind.** The forge-safety claim (§7) is
  not free: constructing a `{data, vtable}` fat pointer has to be a privileged
  operation (like opaque-struct construction), so safe code can reach `*dyn` only
  through the checked coercion. This is real machinery, not a coercion rule.
- **Orphan / coherence rules across modules.** §7 guarantees one `impl Trait for
  Type` per pair, which is trivial within a kernel monolith but underspecified once
  code spans modules/packages. A Rust-style orphan rule (the `impl` must live in the
  trait's or the type's module) is the likely answer; deferred until MC has a
  multi-package story (which it does not yet — there is no package manager).
- **Monomorphization code size.** Tier 1's zero dispatch cost is paid in binary
  size / icache (one code copy per instantiation). This is inherent to MC's
  existing generics, not new — but it is the systems-level reason `dyn` (Tier 2)
  exists as the code-size-saving alternative. The two tiers trade code size against
  dispatch cost; that trade is the user's to make per call site.
- **The effect-contract design itself (§9.1)** is sketched, not specified. Whether
  effects are a fixed set of `#[...]` attributes on the trait, or a more general
  effect-row carried structurally, is an open language-design question that should
  be settled before step 3 of §11.
