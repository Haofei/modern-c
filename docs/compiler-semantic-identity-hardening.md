# Compiler semantic identity hardening

Status: **open**.
Review baseline: **`5df7d566a9986e3736b6bc92458eb89b73ee04cb`**.
Last updated: **2026-07-18**.

This document tracks correctness work found while reviewing how `mcc` represents
declarations, owners, generic instances, tuple types, qualified symbols, and
backend names. It is intentionally separate from
`compiler-production-readiness.md`.

The central defect class is:

> Several semantic identities are encoded as delimiter-joined strings, and the
> resulting display/linkage name is then reused as the semantic cache or
> authorization key.

This can merge distinct types or generic instances and can authorize access to
the wrong opaque owner. These are compiler-correctness issues, not performance
optimizations.

## Scope and evidence status

| Priority | Finding | Review status | Current evidence |
|---|---|---|---|
| P0 | Opaque-owner prefix collision can authorize private field access | **Fixed** | `FnDecl.associated_owner` and `StructDecl.semantic_identity` preserve exact ownership through mangling and specialization; `opaqueAccessAllowed` and the orphan check consume those identities. |
| P0 | Generic instance keys collide after delimiter joining | Inspected, high confidence | `src/monomorphize.zig` deduplicates function, struct, and union instances by the generated mangled name. |
| P0 | Tuple interning merges different structural types | Inspected, high confidence | `src/parser.zig` deduplicates tuples by an unframed string signature and encodes every function-pointer/closure type as `fn`. |
| P1 | `monomorphize` drops `Module.qualified_owners` | Confirmed code defect; main-pipeline impact bounded | The generic rewrite returns only `.decls`; the normal driver runs generic precheck before this loss, so the originally claimed main-path bypass is not yet demonstrated. |
| P1 | Qualified resolution depends on declaration/import order | Inspected, high confidence | Parser resolution uses symbols registered so far; loader emits the importer before imported files; monomorphization adds a conditional late call-only resolution path. |
| P2 pending measurement | Generic-call lookahead may approach quadratic time | Plausible, not yet measured | `lessStartsGenericCall` clones the lexer and scans forward for each candidate `<`. |
| P2 | Import expansion has no graph-wide resource budget | Inspected, high confidence | A visited set and per-file size limit exist; total files, bytes, depth, and expanded tokens are not bounded. |
| P2 design decision | One `pub` declaration changes the whole file's visibility mode | Confirmed intentional behavior | `ast.Decl.is_pub` documents the compatibility rule; this is a non-local API rule rather than an implementation accident. |

`zig build test` passes on the review baseline with Zig 0.16.0. That is the
existing baseline only; it does not cover the collision counterexamples below.

## Required identity model

Semantic identity and output naming must be separate concepts:

| Concept | Required representation | Must not be authoritative |
|---|---|---|
| Declaration identity | `DeclId` or an equivalent stable declaration handle | Source spelling or mangled symbol text |
| Associated owner | Exact owner declaration identity | Prefix before `__` |
| Type identity | Canonical `TypeId` or structural type key | Human-readable synthesized type name |
| Generic instance | Generic declaration identity plus ordered canonical arguments | `Generic__Arg1__Arg2` |
| Tuple identity | Ordered canonical element-type vector | Joined element display names |
| Qualified reference | Structured owner/member reference resolved against a complete symbol table | Parser-time text rewriting based on declarations seen so far |
| Linkage name | Deterministic encoding derived from a resolved semantic key | Cache, authorization, or type-interning key |
| Display name | Diagnostic-only rendering | Linkage or semantic identity |

Length-prefixed encoding or a stable hash may be used for linkage names, but a
hash hit must always be checked against the complete structural key. A linkage
encoding is an output of semantic resolution, never the semantic key itself.

## Implementation plan and TODO

### S0 - Lock the counterexamples

Goal: prove each inspected P0 behavior before changing implementation and make
the final fixes permanent.

- [x] Add `opaque_owner_prefix_collision` with a private read and private
  construction attempt; both must report the appropriate private-access
  diagnostic after the fix.
- [ ] Add `generic_instance_delimiter_collision` covering functions, structs,
  and tagged unions with `Pair<A__B, C>` versus `Pair<A, B__C>`.
- [ ] Add `tuple_component_name_collision` for `(A_B, C)` versus `(A, B_C)`.
- [ ] Add `tuple_function_signature_collision` for distinct function-pointer
  parameter/return signatures and closure types.
- [ ] Assert distinct semantic keys, distinct generated declarations, correct
  layout, and matching C/LLVM runtime behavior where the test is executable.
- [ ] Add a debug/internal-error guard that rejects one output linkage name
  being assigned to two unequal structural keys.

Exit condition: every P0 has a reproducer that fails on the reviewed design and
passes only when the semantic identities remain distinct.

### S1 - Close opaque-owner authorization

Status: **complete**.

Goal: private-field authorization uses exact associated-owner identity.

- [x] Add explicit associated-owner metadata to function declarations or the
  resolved symbol table.
- [x] Preserve that metadata through async lowering, generic precheck,
  monomorphization, private-name mangling, and backend handoff.
- [x] Replace `opaqueAccessAllowed` prefix comparison with exact owner identity.
- [x] Keep the cross-file orphan rule as an independent coherence check; do not
  use it as a substitute for exact owner identity.
- [x] Audit opaque construction, field read/write, declassification, trait impl,
  and generic opaque specialization paths for the same authorization rule.
- [x] Do not reject user-declared `__` names: exact identity removes the opaque
  authorization collision without imposing a source-language restriction.

