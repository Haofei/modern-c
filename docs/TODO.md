# MC Compiler — Remaining Work

Status snapshot of what is left to implement against `MC_0.6.1_Final_Design.md`,
beyond the MC-C0 surface that is already done. The full type-checking surface of
the core language spec is implemented, and every spec operation that produces a
value lowers to clang-checked C. What remains is one language feature, one
analysis pass, and several large runtime/toolchain subsystems.

Effort scale: **S** ≈ <1 day · **M** ≈ 1–3 days · **L** ≈ ~1–2 weeks ·
**XL** ≈ multi-week / architectural.

## Language features (bounded, finishable)

- [x] **Precise inline assembly (§23.2)** — done (2026-06-06), effort **M**.
  Precise asm with register/typed operands is now parsed, sema-validated, and
  lowered to compilable GCC/Clang extended asm (previously rejected with the now
  -removed `E_PRECISE_ASM_UNSUPPORTED`).
  - [x] Parse `asm precise volatile { "..." out("reg") name: T, in("reg") expr, clobber("...") }`
        — `AsmStmt` carries `outputs: []AsmOutput` / `inputs: []AsmInput`
        (register string, operand, type); `out`/`in`/`clobber` parsed in the asm
        block.
  - [x] Verify it appears inside an `#[unsafe_contract(precise_asm)]` region
        (`E_PRECISE_ASM_CONTRACT`) and in `unsafe` (`E_UNSAFE_REQUIRED`); sema
        also checks each output names a mutable local (`E_ASSIGN_TO_IMMUTABLE_LOCAL`
        / `E_UNKNOWN_IDENTIFIER`), type-checks input expressions, and validates
        operand types.
  - [x] Lower to C extended asm: `__asm__ [__volatile__]("…" : "=r"(out_local)… :
        "r"(in_expr)… : clobbers)`. Operands are wired in declared order (outputs
        `%0..`, then inputs) to match the template's positional operands; outputs
        bind their named local lvalue, inputs feed their value expression.
        Generic `"r"` constraints (no C-level physical-register names) keep the
        emission target-portable; the declared registers are trusted per the
        contract and preserved as an `MC_PRECISE_ASM` provenance comment.
  - [x] `tests/spec/inline_asm.mc` precise accept cases + `tests/c_emit_precise_asm.mc`
        fixture (volatile/non-volatile, single/multi input, with/without
        clobbers); covered by `zig build sweep` and `c-test`. Unit test
        "emits C for precise asm with operands" in `lower_c.zig`.

- [x] **Interrupt context `#[irq_context]` (§19.1)** — done (core); effort **M**.
  Implemented as a MIR-owned verifier pass that reuses the `#[no_lang_trap]`
  attribute + verifier pattern. Verifier-only; no special C lowering required.
  - [x] Parse the `#[irq_context]` attribute on functions.
  - [x] Verifier (annex D.6 Context Verifier): a `#[irq_context]` function may
    only call other `#[irq_context]` functions and non-blocking primitives.
    MIR rejects unproven direct/indirect callees with `E_IRQ_CONTEXT_CALL`,
    rejects known blocking/sleeping/allocating operations with
    `E_IRQ_CONTEXT_BLOCKING`, and accepts extern/internal `#[irq_context]`
    callees plus raw/MMIO/atomic primitive names, typed atomic receiver calls,
    and typed MMIO register receiver calls. `tests/spec/irq_context.mc`
    and `tests/c_emit_irq_context.mc` cover the D.6 diagnostics, MIR facts,
    and accepted C lowering paths.
  - [ ] Optional (deferred): an `IrqOff` capability type for interrupts-disabled
    critical sections — a follow-on feature, not required for the §19.1 context
    verifier.

- [x] **Compile-time fixed indexing `const_get<N>()` (§8.1, §20.1)** — done.
  `arr.const_get<N>()` now indexes fixed-length arrays at a compile-time-known
  `N`, requires `N < len(arr)` in sema, has the array element result type, emits
  a MIR `const_get` index instruction with no `Bounds` trap edge, is legal under
  `#[no_lang_trap]`, and lowers to direct C element access without
  `mc_check_index`.

