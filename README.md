# MC / modern-c

MC is a spec-first systems language and compiler for kernels, drivers, and
freestanding software. It explores a specific question: how much low-level
machine behavior can be made explicit and checkable without hiding allocation,
control flow, hardware access, or optimizer assumptions?

MC is a research prototype, not a production C replacement. The compiler has
two differentially qualified backend paths for the documented, implemented subset:

- checked C emission;
- textual LLVM IR emission and object generation.

The useful claim is deliberately narrow: within the tested subset, MC either
emits the documented lowering or rejects the unsupported construct. The current
production assessment and its remaining architecture work are tracked in
[`docs/compiler-production-readiness.md`](docs/compiler-production-readiness.md).

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
also needs Python 3 and LLVM 18 on `PATH`.

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
- Python 3.

The QEMU qualification gates additionally use `qemu-system-riscv64`,
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

| Environment | Qualified LLVM | Support status |
| --- | --- | --- |
| Linux CI/dev container | Ubuntu 24.04 packages for LLVM 18 (`clang-18`, `lld-18`, `llvm-18`) | Release qualification path; `zig build preflight` must pass with `MC_LLVM_MAJOR=18`. |
| macOS host gate | Homebrew `llvm@18` on `macos-15` | Host/fast qualification path; the workflow places `llvm@18` first on `PATH`. |
| Native local | LLVM 18 tools selected on `PATH` | Supported when `MC_LLVM_MAJOR=18 zig build preflight` passes. |
| Other LLVM majors | Any non-18 LLVM toolchain | Unqualified until the major is added to CI, Docker, preflight, and this matrix. |

LLVM backend wrappers intentionally resolve `clang`, `ld.lld`, `llvm-as`, `llc`,
and `opt` from `PATH`. A qualified run must resolve those names to the qualified LLVM 18 toolchain.

## Compiler Workflow

The compiler pipeline is:

```text
source -> AST -> semantic analysis -> HIR -> MIR -> verification -> C or LLVM
```

Inspect each stage from the command line:

```sh
zig-out/bin/mcc lex tests/spec/arithmetic_checked.mc
zig-out/bin/mcc check tests/spec/arithmetic_checked.mc
zig-out/bin/mcc check tests/spec/arithmetic_checked.mc --json
zig-out/bin/mcc facts tests/spec/arithmetic_checked.mc
zig-out/bin/mcc lower-hir tests/spec/arithmetic_checked.mc
zig-out/bin/mcc verify-hir tests/spec/arithmetic_checked.mc
zig-out/bin/mcc lower-mir tests/spec/arithmetic_checked.mc
zig-out/bin/mcc verify tests/spec/arithmetic_checked.mc
zig-out/bin/mcc lower-ir tests/spec/arithmetic_checked.mc
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

## Qualification

Use the smallest gate that matches the work, then finish substantial compiler or
kernel changes with the milestone gate.

```sh
zig build test       # compiler unit tests and spec conformance
zig build c-test     # checked C backend
zig build llvm-test  # LLVM backend
zig build fast       # broad host-only development gate
zig build m0         # complete compiler, backend, toolchain, and QEMU milestone
```

Normal local gates may report a skip when an external tool is unavailable. A
qualification run must fail instead of skipping:

```sh
MC_REQUIRE_TOOLS=1 MC_LLVM_MAJOR=18 zig build m0
```

`m0` covers unit and spec tests, C and LLVM fixture sweeps, IR assembly and object
generation, optimizer compatibility, differential execution, fuzz oracles,
package and release tooling, host-driver tests, and the QEMU kernel matrix.

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

The C backend emits freestanding C by default and uses Clang/GCC builtins for
traps, checked arithmetic, atomics, and wide intermediate arithmetic. Generated
C is an implementation artifact and differential oracle, not portable ISO C11.

```sh
zig build c-test
zig build sweep
zig build cc-test
```

### LLVM

The LLVM backend consumes the same semantic and MIR verification pipeline, emits
textual IR, and uses `llc` for object generation. Its qualified surface is
established by IR assembly, object, optimizer, differential, runtime, and QEMU
gates rather than by a claim that every language form is supported.
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

## Kernel Validation

The repository contains MC kernel modules, C runtime support, drivers, user-mode
components, and host models used to exercise the language against realistic
freestanding workloads. Coverage includes MMIO, timers and traps, schedulers,
syscalls, processes, IPC, virtual memory, filesystems, networking, SMP, virtio,
and multiple target architectures.

The focused RISC-V board-surrogate gate is:

```sh
zig build riscv-qemu-validation
```

It runs the RISC-V QEMU `virt` and OpenSBI path across both compiler backends,
including IRQ, storage, networking, and confined runtime integration. This is a
repeatable surrogate when VisionFive 2 hardware is unavailable; it is not final
real-board boot or soak evidence.

Useful narrower gates include:

```sh
zig build qemu-test
zig build llvm-qemu-test
zig build kmain-test
zig build llvm-kmain-test
zig build aarch64-test
zig build x86-qemu-test
```

See [`docs/qemu-validation-checklist.md`](docs/qemu-validation-checklist.md) for
the complete validation boundary.

## Developer Tooling

The repository includes:

- a token-preserving formatter through `mcc fmt`;
- structured diagnostics and `mcc explain`;
- JSON symbol indexing through `mcc symbols`;
- local package manifests and an offline, filesystem-backed registry with lock
  files, safe package identities, and publish/install commands;
- a CLI-backed language server in `tools/lsp/mc-lsp.py` and a VS Code client in
  `editors/vscode/`.

The language server provides compiler diagnostics, hover, completion, navigation,
references, rename, symbols, semantic tokens, signature help, call hierarchy,
and formatting; cross-file navigation is qualified for files reachable through the current import
graph. Workspace symbols also discover unopened `.mc` files under the workspace
root. Completion and formatting remain intentionally simpler than mature IDE
toolchains.

## Current Boundaries

MC is not generally production-ready. The three open compiler architecture
workstreams are:

1. complete pointer-provenance handling for race-tolerant lowering;
2. make typed semantic facts and typed MIR the sole authority consumed by both
   backends;
3. complete CFG/place-based move ownership analysis.

Other deliberate or current limitations include:

- no general lifetime or borrow checker;
- value-level comptime rather than unrestricted type computation;
- no separate-compilation or mature incremental module graph;
- an offline registry rather than a public network package ecosystem;
- a token-preserving reindenter rather than a full pretty printer;
- incomplete hardware qualification and production kernel hardening;
- no stable public release yet.

Exit criteria, phases, evidence, and design risks are maintained in
[`docs/compiler-production-readiness.md`](docs/compiler-production-readiness.md).
The shorter repository-wide backlog is [`docs/todo.md`](docs/todo.md).

## Repository Map

| Path | Purpose |
| --- | --- |
| `src/` | Compiler implementation and unit tests |
| `std/` | MC standard library |
| `tests/spec/` | Normative language and diagnostic fixtures |
| `tests/c_emit/`, `tests/llvm/` | Backend fixtures |
| `tests/qemu/` | Programs used by QEMU and host-driver gates |
| `kernel/`, `user/` | Kernel runtime, MC modules, and user-mode components |
| `selfhost/` | Self-hosting experiments |
| `tools/` | Drivers, fuzzers, package tools, LSP, and test harnesses |
| `demo/`, `examples/` | Hosted and hardware-oriented examples |
| `docs/` | Specifications, reference material, qualification, and plans |

Start with [`docs/README.md`](docs/README.md) to see which documents are current
sources of truth and which are historical records.

## Release And Security

There is no stable public release yet. Release artifacts, checksums, SBOMs,
attestations, version identity, and immutable publication controls are described
in [`docs/release-process.md`](docs/release-process.md).

Report security issues through the private process in
[`SECURITY.md`](SECURITY.md). Compatibility expectations are documented in
[`STABILITY.md`](STABILITY.md).

## License

See [`LICENSE`](LICENSE).
