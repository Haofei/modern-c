# Kernel region, effect, and FFI contract boundary

Status: **qualified bounded kernel profile; not a general borrow checker or a
general separation-logic FFI verifier**.

This document fixes the production-profile boundary used by the kernel-language
comparison. MC represents the high-value lifetimes below with lexical escape
checks or linear capability tokens. Unsupported general lifetime inference is
not silently treated as proven.

## Restricted region matrix

| Region/property | Supported rule | Evidence | Outside the profile |
|---|---|---|---|
| Stack | A local address cannot be returned, stored in longer-lived outer/global/caller storage, or hidden in an escaping aggregate/closure. | `tests/spec/local_address_escape.mc`, `closure_typing.mc`; `E_LOCAL_ADDRESS_ESCAPE`, `E_BORROW_ESCAPES_SCOPE`. | Arbitrary heap-object lifetime inference. |
| Slice/view | Arrays do not implicitly decay to slices; views originate from an existing view, a typed DMA handle, or an explicit unsafe/raw boundary. | `tests/spec/array_decay.mc`, `pointer_view_conversions.mc`, `dma_cache.mc`. | Proving a raw external allocation remains live for an arbitrary returned view. |
| Guard | A `move` guard is the access capability. Pointers derived by borrowing it carry the guard place and become stale when unlock consumes the guard. | `tests/spec/lock_guards_data.mc`; `E_PRIVATE_FIELD`, `E_USE_AFTER_MOVE`, `E_RESOURCE_LEAK`. | Arbitrary alias relationships not rooted in a tracked capability. |
| RCU read side | A linear read token bounds derived references; unlock consumes the token and invalidates those references. | `tests/spec/kernel_region_tokens.mc`. | Full Linux RCU flavor/grace-period verification. |
| Callback registration | A linear registration token bounds callback data; unregister consumes it, invalidating derived references and preventing a forgotten unregister. | `tests/spec/kernel_region_tokens.mc`. | Proving an external C callback dispatcher obeys the token without an audited adapter. |
| DMA ownership | CPU/device states are distinct move types; only CPU-owned state exposes an access API. | MC and Rust fixtures in `virtio_rng_lang`; `run-dma-ownership.sh`. | Raw aliases retained by common C remain trusted. |
| Async/arena/module/device | No broad lifetime claim is made. New async capture forms remain frozen to the admitted lowering; arena/module/device lifetimes require a linear token adapter or an explicit unsafe boundary. | Compiler readiness and unsafe-boundary inventories. | General inferred regions or arbitrary self-referential values. |

This is deliberately a capability-oriented region checker: it directly covers
the lifetime transitions used in the qualified experiment while preserving a
stable diagnostic boundary for broader programs.

## Compositional kernel effects

The current effect lattice is small and strict:

```text
ordinary / unknown
may_sleep
irq_context == atomic, non-sleeping, bounded-call target set
no_lang_trap
bounded
```

An `#[irq_context]` function may call only another `#[irq_context]` function or
the admitted nonblocking primitive families. A `#[may_sleep]` call is rejected
with `E_SLEEP_IN_ATOMIC`; an unknown direct target and every indirect, closure,
or trait-object dispatch is rejected with `E_IRQ_CONTEXT_CALL`. Loop boundedness
and language-trap freedom are separately verified, so one annotation cannot
stand in for the others. Trait signatures carry their effect attributes and
implementations must match.

This qualifies IRQ/atomic/sleep/bounded/no-trap effects. It does not claim a
generic parameterized lattice for GFP flags, lock ranks, preemption state, or
every RCU flavor. Those protocols use typed wrappers/tokens in the current
profile and remain candidates only when a driver experiment requires them.

## Machine-readable FFI metadata

The MIR producer creates a typed `FfiParamContract` fact for each pointer,
slice, or machine-address parameter of an extern function. `mcc lower-mir`
serializes those facts as `ffi_param_contract` records; it does not rescan the
AST declaration. Records include:

- pointer kind and nullability;
- read versus read/write access from pointer mutability;
- type alignment and whether extent remains an extern obligation;
- slice-length extent;
- conservative `extern_unknown` provenance and call-return stability;
- explicit DMA/physical/virtual address class.

The metadata never invents validity or ownership. A bare MC pointer is non-null
by representation; a nullable pointer says `nonnull=false`; raw pointer extent
remains `extern_contract`; and provenance remains unknown until an audited
adapter establishes a typed capability. Backends therefore cannot turn this
report into an unproved optimizer assumption.

`#[unsafe_contract]` uses the region-scoped model from the language spec:
unchecked assumptions can affect only contracted operations. Values leaving the
region are ordinary values, and contract-only `nuw`, `nsw`, `noalias`, `nonnull`,
or `noundef` facts may not persist. MIR region verification, post-region fact
tests, and LLVM assumption sweeps gate that rule.

The current metadata is compiler- and analyzer-consumable. Rich predicates such
as arbitrary `valid_write<N>` formulas or `stable_until<Token>` across an
external implementation are not claimed without a checked adapter; they remain
explicit trusted obligations in the emitted record.
