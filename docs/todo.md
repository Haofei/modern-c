# Roadmap and refactoring plan

The one active backlog for MC. It merges the former `refactoring-plan.md`
(goal, target shape, completed cutovers, patch rules) with the roadmap, so
there is a single place to look. Historical campaigns live in git history.

## Baseline

| Gate | What it is |
|---|---|
| `zig build test` | Compiler unit tests and spec conformance. |
| `zig build m0` | The normal local/CI compiler-core gate. Must run with zero SKIPs. |
| `zig build fast` | Broad host-only gate: `m0` plus the C fixture sweep (`c-test`) and the spec emit sweep (`sweep`). Both sweeps consult the named known-gap manifest in `docs/backend-expected-failures.json`, so a new failure is distinguishable from recorded debt and a recorded entry that starts passing fails the gate until it is removed. |
| `zig build llvm-oracle` | Every LLVM gate plus `diff-backend`. Run from `m0-full`, not from the tiers that gate a change. |
| `zig build m0-full` | The full matrix: fuzz oracles, host-driver fixtures, retained QEMU fixtures, coverage ratchets, and the LLVM oracle. |

Policy that the gates encode:

- C is the primary backend and the backend under test. LLVM is a differential
  oracle: `mcc emit-llvm` and its lowering stay, its gates live in
  `llvm-oracle`, and a feature is qualified on C first.
- Async/await is not in this tree. It lives on the `experimental-surface`
  branch; the parser rejects `async`/`await` with `E_ASYNC_ON_BRANCH`.
- `docs/feature-maturity.json` is the machine-readable feature-status table.
  Traits, closures, broad generics, and the advanced ownership forms stay
  experimental there; removing them was measured and is not a bounded change.
- Freestanding/QEMU fixtures are compiler-validation workloads, not a kernel
  deliverable.

## Architecture goal

Remove duplicate semantic authority. Every type, representation, ABI, layout,
provenance, control-flow, ownership, and safety decision is made once, in the
front end, and carried to the backend as a typed fact. Backends may use source
spelling for emission mechanics only.

```text
CompilationSession
        ↓
sema                      diagnostics, sema_symbols (a DefId per declaration),
        │                 sema_types.Resolved (interned structural types,
        │                 recorded per expression)
        ↓
CheckedProgram            syntax-free callable / global / signature facts
        ↓
typed MIR + verifier      ExecutableBody plus facts keyed on instruction identity
        ↓
VerifiedProgram
        ↓
mechanical C emission     LLVM lowers the same program as an oracle
```

`src/compiler_session.zig` owns the session. `src/artifact_publisher.zig`
owns output. `src/main.zig` is only the CLI composition root.
`CheckedProgram` is a thin semantic table, not a second expression IR.
The inspection HIR is a dump tool and is not part of the pipeline.

The state of the sema-to-MIR handoff, and the one import rule that keeps
backends off syntax, is described in
[`typed-semantic-facts.md`](typed-semantic-facts.md).

## Closed, and what keeps it closed

| Invariant | Enforced by |
|---|---|
| Backend and MIR-body modules do not import the syntax front end; every remaining edge is named in one exceptions table. | `zig build architecture-boundary-test` |
| `LowerRequest` carries only `VerifiedProgram`, output, and emission options. Legacy AST body emitters, declaration artifacts, and backend comptime providers are deleted. | `src/codegen_request.zig`, unit tests |
| Parsing and source identity are per file; no combined textual source exists. | `src/loader.zig`, `src/module_parser.zig` |
| Every declaration has a `DefId`; sema records an interned resolved type for every expression it types, and the MIR builder reads those instead of re-inferring where the table answers. | `src/sema_symbols.zig`, `src/sema_types.zig`, debug agree-assertions in `src/mir_build.zig` |
| Every instruction-scoped fact joins to its instruction by identity, not by source span, with an exactly-one invariant: integer, float, bounds, representation, target-type, call-target, `const_get`, bind-thunk and range. Resolved accesses key on an `AccessId`. A span repeats -- monomorphization copies one -- so it was never an identity. | `src/mir_verify.zig`, `src/mir_body_plan.zig`, `src/mir_tests.zig` |
| A red sweep is a failure, not background noise, and a recorded gap is pinned to the *cause* it was recorded for, not merely to `E_BACKEND_UNSUPPORTED`. | `docs/backend-expected-failures.json` and the `backend-expected-failures-test` validator; the shared cause shape in `tools/toolchain/backend_gap_lib.py` |
| A non-zero `mcc` exit always prints a diagnostic. | `src/diagnostics.zig`, `src/compiler_session.zig` tests |

