# MC / modern-c

MC is a spec-first compiler prototype for a kernel-profile, Zig-like systems language.
The current repository is an early MC-C0 prototype, not a production-ready C
replacement.

The design goal is to make low-level machine contracts explicit: ordinary
language errors should become compile errors, traps, or `Result` values, rather
than invisible optimizer assumptions. MC is not a memory-safe language.

## Current Status

Implemented today:

- Lexer, parser, semantic checker, fact/inspection output, and partial C output.
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

The full type-checking surface of the core language spec is implemented, and
most operations covered by the current spec fixtures lower to clang-checked C.
The remaining items are the larger runtime/toolchain subsystems outside the
initial MC-C0 snapshot.

Prototype or incomplete:

- Production-grade typed MIR/CFG and verifier.
- Package registry, releases/publishing, and production toolchain support.
- Full comptime execution (§22): the evaluator handles scalar/enum-tag folding,
  const globals, const-fn calls with loops/for/switch/asserts, top-level comptime
  block assignments/loops/switches, aggregate literals and mutable aggregate
  updates, comptime/type feedback, and layout reflection for size/alignment/
  offsets/repr plus `field_type` in type-argument position; broader arbitrary
  interpreter coverage is still incomplete.
- Production MIR optimizer use: MIR records and consumes scoped no-overflow
  range facts for covered unchecked arithmetic; broader range algebra and
  optimization passes are still incomplete.
- Full DMA/cache-coherence model (§18): typed `DmaBuf`, cache clean/invalidate,
  and the address-class rules are implemented; a complete coherence simulation
  is not.
- Debug mapping: `emit-c` writes `#line` source hints for generated C, and
  `emit-map` emits an initial `.mcmap`-style source/generated-C map. DWARF-quality
  native debug mapping is still pending.

Deferred:

- LLVM backend (see Appendix M of `docs/spec/MC_0.6.1_Final_Design.md`). Not started; the
  C backend is the only lowering target for now.

## Requirements

- Zig `0.16.0`
- `clang` for `zig build c-test`

The generated C targets **Clang/GCC only**: the runtime helpers use compiler
builtins (`__builtin_trap`, `__builtin_*_overflow`, `__atomic_*`) and a few
extensions (`__int128`, statement attributes). It is not portable C11; compiling
the output with another toolchain is unsupported.

## Build And Test

```sh
zig build m0
zig build test
zig build c-test
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

`emit-c` defaults to the **kernel / freestanding** profile (no ambient I/O).
`--profile=hosted` selects an opt-in **hosted** profile that links a host C
runtime (libc + `-lm`); it stamps a `/* mc-profile: hosted */` marker and is the
target for programs that use `std/hosted_io` (explicit, fallible byte I/O —
`io_open`/`io_read`/`io_write`/`io_close`/`io_printf_f64`, each returning a
`Result`) and `std/mathf` (the libm float intrinsics `sqrt`/`sin`/`cos`/
`exp2`/`log2`/`exp`/`log`/`tanh` for `f32`/`f64`). See `demo/hosted/` for the
stdin-to-stdout float round-trip; run it with `zig build hosted-test`.
`emit-map` uses the same verified C-emission path and writes a line-oriented
`.mcmap` artifact to stdout, including statement and selected expression spans
with typed-AST and MIR labels.

## Conformance Snapshot

The current fixture suite contains 65 spec milestones and is mostly focused on
parsing, semantic diagnostics, IR/fact inspection, and lower-C inspection
markers. Passing fixtures do not imply full implementation of
`docs/spec/MC_0.6.1_Final_Design.md`.

`zig build m0` is the current milestone gate. It runs unit tests, the spec
sweep, generated-C checks, toolchain/library host tests, and many QEMU-backed
kernel/demo tests; external-tool-dependent tests self-skip when their required
tools are absent.

Generated C is checked by the `tests/c_emit` fixture suite and the spec emission
sweep. Unsupported C emission paths fail rather than silently changing source
semantics.
