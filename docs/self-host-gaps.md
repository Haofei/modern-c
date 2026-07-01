# Self-Host Gap Ledger

Every MC language/library feature the self-hosting effort ([`self-host-plan.md`](self-host-plan.md))
found missing, broken, or awkward — with a minimal repro. This is the "what MC does not support"
output of the stress test.

**Status legend:** `open` · `workaround` (usable but ugly) · `fixed` (commit) · `wontfix` (by design)

## Pre-seeded from review (2026-07-01, before any code)

| ID | Area | Gap | Repro / evidence | Severity | Status |
|----|------|-----|------------------|----------|--------|
| G1 | stdlib | No growable `Vec<T>` (only fixed-capacity containers; `std/collections/vec.mc` is SIMD lanes) | `find std -name '*.mc'`; no dynamic array | blocker | **fixed** — `std/collections/dynarray.mc` (`Vec<T>`), vec-test gate green host+Docker. Generics fully express a heap-backed growable container. |
| G2 | stdlib | No `HashMap<K,V>` anywhere | grep tree | blocker | open |
| G3 | runtime | Hosted MC has no argument access (`argv`/`argc`); hosted `main` is nullary. (Kernel-side argv DOES exist: `kernel/lib/args.mc`.) Gap is the hosted-`main` ABI for `mcc2`. | all hosted examples `fn main() -> i32`; kernel/lib/args.mc:1 | high | open |
| G4 | stdlib | No string builder / no `allocPrint`-equivalent | `std/fmt/*` is fixed-size / streaming only | high | open |
| G5 | stdlib | `std/mem.mc` lacks `eql`/`indexOf`/`startsWith`/`splitScalar` | grep | high | open |
| G6 | design (NOT a language gap) | Pointer-recursive structs DO work — `struct Node { next: *mut Node, value: u32 }` lowers to a forward-declared `typedef struct Node Node;` + `struct Node *next;` (`src/lower_c_emitter.zig:792`). Design note only: **prefer an index-arena AST** for scale/ownership, not because MC can't express pointer recursion. | verified emit; emitter:792 | note | n/a |
| G9 | stdlib/API | `Allocator` trait exposes only `alloc`/`free` — **no `realloc`/`try_alloc`** (`std/alloc/alloc.mc:13`). `heap_try_grow_in_place` exists but is not in the trait. | std/alloc/alloc.mc:13 | medium | **decided** — growth is allocate-copy-free (no trait change); capacity doubling gives amortized O(1). |
| G10 | toolchain | `mcc-cc.sh` compiles emitted C with `-Werror=unused-parameter`, so every trait-impl method must reference all params (an allocator ignoring `align`/`self`). Idiom: a cheap validating `unreachable` guard, as `arena_free_noop` does. | vec spike | low | workaround |
| G7 | ergonomics | No labeled break/continue | spec §11 | low | open |
| G8 | ergonomics | `?` needs matching return type (no error-set auto-coerce like Zig `try`) | spec | low (watch) | open |

## Discovered during execution

_(append: ID, phase, area, gap, minimal repro path, severity, status/commit)_
