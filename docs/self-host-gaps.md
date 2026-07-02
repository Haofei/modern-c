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
| G19 | P1 | codegen | **`raw.load<T>`/`raw.store<T>` only lower for SCALAR T on the C backend** — an aggregate T → `UnsupportedCEmission` (`rawScalarSuffix` src/lower_c_type.zig:205, src/lower_c_call.zig:479). Meant `Vec<Token>` (struct element) wouldn't compile; the lexer had to flatten tokens into `Vec<usize>`. | `vec_push(Token,...)` struct → UnsupportedCEmission | **high** | **fixed (library)** `1855eab` — `Vec<T>` now uses `raw.ptr<T>`+whole-value deref (`p.* = x`/`out = p.*`), which lowers for scalar AND struct T on both backends. Underlying `raw.load/store` scalar-only limit remains (candidate compiler fix, low priority now). |
| G20 | P1 | language | **`let` is function-scoped, not block-scoped** — the same name in two sibling blocks → `E_DUPLICATE_LOCAL: local bindings must have unique names in the current scope`. In Zig each block re-declares freely. Forces name-mangling across loops (`c`/`cf`/`ce`). | two `while` blocks each `let c` | medium | workaround (unique names) |
| G21 | P1 | language | **enum→int needs `open enum` + `.raw()`** — a plain (closed) enum rejects both `x as u32` (`E_ENUM_RAW_REQUIRES_OPEN_ENUM`) and `.raw()`. To read ordinals (e.g. token kinds for a driver), the enum must be `open enum TokKind: u32` and use `.raw()`. (Corrects a stale note that `kind as usize` works.) | closed `enum` `.raw()`/`as` → error | low | workaround (`open enum`) |
| — | P1 | correction | NOT gaps: `std/ascii.mc` DOES export `is_digit`/`is_alpha`/`is_whitespace`/… (usable directly); char literals `'f'`/`'\n'`/`'\''` work as `u8` incl. in `[N]u8` initializers. | — | — | n/a |

