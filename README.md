# MC / modern-c

MC is a spec-first compiler prototype for a kernel-profile, Zig-like systems language.
The current repository implements the MC-C0 baseline and a growing MC-C1 kernel
profile slice, but it is not a production-ready C replacement.

The design goal is to make low-level machine contracts explicit: ordinary
language errors should become compile errors, traps, or `Result` values, rather
than invisible optimizer assumptions. MC is not a memory-safe language.

## Current Status

Implemented today:

- Lexer, parser, semantic checker, fact/inspection output, and checked C output
  for the implemented conformance slice.
- Typed MIR basic-block CFG lowering with explicit language-trap edges,
  contract-region markers, and a MIR verifier used by `emit-c`.
- A spec-driven fixture suite under `tests/spec`.
- Prototype commands through the `mcc` executable.
- All five arithmetic domains, including ordering/division legality for
  `wrap`/`sat`/`serial`/`counter` (sections 5.2-5.5).
- Serial (`before`/`after`/`distance`/`compare`) and counter (`delta_mod`/
  `elapsed_assume_within`/`elapsed_bounded`) operations, with the supporting
  library types `Order`/`Duration`/`AmbiguousSerialOrder`/
  `AmbiguousCounterInterval` (sections 5.4, 5.5).
- The scalar/domain conversions `from`/`try_from`/`trap_from`/`wrap_from`/
  `sat_from`/`from_mod` plus `wrap.residue()` (sections 3, 5), all of which
  lower to C: bound-checked `trap_from`, clamping `sat_from`, Result-returning
  `try_from`, and the cast-style conversions.
- The library result types `Order`/`Duration`/`AmbiguousSerialOrder`/
  `AmbiguousCounterInterval`/`ConversionError`, with C representations, so that
  `serial.compare` and `counter.elapsed_bounded` lower to C as well.
- Floating-point scalar types `f32`/`f64` end-to-end: literals, non-trapping
  IEEE arithmetic, ordering, no implicit conversion, and C lowering to
  `float`/`double` (sections 3, 8.3).
- Integer `reduce.sum_checked<T>` lowers to C with checked accumulation, while
  floating `reduce.sum_left<T>` keeps source-order folding and
  `reduce.sum_fast<T>` emits an explicit reassociation/vectorization opt-in for
  Clang with a strict fallback loop.
- A growing standard library used by the QEMU/kernel demos, including
  `std/sync`, `std/ring`, `std/dma`, `std/endian`, `std/time`, `std/barrier`,
  `std/virtio`, `std/virtqueue`, hosted I/O, float math intrinsics, and fixed
  `f32x4` lane helpers in `std/vec`.
- Local package manifests via `mcc-pkg.sh`: `info`, recursive `deps` with
  transitive version checks, and `build` through the `mcc-cc` driver.

