# MC / modern-c

MC is a spec-first systems language and compiler for kernels, drivers, and
freestanding software. It explores a specific question: how much low-level
machine behavior can be made explicit and checkable without hiding allocation,
control flow, hardware access, or optimizer assumptions?

MC is a research prototype, not a general C replacement. The compiler has
two differentially validated backend paths for the documented, implemented subset:

- checked C emission;
- textual LLVM IR emission and object generation.

The useful claim is deliberately narrow: within the tested subset, MC either
emits the documented lowering or rejects the unsupported construct. Current
language and compiler work is tracked in [`docs/todo.md`](docs/todo.md) and
[`docs/refactoring-plan.md`](docs/refactoring-plan.md).

## Why MC Exists

Low-level code often carries its most important rules in comments: which address
space a value belongs to, whether an access is MMIO, whether arithmetic may wrap,
whether a resource must move exactly once, or whether a function may trap. MC
tries to represent those rules in source and carry them through semantic analysis
and MIR verification.

The language currently includes:

- checked arithmetic by default, plus explicit wrapping, saturating, serial, and
  counter domains;
- distinct physical, virtual, DMA, and MMIO address types;
- explicit atomics, fences, IRQ effects, DMA/cache ownership transitions, and
  unsafe boundaries;
- `move` resources for ownership-sensitive handles;
- `Result<T, E>`, optional values, tagged unions, traits, closures, generics, and
  bounded value-level comptime evaluation;
- `#[no_lang_trap]`, `#[bounded]`, `#[irq_context]`, and unsafe contracts;
- a rule that optimization mode cannot silently change the semantics of an
  already accepted program.

MC does not claim general memory safety. Raw pointers remain available, and the
current compiler does not implement a general borrow checker or lifetime system.

The normative language contract is
[`docs/spec/MC_0.7_Final_Design.md`](docs/spec/MC_0.7_Final_Design.md).

## Quick Start

The required compiler version is Zig 0.16.0. A native development environment
also needs Python 3.10 or newer and LLVM 18 on `PATH`.

```sh
zig build
zig-out/bin/mcc --version
zig-out/bin/mcc check tests/spec/arithmetic_checked.mc
zig-out/bin/mcc emit-c tests/c_emit/smoke.mc -o /tmp/smoke.c
zig-out/bin/mcc emit-llvm tests/c_emit/smoke.mc -o /tmp/smoke.ll
```

Build and run a small hosted executable:

```sh
printf 'export fn main() -> u32 { return 42; }\n' >/tmp/answer.mc
zig-out/bin/mcc build /tmp/answer.mc -o /tmp/answer
/tmp/answer
printf 'exit status: %s\n' "$?"
```

`mcc build` is intentionally limited to the documented nullary hosted `main`
boundary. Kernel and freestanding programs use the emission drivers and their
target-specific link flows.

## Development Environment

Required for compiler and host development:

- Zig `0.16.0`;
- `clang` from LLVM 18;
- LLVM 18 tools: `llvm-as`, `llc`, `opt`, `llvm-dwarfdump`;
- Python 3.10 or newer.

The QEMU validation gates additionally use `qemu-system-riscv64`,
`qemu-system-aarch64`, `qemu-system-x86_64`, `ld.lld`, and `llvm-objcopy`.

Use the native toolchain directly, or run the same build steps in the development
container:

```sh
make docker-build
make fast
make test
make m0
make shell
```

Equivalent container commands:

```sh
docker compose build dev
docker compose run --rm dev zig build fast
docker compose run --rm dev zig build m0
```

The image pins its base digest and Zig download. Ubuntu apt packages remain tied
to the configured distribution repositories, so the environment is controlled
but not bit-for-bit identical across rebuild dates.

### LLVM Support Matrix

| Environment | Validated LLVM | Support status |
| --- | --- | --- |
| Linux CI/dev container | Ubuntu 24.04 packages for LLVM 18 (`clang-18`, `lld-18`, `llvm-18`) | Primary CI/dev path; `zig build preflight` must pass with `MC_LLVM_MAJOR=18`. |
| macOS host gate | Homebrew `llvm@18` on `macos-15` | Host/fast validation path; the workflow places `llvm@18` first on `PATH`. |
| Native local | LLVM 18 tools selected on `PATH` | Supported when `MC_LLVM_MAJOR=18 zig build preflight` passes. |
| Other LLVM majors | Any non-18 LLVM toolchain | Unsupported by current validation gates until the major is added to CI, Docker, preflight, and this matrix. |