| G22 | P2 | language/modules | **Flat cross-import top-level namespace** — `import` pulls ALL top-level fn names (incl. non-`export`) into one shared flat namespace; no module qualification at use sites, no overloading. `parser.mc`'s private `fn advance(p:*mut Parser)` collided with `lexer.mc`'s private `fn advance(lx:*mut Lexer)` → `E_DUPLICATE_DECLARATION`. Real scaling hazard: lexer+parser+sema+lowering all want `advance`/`peek`/`expect`/`make`. | two imported files each `fn advance(...)` | **medium-high** | workaround (name-prefix `p_advance`; or wrap each module's helpers in a `module {}` block — MC has module namespaces). Revisit: adopt `module{}` per selfhost file before P3. |
| G23 | P2 | codegen | **C backend can't emit `return <call> == <call>`** — `sequencedConditionOperandTypes` (`lower_c_flow.zig:391`) can't recover the operand type when BOTH comparison operands are call exprs → `UnsupportedCEmission`. | `fn at(p,k)->bool{ return cur(p)==k.raw(); }` | medium | workaround (bind each operand to a typed local first; +2 lines/site). Candidate compiler fix. |

| G24 | P3 | language | **Reserved keywords steal common local names** — `ok`, `err`, `type`, `use`, `open`, `sat`, `wrap` are keywords (the lexer emits `kw_ok`/`kw_err` for Result sugar etc.), so `let ok: bool = ...` → `expected local name`. A compiler port's own vocabulary overlaps MC keywords. | `let ok: u32 = 1;` → parse error | low-medium | workaround (rename locals) |
| G25 | P3 | language | **`.raw()` and switch-exhaustiveness are mutually exclusive for enums.** An `open enum` supports `.raw()` (needed for ordinal access / driver assertions, G21) but its `switch` REQUIRES a `_ =>` default → the compiler gives ZERO missing-case diagnostics. A closed enum gives exhaustiveness but rejects `.raw()`/`as`. A compiler AST enum wants BOTH. | `switch openEnumVal {...}` forces `_` | **medium** | open — candidate: exhaustiveness on `open enum` switches that omit `_`, or `.raw()` on closed enums. This is the sharpest ergonomic loss for a compiler in MC. |
| G26 | P3 | toolchain | **Unused `let` is a hard error** (`-Werror=unused-variable` in emitted C) — every bound local must be consumed; side-effect-only walks must discard a struct-returning call directly rather than binding it. | bind-and-ignore a local | low | workaround (discard directly) |

**G23 WIDENED (P3):** the `<call> == x` codegen gap (`UnsupportedCEmission`, `sequencedConditionOperandTypes`)
also fires in a **typed `let`-initializer** (`let b: bool = k.raw() == 2;`), not just `return`. It does
NOT fire inside an `if` condition — so it's specific to value-producing contexts (return / typed let-init).
Workaround unchanged: bind the call operand to a typed local first.

**P4 (emit-C) — G12 emission SOLVED via `sb_put_cstr`.** `export fn sb_put_cstr(sb, s: *const u8)`
(appends a NUL-terminated literal) makes fixed C-fragment emission ergonomic — string literals ARE
`*const u8`, so `sb_put_cstr(&sb, "uint32_t")` compiles directly. New confirmed fact: a raw `*const u8`
casts to `usize` with `as usize`. Recommend `sb_put_cstr` as the canonical "emit fixed text" primitive.
Big string-building is still ~2–3× the Zig emitter (no `writer.print`/format interpolation — one call per
fragment). **G25 is AVOIDABLE**: the emitter used `if/else` chains on `nd.kind == .variant` (works on
imported `open enum`) + a contiguous-ordinal range check for the 13 bin-ops, sidestepping the
exhaustiveness/`.raw()` tension entirely.

**P5 self-compile gap list (what the subset compiler CANNOT yet handle — the remaining front-end work):**
`bool`/`void` as parseable type annotations (they're keywords; `parse_type` takes only identifiers);
untyped `let x = e` (needs type inference; currently emits `void x`); slices (`[]const T` emitted as `T*`,
length dropped); and NOT in the P2 grammar at all: `struct`/`enum`/`union`/global/const decls, `for`,
`match`/`switch`, `defer`, `&`/`*` address-deref, bitwise `<< >> & | ^`, `as` casts, string/char/float
literal expressions, method/UFCS calls, generics, multi-module imports/mangling. mcc2's OWN source uses
nearly all of these — true self-compile requires widening the front end across all of them (large, multi-phase).

| G27 | P5.1 | language | **`.raw()` works on an enum-typed PARAMETER but not on a variant-path literal** — `TokKind.l_brace.raw()` → `E_UNKNOWN_IDENTIFIER`. To get the ordinal of a known variant you must pass it as a param and call `.raw()` there (a typed-param indirection). | `SomeEnum.variant.raw()` | low-medium | workaround (helper taking the variant as a param) |

**G23 broadened again (P5.1):** also fires for `let b: bool = x.kind == .variant` and `let b: bool = call.raw() == N`
(any typed-`let bool` whose rhs is a comparison with a call/field-`.raw()` operand). Fine as an `if` condition;
`UnsupportedCEmission` as a `let bool =`. Recurring, easy-to-hit trap — bind the operand to a `u32` local first.

| G28 | P5.2 | selfhost-design | **`enum_lit` AST node carries only the variant token, not its enum** — sema resolved via threaded expected-type, but the emitter (no type table) resolved an enum literal by scanning all module enum decls for a matching variant (first match wins). Silently mis-emitted if two enums share a variant name. | `.variant` emit | ~~medium~~ **FIXED (arch Phase 2 + follow-up)** | Sema publishes the resolved `enum_decl` as a per-node fact (`sema_fact_decl`); emit reads it for `.variant` value positions (`return` / typed `let`/`var` / call args / `ok`·`err` payloads / struct fields / `assign`) AND for `switch`-arm case labels (a fact on the switch node = the subject's enum, consumed by `e_case_label`). No first-match scan on any resolved path. **This corrected a latent bug in mcc2 itself: `sm_type_of_expr_inner`'s `switch nd.kind` (a NodeKind) had been emitting `case TokKind_char_literal`/`TokKind_string_literal` (TokKind is scanned first and shares those variant names) — now `NodeKind_*`.** Fallback scan remains only when no fact (the self-parsing `emit_c_run` path). |

**Pre-existing emitter bug found+fixed by P5.2:** `if (<fully-parenthesized binop>)` emitted `if ((n == 1))`
→ clang `-Wparentheses-equality -Werror` rejects. The enum gate was the first selfhost test with a comparison
in a control-flow condition. Fixed via `e_cond` (skip redundant parens when the condition is already a binop).
This is exactly the class of latent codegen bug the stress test exists to surface.

| G29 | P5.4 | stdlib/portability | **`std/hosted_io.mc` hardcodes Linux `AT_FDCWD = -100`** — on macOS it's `-2`, so `openat` with relative paths fails on a macOS host (absolute paths ignore dirfd and work). Linux/Docker CI unaffected. | relative `io_open` on macOS | low | note (make AT_FDCWD target-conditional) |

**P5.4 forward-prototype pass:** the subset emitter now emits C fn prototypes before definitions
(`e_fn_sig`), so flattened/concatenated modules are order-independent and support cross-module mutual
recursion — needed once imports put a caller textually before its callee.

**⚠️ SUPERSEDED SNAPSHOT (this paragraph is a P5.4-era status, kept for history).** As of 2026-07-02
**MC self-hosts**: all five `mcc2` modules + std deps compile through `mcc2` to a byte-identical fixpoint
(gate `selfhost-bootstrap-test`). Every "recommended order" item below was subsequently done (generics
over structs, `impl`/traits, `unsafe`/`raw`, value-optionals; `match`/`?` — some turned out already-present).
See docs/self-host-plan.md "SELF-HOSTING ACHIEVED" and docs/language-gap-fixes.md.

**HONEST self-compile status (after P5.4):** the subset can compile **~0%** of `mcc2`'s OWN source. Import
plumbing was necessary but not the bottleneck — mcc2's modules pervasively use features the subset still
lacks: **generics** (`Vec<T>` ~30 uses), **fixed byte arrays + `mem.as_bytes`** (~77 uses), **`impl`/traits**
(Allocator), **`unsafe`/`raw.*`**, **`match`**, **`?` propagation**, string-literal exprs. Recommended order
to true self-compile: **generics** (monomorphized `Vec<T>` + fixed arrays + array-slices) → `impl`/traits →
`unsafe`/`raw` intrinsics → `match`/`?`. Each is a large vertical; true self-compile remains multi-phase.

| G30 | P5.5 | language | **`*mut Vec<T>` param → `*const Vec<T>` param rejected** (`E_NO_IMPLICIT_POINTER_CONVERSION`) even though mut→const is a safe narrowing; but `&local`/`&field` address-of expressions DO coerce. Passing a `*mut` pointer *variable* to a `*const`-expecting fn (e.g. `vec_len(u32, v)` where `v: *mut Vec<u32>`) fails — must reborrow `&*v`. | `fn c(v:*mut Vec<u32>)->usize{return vec_len(u32,v);}` fails; `vec_len(u32,&*v)` works | medium | workaround (reborrow `&*v`) |

**P5.5 monomorphizer lesson (for the ledger / any arena-scanning monomorphizer):** a monomorphizer that
collects instantiations by scanning the flat arena for `S<...>` uses will also find the TEMPLATE's own
signature use `S<T>` (arg = abstract `T`) → collecting it produces `S_T` whose `T→T` substitution recurses
forever (stack overflow). Fix: collect ONLY when the type arg is a known concrete scalar lexeme. That filter
IS the scope boundary (why nested/struct type-args are deferred). Substitution was done via threaded scratch
fields on the Parser (set/clear around each monomorphic emit) rather than an arena clone — pragmatic given
no `?T`/node-maps.

**P5.6 array findings:** MC array-literal is `.{ e0, e1, ... }` — the SAME leading-dot-brace as a struct
literal `.{ .f = e }` but positional; disambiguated by 3-token lookahead (`.` IDENT `=` ⇒ struct). The
subset has **no `as` cast expression** yet (deferred). Widening a flat `SmType` with fields forces updating
every full struct-literal site (MC requires all fields present) — O(literal-sites) churn. Field access through
an ABSTRACT type param isn't type-checkable (element type is `named_ T`); works only inside generic-fn bodies
(sema-skipped) whose return substitutes to concrete — same pattern as P5.5.

**P5.7 slices — the accumulating structural cost:** the emitter has NO shared typed IR (parser/sema/emit
are 3 separate passes over the flat arena), so to lower `s[i]`/`s[a..b]`/`.len` correctly the emitter had to
build its own mini local-type resolver (~150 of 349 LOC: a `cur_fn` scratch field + a recursive scan of
params/`let`/`var` to recover a base identifier's declared type). This re-derivation recurs for EVERY
type-directed lowering and is the compounding tax of not having sema annotate the arena. Slice C repr matches
the real backend (`mc_slice_const_<T>{ const T* ptr; size_t len; }`). Also: added a `&` address-of node
(`un_addr`) for `mem.as_bytes(&arr)`; still no `as` casts (cross-width arithmetic must be avoided).

| G31 | P5.10 | codegen | **Pointer field access `p.field` (p: `*mut T`) must emit C `->`, not `.`** — the subset emitter emitted `.` because prior fixtures never did pointer-field access in the accept set. Latent wrong-C bug; fixed with `e_base_is_ptr` (dyn fat pointers stay `.`). | `fn f(p:*mut S)->u32{return p.x;}` → `p.x` (wrong) | medium | fixed (selfhost) |
| G32 | P5.10 | selfhost-sema | **Mutation through a `*mut` pointer receiver is flagged immutable** — `self.total = x` where `self: *mut Acc` → the subset's `sm_target_mutable` only allows `var` locals, so it errors `assign_immutable`. Worked around by NOT sema-checking impl/method bodies → blocks real conformance checking. | `fn m(self:*mut S)->void{self.x=1;}` | ~~medium~~ **FIXED (arch Phase 5)** | `sm_target_mutable` already allows a write through a pointer-typed root (`ptr_depth>0`); once `sm_check_impls` (arch plan Phase 5, `docs/self-host-arch.md`) began checking impl method bodies, `self.x = v` type-checks. No workaround left. |

**ARCH-HARDENING refactor (2026-07-02, `docs/self-host-arch.md`, commits `bd98665b`→`0e48e728`):** mcc2
moved from a 3-pass AST re-walker (parse-twice, emit re-infers types, fn-wide locals, generic/impl
bodies unchecked) to a typed pipeline — parse once (Phase 0, ~1.4×) → sema builds a node-indexed
`Vec<Fact>` typed table (Phase 1) + a lexical scope stack (Phase 4) → emit consumes typed facts for
enum resolution (Phase 2) and slice/ptr/dyn base classification (Phase 3) → impl (Phase 5) and generic
(Phase 6) bodies are now type-checked. Every phase byte-identical + m0-green both backends. This turns
G28-value/G34/G35 into structural guarantees and closes G32. Two latent builtins surfaced by first-time
generic-body checking (`forget_unchecked`, `mem.bytes_equal`) were taught to sema. Residual (unchanged):
`.variant` in switch-arm/assign still name-scans (G28); the subset can't put a regular fn call in a
generic body (monomorphizer limit).
| G33 | post-P5 | selfhost-sema | **Duplicate top-level declaration accepted** — `sm_collect` overwrote the symbol-table entry, so a repeated top-level name type-checked (exit 0) and the emitter output duplicate C definitions. Found by review (initially fn-only; a follow-up review found struct/const/global/enum still slipped through). | two `fn f()` / `struct S` / `const K` / `global G` / `enum E` → dup C | ~~medium~~ **FIXED (all kinds)** | collect now `strmap_contains`-guards EVERY top-level namespace — `fn`/`extern fn`, `struct`, `const`+`global` (shared table), and `enum` — emitting `duplicate_decl` (SmErr 17). (Cross-namespace collisions, e.g. a `struct` and `fn` of the same name, are not detected — separate tables — a minor residual.) |
| G34 | post-P5 | selfhost-sema | **`if let` binding leaked past its block** — the payload binding was added to the fn-wide locals table and never removed, so a use *after* the `if`/`else` type-checked (exit 0) and emitted C referencing a variable out of its C block scope (invalid C). Found by review. Same for `if let ok(v)/err(e)`. | `if let y=o {} return y;` | ~~high~~ **FIXED** | new `strmap_del` (backward-shift deletion, `std/collections/hashmap.mc`) drops the binding when the then-block ends |
| G35 | post-P5 | selfhost-sema | **`ok(x)`/`err(x)` payload type unchecked** — the ctor yielded a LOOSE `result_` that unified with any target `Result<T,E>` without comparing the payload, so `return ok(true)` into `-> Result<u32,u32>` type-checked (exit 0). Found by review. | `ok(true)` into `Result<u32,u32>` | ~~medium~~ **FIXED** | `sm_check_result_ctor` checks a non-literal `ok`/`err` arg against the target's OK/ERR payload at `return` and typed `let`/`var` sites |

**P5.10 traits:** representation matches the real backend — rodata `static const NAME__vtable`, fat pointer
`{void* data; const NAME__vtable* vtbl}`, `void*`-self thunks (`(TYPE*)self`, avoids `-Wincompatible-pointer-types`),
dispatch `d.vtbl->m(d.data, ...)`. Coercion `*mut T`→`*mut dyn Trait` at CALL ARGS only (returns/assigns deferred).
`Self` is a non-problem (erased to `void*` in the vtable; concrete in impl methods).

**⚠️ SUPERSEDED SNAPSHOT (P5.10-era status, kept for history) — ALL RESOLVED as of 2026-07-02.** Every
"remaining blocker" below was subsequently closed: value optionals (P5.15), module-qualified calls + opaque
address classes (P5.14/5.19), the std API incl. `StrHashMap` over struct values (P5.19), G32 impl-body
mutation (P5.15); `match` was a non-gap. **MC self-hosts** — `mcc2` compiles all of selfhost/*.mc + std deps
to a byte-identical fixpoint (gate `selfhost-bootstrap-test`). See docs/self-host-plan.md "SELF-HOSTING ACHIEVED".

**REMAINING blockers to LITERAL `mcc2`-compiles-`mcc2`** (after 11 verticals, ~70–75% coverage): `?T`
optionals (G11 — selfhost mostly avoids), `match` + payload binding, GENERAL module-qualified calls (`mod.fn`
— only `mem.as_bytes`/`raw.*` special-cased today; `pa()`/`pa_value`/etc. not), the OPAQUE `PAddr` address
class from `std/addr.mc`, and the full std API surface (StrHashMap over struct values, exact signatures). Plus
closing G32 for real impl-body checking. These are a mix of a few more features + a substantial end-to-end
INTEGRATION effort (feeding all of selfhost/*.mc + std deps through mcc2 and fixing the long tail).

**Structural observation (P5.1):** parser/sema/emit each re-implement length-prefixed "pair run" walking
(`[count,(a,b)*]`, `fi*2(+1)` indexing) with no shared arena-access module → off-by-one-prone duplication
across 3 files. A shared `selfhost/ast.mc` accessor layer would cut this; deferred (works, just repetitive).

**mcc2 CLI findings (2ac36e7):** G12 file-input ceiling is REAL — to feed the `[]const u8` pipeline you
must read into a compile-time-sized `global g_src:[1048576]u8` and `mem.as_bytes(&g_src)[0..nread]`; a
writable `PAddr` for `io_read` comes from `(&g_src) as usize` → `pa(...)` (the sanctioned addr↔usize
boundary). Files > the fixed buffer are rejected, not truncated. G22 also bit as re-declaring an imported
`extern "C"` (`mc_argv`) → `E_DUPLICATE_DECLARATION` (call the imported one). Canonical idioms confirmed:
**discard a must-handle `Result` via `if let err(e) = expr {}`** (no `let _ = expr;` statement discard,
G26-exempt); Result has no `is_ok`/`unwrap` — use `if let ok(v) = ...` or `?` propagation.

**P3 subset-grammar gaps to widen before P4/P5:** the P2 parser's `parse_type` accepts only `.identifier`
(so keyword-types `bool`/`void`/`u32`… as annotations don't parse — they arise only internally), and there
is no `var` (only immutable `let`). Both must be added for the parser to accept real mcc2 source at P5.

**G20 refined (P2):** *nested* if/else branches CAN reuse a `let` name, but *sequential* sibling blocks
at the same fn level cannot (`E_DUPLICATE_LOCAL`). Safe rule: **every `let`/`var` unique per function.**
Also confirmed: **params are immutable** (`E_ASSIGN_TO_IMMUTABLE_LOCAL`) — mutate via a `*mut` field, not param rebind.

**P2 verbosity vs Zig original: ~1.3–1.4×** real code lines — driven by G20 unique-naming, explicit type
annotations, and the G23 two-line workaround; the parse *structure* is a faithful 1:1 port. Token-kind
comparisons (via the lexer's `open enum TokKind`+`.raw()`) were friction-free — the parser needs almost
no string compares, unlike the lexer.

**P1 keyword-matching friction quantified (G12 consequence):** the 47-keyword table took **~94 lines**
of `[N]u8` + `mem_eql(lex, mem.as_bytes(&kN))` boilerplate (2 lines/keyword) vs ~47 one-line rows in
Zig — ~2× — because string literals are `*const u8`, not `[]const u8`, so `str_eq(lex, "fn")` is
impossible without a slice-from-literal path. This is the strongest single argument for eventually
fixing G12.