The type-checking surface covered by the core language fixtures is implemented,
and the valid declarations in the current spec fixture suite lower to
clang-checked C without `unsupported` emission placeholders. The non-LLVM finish
line is the C backend plus verifier/tooling contract in
`docs/spec/MC_0.6.1_Final_Design.md`. LLVM now has a MIR-backed textual IR path
that runs after the same semantic and MIR verification gates as C emission. The
valid declarations in the current spec fixture suite emit assemblable LLVM IR
through `zig build llvm-sweep`, and that gate also rejects hidden optimizer
assumption tokens (`nuw`/`nsw`/`nonnull`/`noalias`/`noundef`/`poison`/`inbounds`/`undef`
and hidden fast-math flags, with `reassoc` allowed only for explicit
`reduce.sum_fast` floating reductions)
across the swept IR. `zig build llvm-c-sweep` applies the same IR checks to all 109
current `tests/c_emit` fixtures; `zig build llvm-spec-obj-sweep` compiles the
same valid spec-corpus surface to LLVM object files with `llc`, and `zig build
llvm-c-obj-sweep` compiles the C-emission fixture set to LLVM object files with
`llc`. Scalar/pointer globals are covered for
literal and address-of-global initializers. Local fixed arrays of scalar
elements support literals, checked indexing, element assignment, and
element-address taking. Plain local structs with scalar fields support literals,
field load/store, and field-address taking. Scalar fixed-array and scalar-struct
globals support static literals plus element/field access. Scalar aggregate
function returns, parameters, and direct calls are supported for fixed arrays and
plain structs. Nested fixed-array/struct element and field access works for the
covered aggregate subset, including materialized aggregate rvalues from direct
calls when indexing, field access, slicing, or array iteration needs an address.
Core slice values lower as `{ ptr, len }` values with checked
indexing, const fixed-array access, `.len`, direct returns/params, and range slicing from arrays or slices.
Scalar `switch` lowering covers bool and integer subjects, including
multi-pattern literal arms and wildcard defaults. Core loop CFG covers `while`
and `for` over arrays/slices, including array-valued call results, with
loop-local bindings plus `break`/`continue`.
Scalar expression lowering covers integer casts, unsigned bitwise operations,
bitwise not, short-circuit boolean `&&`/`||`, and checked unsigned shifts with
invalid-count and shifted-out-bit traps, plus verified integer/enum coercions at
target-typed expression sites and fixed-layout scalar bitcasts. Checked integer
arithmetic includes signed unary negation with an `INT_MIN` overflow trap. Character literal lowering covers
target-typed `u8` returns, locals, call arguments, comparisons, escapes, and
checked `u8` arithmetic. String literal lowering covers target-typed `u8`
pointers via private LLVM byte constants with MC escape decoding. Floating-point scalar lowering covers `f32`/`f64`
literals, globals, calls, locals, arithmetic, comparison, and unary negation.
Byte-view lowering covers `mem.as_bytes(&value)` as a const `u8` slice and
`mem.bytes_equal` as a length check plus byte loop.
Domain scalar lowering covers `wrap<T>`/`sat<T>`/`serial<T>`/`counter<T>`/
`Duration<T>` payload representation, `wrap` modular add/sub/mul/bitwise/shift
and unary negation, unsigned `sat` add/sub/mul, serial
`before`/`after`/`distance`/`compare`, counter
`delta_mod`/`elapsed_assume_within`/`elapsed_bounded`, scalar conversion calls
`from`/`try_from`/`trap_from`/`sat_from`/`wrap_from`/`from_mod`,
`wrap.residue()`, and `wrapping.add`/`sub`/`mul`. Reduction lowering covers
integer `reduce.sum_checked<T>` with an `i128` accumulator and
`Result<T, Overflow>` result, plus floating `reduce.sum_left<T>` and
`reduce.sum_fast<T>`.
Statement workflow covers expression statements, void calls, `assert`,
nested blocks, unsafe blocks, transparent unsafe-contract blocks, `trap(...)`,
`unreachable`, `never` functions, and `never` coercion in return position for
the covered trap kinds. Unsafe-contract arithmetic lowering covers
`unchecked.add`/`sub`/`mul` as plain arithmetic after semantic contract
verification. Unsafe machine-operation lowering covers opaque address
classes, `phys(...)`, volatile `raw.load`/`raw.store`, `raw.ptr`, `cpu.pause()`,
opaque inline asm, unsafe-block raw stores, and raw-many pointer `.offset(...)`.
Alias and enum lowering covers scalar, array,
raw-pointer, closed-enum, and open-enum representation cases, including enum
globals, calls, returns, arrays, struct fields, `.raw()`, integer casts to open
enums, enum switches over direct calls, and void switch expression arms.
Nullable pointer lowering covers nullable pointer ABI,
`null`, non-null-to-nullable widening, postfix `?` null-unwrapping traps,
nullable `if let`, and simple nullable switches. Result lowering covers
aggregate ABI, `ok(...)`/`err(...)` constructors, `Result<void, E>` marker
payloads, postfix `?` trap unwrap, `if let ok/err` narrowing, and two-arm
Result switches including wildcard fallback arms. Result `?` propagation now
early-returns `err(...)` from `Result`-returning functions, while non-Result
return contexts retain trap unwrap semantics. Atomic lowering covers
`atomic<T>` scalar storage, `atomic.init`, `load`, `store`, `fetch_add`, and
`fetch_sub` with LLVM atomic memory orderings for local and global atomics.
Linear `move` resource types lower through the ordinary struct ABI after sema's
move/liveness verifier; by-value uses are normal value transfers and `drop(x)`
is erased after evaluating its argument.
Tagged-union lowering covers aligned tag-plus-payload ABI, constructors,
direct calls, returns, locals, struct fields, and pattern switches including
payload bindings and wildcard fallback arms.
Function-pointer lowering covers `fn(...) -> T` values as opaque pointers,
static function-name initializers, copied function-pointer aggregate globals,
indirect calls through parameters, locals, globals, arrays, and struct fields,
plus function-pointer returns.
Aggregate assignment lowering covers `uninit` aggregate storage, whole
array/struct literal assignment, aggregate copies from nested elements/fields,
and nested aggregate stores through globals, arrays, and struct fields. Inferred
local lowering covers initializer-derived scalar, slice, array, and struct
storage for the covered backend subset. Aggregate layout coverage includes
structs containing arrays/slices, slices of structs/arrays, and nested array
indexing. Static aggregate global coverage includes nested array/struct
literals plus const-folded `sizeof`/`alignof`/`field_offset` array lengths.
LLVM debug metadata now includes `source_filename`, a compile unit/file record,
function `DISubprogram` records, and line/column locations on local
initialization stores, direct assignment stores, aggregate literal/member field
stores, ordinary pointer/global/index loads and stores, `MaybeUninit` writes,
volatile raw/MMIO stores, atomic stores, precise asm output stores, volatile
raw/MMIO loads, atomic loads and read-modify-write operations, fences,
returns, call instructions, loop/break/continue branch terminators,
switch/if-let dispatches, nullable/Result/tagged-union and for-loop binding
stores, aggregate rvalue and tagged-union constructor materialization stores,
tagged-union switch subject stores and tag loads, and trap-path plus `?`
propagation, short-circuit boolean, and if-let join branch terminators for the
covered backend subset, plus
branch terminators in compiler-expanded `mem.bytes_equal` and `reduce.*` helper
loops.
The LLVM toolchain driver `tools/toolchain/mcc-llvm-cc.sh` compiles textual IR
to linkable object files through `llc`, and
`zig build llvm-obj-test` validates representative scalar, statement-workflow,
and aggregate objects. `zig build llvm-pkg-test` builds the manifest-driven demo
package through the LLVM driver, links it, and runs it.