LLVM backend wrappers intentionally resolve `clang`, `ld.lld`, `llvm-as`, `llc`,
and `opt` from `PATH`. A validated run must resolve those names to the LLVM 18 toolchain used by the validation gates.

## Compiler Workflow

The compiler pipeline is:

```text
source -> AST -> semantic analysis -> MIR -> MIR verification -> C or LLVM

semantic representation -> optional HIR inspection / HIR verification
```

Inspection projections are debug/report surfaces only; MIR verification is the
backend semantic boundary.

`extern "C" fn` and unmarked `export fn` use a strict, target-classified C ABI
surface. `#[mc_abi] export fn` is available for same-backend object boundaries and
is not C ABI stable. See [C ABI and interop](docs/c-abi-interop.md) for the current
type allowlist and aggregate restrictions.

HIR and the compact IR report are inspection projections; they are not the
pipeline input to MIR or either backend. Inspect the available stages from the
command line:

```sh
zig-out/bin/mcc lex tests/spec/arithmetic_checked.mc
zig-out/bin/mcc check tests/spec/arithmetic_checked.mc
zig-out/bin/mcc check tests/spec/arithmetic_checked.mc --json
zig-out/bin/mcc facts tests/spec/arithmetic_checked.mc
zig-out/bin/mcc inspect-hir tests/spec/arithmetic_checked.mc
zig-out/bin/mcc verify-inspect-hir tests/spec/arithmetic_checked.mc
zig-out/bin/mcc lower-mir tests/spec/arithmetic_checked.mc
zig-out/bin/mcc verify tests/spec/arithmetic_checked.mc
zig-out/bin/mcc inspect-ir tests/spec/arithmetic_checked.mc
```

Emission and tooling commands:

```sh
zig-out/bin/mcc lower-c tests/c_emit/smoke.mc
zig-out/bin/mcc emit-c tests/c_emit/smoke.mc -o /tmp/smoke.c
zig-out/bin/mcc emit-map tests/c_emit/smoke.mc -o /tmp/smoke.mcmap
zig-out/bin/mcc emit-llvm tests/c_emit/smoke.mc -o /tmp/smoke.ll
zig-out/bin/mcc emit-layout tests/c_emit/struct.mc --structs=Pair
zig-out/bin/mcc emit-c-struct tests/c_emit/struct.mc --structs=Pair
zig-out/bin/mcc fmt tests/spec/arithmetic_checked.mc --check
zig-out/bin/mcc symbols tests/spec/arithmetic_checked.mc
zig-out/bin/mcc list-tests tests/test/lang_tests.mc
zig-out/bin/mcc explain E_UNKNOWN_IDENTIFIER
```

Run `zig-out/bin/mcc --help` for profile, check-mode, import-path, remapping, and
stdin options. `emit-c` defaults to the kernel/freestanding profile; hosted C is
explicitly selected with `--profile=hosted`.

## Validation Gates

Use the smallest gate that matches the work, then finish substantial compiler
changes with the milestone gate. Run retained kernel/QEMU gates only when the
change touches freestanding, ABI, MMIO, interrupt, or backend-lowering behavior.

```sh
zig build test       # compiler unit tests and spec conformance
zig build c-test     # checked C backend
zig build llvm-test  # LLVM backend
zig build fast       # broad host-only development gate, no fuzz or QEMU
zig build m0         # core compiler validation gate
zig build m0-full    # broad compiler/backend/fuzz validation matrix
```

Normal local gates may report a skip when an external tool is unavailable. A
validation run must fail instead of skipping:

```sh
MC_REQUIRE_TOOLS=1 MC_LLVM_MAJOR=18 zig build m0-full
```

`m0` covers the deterministic compiler-core validation path used for normal
local and CI feedback. It intentionally omits the full `c-test` fixture compile
sweep; use `fast`, `c0`, or `m0-full` when a change needs that C-backend
coverage. `m0-full` preserves the broad validation matrix: unit and spec tests,
C and LLVM fixture sweeps, IR assembly and object generation, optimizer
compatibility, differential execution, fuzz oracles, selected host-driver
tests, and retained QEMU validation fixtures.