## Active priorities

| Priority | Work | Why, and what it depends on |
|---|---|---|
| P0 | Collapse MIR to the single `ExecutableBody`: move the remaining consumers of the string `Instruction.detail` field off it (see the note below), rewrite the legacy-stream checks in `mir_verify.zig` against the typed body, fold instruction-scoped fact tables into typed nodes, repoint `mir_dump.zig`, then delete `Function.blocks[].instructions`. | The core of the original design review. Two body representations cost every change twice. Depends on the golden-test conversion below for affordability. |
| P0 | Replace the string-carrying `mir.ValueType` with type ids from the resolved table, then drop the parallel `typed_result_ty` mirrors. | Falls out once the table answers everything `ValueType.name()` is asked for. |
| P0 | Finish the sema handoff: intrinsic call results where sema and builder share one rule, `address_of` / `borrow` / `~`, alias collapse once the emitters take spellings from the table, and deletion of the builder's own type maps once unit tests build MIR through a checker. | Each slice: record in sema, read in the builder under the agree-assertion, delete the builder copy. |
| P1 | Give expressions a node identity that survives copying, or a per-instance span remap in monomorphization. | Unblocks monomorphizing after sema and stops instances failing closed in the resolved table. |
| P1 | Bring the C backend's `ast_bridge` / `type_bridge` imports to zero, one file at a time. | The exceptions table in `src/architecture_boundary_tests.zig` is the countdown. LLVM is already at zero. |
| P1 | Finish converting golden tests into fixtures: the MIR *dump* corpus is now `tests/mir/` (see `test-architecture.md`), but the `appendVerificationFactsFrom*` sites in `src/mir_tests.zig` are still in-Zig golden strings, as are the emitted-C goldens in `src/lower_c_tests.zig`. | The in-Zig golden strings are the largest consumer of the legacy instruction stream and the reason representation changes turn into mass test rewrites. |
| P1 | Clear the remaining `docs/backend-expected-failures.json` entries or record a precise cause for each. | Each entry is a backend feature gap with a minimal reproduction. Every `E_BACKEND_UNSUPPORTED` entry now carries a machine-checked `cause` (refusing phase, category, construct, function), so an entry can no longer outlive the gap it was written for. See the note below for what is left. |
| P2 | Split `src/mir_build.zig` by construct family and extract the shared AST-query surface still in `src/mir.zig`. | Readability. No behavior change. |
| P2 | Audit `tools/` for scripts no gate runs; mark spec sections by maturity inline. | Hygiene. |

### Note: the `Instruction.detail` readers that are left

`mir_build.zig`, `mir_body_plan.zig` and `lower_c_map.zig` no longer classify
instructions by their `detail` string. One real reader remains:

- **`lower_c_map.zig`** is off `detail` for row labelling. It reads
  `TargetTypeFact.kind` and the new `RepresentationFact.use`, and crosses the
  instruction-to-typed-node join for the rest: a `binary` instruction is a
  switch subject when the `guard` statement that realizes it says `.switch_`,
  and an `expr` instruction's syntactic class is its typed expression's
  `operation`. The only `detail` left in the file prints the field verbatim
  into the MIR digest, which is a dump of the stream, not a reader of it.
  Labels got *more* accurate in the move: the string test misread a parameter
  named `int` as an integer literal, and never recognised a boolean literal at
  all (`exprText` spells it `bool`).
- **`mir_build.zig`'s `addCallTargetFact`** checks that the instruction it just
  emitted really is the `call_target` the fact claims. That is a cross-check
  *between* the two representations; it should go when the stream does.
- **`mir_representation.zig` and `backend_cleanup.zig`** mention `detail` only
  inside `test {}` blocks, where they hand-build an `Instruction`. Nothing to
  move: they are test-only consumers.

The join that unblocked `lower_c_map.zig`:

`ExecutableStatement` and
`ExecutableExpression` carry `inst_id`, the identity of the instruction the
node replaces, and `mir_verify.validateExecutableBodyJoinForLowering` proves it
resolves, is single-valued, and is total on the statement-shaped instruction
kinds. `ExecutableStatement.id` keeps its meaning as an array index -- it is
what `owner_statement` points at -- so the two were not renumbered from one
sequence. See [`typed-semantic-facts.md`](typed-semantic-facts.md#the-join-between-the-two-bodies).

### Note: how deref-of-a-call-result was closed

`call(...).*` was the largest `E_BACKEND_UNSUPPORTED` family in
`backend-expected-failures.json`. Recorded because the shape that works is not
the obvious one:

- Rooting the place at the call *value*, the way the index path does, is
  wrong. A guarded deref spells its place more than once, so the call would be
  evaluated more than once.
- Binding the call result to a synthetic local first gives the deref the
  ordinary `executableGuardedLocalScalarDerefPlace` form, which already has
  its representation check, its trap edge and its renderer in both backends.
- The remaining piece was the guard. The call result is already wrapped in a
  `representation_check` expression, so a second guard on the place would
  check the same pointer twice against one legacy `representation_check`
  instruction. `executableLocalInitializedByCheckedPointer` is the proof that
  it does not need one, and it is deliberately narrow: only a *synthetic*
  local, initialized exactly once from a `nonnull_pointer` check and never
  stored through. Widening it to source locals changes the guard on places
  that have always carried one -- `let q = p; q.* = v;` regressed the moment
  the predicate accepted a named local.

`data_race_semantics.mc` is still listed: its deref cause is fixed, and what
remains there is `index` / `range_slice` over slices whose elements are
pointers.

### Note: the sweep gaps that are left

One `E_BACKEND_UNSUPPORTED` entry remains in
`backend-expected-failures.json`:

| Family | Fixtures | What it is |
|---|---|---|
| pointers through arrays, slices and aliases | `data_race_semantics.mc` | **Blocked, and it is not one gap.** Deleting each failing function and re-emitting enumerates 60 of them. 21 are an `index` expression over a slice whose elements are pointers: mir-build accepts those now, and the C backend's own `supportsType` admission still declines the element type. 5 more are an array of pointers reached through a pointer to it, 3 an aggregate pointer alias whose executable shape is incoherent, 1 an array-element assignment. The remaining families are a `*T as [*]T` cast kind that neither `ExecutableCastKind.classify` nor either renderer has, an indirect call through a pointer alias copied from a parameter (declined by codegen admission as `expression `local``), and a trapping store of a pointer into an aggregate field. Closed on the way past: `(&E).*`, and the slice-element rule's mir-build half. |

The five `E_EXPERIMENTAL_DYN_CODEGEN` entries are policy and stay.

Closed: **`incoherent_place`** (`local_address_escape.mc`). `*out = p` where
`out: *mut *mut u32` was refused because the deref place's pointee check
compared the pointer's `PointerShape.child` spelling against the pointee type's
`ValueType.name()` -- and those were two different spelling rules. The syntax
side kept the pointee for the scalar names it could name (`*mut u32`), the
model side dropped it for everything but `c_void` (`*mut`), so a pointer to a
pointer never compared equal to its own pointee. They are one rule now,
`mir_model.pointerSpelling`, which `mir_syntax` renders through and
`ValueType.name()` is; `pointerShapeFromSpelling` inverts the spellings that
kept their pointee, which is what lets the C renderer *render* a
pointer-to-pointer instead of pasting `*mut u32` in front of a `*`. The
spelling is still a presentation name, not an identity: a pointee it cannot
name falls back to the bare form.

Reclassified, not fixed: **`incoherent_executable_shape`**
(`type_arg_and_trivial_drop_reject.mc`). This is a pure `expect=compile_error`
fixture whose two cases are both sema diagnostics. Stripping them leaves only
the `fn type_id(comptime T: type)` template the rejected call was written to
exercise, and an uninstantiated type-generic template is not a C-emission
contract -- the backend emits instances, never templates. It belongs in the
sweep's `OUT_OF_SCOPE` allowlist beside the other pure diagnostic fixtures, not
in the backend-gap manifest, and that is where it is now. (Making
`comptime T: type` always type-generic in `monomorphize.zig` would also make
the chunk emit, but it moves the rejected call into the instantiation path and
`E_TYPE_ARG_REQUIRED` stops being reported -- a real regression on the
fixture's own contract. Measured and reverted.)

Closed: **`unsupported_try`** (`hosted_io.mc`). `let f = io_open(...)?;` inside
a `-> Result<usize, IoError>` function propagates a `Result<Fd, IoError>`. The
two `Result` types differ, so `try_propagate` -- which returns the operand
itself -- does not apply; and `try_map_error`, which builds the enclosing
function's `Result`, required the two ok payloads to be equal. That requirement
was spurious: the operation returns only on the error path, where the enclosing
`Result`'s ok slot is never filled, and the value it yields on the ok path is
the operand's own payload. Dropping it leaves the same-error case with no
mapper, so `ExecutableTryErrorMapper` gained an `identity` arm: the error moves
into the return value's error slot unchanged, and both renderers read it
straight out of the operand.

Closed: **`unsupported_call`** (`comptime_params.mc`). It was not a call
problem either. `sizeof([{ return N; }]u8)` folds to nothing because
`mir_reflect.staticArrayLen` was a second, weaker copy of
`array_len.parseArrayLen`: literals, grouping and binary arithmetic, and no
block-expression length -- the form every other array-length consumer in the
tree folds. Reflection is not a place to decide what an array length is, so it
reads the one rule now. The evaluator arguments stay null, so an identifier or
call length still does not fold there; nothing the copy could answer was lost.

Closed, inside a family that stays open: `(&E).*`. The address is taken and
immediately given back, so the pair names `E`'s own storage. Nothing folded it:
the deref asked for the pointee of `&E`, neither sema nor the builder computes a
type for an `address_of`, and an `address_of` is a value with no storage to root
a place at -- so the place, the root identity, the access class and the type
were all missing at once. Folding the pair answers all four with `E`'s own
answers, which is also the only correct set.

Closed: **`incoherent_cleanup_action`** (`try_propagation.mc`,
`move_borrow_escape.mc`). The reason was misreported: a refused trap projection
now says `incoherent_trap_projection`, which is its own thing -- not a
malformed node, but the two bodies disagreeing about where control leaves the
function. Underneath, both fixtures were one missing rule each in the same
place, the map from a value-producing expression to the representation
obligation its result carries.

`result?` over a `Result<*mut u8, E>` pulls a pointer out of the union with its
representation still unproven, exactly as a load of that type would, so the
source-shaped pass records a trapping check for it. `try` over a *nullable*
pointer is the deliberate exception -- the niche test is the check -- so
`executableTryUnwrapsResultPayload` distinguishes the two. `arr[i]` over an
array or slice of pointers is the same story: the bounds proof the index
carries says nothing about the value it produced, so `index` joins `load` and
`member` in that map. Both then needed their generated typedef names: a
`Result<*mut T, E>` and an array of pointers name typedefs the declaration
collector frames from `cSignatureSuffix`, and the body's own type-suffix
renderer had no pointer case at all, so it would have referenced a typedef
nothing declared. It has one now, over the pointee classes a bare spelling can
recover -- a primitive scalar, and a struct the body's aggregate table carries.

Closed: **`builtin_call` result not accepted** (`cast_class_strip.mc`,
`serial_counter_ops.mc`). Two independent gaps hid behind one reason.
`Ticks.elapsed_assume_within` was simply missing from
`executableBuiltinTypesValid` and from both renderers' admitted-kind lists; it
is the same modular delta `delta_mod` emits, read as a `Duration<T>`, and its
asserted bound is an operand both renderers now evaluate exactly once and
otherwise ignore (spec 5.5 makes it a proof obligation, not an optimizer
contract). `bitcast<*u8>(p)` needed two changes: the reinterpretation rule
widened from "same-width scalars" to also admit a thin pointer reinterpreted as
another thin pointer of the same nullability
(`mir_model.executableBitcastReinterprets`, which both backends now defer to),
and the *representation* obligation on the result. A bitcast to a single
pointer mints a non-null pointer out of an arbitrary bit pattern, exactly as
`raw.ptr` mints one out of an address, so it owns its guard on the call node
through `representation_span_id` rather than being wrapped in a second
`representation_check`. `mir_model.executableBuiltinOwnsRepresentationCheck`
is that rule, and it replaced the five open-coded `kind == .raw_ptr` tests in
the builder, the executable-body verifier and both backends.

Not on the list: removing traits, closures, generics, or the advanced ownership
forms. All were measured and none is a bounded cut. They stay frozen.

## Non-goals

- New language surface before the P0 items above are done.
- New backends. Make the C backend more mechanical instead.
- A full typed HIR or any second expression/control-flow representation.
- Incremental query databases, serialized semantic caches, separate compilation.
- Editor integration or persistent service work.
- Kernel deliverable features: filesystem, networking, storage, packages,
  supervision, update/recovery, board certification, fleet or support process.
- Validation workloads defining compiler semantics.

## Patch rules

Each patch changes one invariant family and carries one focused proof:

- `zig build architecture-boundary-test` for authority-boundary changes;
- a direct backend or MIR regression test for semantic changes;
- a CLI or tool test for surface removals;
- no unrelated kernel or validation-workload edits.

Before committing compiler-core work:

```text
git diff --check
zig build test
zig build m0
zig build c-test
zig build architecture-boundary-test
```

Run `zig build fast`, the LLVM oracle, fuzz, or QEMU gates only when the
touched slice changes that path.