Prototype or incomplete:

- Production-grade typed MIR/CFG and verifier hardening beyond the current
  checked C-emission path.
- Package registry, releases/publishing, and production toolchain support.
- Full comptime execution (§22): the evaluator handles scalar/char/unit/enum-tag
  folding, scalar and aggregate const globals and typed static global
  initializers, reflected named const globals, const-fn calls with
  loops/for/switch/asserts, top-level comptime block assignments/loops/switches,
  aggregate literals and nested mutable aggregate updates, comptime/type feedback, and
  C-ABI layout reflection for size/alignment/offsets/repr, including slices and
  tagged unions, plus `field_type` in type-argument position for fields and
  tagged-union payload cases; broader arbitrary
  interpreter coverage is still incomplete.
- Production MIR optimizer use: MIR records and consumes scoped no-overflow
  range facts for covered unchecked arithmetic; broader range algebra and
  optimization passes are still incomplete.
- Full DMA/cache-coherence model (§18): address-class rules, typed `DmaBuf`,
  cache clean/invalidate, and the linear `move` checker are implemented; a
  complete hardware coherence simulation is not.
- Debug mapping: `emit-c` writes `#line` source hints for generated C, and
  `emit-map` emits an initial `.mcmap`-style source/generated-C map, including
  global initializer, statement/expression, and deferred cleanup spans.
  `emit-llvm` now emits initial LLVM debug metadata for source files,
  functions, calls, returns, loads/stores including ordinary pointer/global/
  index access, aggregate literal/member field, `MaybeUninit`, volatile
  raw/MMIO, and atomics, loop/break/continue branch terminators, precise asm
  output stores, atomic RMWs, fences, switch/if-let dispatches,
  nullable/Result/tagged-union and for-loop binding stores, aggregate rvalue and
  tagged-union constructor materialization stores, tagged-union switch subject
  stores and tag loads, and trap-path plus `?` propagation and short-circuit
  boolean and if-let join branch terminators, plus
  compiler-expanded `mem.bytes_equal` and `reduce.*` helper loop branch
  terminators. DWARF-quality native debug mapping with richer
  statement/expression coverage is still pending.

