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
| P0 | Collapse MIR to the single `ExecutableBody`: move the remaining consumers of the string `Instruction.detail` field off it (see the note below), **fold the instruction-scoped fact tables into typed nodes first**, then rewrite the legacy-stream checks in `mir_verify.zig` against the typed body, repoint `mir_dump.zig`, then delete `Function.blocks[].instructions`. | The core of the original design review. Two body representations cost every change twice. The fold now comes first: surveying all eleven verifier families showed none of them can move until the typed body represents the obligations the checking instructions carry -- see the note below. Depends on the golden-test conversion for affordability. |
| P0 | Replace the string-carrying `mir.ValueType` with type ids from the resolved table, then drop the parallel `typed_result_ty` mirrors. | Falls out once the table answers everything `ValueType.name()` is asked for. |
| P0 | Finish the sema handoff: intrinsic call results where sema and builder share one rule, `address_of` / `borrow` / `~`, alias collapse once the emitters take spellings from the table, and deletion of the builder's own type maps once unit tests build MIR through a checker. | Each slice: record in sema, read in the builder under the agree-assertion, delete the builder copy. |
| P1 | Give expressions a node identity that survives copying, or a per-instance span remap in monomorphization. | Unblocks monomorphizing after sema and stops instances failing closed in the resolved table. |
| P1 | Bring the C backend's `ast_bridge` / `type_bridge` imports to zero, one file at a time. | The exceptions table in `src/architecture_boundary_tests.zig` is the countdown. LLVM is already at zero. |
| P1 | Finish converting golden tests into fixtures: the MIR *dump* corpus is `tests/mir/` and the MIR *verification-fact* corpus is now `tests/mir_verify/` (see `test-architecture.md`); the emitted-C goldens in `src/lower_c_tests.zig` are still in-Zig golden strings, and need a grammar they do not have yet — see the note below. | The in-Zig golden strings are the largest consumer of the legacy instruction stream and the reason representation changes turn into mass test rewrites. |
| P1 | Clear the remaining `docs/backend-expected-failures.json` entries or record a precise cause for each. | Each entry is a backend feature gap with a minimal reproduction. Every `E_BACKEND_UNSUPPORTED` entry now carries a machine-checked `cause` (refusing phase, category, construct, function), so an entry can no longer outlive the gap it was written for. See the note below for what is left. |
| P2 | Split `src/mir_build.zig` by construct family and extract the shared AST-query surface still in `src/mir.zig`. | Readability. No behavior change. |
| P2 | Audit `tools/` for scripts no gate runs; mark spec sections by maturity inline. | Hygiene. |

### Note: which verifier families can leave the instruction stream

Surveyed all of them before converting any, because the first one attempted
(bounds) turned out to be blocked for a reason that generalizes. The rule is
`mir_model.instructionJoinsExecutableBody`, whose joinable kinds are exactly
`local`, `assign`, `assert_condition`, `defer_cleanup`, `control_transfer`,
`return_value` and `asm_effect`. **No instruction-scoped fact family keys on
any of them.** Every one keys on a checking or literal-conversion instruction
that the typed body does not represent as a node at all:

| Family | Instruction kind its fact joins on | Joins a typed node? |
|---|---|---|
| bounds | `cmp_bounds` | **Done.** Joins `index.bounds_obligation` / `range_slice.bounds_obligation` on the typed node; see below. |
| const_get | `index` with `detail == "const_get"` | No. Also still a `detail` string test. |
| integer literal | `integer_literal_conversion`, agreeing on `detail` (the literal spelling) | No. |
| float literal | `expr` with `detail == "float"` | No. |
| representation | `representation_check` / `representation_use`, agreeing on `kind` and `detail` | No. |
| target-type | `target_type`, agreeing on `detail` (the `TargetTypeKind` tag) | No. |
| call-target | `call_target` | No. |
| range | `unchecked_assume` inside a `no_overflow` contract region | No. |
| access facts | `index` / `expr` | No. |
| bind-thunk | `call_target` and `target_type`; its closure-local half really is `.local`, a joinable kind | No, for a different reason: `BindThunkFact` names the closure local by `closure_value_id`, and `ExecutableLocalIdentity` carries no `ValueId`. There is no recorded correspondence to join on, and joining by spelling would be weaker than what is there. |
| ownership events | none -- `verifyFunctionOwnershipEvents` does not walk the stream | Already off it. |
| trap projection | none in `mir_verify` -- the typed body owns `trap_edges`, and a refusal is reported as `incoherent_trap_projection` from the executable-body side | Already off it. |

