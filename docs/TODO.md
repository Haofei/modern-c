# MC Compiler — Remaining Work

Status snapshot of what is left to implement against `MC_0.6.1_Final_Design.md`,
beyond the MC-C0 surface that is already done. The full type-checking surface of
the core language spec is implemented, and every spec operation that produces a
value lowers to clang-checked C. What remains is one language feature, one
analysis pass, and several large runtime/toolchain subsystems.

Effort scale: **S** ≈ <1 day · **M** ≈ 1–3 days · **L** ≈ ~1–2 weeks ·
**XL** ≈ multi-week / architectural.

## Language features (bounded, finishable)

- [ ] **Precise inline assembly (§23.2)** — effort **M**, risk low.
  Currently rejected with `E_PRECISE_ASM_UNSUPPORTED`; only opaque asm (§23.1)
  works.
  - Parse `asm precise volatile { "..." out("reg") name: T, in("reg") expr, clobber("...") }`.
  - Verify it appears inside an `#[unsafe_contract(precise_asm)]` region.
  - Lower to C `asm volatile("..." : outputs : inputs : clobbers)`.
  - Add `tests/spec/inline_asm.mc` precise cases + a `c_emit_*` fixture.
  - _Last strictly-language feature; most self-contained remaining item._

- [ ] **Interrupt context `#[irq_context]` (§19.1)** — effort **M**, risk low.
  Newly specified primitive; partially implemented as a MIR-owned verifier pass
  that reuses the `#[no_lang_trap]` attribute + verifier pattern.
  - [x] Parse the `#[irq_context]` attribute on functions.
  - [ ] Verifier (annex D.6 Context Verifier): a `#[irq_context]` function may
    only call other `#[irq_context]` functions and non-blocking primitives.
    Current MIR rejects unproven direct/indirect callees with `E_IRQ_CONTEXT_CALL`,
    rejects known blocking/sleeping/allocating operations with
    `E_IRQ_CONTEXT_BLOCKING`, and accepts extern/internal `#[irq_context]`
    callees plus raw/MMIO/atomic primitive names, typed atomic receiver calls,
    and typed MMIO register receiver calls. External `tests/spec/irq_context.mc`
    and `tests/c_emit_irq_context.mc` now cover the D.6 diagnostics, MIR facts,
    and accepted C lowering paths.
  - Optional: an `IrqOff` capability type for interrupts-disabled critical
    sections.
  - Verifier-only; no special C lowering required.

- [x] **Compile-time fixed indexing `const_get<N>()` (§8.1, §20.1)** — done.
  `arr.const_get<N>()` now indexes fixed-length arrays at a compile-time-known
  `N`, requires `N < len(arr)` in sema, has the array element result type, emits
  a MIR `const_get` index instruction with no `Bounds` trap edge, is legal under
  `#[no_lang_trap]`, and lowers to direct C element access without
  `mc_check_index`.

- [ ] **Mathematical checked reduction `reduce.sum_checked<T>` (§8.2)** — effort **M**.
  A checked reduction whose semantics differ from stepwise checked addition:
  compute the sum in a wide/abstract integer domain and return `Overflow` only
  if the *final* result does not fit `T`. Not implemented (grep: `reduce.*`
  absent). Needs an intrinsic (the wide accumulation cannot be expressed as a
  plain library loop of checked adds). Per the §0/A.1 layering this is a
  compiler-blessed intrinsic, not an ordinary device library.
  - Sema: `reduce.sum_checked<T>(xs: []const T) -> Result<T, Overflow>`.
  - Lower to C: accumulate in the next-wider integer (or `__int128`), then a
    single range check into `T`.
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

- [ ] **Production typed MIR/CFG + verifier** — effort **XL**, risk high.
  `src/mir.zig` now provides the production MIR entry point used by `mcc verify`
  and `emit-c`: basic blocks, typed instruction categories, explicit trap
  blocks/edges, contract-region ids, and MIR verifier facts. The older `ir.zig`
  remains a compatibility fact collector for spec inspection.
  - [x] Basic-block CFG with typed instructions and explicit trap edges
        (Appendix B/E).
  - [ ] D.1–D.6 verifiers as complete real passes over MIR (Appendix D, incl.
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
        Broader aggregate value identity through more complex nested copies is
        still enforced in sema or not yet MIR-native.
  - [ ] Value-range fact propagation from `#[unsafe_contract(no_overflow)]`
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
        Broader optimizer consumption (other nested
        expression forms beyond binary operands, value-range algebra, and downstream optimizer
        propagation) remains open.
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

  Genuinely remaining for this item:
  - **~11 D-invariant *usage* checks still sema-only**: `E_MMIO_ORDERING`,
    `E_ATOMIC_OPERATION`/`E_ATOMIC_ORDERING`, `E_DMA_OPERATION`/
    `E_DMA_CACHE_MODE`, `E_BITCAST_TYPE`, `E_ARRAY_TO_POINTER_DECAY`,
    `E_LOCAL_ADDRESS_ESCAPE`, `E_MC_VOID_POINTER_FFI`,
    `E_ENUM_RAW_REQUIRES_OPEN_ENUM`, `E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION`.
    Each duplicates sema logic; doing them well should **share** the sema/MIR
    semantic model rather than triple it (the three-way-duplication root issue).
  - NOTE (scoping per Annex B): the remaining `E_MMIO_REGBITS_TYPE`,
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

- [ ] **Broader C-backend conformance** — effort **L**, ongoing.
  ~126 `UnsupportedCEmission` bail sites in `src/lower_c.zig`. The emitter
  handles known patterns and fails loudly otherwise (by design); closing these
  is steady, open-ended work.

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

1. Precise inline assembly (§23.2) — finishable, self-contained.
2. Interrupt context `#[irq_context]` (§19.1) — reuses the `#[no_lang_trap]` path.
3. DMA/cache-coherence core checks (§18) — boundary now decided; ownership is a
   library profile, so the remaining core work is small.
4. Comptime interpreter (§22).
5. Production MIR/CFG + verifier (unblocks broader C-backend conformance).
6. Stdlib / toolchain / hardware tests in parallel as needed.