Deferred:

- LLVM backend production hardening (see Appendix M of
  `docs/spec/MC_0.6.1_Final_Design.md`). The current spec sweep is clear for
  valid declarations and rejects hidden optimizer assumption tokens in swept IR;
  the same valid spec-corpus surface compiles to LLVM object files with `llc`;
  all current C-emission fixtures emit assemblable LLVM IR under the same
  assumption-token gate, and all current C-emission fixtures compile to LLVM
  object files with `llc`. The LLVM toolchain has link-and-run smoke coverage,
  including a linear `move` handle ABI roundtrip, imported generic `std/stack`,
  `std/sync` guard, fn-pointer runtime checks, import/std merge,
  monomorphization and generic-struct runtime checks, reflection object
  lowering, manifest package builds, and multi-object
  `std/{core,bits,math,ascii,fmt,addr}` runtime checks, plus LLVM object
  coverage for the framebuffer/gpio/irq/spi/timer/uart hardware demos and the
  hosted elementwise demo, and LLVM link/run coverage for the hosted
  elementwise stdin/stdout round trip.
  Remaining work is additional runtime/toolchain coverage, deeper optimizer
  proof work, and fuller native debug mapping.

## Requirements

- Zig `0.16.0`
- `clang` for `zig build c-test`
- `llvm-as` for `zig build llvm-test`
- `llc` for LLVM object-output gates such as `zig build llvm-obj-test`,
  `zig build llvm-spec-obj-sweep`, and `zig build llvm-c-obj-sweep`

The generated C targets **Clang/GCC only**: the runtime helpers use compiler
builtins (`__builtin_trap`, `__builtin_*_overflow`, `__atomic_*`) and a few
extensions (`__int128`, statement attributes). It is not portable C11; compiling
the output with another toolchain is unsupported.

## Build And Test

```sh
zig build m0
zig build test
zig build c-test
zig build sweep
zig build llvm-test
zig build llvm-obj-test
zig build llvm-sweep
zig build llvm-spec-obj-sweep
zig build llvm-c-sweep
zig build llvm-c-obj-sweep
zig build llvm-cc-test
zig build llvm-move-test
zig build llvm-runtime-test
zig build llvm-toolchain-test
zig build llvm-std-test
zig build llvm-pkg-test
zig build llvm-demo-test
zig build llvm-hosted-demo-test
```

Run the compiler prototype:

```sh
zig build run -- check tests/spec/arithmetic_checked.mc
zig build run -- verify tests/spec/no_lang_trap.mc
zig build run -- lower-mir tests/spec/no_lang_trap.mc
zig build run -- lower-hir tests/spec/try_propagation.mc
zig build run -- verify-hir tests/spec/no_lang_trap.mc
zig build run -- facts tests/spec/no_lang_trap.mc
zig build run -- lower-c tests/spec/mmio_ordering.mc
zig build run -- emit-c tests/c_emit/smoke.mc
zig build run -- emit-map tests/c_emit/smoke.mc
```

Available commands:

- `lex <file.mc>`
- `check <file.mc>`
- `run-trap <file.mc>`
- `facts <file.mc>`
- `lower-hir <file.mc>`
- `verify-hir <file.mc>`
- `lower-mir <file.mc>`
- `verify <file.mc>`
- `lower-ir <file.mc>`
- `lower-c <file.mc>`
- `emit-c <file.mc> [--profile=kernel|hosted]`
- `emit-map <file.mc> [--profile=kernel|hosted]`
- `emit-llvm <file.mc>`

