# MC / modern-c

MC is a spec-first compiler prototype for a kernel-profile, Zig-like systems
language. The project explores how a C replacement for low-level systems code
could make machine contracts explicit without promising memory safety.

The compiler currently has two verified backend paths for the implemented spec
surface:

- C emission through `emit-c`
- LLVM IR emission through `emit-llvm`, then object generation through `llc`

Both backends are exercised by host tests, toolchain tests, broad fixture sweeps,
and QEMU kernel tests. The kernel e2e test scripts in `zig build m0` are wired
for both C and LLVM lowering.

MC is still a prototype. It is useful as a language/compiler experiment and as a
testbed for kernel-oriented type and runtime contracts; it is not a production
C replacement.

## What MC Tries To Prove

MC keeps low-level behavior visible. The language and compiler try to turn common
systems-programming traps into one of three explicit outcomes:

- compile-time diagnostics
- runtime traps with a known language edge
- typed `Result` values

Important design points include:

- explicit arithmetic domains: checked, wrapping, saturating, serial, and counter
- typed address classes and MMIO access
- unsafe blocks and unsafe contracts instead of hidden optimizer assumptions
- linear `move` resources for ownership-sensitive handles
- explicit atomics, fences, DMA/cache markers, and IRQ witnesses
- kernel-profile defaults with an opt-in hosted profile
- generated C and LLVM IR that avoid hidden assumptions such as `nuw`, `nsw`,
  `nonnull`, `noalias`, `noundef`, `poison`, `inbounds`, and `undef`

The full language design lives in
[`docs/spec/MC_0.7_Final_Design.md`](docs/spec/MC_0.7_Final_Design.md).

## Current Status

Implemented today:

- lexer, parser, semantic checker, HIR/MIR lowering, MIR verification, and fact
  inspection
- checked C emission for the implemented language surface
- LLVM IR emission for the same current backend surface
- LLVM object generation through `tools/toolchain/mcc-llvm-cc.sh`
- source map output for generated C via `emit-map`
- initial LLVM debug metadata, verified by `llvm-debug-test`
- a spec fixture suite under `tests/spec`
- generated-C fixtures under `tests/c_emit`
- kernel, driver, filesystem, IPC, process, memory-management, networking, SMP,
  and architecture tests under QEMU
- data-driven host-driver tests for kernel libraries in `tools/lib/host-tests.tsv`
- local package manifests through `tools/toolchain/mcc-pkg.sh`, and an offline
  registry with semver-ish version resolution, `publish`/`install`, and a
  reproducible lockfile through `tools/toolchain/mcc-registry.sh`
