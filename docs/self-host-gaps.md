# Self-Host Gap Ledger

Every MC language/library feature the self-hosting effort ([`self-host-plan.md`](self-host-plan.md))
found missing, broken, or awkward — with a minimal repro. This is the "what MC does not support"
output of the stress test.

**Status legend:** `open` · `workaround` (usable but ugly) · `fixed` (commit) · `wontfix` (by design)

## Pre-seeded from review (2026-07-01, before any code)

| ID | Area | Gap | Repro / evidence | Severity | Status |
|----|------|-----|------------------|----------|--------|
| G1 | stdlib | No growable `Vec<T>` (only fixed-capacity containers; `std/collections/vec.mc` is SIMD lanes) | `find std -name '*.mc'`; no dynamic array | blocker | **fixed** — `std/collections/dynarray.mc` (`Vec<T>`), vec-test gate green host+Docker. Generics fully express a heap-backed growable container. |
| G2 | stdlib | No `HashMap<K,V>` anywhere | grep tree | blocker | **fixed** — `std/collections/hashmap.mc` `StrHashMap<V>` (string-keyed, open-addressing, FNV-1a, grow+rehash), hashmap-test green. Fully-generic-key blocked by G16. |
| G3 | runtime | Hosted MC has no argument access (`argv`/`argc`); hosted `main` is nullary. (Kernel-side argv DOES exist: `kernel/lib/args.mc`.) Gap is the hosted-`main` ABI for `mcc2`. | all hosted examples `fn main() -> i32`; kernel/lib/args.mc:1 | high | **fixed** — `std/hosted_args.mc` + `tools/toolchain/hosted_args_rt.c` shim (`export fn mc_main`), argv-test green. NB: MC has NO compiler-level `main` at all — entry is a pure link/crt concern (`grep '"main"' src/` = 0 hits). |
| G4 | stdlib | No string builder / no `allocPrint`-equivalent | `std/fmt/*` is fixed-size / streaming only | high | **fixed** — `std/strbuf.mc` `StrBuf` over `Vec<u8>` (put_byte/str/u32/hex), strbuf-test green. `sb_as_slice` NOT possible (G12); read via `sb_byte`. |
| G5 | stdlib | `std/mem.mc` lacks `eql`/`indexOf`/`startsWith`/`splitScalar` | grep | high | **fixed** — `std/mem.mc` `mem_eql`/`mem_starts_with`/`mem_index_of[_byte]`/`split_by`+`split_next`, memstr-test green (C+LLVM). `?usize`/`?[]const u8` returns became result structs (G11). |
| G6 | design (NOT a language gap) | Pointer-recursive structs DO work — `struct Node { next: *mut Node, value: u32 }` lowers to a forward-declared `typedef struct Node Node;` + `struct Node *next;` (`src/lower_c_emitter.zig:792`). Design note only: **prefer an index-arena AST** for scale/ownership, not because MC can't express pointer recursion. | verified emit; emitter:792 | note | n/a |
| G9 | stdlib/API | `Allocator` trait exposes only `alloc`/`free` — **no `realloc`/`try_alloc`** (`std/alloc/alloc.mc:13`). `heap_try_grow_in_place` exists but is not in the trait. | std/alloc/alloc.mc:13 | medium | **decided** — growth is allocate-copy-free (no trait change); capacity doubling gives amortized O(1). |
| G10 | toolchain | `mcc-cc.sh` compiles emitted C with `-Werror=unused-parameter`, so every trait-impl method must reference all params (an allocator ignoring `align`/`self`). Idiom: a cheap validating `unreachable` guard, as `arena_free_noop` does. | vec spike | low | workaround |
| G7 | ergonomics | No labeled break/continue | spec §11 | low | open |
| G8 | ergonomics | `?` needs matching return type (no error-set auto-coerce like Zig `try`) | spec | low (watch) | open |

## Discovered during execution (Phase 0, 2026-07-01)

These are the substantive stress-test findings. **G11 and G12 are the two dominant themes** — a
compiler uses value-optionals and `[]const u8` on nearly every line, so both likely warrant a
proper compiler fix (candidate Phase 0.6) before the P1–P5 port, rather than per-site workarounds.