`emit-c` defaults to the **kernel / freestanding** profile (no ambient I/O).
`--profile=hosted` selects an opt-in **hosted** profile that links a host C
runtime (libc + `-lm`); it stamps a `/* mc-profile: hosted */` marker and is the
target for programs that use `std/hosted_io` (explicit, fallible byte I/O —
`io_open`/`io_read`/`io_write`/`io_close`/`io_printf_f64`, each returning a
`Result`) and `std/mathf` (the libm float intrinsics `sqrt`/`sin`/`cos`/
`exp2`/`log2`/`exp`/`log`/`tanh` for `f32`/`f64`). See `demo/hosted/` for the
stdin-to-stdout float round-trip; run it with `zig build hosted-test`.
`emit-map` uses the same verified C-emission path and writes a line-oriented
`.mcmap` artifact to stdout, including statement, deferred cleanup, and selected
expression spans, plus global initializer spans, with typed-AST and MIR labels.
`emit-llvm` uses the same semantic/MIR verification gate and emits textual LLVM
IR for the covered backend surface. `zig build llvm-test`, `zig build
llvm-sweep`, and `zig build llvm-c-sweep` check LLVM IR with `llvm-as`; the two
sweep gates also reject hidden optimizer assumption tokens
(`nuw`/`nsw`/`nonnull`/`noalias`/`noundef`/`poison`/`inbounds`/`undef` and
hidden fast-math flags, with `reassoc` allowed only for explicit
`reduce.sum_fast` floating reductions).
`tools/toolchain/mcc-llvm-cc.sh` compiles an MC module through `emit-llvm` and
`llc -filetype=obj`; `zig build llvm-obj-test` checks representative LLVM object
output, `zig build llvm-spec-obj-sweep` compiles every in-scope valid spec
fixture to an object file, and `zig build llvm-c-obj-sweep` compiles every
current `tests/c_emit` fixture to an object file. `zig build llvm-cc-test` links
and runs a simple exported function through the LLVM driver, and `zig build
llvm-move-test` links and runs a linear `move` handle ABI roundtrip. `zig build
llvm-runtime-test` links and runs imported generic `std/stack`, `std/sync`
guard, and fn-pointer modules through LLVM. `zig build llvm-toolchain-test`
links and runs import/std-merge, monomorphization, and generic-struct modules
through LLVM, and verifies reflection modules with `check` plus LLVM object
lowering. `zig build llvm-std-test` links and runs LLVM-built std module objects
against a C driver. `zig build llvm-pkg-test` builds the package-manifest demo
through LLVM, links the resulting object, and runs it. `zig build
llvm-demo-test` compiles the framebuffer/gpio/irq/spi/timer/uart hardware demo
drivers and the hosted elementwise demo through LLVM to non-empty objects under
the same hidden-assumption token check. `zig build llvm-hosted-demo-test`
links and runs the hosted elementwise demo through LLVM, libc, and libm, then
verifies the binary stdin/stdout `f32` round trip.

## Conformance Snapshot

The current fixture suite contains 65 spec milestones and is mostly focused on
parsing, semantic diagnostics, IR/fact inspection, and lower-C inspection
markers. Passing fixtures do not imply full implementation of
`docs/spec/MC_0.6.1_Final_Design.md`.

`zig build m0` is the current milestone gate. It runs unit tests, the spec
sweep, generated-C checks, LLVM IR/object/link-run gates, toolchain/library
host tests, and many QEMU-backed kernel/demo tests; external-tool-dependent
tests self-skip when their required tools are absent.

Generated C is checked by the `tests/c_emit` fixture suite and the spec emission
sweep. Unsupported C emission paths fail rather than silently changing source
semantics.

