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
| A red sweep is a failure, not background noise. | `docs/backend-expected-failures.json` and the `backend-expected-failures-test` validator |
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
| P1 | Clear the remaining `docs/backend-expected-failures.json` entries or record a precise cause for each. | Each entry is a backend feature gap with a minimal reproduction. The deref-of-a-call-result family is the largest one left; see the note below for what it actually needs. |
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

### Note: what deref-of-a-call-result needs

`call(...).*` is the largest remaining `E_BACKEND_UNSUPPORTED` family in
`backend-expected-failures.json` (`address_classes.mc`,
`kernel_region_tokens.mc`, `lock_guards_data.mc`, and part of
`data_race_semantics.mc`). Measured, not guessed:

- Rooting the place at the call *value*, the way the index path does, is the
  wrong shape. A guarded deref spells its place more than once, so the call
  would be evaluated more than once. The place must be rooted at storage.
- Binding the call result to a synthetic local first is the right shape: the
  deref then has the ordinary `executableGuardedLocalScalarDerefPlace` form,
  which already carries its representation check, its trap edge and its
  renderer in both backends. That much works -- with it, the place stops being
  `<unsupported-place>`.
- What is left is the representation check. A single-pointer call result
  already gets a `representation_check` *expression* wrapping the call, and
  the deref's place then wants a second guard for the same pointer, while the
  legacy stream emits only one `representation_check` instruction to own the
  trap edge. The right answer is that the bound local is proven non-null by
  the check at the call, so the place needs no guard of its own -- which means
  teaching `root_nonnull_proven` a second way to be established.
  `mir_executable_body.verifyCompletePlace` currently admits it only via
  `executableLocalInitializedByOptionalPresentPayload`, so this is a new model
  predicate plus its verifier rule, not a widening of an existing one.

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