So this step of the P0 is not a sequence of eleven independent rewrites. It is
blocked behind one prior change: the typed body needs nodes (or recorded
identities) for the obligations the checking instructions currently carry, and
the fact tables need to name those instead of `cmp_bounds`, `target_type`,
`call_target`, `representation_check` and friends. Folding the
instruction-scoped fact tables into typed nodes -- the *next* P0 bullet -- is
what unblocks this one, not the other way round. The two ordered bullets
should be swapped.

### Note: how the bounds family left the instruction stream

The blocker was real and is closed. `cmp_bounds` is still not a joinable
instruction kind and still has no typed node -- but it does not need one. The
obligation it carries is now *recorded on the node that owns it*:
`ExecutableExpression.Operation.index.bounds_obligation`,
`range_slice.bounds_obligation`, and the same field on an `index` projection
of an `ExecutablePlace`. The builder sets it where it already appends the
`BoundsFact`, so both name one identity, and
`mir_model.executableBoundsObligationCount` is where the count is taken.

That answers the two measurements the earlier attempt produced:

- The span problem disappears rather than being fixed. Nothing keys on a span
  any more: an index fact and a range-slice fact name obligation identities,
  not the operand span or the whole-access span, so the two spellings no
  longer have to be told apart. `BoundsFact.typed_span_id` stays, still keyed
  the old way, but only for the resolved-access join and for diagnostics.
- Two checks at one span stay distinct because each claims its own typed node.
  `recordExecutableBoundsObligation` claims the first *unclaimed* checked
  obligation at that access span, so a second check at the same span takes the
  second node.

The typed walk is also strictly stronger in the way the earlier note
predicted: it sees `checked`, so an elided bound is not mistaken for a checked
one, which the `detail` string never distinguished.

What still reads the instruction stream, and why: a body the typed form does
not represent -- an incomplete body (the builder stopped partway, so there is
no typed node to carry the obligation), an `extern` declaration, and a global
initializer's pseudo-callable, which is an expression compiled with a function
body's checks rather than a statement sequence. `boundsObligationsRepresented`
in `mir_verify.zig` is that predicate, and those three shapes are the only
callers of `countMatchingBoundsInstructions` left.

One direction of the invariant is deliberately weaker than "exactly one":
an obligation is named by *at most* one fact, not exactly one. The executable
body already owns complete trap-edge validation, so a missing legacy fact does
not block canonical lowering -- `lower-c canonical executable body does not
depend on legacy bounds facts` is that contract -- and requiring a fact per
obligation would make the legacy table load-bearing again, which is the
opposite of the goal.

### Note: `index` over a slice of pointers is not a `supportsType` gap

The sweep manifest and the entry below both said the C backend's `supportsType`
admission declines a slice whose elements are pointers. Measured, that is
wrong, and it sent the fix at the wrong file:

```text
fn pass_slice_of_pointers(items: []*mut u32) -> usize { return items.len; }   // emits fine
fn read_slice_of_pointers(items: []*mut u32, i: usize) -> *mut u32 { return items[i]; }
// E_BACKEND_UNSUPPORTED: ... expression `index` ... (declined by capability)
```