LLVM atomics are covered for scalar `atomic<T>` storage, `atomic.init`,
`load`, `store`, `fetch_add`, and `fetch_sub` over local and global atomics.
LLVM function-pointer coverage includes static function-name initializers,
copied aggregate globals, indirect calls, arrays/struct fields,
locals/params/globals, and returns.
LLVM string literal coverage includes `*const u8`/raw-many `u8` pointer targets
for returns, locals, and call arguments, including MC escape sequences.
LLVM packed-bits coverage uses the declared integer representation for ABI,
globals, aliases, static/dynamic literals, boolean field mask tests, and
read-modify-write field updates.
LLVM overlay-union coverage uses byte storage rather than C/LLVM union punning,
including scalar field writes, byte-array reads, and overlay field reflection.
LLVM tagged-union coverage uses an aligned tag-plus-payload aggregate ABI and
supports constructors, direct calls/returns, locals, struct fields, and
pattern switches with payload bindings and wildcard fallback arms.
LLVM byte-view coverage includes `mem.as_bytes(&value)` and `mem.bytes_equal`
over direct byte views and local byte-view slice values.
LLVM comptime block coverage omits accepted pure `comptime { ... }` blocks from
runtime IR after semantic checking.
LLVM initialization coverage materializes observable `uninit` storage with
concrete zero values and lowers `MaybeUninit<T>.write/assume_init` through the
payload storage representation.
LLVM opaque-address coverage lowers `PAddr`/`VAddr` representation-preserving
casts as `i64`, including `UserPtr<T>`/`PhysPtr<T>` wrapper ABI and the std/addr
helpers used by raw float buffers and fixed-lane helper arrays.
LLVM unsafe machine coverage includes volatile raw loads/stores, raw pointers,
raw-many offsets, `cpu.pause()`, opaque inline asm with explicit LLVM clobbers,
and precise asm operands with input/output constraints.
LLVM MMIO coverage includes `MmioPtr<T>` ABI lowering, `Reg`/`RegBits`
storage-width lowering, explicit `@offset(...)` register addressing, volatile
typed register reads/writes, `.acquire`/`.release` fences, and irq-context MMIO
fixtures.
LLVM DMA/IRQ marker coverage includes `DmaAddr`/`DmaBuf<T, mode>` as opaque
address-width values, `cache.clean`/`cache.invalidate` fences,
`dma_addr()`/`as_slice()` bridges, and the `IrqOff` witness ABI.
LLVM aggregate assignment coverage includes whole array/struct assignment and
nested aggregate field/element replacement.
LLVM debug metadata coverage includes compile-unit/file records, function
subprograms, precise-asm output stores, ordinary pointer/global/index loads and
stores, aggregate literal/member field stores, `MaybeUninit` writes, volatile
raw/MMIO stores and loads, atomic stores/loads/RMWs, fences, and
call/return/loop-branch/switch/if-let/trap-path/`?`
propagation/short-circuit/if-let-join/helper-loop branch line locations for the
covered subset.
LLVM inferred-local coverage includes initializer-derived slice, array, and
struct locals in covered expression and assignment workflows.
LLVM aggregate layout coverage includes dependency-ordered struct/array/slice
combinations and target-typed integer coercions such as `usize` slice lengths
returned as narrower integer types after MIR verification.
LLVM pointer coverage includes explicit pointer-to-`usize`/`isize` address
casts for pointer-width integer interop.
LLVM iterable coverage includes arrays and slices from parameters, globals,
nested array rows, aggregate fields, direct-call aggregate fields, and
direct-call array/slice results.
LLVM static global initializer coverage includes scalar copies, casted scalar
copies, string pointer/raw-many pointer arrays, constant address-of globals,
default slice/Result/tagged-union zero initializers, function-pointer globals,
copied function-pointer aggregate globals, and closure/function-pointer fields
inside mutable globals.
LLVM defer coverage runs lexical cleanups in reverse order before function
returns, block fallthrough, and loop `break`/`continue` exits.
LLVM reflection coverage includes `sizeof`/`alignof`, `repr_of`, field and bit
offsets, `DmaBuf`/MMIO register wrapper layouts, and `field_type(...)` in
monomorphized type-argument position.
LLVM unsafe-contract scope coverage includes nested contract blocks,
post-contract checked arithmetic, `compiler.assume_noalias_unchecked(...)` as a
contract-scoped identity, and pointer-to-address coercion for raw stores.
LLVM domain coverage includes payload ABI lowering for `wrap<T>`/`sat<T>`,
`serial<T>`/`counter<T>`/`Duration<T>` scalar storage, modular `wrap` arithmetic
and shifts, unsigned saturating arithmetic, serial
`before`/`after`/`distance`/`compare`, counter
`delta_mod`/`elapsed_assume_within`/`elapsed_bounded`, checked/clamping/
Result-returning scalar conversions, residue extraction, and wrapping builtins.
LLVM reduction coverage includes `reduce.sum_checked<T>` over integer slices,
`reduce.sum_left<T>` over floating slices, and `reduce.sum_fast<T>` with LLVM
floating reassociation on the accumulation add.