| ID | Phase | Area | Gap | Repro / root cause | Severity | Status |
|----|-------|------|-----|--------------------|----------|--------|
| G11 | 0.2/0.5 | language | **Value optionals `?V` are not expressible** — only pointer-shaped optionals work (`?*T`, `?*dyn`, `?c_void*`). `?usize`/`?[]const u8`/`?u32` can be declared & `return null`'d but NO consumer form accepts them: `if let` → `E_IF_LET_OPTIONAL_REQUIRED`; `== null` → `E_NO_IMPLICIT_CONVERSION`; `switch` → `E_SWITCH_RESULT_TAG`. So a value optional is write-only. | `src/sema_type.zig` `isNullableValue()` admits only nullable pointers; `classifyNullableType()` → `.unknown` for value types | **high** | workaround (result structs / `?*mut V` / sentinel). Candidate fix: extend optionals to value types (tagged repr). |
| G12 | 0.3/0.4/0.5 | language/codegen | **`[]const u8` slice support is half-implemented.** (a) string literals are `*const u8`, NOT `[]const u8` — `let s: []const u8 = "hi"` type-checks but `emit-c` → `UnsupportedCEmission` (`ast_query.isStringLiteralTarget`). (b) cannot construct a slice from raw ptr+len (no slice-from-parts); struct-literal to a slice type → `E_RETURN_TYPE_MISMATCH`. (c) `[]mut u8` → `[]const u8`: implicit → `E_NO_IMPLICIT_POINTER_CONVERSION`, explicit `as` → emits undeclared `mc_slice_mut_u8` / `E_REPRESENTATION_CHECK_MISSING`. (d) **soundness hole:** `pa_value(p) as []const u8` passes the checker but emits invalid C (casts the scalar, drops the length). | multiple 5-line probes (0.3/0.5 reports) | **high** | workaround (`mem.as_bytes(&arr)` builtin; `extern "C" fn -> []const u8`; `ByteReader`). Candidate fix: real fat-pointer/slice-from-parts + literal-to-slice lowering. |
| G13 | 0.5 | codegen | **Sub-slicing `base[a..b]` only lowers when `base` is a plain local/param of slice type.** A struct-field base (`sp.s[a..b]`), a re-slice, or a `mem.as_bytes(...)` result base → `exprSourceTypeForEmission`→null→`UnsupportedCEmission`. Also range endpoints must be simple operands (`hay[start..start+n]` fails; precompute `end`). | 0.5 `sn.mc` probe | medium | workaround (copy base to a local first) |
| G14 | 0.2 | soundness/analysis | **Escape analysis over-rejects returning `&field` reached through a heap pointer** (`return &slot.val` where `slot: *mut Entry`) → `E_LOCAL_ADDRESS_ESCAPE`, even though the storage is heap. | 0.2 report | medium | workaround (put field at offset 0, mint via `raw.ptr<V>(pa_offset(..))`) |
| G15 | 0.2 | stdlib | **No `wrapping_mul_u32`** in `std/math.mc` (has wrapping add/sub/shl). FNV-1a needs mod-2³² multiply; `*` is checked and traps. Cross-domain `wrap<u32>`↔checked needs explicit conversions both ways (`E_NO_IMPLICIT_CONVERSION`). | 0.2 report | low | workaround (u64 product + truncate). Candidate: add `wrapping_mul_u32`. |
| G16 | 0.2 | language | **No `Hash`/`Eq` trait bounds** usable on a comptime-generic value → a fully-generic `HashMap<K,V>` can't hash/compare an arbitrary `K`. String-keyed only for v0. | 0.2 report | medium | open (needs trait-method dispatch on generic K) |
| G17 | 0.3 | toolchain | Diamond-import dedup needs an **absolute** path to the root `.mc`; a relative path caused spurious `ImportNotFound`. `mcc-cc.sh` already passes absolute paths. | 0.3 report | low | note |
| G18 | 0.6-probe | language | **Tagged unions cannot be generic** — `union Opt<T> { some: T, none }` fails to parse (`expected '{' after union name`, `src/parser.zig:1769`). So a generic value-optional / generic sum type is not expressible; the idiomatic workaround for G11 (a generic `Opt<T>`) is blocked. Structs ARE generic; unions are not. | `union Opt<T>{...}` → ParseFailed | medium | open |