- a token-preserving source formatter (`mcc fmt [--check]`), a JSON symbol index
  (`mcc symbols`), and a full language server (`tools/lsp/mc-lsp.py`, with a VS Code
  client in `editors/vscode/`) providing diagnostics (the compiler's own `E_` codes),
  hover, go-to-definition, find-references, rename, document/workspace symbols,
  semantic tokens, completion, signature help, call hierarchy, and formatting
- a small standard library under `std/`

The milestone gate is:

```sh
zig build m0
```

`m0` runs the unit tests, C backend tests, LLVM IR/object tests, optimizer
checks, package/toolchain tests, host-driver tests, and the QEMU kernel matrix.
Tests that require external tools self-skip when the required tool is absent.

The focused RISC-V board-surrogate validation gate is:

```sh
zig build riscv-qemu-validation
```

That gate runs the RISC-V QEMU `virt` + OpenSBI S-mode platform, IRQ, virtio-blk,
virtio-net, confined QuickJS, real broker, TCP-backed `host_net_fetch`, and
IRQ-backed `SYS_POLL` storage/network gates across both C and LLVM backends. It is
the repeatable validation path when VisionFive 2 hardware is unavailable; it is
not a substitute for final real-board boot and soak evidence.

## Development Environment

The toolchain is Zig 0.16.0 plus clang/lld/llvm and QEMU (riscv64/aarch64/x86_64).
You can install those natively, or use the bundled container, which pins the exact
toolchain from CI and runs on Linux, macOS (incl. Apple Silicon), and Windows/WSL.

```sh
make docker-build          # build the dev image (selects amd64 or arm64 automatically)
make fast                  # host-only inner-loop gate (~seconds), no QEMU
make test                  # compiler unit + spec suite
make m0                    # full milestone gate: clang + llvm + QEMU
make run CMD='zig build riscv-qemu-validation' # focused RISC-V QEMU/OpenSBI surrogate
make shell                 # interactive shell at /work
make run CMD='zig build abi-test'
```

Equivalently, without `make`:

```sh
docker compose build dev
docker compose run --rm dev zig build fast
docker compose run --rm dev zig build m0
docker compose run --rm dev                 # interactive shell
```

The repo is bind-mounted live; `.zig-cache` and `zig-out` are container-local volumes
so host (e.g. macOS) artifacts never mix with the Linux build. With the toolchain on
your `PATH`, the same gates run natively as `zig build <step>`.

## Backend Coverage

### C Backend

`emit-c` is the original checked backend. It emits freestanding C by default and
uses Clang/GCC builtins for traps, checked arithmetic, atomics, and 128-bit
intermediate arithmetic. The generated C is intentionally not portable ISO C11.

Useful C gates:

```sh
zig build c-test
zig build sweep
zig build cc-test
zig build m0
```

### LLVM Backend

`emit-llvm` uses the same semantic and MIR verification path as C emission, then
emits textual LLVM IR. The LLVM test suite verifies IR assembly, object lowering,
debug metadata, object linking/running, package builds, standard-library objects,
spec sweeps, C-fixture sweeps, optimizer pipeline compatibility, and QEMU boot
behavior.

Useful LLVM gates:

```sh
zig build llvm-test
zig build llvm-obj-test
zig build llvm-debug-test
zig build llvm-sweep
zig build llvm-spec-obj-sweep
zig build llvm-c-sweep
zig build llvm-opt-sweep
zig build llvm-c-obj-sweep
zig build llvm-cc-test
zig build llvm-runtime-test
zig build llvm-toolchain-test
zig build llvm-std-test
zig build llvm-pkg-test
zig build llvm-host-suite-test
zig build m0
```

The driver for object generation is:

```sh
tools/toolchain/mcc-llvm-cc.sh path/to/file.mc -o file.o
```

## Kernel And QEMU Coverage

The kernel e2e matrix is now backend-selectable. Every kernel/QEMU script family
used by `m0` has a C invocation and an LLVM invocation.

Covered areas include:

- typed MMIO and trap/timer paths
- cooperative threads, round-robin scheduling, timer preemption, and scheduler
  VM switching
- syscall dispatch, U-mode entry, user-mode process lifecycle, ELF load/run,
  `exec`, file syscalls, socket syscalls, and the user shell
- IPC request/reply, multi-slot IPC, source filtering, notifications, timeouts,
  registry lookup, signals, restart supervision, heartbeat liveness, capability
  gates, and least-privilege checks
- Sv39 activation, address-space switching, per-process page tables, context
  switches that swap `satp`, demand paging, anonymous mmap, copy-on-write,
  crash containment, and per-server MMU isolation
- frame allocator, kernel heap, and page-table host checks
- user-mode block/filesystem/network servers
- virtio-net, virtio-blk, UDP transmit with pcap verification, ARP/ICMP gateway
  round trip, live virtio-net RX routing, e1000 PCI probing, and synthetic NIC
  driver-library checks
- SMP boot/sync, ticket-lock mutual exclusion, and inter-processor interrupts
- integrated RISC-V kernel boot and integrated kernel+network boot
- OpenSBI boot, aarch64 QEMU boot, and x86-64 native/QEMU scheduler boot

Examples:

```sh
zig build riscv-qemu-validation
zig build qemu-test
zig build llvm-qemu-test
zig build kmain-test
zig build llvm-kmain-test
zig build kmain-net-test
zig build llvm-kmain-net-test
zig build ushell-test
zig build llvm-ushell-test
zig build sbi-boot-test
zig build llvm-sbi-boot-test
zig build aarch64-test
zig build llvm-aarch64-test
zig build x86-qemu-test
zig build llvm-x86-qemu-test
```

Interactive user shell boot:

```sh
zig build run-ushell
zig build run-llvm-ushell
```

## Requirements

Required for normal development:

- Zig `0.16.0`
- `clang`
- LLVM tools: `llvm-as`, `llc`, `opt`, `llvm-dwarfdump`
- Python 3

Required for QEMU gates:

- `qemu-system-riscv64`
- `qemu-system-aarch64`
- `qemu-system-x86_64`
- `ld.lld`
- `llvm-objcopy`

Most tests check for their tools and skip cleanly if the environment cannot run
that gate.

## Build

Build the compiler:

```sh
zig build
```

Run the full milestone gate:

```sh
zig build m0
```

Run a spec conformance-level tier (subsets of `m0` aligned to the staged
C-backend profiles in spec §L — validate the level you touch):

```sh
zig build c0   # §L.1 baseline language: fixtures + spec-coverage gate, emit-C sweep, demo lowering
zig build c1   # §L.2 kernel profile: c0 + kernel suite (MMIO, DMA, move checking, address-space lowering)
```

The `test` gate includes a spec-section coverage check: every normative section
of the spec must be exercised by at least one `tests/spec/*.mc` fixture (tagged
`// SPEC: section=`), or be listed in `coverage_exempt` in `src/spec_tests.zig`.

Run core checks:

```sh
zig build test
zig build c-test
zig build sweep
zig build llvm-test
zig build llvm-opt-sweep
```

Differential and dynamic gates (also part of `m0`) — these execute the emitted
code rather than only compiling it, which is what static review and `-fsyntax-only`
sweeps cannot do:

```sh
zig build diff-backend   # compile each host fixture through BOTH backends; assert C and LLVM agree
zig build diff-fuzz      # generate random MC programs; assert the two backends agree on each (seed-reproducible)
zig build move-fuzz      # generate move-resource programs; assert every resource is released once (live_count==0)
zig build sanitize       # run the host-driver corpus under ASan + UBSan over the emitted C
zig build vqfault-test   # virtqueue completion fault injection (bad id / not-in-flight / length overflow)
zig build wrap-test      # long-running ring-index / pool-generation wrap and pool-exhaustion invariants
```

`mcfuzz` (`tools/fuzz/mcfuzz.py`) is the type-directed framework — a type model over the whole
scalar system plus structs and enums, a generator that produces well-typed programs by
construction, and pluggable oracles:

It covers ints (every width, signed/unsigned), f64, bool, structs, enums, fixed arrays, and a DAG
of helper functions with calls. Oracles (all in `m0`):

```sh
zig build fuzz             # differential: C vs LLVM agree (status + stdout) over the full type system
zig build fuzz-trap        # trap-consistency: programs that may overflow/divide-by-zero must trap on BOTH backends together
zig build fuzz-sanitize    # emitted C is UBSan-clean
zig build fuzz-robust      # robustness: `mcc check` never crashes/hangs on mutated (malformed) input
zig build fuzz-failclosed  # soundness: `mcc check` must reject deliberately ill-typed programs
zig build fuzz-determinism # emit-c / emit-llvm are byte-deterministic for the same input
zig build fuzz-pipeline    # every lowering/verify stage succeeds on a check-accepted program
```

Additional standalone oracles exist for deeper runs:

```sh
zig build fuzz-metamorphic # semantics-preserving source transform must not change the result
zig build fuzz-optlevel    # emitted C agrees at -O0 and -O2
zig build fuzz-reference   # compiled output matches the independent Python reference interpreter
zig build fuzz-corpus      # replay persisted regression seeds
```

A fuzzer failure prints the seed; reproduce with `tools/fuzz/mcfuzz.py gen <seed>` and minimize
with `tools/fuzz/mcfuzz.py shrink --seed <seed> --oracle <name>`. The older one-shape generators
(`diff-fuzz`/`move-fuzz`) reproduce via `tools/toolchain/mcgen.py <seed>` / `mcgen_move.py <seed>`.
Raise `COUNT=` on any of them to explore further.

## Compiler CLI

Run the compiler through Zig:

```sh
zig build run -- check tests/spec/arithmetic_checked.mc
zig build run -- verify tests/spec/no_lang_trap.mc
zig build run -- lower-mir tests/spec/no_lang_trap.mc
zig build run -- emit-c tests/c_emit/smoke.mc
zig build run -- emit-llvm tests/c_emit/smoke.mc
zig build run -- emit-map tests/c_emit/smoke.mc
```

Installed binary after `zig build`:

```sh
zig-out/bin/mcc check tests/spec/arithmetic_checked.mc
zig-out/bin/mcc emit-c tests/c_emit/smoke.mc
zig-out/bin/mcc emit-llvm tests/c_emit/smoke.mc
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

`emit-c` defaults to the kernel/freestanding profile. The hosted profile is
explicit:

```sh
zig build run -- emit-c demo/hosted/elementwise.mc --profile=hosted
zig build hosted-test
```

The hosted profile is for code that uses `std/hosted_io` and `std/mathf`; it
links against libc and libm.

## Repository Layout

- `src/` - compiler implementation
- `std/` - MC standard-library modules used by tests and demos
- `tests/spec/` - spec and diagnostic fixtures
- `tests/c_emit/` - generated-C/backend fixtures
- `tests/llvm/` - LLVM-specific backend fixtures
- `tests/qemu/` - MC programs booted or linked by QEMU/host-driver gates
- `kernel/` - C runtimes and MC kernel modules used by QEMU tests
- `tools/toolchain/` - compiler, package, sweep, and LLVM driver tests
- `tools/arch/`, `tools/proc/`, `tools/mem/`, `tools/ipc/`, `tools/fs/`,
  `tools/net/`, `tools/lang/` - e2e test scripts
- `tools/lib/` - data-driven host-driver harness and manifest
- `demo/` - hardware and hosted demos
- `docs/` - specs, reference docs, and roadmap notes; start at
  [`docs/README.md`](docs/README.md)

## What Is Still Prototype Work

The current backend milestone is complete for the implemented spec surface, but
the project as a whole is still not production-grade. Several areas remain
prototype work:

- full arbitrary comptime *type* computation (deliberately out of scope — MC
  evaluates values, not types; see spec §22)
- a broader MIR optimization pass set (the fact-gated optimizer currently has
  two transforms: const-index bounds-check elision and divide/modulo
  by-constant check elision)
- a networked package registry with signing (the current registry, version
  resolution, lockfile, and publish/install flow are offline/filesystem-local)
- a full pretty-printing formatter (`mcc fmt` is currently a token-preserving
  reindenter) and richer, type-directed LSP completion (`.`-member field completion
  and type-filtered candidates; the current completion offers identifiers in scope +
  keywords/types)
- complete DMA/cache-coherence simulation
- broader per-architecture production kernel hardening
- full VFS/POSIX/network service completeness

See [`docs/todo.md`](docs/todo.md) for the current consolidated follow-up list.

## License

See [`LICENSE`](LICENSE).
