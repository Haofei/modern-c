# The MC `unsafe` boundary — S0.2

The **safe subset** of MC is the hardening target: it should be provably free of the
UB-introducing constructs catalogued in [`docs/c-ub-matrix.md`](c-ub-matrix.md) (S0.3). The
**unsafe surface** is the small, explicit, reviewed set of constructs that the language *cannot*
prove safe because they touch hardware, raw memory, the optimizer, or non-MC code. This document
defines that boundary, the marker that contains it, and the audited inventory of unsafe sites in
`kernel/` and `std/`.

> **Scope (honesty).** This item is *audit + greppable-discipline + a lint*. MC already
> **type-enforces** the boundary (see below), so this is not a new type-system feature — it
> documents the existing rule, enumerates the constructs, and adds an independent source-level
> auditor (`tools/toolchain/unsafe-audit.sh`) that produces the inventory and flags any escape.
> A deeper *whole-function safe/unsafe effect system* (e.g. propagating "this fn is unsafe" to
> callers, or a `#[safe]` attribute the compiler verifies) is a larger follow-up — see
> [Follow-up](#follow-up).

## The marker: an existing language construct, not a comment convention

MC already has the unsafe boundary as **first-class syntax**, and the front-end **rejects** unsafe
operations that appear outside it. So the "greppable marker" is the language construct itself —
there is no `// UNSAFE:` comment convention to invent.

Two markers, for two different kinds of promise (per `docs/spec/MC_0.7_Final_Design.md` §1.2–1.3):

1. **`unsafe { … }`** — *machine-effect* operations. The language cannot prove the operation is
   well-formed (a physical address really is a UART; a raw pointer is valid; a linear value has
   been transferred). It does **not** grant the optimizer arbitrary assumptions — these are
   machine effects, not language UB.

   ```mc
   unsafe { raw.store<u64>(addr, value); }
   unsafe { let uart = mmio.map<Uart16550>(phys(0x1000_0000))?; }
   unsafe { asm opaque volatile { "cli" clobber("memory") } }
   ```

2. **`#[unsafe_contract(<promise>)] { … }`** — *optimizer-license* promises. An unchecked fact the
   compiler may rely on inside the region; if false at runtime the region's behavior is
   region-scoped unspecified. Promises: `no_overflow` (for `unchecked.{add,sub,mul,shl}`),
   `noalias` (for `compiler.assume_noalias_unchecked`), `precise_asm` (for `asm precise`).

   ```mc
   #[unsafe_contract(no_overflow)] { sum = unchecked.add(sum, x); }
   #[unsafe_contract(noalias)]     { let a = compiler.assume_noalias_unchecked(p, n); }
   ```

### How the front-end enforces it (this is the real gate)

`src/sema.zig` carries an `in_unsafe` flag and an `unsafe_contracts` set down the checker context.
Operations are rejected outside the right region:

| Diagnostic | Fires when |
|---|---|
| `E_UNSAFE_REQUIRED` | `raw.load`/`raw.store`, `mmio.map`, raw-many-pointer `.offset(...)`, inline `asm`, `forget_unchecked`, or `arc_get_mut` is used outside an `unsafe { … }` block (`isUnsafeOperationCall`, and the explicit checks at sema.zig: asm-stmt, raw-many offset, `forget_unchecked`, `arc_get_mut`). |
| `E_UNCHECKED_OUTSIDE_CONTRACT` | an `unchecked.*` op is used outside a matching `#[unsafe_contract]`. |
| `E_PRECISE_ASM_CONTRACT` | `asm precise` is used without `#[unsafe_contract(precise_asm)]`. |

So an unsafe op outside its marker is a **compile error**, not a lint warning. The lint below is a
*second, independent* check at the source level (defense in depth + the inventory generator).

## The enumerated unsafe-construct set

These are the MC constructs that can introduce UB or require programmer-asserted care. Each row
cross-references the C-UB class it relates to in [`docs/c-ub-matrix.md`](c-ub-matrix.md). The
**Gate** column is what `unsafe-audit.sh` enforces.

| Construct | What it can do | Marker (gate) | Related C-UB class |
|---|---|---|---|
| `raw.load<T>` / `raw.store<T>` | Type-punned read/write through `uintptr_t -> volatile T*` (hardware/raw memory). | `unsafe` block (**gated**) | Strict aliasing (row 2); covered by `-fno-strict-aliasing` |
| `mmio.map<T>(pa)` | Mint a typed MMIO register view from a physical address. | `unsafe` block (**gated**) | Strict aliasing (row 2); provenance (row 9) |
| `raw.ptr<T>(addr)` | Mint a typed `*mut T` from an address. Minting is *not* gated; the **deref** is the checked part. | tracked (not gated) | Provenance (row 9) |
| raw-many `.offset(i)` | Pointer arithmetic on a raw many-pointer. | `unsafe` block (**gated**) | Out-of-bounds (row 3); provenance (row 9) |
| inline `asm { … }` | Arbitrary machine effects; `asm precise` also makes optimizer promises. | `unsafe` block; `precise` needs `#[unsafe_contract(precise_asm)]` (**gated**) | (machine effect, not C-AM UB) |
| `forget_unchecked(v)` | Drop a linear value without releasing it (leaks / transfers ownership outside the checker). | `unsafe` block (**gated**) | (resource-safety, not C-UB) |
| `arc_get_mut(T, h)` | Yields an aliasable `*mut T` whose uniqueness the checker cannot prove. | `unsafe` block (**gated**) | Aliasing / data race |
| `unchecked.{add,sub,mul,shl}` | Arithmetic with the overflow trap removed (optimizer may assume no overflow). | `#[unsafe_contract(no_overflow)]` (**gated**) | Signed overflow (row 1); shift (row 4) |
| `compiler.assume_noalias_unchecked` | Optimizer noalias promise. | `#[unsafe_contract(noalias)]` (**gated**) | Strict aliasing (row 2) |
| `bitcast<T>` / overlay-union reinterpret | Reinterpret bytes as another type. **Alias-safe** (lowers to `__builtin_memcpy`), so not gated — tracked for review. | tracked (not gated) | Strict aliasing (row 2) — defined away |
| `var x = uninit;` | Storage whose bytes are **unspecified, not UB** (no trap reps / poison); must be written before read. | tracked (not gated) | Uninitialized read (row 7) |
| `extern` fn (FFI) | Calls into non-MC code; callee correctness is outside MC's checks. | declaration (trust boundary; counted) | (all classes, via the callee) |

The **load-bearing** unsafe construct (per S0.3's honesty note) is the **raw register / MMIO
path**: `raw.load`/`raw.store` and `mmio.map` are the only type-punned pointer derefs MC emits, and
they are the one place a *flag* (`-fno-strict-aliasing`) — not an MC check — is what keeps the
emitted C well-defined. Everything else MC offers as a reinterpretation feature (`bitcast`, overlay
unions) is already alias-safe via `memcpy`.

## The lint: `tools/toolchain/unsafe-audit.sh`

Scans every `.mc` under `kernel/` and `std/`, tracks `unsafe`/`unsafe_contract` regions by brace
depth (with comment/string stripping), and:

- **flags** any *gated* unsafe op that sits **outside** an `unsafe`/`unsafe_contract` region as a
  `VIOLATION` (and exits non-zero). The sound front-end never lets one compile, so a hit means
  either a gap in the lint's brace tracking or a genuine escape — either is worth surfacing.
- **prints the inventory** of audited unsafe sites by category (gated and tracked), plus the
  `extern` FFI surface count.

Run it:

```sh
bash tools/toolchain/unsafe-audit.sh
```

It is a *lint*, not the compiler: it parses with `awk` and is deliberately conservative. The
authoritative gate is `sema`; this gives the greppable, human-auditable view and a clean
inventory.

## Audited inventory — `kernel/` + `std/` (142 `.mc` files)

Snapshot from `tools/toolchain/unsafe-audit.sh` at S0.2. **Result: clean** — every gated unsafe op
sits inside an `unsafe`/`unsafe_contract` region (re-run the lint for the live count).

| Category | Count | Gate | Where the load-bearing ones live |
|---|---:|---|---|
| `raw.load` / `raw.store` | 69 | unsafe block | The raw-register/MMIO path. Concentrated in the driver/MMIO layer: `kernel/drivers/irq/plic.mc` (9), `std/mmio.mc` (6), `std/bytes.mc` (5), `std/mem.mc`/`std/libc.mc` (4 each), `kernel/core/time.mc`, `kernel/core/shell.mc`, `kernel/drivers/timer/clint.mc`, `kernel/drivers/fb.mc`, `std/dma.mc`, `std/vec.mc`. This is the **S0.3 strict-aliasing** surface. |
| `mmio.map<T>` | 1 | unsafe block | `std/rand.mc:59` (`mmio.map<VirtioMmio>(phys(addr))`) — the typed-MMIO-view mint. |
| `raw.ptr<T>` | 13 | tracked | Mostly `std/arc.mc` (the `Arc` block pointer plumbing) and `std/hosted_io.mc`. Minting only; derefs are checked. |
| raw-many `.offset()` | 0 | unsafe block | — none currently. |
| `forget_unchecked` | 28 | unsafe block | Driver completion/lock release paths: `kernel/drivers/virtio/*`, `kernel/drivers/irq/plic.mc`, etc. — transferring a linear value's ownership out of the checker. |
| `arc_get_mut` | 1 | unsafe block | `std/arc.mc` (definition); call sites require `unsafe`. |
| inline `asm` | 8 | unsafe block | `kernel/arch/riscv64/csr.mc` (CSR read/write, `asm precise volatile`) and `kernel/arch/riscv64/paging.mc` (SATP/SFENCE). The `precise` forms carry `#[unsafe_contract(precise_asm)]`. |
| `unchecked.{add,…}` | 0 | `#[unsafe_contract(no_overflow)]` | — none currently in kernel/std. |
| `assume_noalias_unchecked` | 0 | `#[unsafe_contract(noalias)]` | — none currently in kernel/std. |
| `bitcast<T>` | 8 | tracked | `std/vec.mc` (typed-slot reinterpret). Alias-safe (memcpy). |
| `uninit` | 18 | tracked | Buffers written before read: `std/vec.mc`, `std/fmt.mc`, `std/rand.mc`, `kernel/core/record.mc`, `kernel/core/checkpoint.mc`, `kernel/core/heap.mc`. Unspecified-not-UB. |
| **TOTAL (constructs)** | **146** | | |
| `extern` declarations (FFI) | 44 | trust boundary | The non-MC call surface (runtime, libc shims, platform hooks). Callee correctness is not MC-checked. |

### Reading the inventory

- The **gated** categories (raw.load/store, mmio.map, raw-many offset, forget_unchecked,
  arc_get_mut, asm, unchecked, assume_noalias) are each, by construction, inside an
  `unsafe`/`unsafe_contract` region — the lint result is **clean**, confirming the boundary holds.
- The **tracked** categories (raw.ptr, bitcast, uninit) are legal in safe code by design (minting
  a pointer, an alias-safe memcpy reinterpret, and unspecified-not-UB storage respectively); they
  are inventoried so the reviewer can see them, not because they are escapes.
- The **load-bearing** site is the `raw.load/store` + `mmio.map` register path — the one place
  MC's safety leans on a compiler flag (`-fno-strict-aliasing`) rather than an MC check (S0.3,
  row 2). That surface is concentrated in the driver/MMIO layer above and is small.

## Follow-up

This item delivered the **boundary definition + marker discipline + lint + inventory**. Not in
scope (larger follow-ups):

- **Whole-function safe/unsafe effect typing.** Today the gate is per-operation (the op must be in
  an `unsafe` region); there is no notion of an "unsafe function" whose unsafety propagates to
  callers, nor a verified `#[safe]` attribute. A function that wraps a `raw.store` in `unsafe`
  presents a safe signature, and that is intentional (it is the audited abstraction boundary) —
  but the *quality* of that wrapping is reviewed by humans, not proven.
- **FFI contract typing.** `extern` declarations are a trust boundary counted here; MC does not
  verify the callee honors the declared signature/effects.
- **A `make`/CI gate.** The lint is wired as a `zig build` step (`unsafe-audit`) and runs
  standalone; promoting it to a blocking CI gate (alongside `diff-backend`) is a follow-up.

## Gates

- `bash tools/toolchain/unsafe-audit.sh` → clean inventory, exit 0.
- `zig build unsafe-audit` → same, via the build graph.
- Kernel still builds + boots after this item (no source changes to `kernel/`/`std/` were needed —
  the boundary already held): `bash tools/proc/kmain-test.sh zig-out/bin/mcc c` → `KERNEL-OK`.