Exit condition: no user-controlled spelling can make a function appear to be an
associated function of a different opaque declaration.

Implementation evidence: `src/ast.zig`, `src/parser.zig`,
`src/monomorphize.zig`, `src/sema_model.zig`, and `src/sema.zig`; collision
read/construction cases in `tests/spec/opaque_field.mc`; generic opaque access
and cross-file inherent/trait orphan fixtures; `zig build test`.

Verification note: the broader `c-test` gate currently stops on the pre-existing
`tests/c_emit/arithmetic_checked.mc` negative-integer unary failure. The same
failure reproduces in a clean detached `5df7d566` worktree, so it is not caused
by this owner-identity change.

### S2 - Make generic and tuple keys structural

Goal: specialization and type interning cannot merge unequal semantic inputs.

- [ ] Introduce `GenericInstanceKey { generic_decl, args }` with structural hash
  and equality.
- [ ] Canonicalize type arguments, typed constant values, mutability, address
  space, and every other semantics-affecting generic argument.
- [ ] Key function, struct, and union instance maps by `GenericInstanceKey`.
- [ ] Generate deterministic linkage names only after the structural key has
  selected or created an instance.
- [ ] Introduce `TupleKey { elements }` using canonical element type identities.
- [ ] Include complete function-pointer and closure signatures in tuple element
  identity, including parameters, return type, effects, and relevant qualifiers.
- [ ] Key tuple interning by `TupleKey`; keep synthesized names diagnostic/linkage
  artifacts only.
- [ ] Add collision checks for user declarations versus synthesized linkage
  names.

Exit condition: unequal generic argument vectors and unequal tuple element
vectors cannot resolve to the same semantic instance, even if their display or
candidate linkage names collide.

### S3 - Preserve pass metadata

Goal: every AST/HIR transformation declares and preserves module-level metadata.

- [ ] Immediately preserve `module.qualified_owners` in `monomorphize` output.
- [ ] Add `Module.withDecls` or an equivalent constructor so passes do not rebuild
  `Module` with implicit metadata defaults.
- [ ] Inventory every pass that returns `ast.Module` and state whether each
  metadata field is preserved, extended, or deliberately replaced.
- [ ] Add `monomorphize_preserves_qualified_owners` covering top-level values,
  parameters, and locals.
- [ ] Add a pass-pipeline test proving unrelated generic declarations cannot
  alter reserved-qualified-name diagnostics.

Exit condition: adding a no-op transformation or unrelated generic declaration
cannot remove or change module semantic metadata.

### S4 - Remove source-order-dependent qualified resolution

Goal: the same module graph resolves identically regardless of declaration order
or the presence of unrelated generics.

- [ ] Represent `Owner.member` as a structured qualified-reference AST/HIR node.
- [ ] Build the import/module graph before semantic binding.
- [ ] Collect module, impl, declaration, visibility, and export identities before
  resolving any qualified reference.
- [ ] Move qualified binding from parser-time `impl_methods` lookup to sema or a
  dedicated name-resolution pass.
- [ ] Resolve calls, constants, globals, types, and trait/inherent methods through
  the same complete symbol table.
- [ ] Add `imported_qualified_forward_reference`.
- [ ] Add `qualified_import_behavior_independent_of_generics`.
- [ ] Add declaration-order permutation tests for module and impl members.

Exit condition: declaration/import order and unrelated generic declarations do
not change whether a qualified program is accepted or which symbol it binds.

### S5 - Bound parser and import resources

Goal: adversarial source and dependency graphs have explicit, tested limits.

- [ ] Add an adversarial benchmark for repeated ambiguous `<` tokens and record
  runtime/allocation growth over increasing input sizes.
- [ ] If growth is superlinear at relevant sizes, tokenize once and memoize
  generic-call lookahead by token offset, or use bounded speculative parsing.
- [ ] Add configurable import limits for file count, cumulative input bytes,
  import depth, and expanded token/source size.
- [ ] Replace recursive import traversal with an explicit stack before claiming
  deep-graph robustness.
- [ ] Emit stable diagnostics identifying which resource budget was exceeded.
- [ ] Add exact-limit, one-over-limit, cycle, wide-DAG, and deep-chain tests.

Exit condition: parser complexity is measured and bounded, and import expansion
cannot consume unbounded memory or call-stack depth from a finite configured
build budget.

## Separate visibility decision

The current implicit-public/explicit-public compatibility switch is not part of
the P0 identity repair. Track it as an explicit language-design decision:

- [ ] Choose an edition, manifest option, or fixed language-wide visibility
  default instead of inferring the mode from whether any declaration is `pub`.
- [ ] Define migration diagnostics and source compatibility behavior.
- [ ] Add API-surface tests proving an unrelated declaration cannot silently
  change visibility of existing declarations under the selected modern mode.

## Execution order

1. Complete S0 together with the first P0 fix so the repository never lands a
   known red test state.
2. Complete S1 and S2 before extending opaque, generic, tuple, trait namespace,
   or module-name features.
3. Land the small S3 metadata fix independently after its regression test.
4. Design and implement S4 as a module/name-resolution change, not another
   parser mangling patch.
5. Measure and close S5; do not label the lookahead issue P1 without benchmark
   evidence.
6. Resolve the visibility decision independently from the correctness fixes.

## Completion rule

This document is complete only when S0-S5 meet their exit conditions and the
visibility item is either implemented or recorded as an explicit accepted
language limitation. A single collision fix, mangling assertion, or identifier
restriction does not close the structural identity work.