- [x] **Mathematical checked reduction `reduce.sum_checked<T>` (§8.2)** — done
  (2026-06-06), effort **M**. A checked reduction whose semantics differ from
  stepwise checked addition: the sum is computed in a wide integer domain and
  `Overflow` is returned only if the *final* result does not fit `T`.
  - [x] Sema: `reduce.sum_checked<T>(xs: []const T) -> Result<T, Overflow>`
        (`Overflow` added as a known error type; classified `.result`). Validated
        as a builtin namespace member: integer type arg (`E_REDUCE_REQUIRES_INTEGER`),
        exactly one slice argument (`E_REDUCE_ARG_NOT_SLICE`, `E_CALL_ARG_COUNT`).
  - [x] Lower to C: a GCC/Clang statement-expression accumulates the slice in an
        `__int128`, then single-range-checks the final result into `T`, yielding
        the `Result<T, Overflow>` struct (`.is_ok`/`.payload`); the slice is bound
        once to avoid double evaluation. `Overflow` lowers to a `uint8_t`
        (payload-free) error marker like `ConversionError`.
  - [x] Fixtures: `tests/spec/reduce_sum_checked.mc` (accept + the three reject
        diagnostics) and `tests/c_emit_reduce_sum_checked.mc`
        (signed/unsigned/narrow/mutable-slice), plus a `lower_c` unit test.
        Green under sweep + c-test.
  - _Known limitation (pre-existing, not specific to this feature): applying `?`
    to the call in a local initializer hits the MIR verifier's
    `E_TRY_REQUIRES_RESULT_OR_NULLABLE` gap, which also affects `try_from(x)?`;
    tracked with the MIR Result-inference work, not here. Direct `return` of the
    Result works._
  - _Note: §8.4 (unsafe hot checked loop) is already expressible — its
    primitives (`#[unsafe_contract(no_overflow)]` + `unchecked.add`) exist; only
    the optimizer's value-range fact propagation from the contract is missing,
    which is tracked under the MIR/optimizer item, not here._

## Compiler analysis (medium, partly prose-defined)

- [ ] **DMA/cache-coherence — core vs library boundary (§18)** — effort **M**, risk: spec interpretation.
  Done: typed `DmaBuf`, `cache.clean`/`cache.invalidate`, mode checks,
  address-class rules — the core tracks a buffer's *access mode and coherence*.
  The §18 update settled the boundary, which narrows the remaining core work:
  - [x] Documented (§18 summary): the DMA **primitive** = `DmaAddr` address class
        + typed `DmaBuf<T, coherence>` + typed `cache.clean`/`cache.invalidate`
        + `dma_addr()`/`as_slice()` bridge (spatial/representational facts,
        always enforced).
  - [x] Decided (§18): buffer *lifetime and ownership* are a **library profile**
        (move-only handles, temporal/linear facts), **not** a core compiler
        guarantee. The previously listed "ownership state machine per `DmaBuf`"
        is therefore out of core scope.
  - [ ] Core (still open): confirm the typed cache ops and `DmaBuf` modes gate
        coherent vs noncoherent access correctly, and that DMA-descriptor
        ordering composes with the §17/§19 ordering rules.
  - [ ] Library (out of core conformance): a move-only `DmaBuf` API returning
        `cpu_owned`/`device_owned` handles that requires `invalidate`-before-read
        and `clean`-before-handoff at the ownership transitions.

## Large subsystems (weeks, architectural)

- [ ] **Full comptime execution (§22)** — effort **L**, risk medium.
  Today `eval.zig` only const-folds scalar arithmetic and enforces the comptime
  effect rules. A general comptime interpreter needs:
  - [ ] Tree-walking evaluator over typed AST/HIR: expressions, control flow,
        calls, locals, structs/arrays, comptime memory.
  - [ ] Comptime↔type feedback (comptime values as array lengths, etc.).
  - [ ] Comptime trap / no-runtime-effect semantics.

