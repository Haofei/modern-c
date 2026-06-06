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

The full type-checking surface of the core language spec is implemented, and
every operation that has a defined value lowers to clang-checked C. The
remaining items are the larger runtime/toolchain subsystems that
`docs/implementation-plan.md` scopes out of the initial MC-C0 suite.

Prototype or incomplete:

- Production-grade typed MIR/CFG and verifier.
- Standard library, package manager, releases, and production toolchain support.
- Full comptime execution (§22): the comptime evaluator currently const-folds
  arithmetic and enforces the comptime effect rules, but does not yet interpret
  arbitrary comptime code.
- Production MIR optimizer use: MIR records scoped no-overflow range facts for
  covered unchecked arithmetic, but optimizer consumption and broader range
  algebra are not implemented yet.
- Full DMA/cache-coherence model (§18): typed `DmaBuf`, cache clean/invalidate,
  and the address-class rules are implemented; a complete coherence simulation
  is not.
- Hardware MMIO execution tests.

Deferred:

- LLVM backend (see Appendix M of `MC_0.6.1_Final_Design.md`). Not started; the
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
zig build run -- emit-c tests/c_emit_smoke.mc
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
- `emit-c <file.mc>`

## Conformance Snapshot

The current fixture suite contains 51 spec milestones and is mostly focused on
parsing, semantic diagnostics, IR/fact inspection, and lower-C inspection
markers. Passing fixtures do not imply full implementation of
`MC_0.6.1_Final_Design.md`.

`zig build m0` is the current milestone gate. It runs the spec fixture/unit
tests and generated-C smoke fixtures together.

Generated C is currently checked by a small smoke fixture set. Unsupported C
emission paths fail rather than silently changing source semantics.
