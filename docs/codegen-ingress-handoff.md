# Codegen ingress handoff

Measured 2026-09-01 on `master`.

## Current state

- The strict corpus is 160/160 canonical for both C and LLVM.
- Specialized MIR plans are fully retired: zero admissions, zero plan
  definitions, and no `mir_statement_plan.zig` exception.
- The broad census admits 1541/1825 C functions and 1583/1879 LLVM functions.
  The remaining 284 C and 296 LLVM bodies use the explicit AST fallback.
- `CheckedProgram` and the per-file module graph goals are complete. The active
  review goal is deletion of `FunctionBodyFallbackArtifact.syntax` and both
backend fallback branches.

Canonical `try_unwrap` consumes the nullable-value and Result layout tables as
well as nullable-pointer shape. Canonical `try_propagate` owns the distinct
same-type Result early-return contract: verifier admission requires the exact
enclosing Result type, C returns the already evaluated operand on error, and
LLVM emits the corresponding conditional return before extracting the success
payload. Assignment, expression-statement, nested-call, and multiple-`?`
evaluation order now use this operation. Checked `mmio.map<T>(PAddr)?` is also
one explicit pointer-niche MIR operation: lexical unsafe admission, exact
`Unwrap` edge, address-to-pointer conversion, and null trapping are verified
once and rendered mechanically by both backends. These slices retired twenty
broad-corpus fallbacks per backend in total and reduced `unsupported_try` from
26 to 4. Mapped `#[error_from]`, mapped `? else`, and cleanup-edge integration
remain fail-closed. The census runner refreshes
the default installed compiler before measuring, closing a stale-binary hole.

The latest cutover added canonical `for_each` and `for_step` terminators. MIR
owns iterable evaluation, synthetic iterable/index locals, element binding,
loop control, and representation traps. Both renderers mechanically consume the
same verified terminators. The old foreach return/update recognizers, emitters,
tests, census variants, and shared statement-plan module were deleted.

Canonical memory facts now distinguish ordinary aggregate storage from packed
bits and unions. Declared structs, value optionals, and fixed arrays are copied
through recursively verified scalar leaves for mutable-global and guarded
pointer accesses; packed/union values retain one plain storage operation so
their representation is not decomposed incorrectly. This closes eight C and
nine LLVM broad-corpus fallbacks while preserving the prior race-unordered
contract. C fixed-array leaves use the canonical `.elems[index]` layout and the
generated row-replacement fixture compile-checks with `clang -Werror`.

Checked unary/binary trap ownership is resolved after the canonical expression
table is complete. This removes the construction-order dependency between the
source-shaped legacy fact walk and evaluation-ordered `ExprId`s without
weakening the bijective trap projection check. The complete monomorphization
fixture is now 8/8 canonical in both backends; the broad `trap_projection`
reason fell from 60 to 55.

Scalar/enum switch admission now keeps source wildcard arms separate from
representation/bounds trap successors created while evaluating the subject.
Those traps remain explicit executable edges; they no longer consume the
switch default slot. Canonical `declassify` now carries its payload type and
unsafe authorization and lowers as the representation-transparent identity it
is. Eight broad-corpus entries per backend moved to canonical emission across
the two slices, leaving 16 C / 18 LLVM `general_switch` bodies in the structural
variant/generated-control-flow tail.

Fixed-array `const_get` is also syntax-free at codegen ingress. Its executable
builtin owns both the array receiver and checked compile-time index; the MIR
verifier rejects an out-of-range mutation, while C emits `.elems[index]` and
LLVM emits `extractvalue`. One additional body per backend is canonical.

Reflection comparisons are syntax-free as well. MIR uses the checked `usize`
result of `size_of`, `alignof`, and `field_offset` to target-type the opposite
unsuffixed literal, so neither renderer sees a residual `comptime_int`.
`fuzz_c_union.size_check` moved to canonical emission in both backends.

Packed-bits field stores are no longer reconstructed by the legacy body
emitter. Executable MIR carries a whole-aggregate place plus the exact boolean
field index and scalar-storage access class. Both renderers perform the same
read-modify-write, including race-unordered mutable-global access. The local
and global updates in `packed_overlay.mc` moved to canonical emission in both
backends.

Ordinary stores now derive their access class from the resolved place root,
not from a source spelling that may also name a global. The
`local_shadows_global_assignment` regression is canonical in both backends.
The shared memory model also records 16-byte alignment for direct local
`u128`/`i128` values while leaving unsupported shared C access fail-closed;
`numeric_literal_boundaries.wide_assignment` is canonical in both backends.

## Next work

Run the broad census and work from the largest producer-owned reason:

```sh
OUTDIR=zig-out/fallback-census-broad JOBS=8 \
  bash tools/toolchain/fallback-census.sh
```

Current leading blockers are `trap_projection`, `try`, `unsupported_member`,
signature/place invariants, `general_switch`, string and aggregate
construction, and unsupported calls. Renderer rejection is a smaller
secondary group.