- [x] **Production typed MIR/CFG + verifier** — core milestone **done**
  (2026-06-06). `src/mir.zig` is the production MIR entry point used by
  `mcc verify` and `emit-c`: basic blocks, typed instruction categories, explicit
  trap blocks/edges, contract-region ids, and MIR verifier facts. The older
  `ir.zig` remains a compatibility fact collector for spec inspection.
  Scope of "done": the typed CFG exists and is authoritative, and the D.1–D.6
  verifiers run as real MIR passes (81 MIR-native diagnostics; every D-invariant
  *usage* check migrated — the only sema-resident D-codes left are
  declaration/type well-formedness that Annex B *places* in sema). Evidence: full
  unit suite green, `zig build sweep` (54 spec fixtures / 348 functions) green,
  and `zig build c-test` green. Two genuinely **open-ended** tails (deeper
  value-range optimizer *algebra* and lowering the C backend *uniformly from*
  MIR) are explicitly carved into their own follow-on items below and under tech
  debt — they are research/architecture tier, not blockers for this milestone.
  - [x] Basic-block CFG with typed instructions and explicit trap edges
        (Appendix B/E).
  - [x] D.1–D.6 verifiers as complete real passes over MIR (Appendix D, incl.
        D.6 Context Verifier for `#[irq_context]`). Current MIR verifies
        fallthrough, structural CFG invariants including block-id/index
        consistency, `#[no_lang_trap]` trap edges, matching unsafe-contract
        regions, strict `unsafe {}` context checks for raw store, MMIO map,
        opaque asm, and raw-many pointer dereference, D.1 duplicate switch cases for scalar/Result/enum/union
        patterns plus switch literal-pattern type validation, enum/union
        switch case validation, and closed-enum exhaustiveness,
        D.2 complete checked binary trap-edge emission for unsigned
        division/remainder divide-by-zero, signed division/remainder
        divide-by-zero plus min/-1 overflow, left/right-shift invalid-count,
        and left-shift shifted-out-bit overflow,
        D.2 invalid-representation trap edges for runtime non-null pointer
        and closed-enum representation checks, while raw-many pointer and
        `ptr.offset` representation facts remain non-trapping,
        D.4 direct address-class dereference/opaque-operation rules and
        address-class conversion mismatch checks, including DmaAddr to
        PAddr/VAddr diagnostics,
        D.1 assignment target mutability and const-view write checks,
        including casted const pointer/slice storage views,
        D.1 arithmetic-domain misuse checks for implicit domain mixing,
        domain division/remainder, forbidden bitwise operands, and forbidden
        ordered comparison (`< <= > >=`) on `wrap`/`serial`/`counter` (allowed on
        `sat`) across `wrap`/`sat`/`serial`/`counter` aliases,
        D.1 operator operand checks for unsigned negation, logical bool
        operands, and bitwise signed/bool/pointer/generic operand misuse,
        D.1 binary numeric compatibility checks for signed/unsigned integer
        mixing, implicit integer promotion, float/integer mixing, and f32/f64 mixing,
        D.5 representation checks for boundary-returned non-null pointers and
        closed enums, D.1 null-to-non-null and nullable-to-non-null pointer
        conversions at target-typed sites, target-typed return/local/assignment,
        direct-call argument, condition-site, `for` iterable, and index
        base/operand conversion checks for the MIR type classes it currently preserves (including
        pointer mutability/view, pointee, and `c_void` boundary rejection),
        explicit cast result types for conversion/nullability facts,
        target-typed integer literal range checks,
        typed MMIO `Reg`/`RegBits` access-mode checks for read/write receiver
        calls (with MIR `pass=mmio` facts and `E_MMIO_ACCESS_FORBIDDEN`),
        direct target-typed array/struct aggregate literal element/field
        conversion recursion and aggregate shape checks for locals, returns,
        assignments to named locals, and direct-call arguments, including
        type-alias-resolved aggregate targets and cast-wrapped aggregate literals,
        a conservative D.1 Result pass for invalid `?`, invalid if-let and
        Result-switch branch patterns, unhandled Result
        statements/defers/switch expression arms/locals/reassignment, including
        Result locals handled through switch arm bodies and aggregate literal
        elements/fields, and
        try-payload return type compatibility plus target-typed
        local/assignment/call-argument and aggregate-field payload
        compatibility, including pointer mutability/view
        rejection for `?` payloads where MIR preserves the pointer class,
        including cast-wrapped try payloads, plus
        call-context summaries. MIR type alias resolution also feeds checked integer
        classification and `wrap`/`sat` arithmetic-domain trap suppression,
        including explicit casts into arithmetic-domain aliases.
        D.5 now also emits typed-load representation checks for global/local
        identifier reads, if-let narrowed bindings, and struct-field
        projections of non-null pointers and closed enums; target-context
        representation checks cover closed-enum literals and address-of pointer
        producers in globals, locals, returns, assignments, aggregate
        elements/fields, and direct-call arguments; and the MIR verifier checks
        predecessor-path dominance for representation-sensitive returns plus
        explicit representation-use markers for globals, locals, assignments,
        aggregate literal elements/fields, and direct-call arguments. Nested
        member/index/deref expressions in target-typed aggregate fields/elements
        now also emit explicit D.5 representation-use markers, casts are
        transparent for target-context D.5 representation checks, and ordinary
        non-null pointer dereference bases now emit `deref_base` representation
        uses while raw-many unsafe deref remains non-trapping/non-consuming.
        Representation-sensitive binary operands now emit `binary_operand`
        representation-use markers, with closed-enum literals kept as intrinsic
        compile-time values until a target context materializes a checked enum
        value, and representation-sensitive switch subjects
        now emit `switch_subject` representation-use markers for control-flow
        dispatch. `try` unwrap payloads that produce representation-sensitive
        values now emit `try_unwrap` representation-use markers.
        Nested
        assignment target paths
        (`field`, deref, and index storage targets) now resolve target types in
        MIR for conversion and representation-use checks. MIR also preserves
        inferred local type expressions for aggregate copies, direct function
        returns, `?` payload unwrapping, and narrowed `if let`/`switch`
        bindings, and emits D.5 typed-load representation checks for
        representation-sensitive deref/index/member projections, including
        copied array/struct values and array/struct values returned from calls.
        The verifier now also matches representation-sensitive producers and
        uses by MIR value identity when the producer/use carries one, including
        pointer-producing call results and inferred raw-many pointer offsets,
        with regression coverage for predecessor-path dominance of matching
        and mismatched value identities.
        MIR also distinguishes indirect calls from known direct calls and
        conservatively rejects them in `#[no_lang_trap]`/`#[irq_context]`
        contexts unless a typed callee summary can prove the target; the D.6
        verifier now emits MIR verification facts for context-call findings,
        distinguishes known blocking IRQ calls from unproven callees, and
        recognizes typed atomic/MMIO receiver methods as IRQ-safe primitives.
        (Value-identity matching for representation checks is MIR-native and
        regression-tested; broader aggregate value identity through more complex
        nested copies keeps a sema backstop — carved into the "MIR optimizer
        depth" follow-on below, not a gap in the D.1–D.6 milestone.)
  - [x] Value-range fact propagation from `#[unsafe_contract(no_overflow)]`
        regions (§8.4): the escape-hatch *syntax* already works, but the
        optimizer benefit (assuming covered ops don't overflow and propagating
        the resulting ranges) needs the MIR. Current MIR records scoped
        `RangeFact` entries for semantic top-level `unchecked.add/sub/mul`
        covered by `no_overflow` (transparent grouping and top-level casts do
        not hide a top-level operation), including the target result type for return,
        local, assignment, direct-call argument, and target-typed aggregate
        element/field facts; C lowering now consumes matching MIR range facts
        for top-level `unchecked.add/sub/mul` return/local/assignment paths,
        including inferred `u32` locals and cast-wrapped scalar
        return/local/assignment values,
        direct-call argument `unchecked.add/sub/mul` range facts including
        cast-wrapped arguments, and
        target-typed aggregate return/local/assignment/call-argument element
        and field facts including cast-wrapped elements/fields, and nested
        binary-operand facts before emitting plain overflow-free C arithmetic.
        Regression coverage: `tests/c_emit_value_range.mc` (constant-operand
        elimination) and `tests/c_emit_mir_value_range_contract.mc` (no_overflow
        range-fact consumption across return/local/nested/cast/aggregate-field).
        Deeper optimizer consumption (value-range *algebra* and downstream
        propagation past the materializing site) is open-ended and carved into
        the "MIR optimizer depth" follow-on below — not a blocker for this
        milestone, since MC's grammar produces no integer-range guards to analyze
        beyond the constant + contract sources already handled (see GRAMMAR NOTE).
  - [x] D.2 precise trap classification for the scalar/domain builtins and
        floats: `trap_from` emits a real trap edge; `from`/`wrap_from`/`sat_from`/
        `from_mod`/`try_from`/`residue` and the serial/counter ops
        (`before`/`after`/`distance`/`compare`/`delta_mod`/`elapsed_*`) emit none;
        IEEE float `+ - * /` and unary `-` emit none. This removed a class of
        `#[no_lang_trap]` false positives (pure casts/float math wrongly rejected)
        and a false negative (`trap_from` wrongly allowed). Regression fixture:
        `tests/spec/no_lang_trap_conversions.mc`.
  - [x] sema/MIR consistency for this case: `mcc check` (sema) now also flags
        `trap_from` under `#[no_lang_trap]`, matching the MIR verifier. `mcc check`
        remains a lighter type-check pass overall (the MIR verifier is the
        authoritative trap/contract/representation/context verifier, run by
        `verify` and `emit-c`); fully aligning the two passes is open.
  - [x] D.1 ordered-comparison domain operand check migrated to a MIR-native pass
        (`E_ORDERED_ARITH_DOMAIN_OPERAND` on `wrap`/`serial`/`counter`). Fixture:
        `tests/spec/mir_domain_ordering.mc`.

  - [x] D.1/D.4 check migration batch (10 checks, sema-only → MIR-native passes):
        ordered-comparison (`E_ORDERED_ARITH_DOMAIN_OPERAND`), pointer
        arithmetic on single-object pointers (`E_POINTER_ARITH_SINGLE_OBJECT`),
        pointer/view ordering (`E_POINTER_ORDERING`), serial/counter/conversion
        operation legality (`E_SERIAL_OPERATION`/`E_COUNTER_OPERATION`/
        `E_CONVERSION_OPERATION`), `c_void` dereference + member access
        (`E_C_VOID_DEREF`/`E_C_VOID_NO_LAYOUT`), direct MMIO register
        assignment (`E_MMIO_DIRECT_ASSIGN`), and array-to-pointer decay
        (`E_ARRAY_TO_POINTER_DECAY`). MIR-native diagnostic codes: 63 → 72.

  - [x] **D-invariant *usage* check migration — second batch (10 checks):** the
        remaining D.1/D.4/D.5 usage checks now emit MIR-native findings with
        regression fixtures: `E_MMIO_ORDERING` (`tests/spec/mmio_ordering.mc`),
        `E_ATOMIC_OPERATION`/`E_ATOMIC_ORDERING` (`tests/spec/atomics.mc`),
        `E_DMA_OPERATION`/`E_DMA_CACHE_MODE` (`tests/spec/dma_cache.mc`),
        `E_BITCAST_TYPE` (`tests/spec/bitcast_aliasing.mc`),
        `E_ARRAY_TO_POINTER_DECAY`, `E_LOCAL_ADDRESS_ESCAPE`,
        `E_ENUM_RAW_REQUIRES_OPEN_ENUM`, and
        `E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION` (each via a `finding ->
        code` mapping plus a production site in `src/mir.zig`). MIR-native
        diagnostic codes: 72 → 81.

  - [x] **D-invariant *usage* check migration — complete.** All D.1/D.4/D.5
        *usage* checks (those that operate on MIR instructions/values/operations)
        are now MIR-native. The one previously-listed straggler,
        `E_MC_VOID_POINTER_FFI`, was re-examined and is **not** a usage check: it
        fires in `checkType` purely on the raw type-annotation *spelling* ("at a
        C-ABI opaque boundary you wrote MC `void` where `c_void` is required").
        MIR does not preserve that `void`-vs-`c_void` annotation spelling (types
        are resolved by then), so there is nothing for a MIR pass to operate on.
        It belongs to the declaration/type well-formedness family below — moved
        there — which the Annex B pipeline correctly places upstream of MIR.

  - NOTE (scoping per Annex B): `E_MC_VOID_POINTER_FFI`, `E_MMIO_REGBITS_TYPE`,
    `E_MMIO_REGISTER_WIDTH`, `E_MMIO_REGISTER_POSITION`, `E_MMIO_PTR_TARGET`,
    `E_MMIO_ACCESS_MODE`, and `E_DMA_BUF_MODE` are **declaration/type
    well-formedness**, which the spec pipeline (Annex B) places in the typed
    AST/HIR stage *upstream* of the MIR — they correctly stay in sema and are
    not MIR-verifier gaps.
  - [x] **Value-range optimizer — constant trap elimination + propagation**:
        a checked `+`/`-`/`*` whose exact result (computed in `i256`) fits the
        target type lowers to **plain C arithmetic**, no overflow helper. This
        covers literal operands *and* constants propagated through immutable
        (`let`) integer locals (`constIntValue`/`constLocalValue`/
        `constBinaryProvenNoOverflow` in `lower_c.zig`): e.g. `let x:u8 = 200;
        let z:u8 = x + 50;` emits `x + 50` plain. Runtime and possibly-
        overflowing operands stay checked. Fixture: `tests/c_emit_value_range.mc`.
  - GRAMMAR NOTE: the classic **dominating-comparison-guard lattice**
    (`if x < 100 { ... x + 1 ... }`) is **not expressible in MC** — the language
    has no plain `if cond { }`, only `if let` (optional/Result narrowing) and
    `while`/`for`/`switch`. So integer-range guards from boolean `if`s simply do
    not exist to analyze. The implemented constant-operand + constant-local
    propagation covers MC's compile-time-known value-range sources; the only
    remaining (niche) source is constant-bounded `while i < CONST` loop bodies,
    which also needs reassignment tracking. The value-range optimizer is thus
    materially complete for what MC's grammar can express.

- [ ] **MIR optimizer depth & uniform lowering (follow-on to the production
  MIR milestone)** — effort **XL**, open-ended/research-architecture tier.
  The production typed MIR/CFG + verifier milestone above is done; this captures
  the deliberately-deferred, *unbounded* remainder so the milestone's scope stays
  honest:
  - [ ] **Deeper value-range optimizer**: value-range *algebra* (interval
    arithmetic over MIR values) and downstream propagation past the materializing
    site, plus constant-bounded `while i < CONST` loop-body ranges with
    reassignment tracking. Note (see GRAMMAR NOTE above): MC has no boolean `if`
    guards, so there is no comparison-guard lattice to mine — the high-value
    sources (constant operands/locals, `no_overflow` contract regions) are
    already consumed. This is incremental optimizer polish, not a correctness gap.
  - [ ] **Broader aggregate value-identity in MIR**: move the remaining
    complex-nested-copy value-identity tracking off its sema backstop and onto
    MIR value ids (scalar/pointer/closed-enum identity is already MIR-native and
    regression-tested).
  - [ ] **Uniform lowering from MIR** (the real architectural XL): lower the C
    backend uniformly *from* the typed MIR instead of today's AST-shape
    special-case matching in `lower_c.zig`. Tracked in detail under tech debt
    ("C backend is special-case matching, not a uniform lowering"); listed here
    too because it is the structural endgame these passes enable.

- [x] **Broader C-backend conformance (core emission)** — effort **L**.
  Scope: `src/lower_c.zig` faithfully lowers every construct the front-end
  (parser + sema + MIR verifier) accepts and that declares a `lower-c` phase.
  As of the 2026-06-06 audit + empirical sweep this is **complete and
  evidenced**, with the standing caveat that it is a *living* target: each new
  language feature adds new lowering, and "no known reachable defect" means
  validated-by-sweep, not exhaustively proven (two earlier "closed" claims this
  cycle were later disproven by deeper probing, which is why the evidence below
  is empirical rather than asserted).

  Evidence: `tools/spec-emit-sweep.py` (run via `zig build sweep`, also part of
  the `m0` gate) strips the `EXPECT_ERROR` functions from all 54
  `tests/spec/*.mc` fixtures and `emit-c` + `clang -std=c11 -Wall -Wextra
  -Werror`'s the ~348 remaining valid functions — all compile, except the two
  documented out-of-scope items it allowlists (`dma_cache.mc` DmaBuf =
  library-profile per §18; `unsafe_context.mc`'s `mmio.map<T>(pa)?` lives in a
  `phase=sema` fixture, so C emission is not a declared target). The reachable
  feature gaps found this cycle are closed (sub-items below); 10 new
  `tests/c_emit_*.mc` fixtures lock them in.

  Bail-site classification (all 128 audited): ~100 are one-line defensive
  guard-rails — call/type-arg arity (`call.args.len != N`), type-class lookups
  (`typeName(...) orelse`, `checkedTypeSuffix`, `primitiveCTypeName`),
  struct/array shape lookups — that sema validates *before* emission, so they
  are unreachable for sema-accepted programs. Of the 27 bare bails, the
  reachable feature gaps are closed; the rest guard shapes sema/parser already
  reject (non-static global initializers `E_GLOBAL_INITIALIZER_NOT_STATIC`,
  if-let patterns other than optional/Result bindings `E_IF_LET_NARROW_PATTERN`,
  precise inline asm `E_PRECISE_ASM_UNSUPPORTED`).

  Out of scope for this item (not `lower_c.zig` gaps): language constructs MC
  deliberately omits or never specified — plain `if cond {}`
  (`MC_0.6.1_Final_Design.md`: "a deliberately narrow `if let` form"),
  function-pointer types, sub-slicing
  `a[i..j]`, switch range patterns (all rejected upstream in the parser/sema) —
  and library-profile types (serial/counter/DmaBuf, explicitly out of core
  conformance, §18). Lowering those would require front-end/language work and
  is tracked by their own items, not here.

- [ ] **C-backend conformance — ongoing maintenance.** As new language/library
  features land (Standard library, full comptime, precise inline asm, etc.),
  add their C lowering and a `tests/c_emit_*.mc` fixture; `zig build sweep`
  (`tools/spec-emit-sweep.py`, also in the `m0` gate) re-runs the spec-corpus
  emit+clang check to catch regressions. This is the perpetual tail of the
  item above.
  - [x] Aggregate typedef ordering: generated container typedefs (slices,
        arrays, `Result`) reference user structs, and structs embed those
        containers, so emitting them in a fixed category order produced
        forward-reference errors (`[]Packet`/`[4]Packet`/`struct { []Inner }`
        all failed `clang` with "unknown/incomplete type"). Now every user
        struct and tagged union is forward-declared up front (so pointer/slice
        references resolve), and arrays/structs/`Result`s/tagged-unions are
        emitted in dependency order (`emitOrderedAggregates`) so by-value
        embedding sees complete types. Array and `Result` typedefs are
        forward-declared too, so a slice of an array (`[][N]T`, element pointer
        `mc_array_..._N *`) resolves. Fixture
        `tests/c_emit_aggregate_ordering.mc`.
  - [x] Nested (multidimensional) array indexing `m[i][j]` over `[N][M]T` now
        lowers correctly: `arrayTypeForExpr` recurses through index bases so
        each dimension indexes its `.elems` member with its own bounds check
        (`m.elems[check(i,N)].elems[check(j,M)]`), instead of emitting an
        invalid `m.elems[..][j]`. Same fixture.
  - [x] Empirical spec-corpus sweep (2026-06-06): stripped the `EXPECT_ERROR`
        functions from all 54 `tests/spec/*.mc` fixtures and `emit-c` +
        `clang -Werror`'d the ~348 remaining valid functions. Found and fixed
        three reachable emission bugs (below); the only residual failures are
        `dma_cache.mc` (DmaBuf, explicitly library-profile/out-of-core, see §18
        above) and `unsafe_context.mc`'s `mmio.map<T>(pa)?` (a `phase=sema`
        fixture — C emission is not a declared target there).
  - [x] Signed-repr enums with negative discriminants (`enum E: i8 { n = -1 }`)
        now lower: the enum-value emitter handles unary negation, not just bare
        integer literals. Fixture `tests/c_emit_signed_enum.mc`.
  - [x] The explicit `wrapping.add(a, b)` builtin now lowers to plain C `+`
        (modular, no trap edge), matching `a + b` on `wrap<T>` operands;
        previously it emitted an undeclared `wrapping` identifier. Fixture
        `tests/c_emit_wrapping_builtin.mc`.
  - [x] `Result<void, E>` (e.g. `return ok(())`) now lowers: C has no `void`
        struct member, so a void Result payload uses a 1-byte placeholder and
        the unit value `()` stays `0`. Fixture `tests/c_emit_void_result.mc`.
  - [x] Character literals (`'x'`, `'\n'`, …) now lower to C — MC's escape set
        (`\\ \' \" \0 \n \r \t`) is a subset of C's, so the lexeme emits verbatim
        in returns, typed locals, and call arguments. Fixture
        `tests/c_emit_char_literals.mc`.
  - [x] Checked integer arithmetic assigned into a struct field or array
        element (`r.v = a + b`, `xs[0] = a * 2`) now lowers through the checked
        helper. The assignment path carries no target type for `.member`/`.index`
        targets, so `emitCheckedBinary/UnaryWithTarget` now decline (return false)
        on a null target instead of erroring, letting `emitExpr` infer the type
        from the operands. Fixture `tests/c_emit_checked_in_assignment.mc`.
  - [x] Checked integer arithmetic used as a comparison operand (e.g.
        `(a + b) == c`) now lowers through the checked helper instead of
        bailing: the targetless `emitExpr` binary path recovers the operand
        storage type via `numericExprTypeForEmission` and delegates to
        `emitCheckedBinaryWithTarget`, so the overflow trap edge survives.
        Covers add/sub/mul/div, signed/unsigned, nested, and logical
        connectives. The same recovery applies to targetless signed
        negation (`(-a) == b` → `mc_checked_neg_i32`), while wrap/sat
        negation stays plain. `numericExprTypeForEmission` also lets a bare
        numeric literal adopt its sibling operand's type, so `a + 1` resolves
        (e.g. `while (i + 1) < n`, `(a + 1) == a`).
        Fixture `tests/c_emit_checked_in_comparison.mc`.
  - [x] `?` (try) nested inside other expressions now lowers in more shapes:
        (a) `?` as a typed-local initializer in a non-`Result` function (unwrap
        with trap-on-err, not just the propagation case `emitResultTryExprLocalInit`
        previously required); (b) `?` inside an `ok(...)`/`err(...)` constructor
        argument (`return ok(a?)`, `return ok(dbl(a?))`) via a new
        `emitResultTryConstructorReturn`; (c) two `?` operands in one
        sub-expression (`ok(a? + b?)`) — fixed a short-circuit `or` in the
        `collectResultTryHoistsFor{Return,LocalInit}` binary/index cases that
        previously hoisted only the left operand's try. Fixture
        `tests/c_emit_try_in_expressions.mc`.
  - [x] String literals now lower to C. They require a target type (sema
        rejects targetless ones) and emit a C string literal cast to the target
        u8-pointer type (`*const u8` -> `(uint8_t const *)"…"`); MC's escape set
        is a subset of C's so the lexeme emits verbatim. This needed a MIR
        verifier change too: a string literal is a non-null pointer by
        construction, so `exprNeedsTargetRepresentationCheck` now treats it like
        `address_of`, emitting the dominating `representation_check` that
        discharges the `nonnull_pointer` obligation (previously the
        `return_value`/`call_arg` use tripped `E_REPRESENTATION_CHECK_MISSING`).
        Fixture `tests/c_emit_string_literals.mc`.
  - [x] Atomic locals (§19) now lower to C: an `atomic<T>` local becomes its
        plain payload object, `atomic.init(v)` becomes the initial value, and
        `obj.load/store/fetch_add(..., .ordering)` become
        `__atomic_load_n` / `__atomic_store_n` / `__atomic_fetch_add` on `&obj`
        with the mapped `__ATOMIC_*` order constant — matching the inspector's
        existing `atomics-lowering` facts. Previously only the inspector facts
        existed and emission bailed. Fixture `tests/c_emit_atomics.mc`.
  - [x] Generated C no longer `#include <string.h>`; internal struct/bitcast
        copies use `__builtin_memcpy` (the emitter already requires GCC/clang
        builtins via `__builtin_trap`). This stops libc fortify macros (e.g.
        macOS `#define memcpy(...) __memcpy_chk_func(...)`) from mangling user
        FFI declarations like `extern "C" fn memcpy(...)`, which previously
        broke `tests/c_emit_c_void_ffi.mc` under `clang -Werror`.

## Engineering tracks (large, low conceptual risk)

- [ ] **Standard library** — effort **L+**, open-ended; the design doc does not
      fully specify one, so scoping is the hard part.
- [ ] **Package manager / toolchain / releases** — effort **L+**, plumbing, not
      language work.
- [ ] **Hardware MMIO execution tests** — effort **M**; stand up a QEMU-based
      harness (the MMIO *lowering* already exists).

## Known implementation issues / tech debt

From an external static review; each verified against the code.

- [x] **`emit-c`/`lower-*`/`facts` wrote artifacts to stderr** — fixed: generated
      output now goes to stdout (`writeStdout` in `main.zig`); diagnostics/logs
      stay on stderr; `tools/check-generated-c.sh` updated to capture with `>`.
- [ ] **C backend is special-case matching, not a uniform lowering** — ~126
      `UnsupportedCEmission` bail sites; local-init tries ~a dozen shapes and
      falls back to defaulting untyped locals to `uint32_t`. This is the
      "production MIR/verifier" item: lower from a typed MIR uniformly. (Accurate.)
- [x] **`export` was parsed then discarded** — fixed: `FnDecl.exported` flag
      captured by the parser; the C emitter omits `static` for exported
      functions so `export fn boot_entry` is linkable. Fixture
      `tests/c_emit_export.mc`.
- [x] **No C identifier mangling/escaping** — fixed: `cIdent` in `lower_c.zig`
      rewrites C reserved words (`int` → `int_`, …) consistently at definitions
      and uses; identity for ordinary names. Fixture
      `tests/c_emit_keyword_idents.mc`. (User `mc_*`-prefixed names are left
      as-is to avoid clashing with the emitter's own temporaries — a narrow,
      documented edge.)
- [x] **Plain `struct` vs `extern struct` AST modeling** — fixed: the AST kind
      was renamed `.extern_struct` → `.struct_decl` (it carries all structs);
      the `abi` field is the documented ABI/extern discriminator, so the name no
      longer implies extern-only.
- [x] **Silent failures swallowed allocator errors** — fixed: sema sets an
      `oom` flag on any failed symbol-table put and surfaces `E_INTERNAL_OOM`
      instead of checking an incomplete table; HIR now propagates allocation
      errors with `try` instead of `catch {}`/`catch unreachable`.
- [x] **Compound-assignment tokens were lexed but never parsed** — fixed:
      removed the dead `+= -= *= /= %= &= |= ^= <<= >>=` production and token
      variants (not in the spec; no fixtures used them). `->`, `<=`, `>=`, `<<`,
      `>>`, `&&`, `||` are unaffected.
- [ ] **`return` span covers only the `;`**, not `return`→`;`; affects
      diagnostics/source maps. (Plausible; low impact.)
- [x] **AST `Module.deinit` is a shallow free** — clarified with a doc comment:
      it frees only the top-level `decls` slice because the AST is arena-backed;
      it is not a recursive destructor.
- [x] **C backend relies on GCC/Clang builtins** (`__builtin_trap`,
      `__builtin_*_overflow`, `__atomic_*`, `__int128`) — documented as
      Clang/GCC-only in the README Requirements section.

Note: the review's "inferred globals are silently inconsistent" point is mostly
inaccurate — untyped globals are rejected in sema with `E_GLOBAL_REQUIRES_TYPE`
(parse-permissive, reject-in-sema), which is intentional, not a silent hole.

## Explicitly deferred

- [ ] **LLVM backend (Appendix M)** — not started; the C backend is the only
      lowering target. Deferred by request.

## Suggested order

1. ✅ **Precise inline assembly (§23.2)** — **done** (2026-06-06). Parsed,
   sema-validated, and lowered to compilable GCC/Clang extended asm with
   `out`/`in`/`clobber` operands; fixtures in `tests/spec/inline_asm.mc` +
   `tests/c_emit_precise_asm.mc`, green under sweep + c-test.
2. **DMA/cache-coherence core checks (§18)** — effort **M**. Boundary decided;
   ownership is a library profile, so the only open *core* work is confirming the
   typed cache ops/`DmaBuf` modes gate coherent vs noncoherent access and that
   descriptor ordering composes with §17/§19. Small, bounded.
3. ✅ **`reduce.sum_checked<T>` (§8.2)** — **done** (2026-06-06). Wide-accumulate
   (`__int128`) + single range-check lowering to `Result<T, Overflow>`; fixtures
   in `tests/spec/reduce_sum_checked.mc` + `tests/c_emit_reduce_sum_checked.mc`,
   green under sweep + c-test.
4. **Full comptime interpreter (§22)** — effort **L**. Tree-walking evaluator +
   comptime↔type feedback. Largest *bounded* language item.
5. **Production typed MIR/CFG + verifier** — ✅ **done** (core milestone,
   2026-06-06). Typed CFG + trap edges + D.1–D.6 verifier passes (81 MIR-native
   diagnostics, all usage checks migrated); unit suite + sweep + c-test green.
   What remains is the explicitly-carved **MIR optimizer depth & uniform
   lowering** follow-on (deeper value-range algebra, broader aggregate
   value-identity in MIR, and the architectural uniform-lowering-from-MIR goal) —
   open-ended/research tier, sequence it after the bounded language items above.
6. **Engineering tracks in parallel as needed**: Standard library (scoping is the
   hard part — design doc underspecifies it), package manager / toolchain, QEMU
   MMIO hardware tests.
7. Deferred by request: LLVM backend (Appendix M).