`supportsType` admits `[]*mut u32` already: `pointeeSupported` inverts the
`*mut u32` element spelling through `pointerShapeFromSpelling` and accepts it.
The refusal is in `mir_executable_c.indexSupported`, in the `.slice` arm:

```zig
if (scalarMemoryInfo(expression.result_ty) == null and
    raceAggregateLoadShape(body, expression) == null) return false;
```

A slice read preserves the race-tolerant access contract, so the element must
either be a scalar with a `mc_race_load_<suffix>` helper or a declared struct
rebuilt field by field. `scalarMemoryInfo` has no pointer case -- its `suffix`
switch covers `bool`, `integer`, `float`, `domain_integer` and `address` -- so
a pointer element is neither, and the read fails closed.

A thin pointer *is* a scalar of `usize` width, so the fix is a pointer arm in
`scalarMemoryInfo` whose `helper_suffix` is `usize` and whose `c_type` is the
rendered pointer type rather than a `primitiveType` lookup, plus the matching
cast in the slice-read renderer and its LLVM counterpart. That is a renderer
change with an emitted-C byte-identity obligation across all four corpora, not
the one-line admission widening the entry described.

### Note: why the emitted-C goldens are not a fixture corpus yet

Measured over all 425 tests in `src/lower_c_tests.zig`, not estimated. The MIR
verification-fact corpus converted cleanly because every one of those tests had
the same shape: one program, one dump, a list of substrings. The emitted-C
tests do not:

| Count | Shape | Why the `tests/mir_verify/` grammar cannot hold it |
|---|---|---|
| 220 | assert through `cFunctionBody(output, "<signature prefix>")` | The assertion is scoped to **one function's emitted body**. A `+ "needle"` over the whole file is a strictly weaker claim -- it would pass when the needle lands in a different function -- so converting these as-is would weaken 220 tests. |
| 160 | build the MIR inline, 17 of them through `…WithoutRangeFacts` / `…WithRetargetedRangeFacts` / `…WithoutPointerProvenanceFactsForSubject` / `…WithoutAggregateReturnPointerFact` | The fixture is a *program*; these lower a program whose fact tables were edited by hand afterwards, to prove the renderer fails closed when a fact is missing. No MC source produces that module. |
| 37 | pass a `diagnostics.Reporter` and assert on what lowering reported | Needs the diagnostics channel in the matched text, as `tests/mir_verify/` does -- cheap, but only after the two above are settled. |
| 4 | already the uniform shape | Not worth a corpus on their own. |

`tests/c_emit/` was checked first and has no expected-output mechanism to
reuse: `check-generated-c.sh` asserts only that a fixture emits and that clang
accepts it, never what the C says.

So the blocker is a *grammar* gap, not a volume problem. The corpus needs at
least a scope rule (`in "<signature prefix>": + "needle"`, matching against
that function's body the way `cFunctionBody` does) and a profile/checks
selector line, before any of the 220 can move without losing what they prove.
Adding those to `src/fixture_expect.zig` is the next step; the 4 uniform tests
are not a reason to start the corpus before it can hold the other 421.

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
| pointers through arrays, slices and aliases | `data_race_semantics.mc` | **Blocked, and it is not one gap.** Deleting each failing function and re-emitting enumerates 60 of them. 21 are an `index` expression over a slice whose elements are pointers: mir-build accepts those now, and the C backend declines the *read* -- in `indexSupported`'s race-tolerant slice arm, not in `supportsType`, which admits the slice type fine; see the note above for the measurement and the actual fix site. 5 more are an array of pointers reached through a pointer to it, 3 an aggregate pointer alias whose executable shape is incoherent, 1 an array-element assignment. The remaining families are a `*T as [*]T` cast kind that neither `ExecutableCastKind.classify` nor either renderer has, an indirect call through a pointer alias copied from a parameter (declined by codegen admission as `expression `local``), and a trapping store of a pointer into an aggregate field. Closed on the way past: `(&E).*`, and the slice-element rule's mir-build half. |

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