The canonical Zig aggregate executes side-effecting `Run` gates serially. For
the same broad gate inventory with process-level parallelism, bounded nested
worker pools, longest-first scheduling, and serial rechecks of contention
failures, use:

```sh
tools/fast-parallel.sh              # fast inventory with process-level parallelism
MC_REQUIRE_TOOLS=1 tools/m0-parallel.sh  # broad inventory; skips are failures
```

Both runners derive their gate lists directly from `build/tiers.zig`; they do
not maintain a smaller duplicate list.

For an edit loop, the repository can select focused gates from changed files:

```sh
tools/dev-gates.py
tools/dev-gates.py --base origin/master
tools/dev-gates.py --run
```

The complete test architecture and gate ownership model are documented in
[`docs/test-architecture.md`](docs/test-architecture.md).

## Backends

### C

The C backend emits freestanding C for the validated Clang 18 toolchain and uses
Clang builtins for traps, checked arithmetic, atomics, wide intermediate
arithmetic, and exact-bit floating constants. Generated C is an implementation
artifact and differential oracle, not portable ISO C11; GCC C is not currently
a validated consumer because it does not provide Clang's C-mode
`__builtin_bit_cast`.

```sh
zig build c-test
zig build sweep
zig build cc-test
```

### LLVM

The LLVM backend consumes the same semantic and MIR verification pipeline, emits
textual IR, and uses `llc` for object generation. Its validated surface is
established by IR assembly, object, optimizer, differential, host-driver, and
selected QEMU gates rather than by a claim that every language form is supported.
Expected differential exclusions are explicit in the checked
[`diff-backend-expected-skips.tsv`](tools/toolchain/diff-backend-expected-skips.tsv)
manifest; an unlisted skip fails the gate.

```sh
zig build llvm-test
zig build llvm-sweep
zig build llvm-spec-obj-sweep
zig build llvm-opt-sweep
zig build llvm-runtime-test
```

Object generation is available through:

```sh
tools/toolchain/mcc-llvm-cc.sh path/to/file.mc -o file.o
```

## Kernel Validation Workload

The `kernel/` and QEMU fixtures are compiler-validation workloads. They exercise
freestanding ABI boundaries, address classes, ownership, unsafe operations, MMIO,
interrupts, and backend lowering. They are not an OS deliverable track.

Use `zig build riscv-qemu-validation` only when a change needs the retained
RISC-V OpenSBI/QEMU surrogate.

## Developer Tooling

The repository includes:

- a token-preserving formatter through `mcc fmt`;
- structured diagnostics and `mcc explain`;
- JSON symbol indexing through `mcc symbols`.

The formatter preserves every payload-bearing line inside a multiline block comment
byte-for-byte. A complete inline block comment still permits indentation and trailing-space
normalization, but code/comment internal spacing on that line is intentionally conservative.

## Current Boundaries

Three compiler architecture workstreams are closed only for the currently
admitted supported subset and reopen when a new semantic/projection/pointer-flow
family is admitted:

1. pointer-provenance handling for race-tolerant lowering;
2. typed semantic facts and typed MIR as backend semantic authority;
3. CFG/place-based move ownership analysis.

Other deliberate or current limitations include:

- no general lifetime or borrow checker;
- value-level comptime rather than unrestricted type computation;
- no separate-compilation or mature incremental module graph;
- a token-preserving reindenter rather than a full pretty printer;
- kernel code is a compiler-validation workload, not a board-certification
  target;
- no shipped-version guarantee.

The repository-wide backlog is [`docs/todo.md`](docs/todo.md).

## Repository Map

| Path | Purpose |
| --- | --- |
| `src/` | Compiler implementation and unit tests |
| `std/` | MC standard library |
| `tests/spec/` | Normative language and diagnostic fixtures |
| `tests/c_emit/`, `tests/llvm/` | Backend fixtures |
| `tests/qemu/` | Programs used by QEMU and host-driver gates |
| `kernel/`, `user/` | Freestanding validation modules and user-mode fixtures |
| `tools/` | Drivers, fuzzers, and test harnesses |
| `demo/`, `examples/` | Hosted and hardware-oriented examples |
| `docs/` | Specifications, reference material, validation, and plans |

Start with [`docs/README.md`](docs/README.md) to see which documents are current
sources of truth and which are historical records. This repository is a research
compiler workspace and does not define shipped-version guarantees.

## License

See [`LICENSE`](LICENSE).