Opaque and precise inline assembly are syntax-free executable statements now.
MIR owns decoded template/clobber bytes, precise input `ExprId`s, output
`LocalId`s, and checked operand types; stub mode is an explicit renderer option.
Both backends consume the same operation and the precise-asm fixture is 4/4
canonical. This retires nineteen broad-corpus fallbacks per backend and reduces
`unsupported_statement` from 27 bodies to one.

The valid naked-function tail is canonical as well. A deliberately narrow
verified shape admits exactly one opaque asm statement followed by
`unreachable`; dedicated C and LLVM renderers emit no ordinary CFG prologue.
The host-ISA runtime proof stores 42 through the ABI argument register in both
backends. Five more broad-corpus fallbacks per backend moved to canonical
emission, and the backend-local AST naked-body emitters plus their syntax bridge
were deleted. The broad census has no `canonical=ready` fallback remaining.

The remaining `trap_projection` group is 26 bodies per backend. Representation
edges are now resolved after canonical statement construction, which removes
the earlier source-walk ordering dependency for local pointer stores. The
resolver remains bijective and syntax-free: it accepts exactly one typed
expression or statement owner, while dynamic-trait receiver calls and nullable
dynamic values remain explicit structural blockers rather than being guessed
from a span.

Nested IEEE float arithmetic is no longer part of that group. Float
classification now follows grouped, unary, binary, and cast expression
structure, so legacy MIR no longer invents an `IntegerOverflow` edge for an
expression such as `(a[0] + a[1]) + (a[2] + a[3])`.

Field projection through a typed local pointer generation is canonical too.
The producer distinguishes pointer-valued local storage from a direct aggregate
place, attaches the exact representation edge to the projected pointee, and
both renderers use that same place. Eleven entries leave the trap-projection
group; four broad-corpus functions per backend become fully canonical, while
the remainder expose their next structural blocker instead of guessing.

Fixed-array places rooted behind a checked pointer parameter carry one
representation obligation plus their checked-index obligations. The producer,
verifier, C renderer, and LLVM renderer share that accounting; LLVM emits the
pointer guard for either an expression or statement owner. This removes sixteen
more entries from `trap_projection` and admits fourteen broad-corpus functions
per backend, including pool/ring/slotmap/const-generic families. Two bodies now
fail closed on the next structural reason rather than on trap ownership.

Declared-struct slice element reads with scalar fields are no longer part of
that renderer group. Canonical C and LLVM rebuild the value from unordered
field loads, preserving the prior race-tolerant behavior.

Executable `LocalId` values are declaration-generation identities. Reusing a
name in a later disjoint lexical scope no longer aliases the earlier LLVM
alloca; 16 LLVM-only fallback bodies moved to canonical emission.

Function MIR also owns callable return signatures. LLVM applies that fact to
the declaration, call result, local slot, and aggregate field representation,
which retires the final four bodies that were renderer-ready but rejected by
the integration ingress. The remaining LLVM fallback set has no
`canonical=ready` tail.

Canonical MIR now owns byte-view construction and equality. Both renderers use
the addressed `Place.ty` for object size instead of reconstructing it from a
lossy pointer child spelling; fixed-array byte views therefore preserve their
length and compile in both outputs. The direct byte-view fixture is 3/3
canonical in C and LLVM, and the nine LLVM bodies exposed by this producer
cutover no longer fall back. Later lexical generations with a repeated local
name are also distinct in canonical C output.

The producer no longer carries a one-off slice-store completion recognizer.
The executable-body verifier promotes every valid body without an explicit
incomplete reason; compile-time statements are explicitly classified and stay
outside runtime MIR. Parameter-field addresses now own their representation
trap at construction time and are rendered mechanically by both backends.
Fixed-array indexing is now admitted by typed base identity rather than by its
source consumer shape. The direct-return-only helpers were deleted; parameters,
locals, nested projections, and direct-call array values share one path. The
`arrays_slices.mc` root is 29/29 canonical in both backends. `uninit` is also
modeled as a local storage policy, so C no longer claims it is an ordinary
renderable value and LLVM no longer emits a fake initializer store.

Fixed-array places may now begin at one checked dereference of a typed pointer
parameter. The shared place predicate reports that provenance explicitly, so
the producer, verifier and both renderers preserve both the non-null
representation edge and every bounds edge. Immutable local pointer copies of a
parameter use the same field-address path. Consequently all three address
helpers in `pointer_field_addr.mc` are canonical in both backends; only its
larger aggregate-construction caller still falls back.

Each slice must:

1. add one typed executable-MIR operation or complete an existing one;
2. verify identity, type, effects, traps, and CFG ownership before codegen;
3. make C and LLVM consume the same operation;
4. pass focused tests, both backend shards, and the strict census;
5. delete superseded fallback code in the same change.

Do not add another specialized plan or backend AST recognizer. Missing facts
remain an explicit fallback until canonical MIR owns them.

## Completion condition

P0 completes only when the broad fallback reaches zero and these are deleted:

- `FunctionBodyFallbackArtifact.syntax: ast.Block`;
- `function_body_fallbacks` from codegen artifacts;
- both backend calls to `findLegacyFunctionBody`;
- fallback-only inventory exceptions.

Tests or a high admission percentage alone do not complete the goal.
