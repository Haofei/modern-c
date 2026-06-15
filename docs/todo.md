# TODO - spec/code delta as of MC 0.7

This file is regenerated from the current spec, README, build gates, and source
tree after the LLVM backend was finished for the current spec surface.

Legend:

- `[~]` implemented enough for the current milestone, but not production-grade
- `[ ]` not implemented yet

Current baseline evidence:

- `zig build m0` passes with C, LLVM IR, LLVM object, LLVM O2/object, package,
  std, demo, kernel-module LLVM object, LLVM kernel QEMU boot, host-suite, and
  QEMU gates.
- `docs/spec/MC_0.7_Final_Design.md` Appendix M describes LLVM as complete for
  the current spec surface.
- `docs/spec/MC_0.7_Final_Design.md` L.3 and README "Prototype or incomplete"
  describe the remaining work as MC-C2/tooling work, not current backend
  conformance work.

## Compiler and spec follow-up

| Status | Item | Current code evidence | Next step |
|---|---|---|---|
| `[x]` | Full comptime execution / reflection | The interpreter boundary is decided and documented (spec §22): comptime evaluates **values** in MC's own type/arithmetic-domain system but never computes **types** or generates code (no `@Type`/`inline for`/type-returning fns — deliberately out, "not a Zig clone"). `src/eval.zig` now folds, beyond the prior scalar/aggregate/loop/recursion/reflection core: **floats** (f32/f64 literals, arithmetic, comparison, int↔float casts), **byte strings** (`.len`, indexing, compare), **`bitcast<T>`** (same-width reinterpret), **expression-`switch`**, **optionals/Result** (`ok`/`err`/`null` + `switch`/`if let` narrowing), **wrap/sat/checked arithmetic-domain folding** (checked overflow at the declared width traps), and **`comptime_error("msg")`** (E_COMPTIME_ERROR). Fixtures: `tests/spec/comptime_extended.mc` (emittable subset, in the spec sweep) and `comptime-fold-test` (in `m0`, count-checked byte/wrap/sat folds). | Optional: extend the in-boundary value set further (e.g. comptime `?T` once MC has non-pointer optionals; the `?` operator at comptime), per the documented §22 boundary. |
| `[x]` | Production MIR optimizer use | Fact-gated optimizer (spec §E.4): `mir.buildOpt`/`verifyOpt` + `mcc verify\|lower-mir\|emit-c\|emit-llvm --optimize`, **off by default** (byte-identical standard pipeline). **Both backends consume the optimized MIR to elide the *emitted* runtime check** — each elided check's operand source point is recorded so the C and LLVM emitters skip exactly it. Two transforms, each with a stated proof obligation and the §E.4 discipline: (1) const-index bounds-check elision (`k < N`, both constants), (2) divide-by-zero elision for an unsigned `/`/`%` by a non-zero literal. Tested: `mir.zig` unit test (trap edge dropped for the provable case, kept for the variable one); `opt-test` (verify rejects / `--optimize` accepts a `#[no_lang_trap]` const-index; in `m0`); `opt-equiv-test` (in `m0`) compiles a fixture through C and LLVM × default/`--optimize`, runs all four, and asserts identical results AND that each optimized build dropped the check — so the elision is verified behavior-preserving on both backends. | Optional: add further transforms one at a time per §E.4 (e.g. const-fold checked arithmetic on literal operands; extend bounds elision to slice/global/assignment-target index sites). |
| `[x]` | Full CFG-based linear `move` verifier | `src/sema.zig` tracks each binding through the structured CFG with the `Live`/`Moved`/`Deferred`/`Unreachable` lattice: return-exit and `?`-error leaks, branch-local resources, if-let move payloads, scoped block locals, outer-resource-in-loop rejection, and `break`/`continue` leak edges. The remaining blind spot — *aborting/unreachable* exit edges — is now closed: `trap(...)`, `unreachable`, and calls to `-> never` functions are recognized as divergence in both the move pass and the return-path analyzer (`exprMayFallThrough`/`callReturnsNever`), so such a path is the `Unreachable` state (no leak obligation, dropped from the join) instead of raising a spurious `E_MOVE_BRANCH_MISMATCH`/`E_RESOURCE_LEAK`/`E_RETURN_MISSING`. Fixtures: `tests/spec/move_diverge.mc` (nested returns, panic/trap/unreachable exits, defer across abort); defer LIFO codegen covered by `tests/c_emit/defer.mc`. Spec §18.1 documents the control-flow model. | Optional: relocate the analysis onto `mir.zig`'s materialized CFG (would require persisting move-type info into MIR, which is currently dropped at `finish()`); the structured-CFG analysis is now edge-complete, so this is a refactor, not a soundness gap. |
| `[~]` | Source/MIR-quality native debug tooling | `emit-map` emits initial `.mcmap`; LLVM emits DWARF and `llvm-debug-test` checks calls, control flow, atomics/fences, and nullable/Result narrowing. Spec N still describes long-term object-to-MC-source/MIR mapping. | Extend `.mcmap` to include stable typed-AST/MIR IDs and object-symbol correlation; add a test that checks map rows against generated C and LLVM object symbols. |
| `[~]` | Production package manager | `tools/toolchain/mcc-pkg.sh`, `pkg-test`, and `llvm-pkg-test` cover local manifests, recursive deps, version checks, and build. README/spec still leave registry and release publishing outside the current implementation. | Define registry metadata, version resolution policy, lockfile format, and publish/install commands; add offline registry fixtures. |
| `[ ]` | LSP and formatter | No LSP or formatter implementation is present. | Choose formatter ownership first, then expose parser/sema diagnostics through an LSP server using the same diagnostic codes as `mcc check`. |

## Standard library and MC-C2 profile

| Status | Item | Current code evidence | Next step |
|---|---|---|---|
| `[~]` | `std/mmio` register-field helpers and IO-memory copy | Spec 28.6 explicitly calls `std/mmio` planned; current code uses typed MMIO directly in tests such as `tests/c_emit/mmio*.mc` and QEMU MMIO demos. No `std/mmio.mc` exists. | Add `std/mmio.mc` helpers on top of `Reg`, `RegBits`, `MmioPtr`, and fences; port one driver/demo to the module. |
| `[~]` | Library-scale DMA ownership protocols | `std/dma.mc`, `move` checking, and DMA/cache spec fixtures exist; README says a complete hardware coherence simulation is not implemented. | Add multi-device ownership/state-machine tests and decide whether simulation belongs in std tests, QEMU demos, or host drivers. |
| `[x]` | Generational handle opacity | `opaque struct` (spec §31) makes a struct's fields private to its associated functions (`impl Name`): outside code may hold/pass/return a value but cannot construct, read, or write it (`E_PRIVATE_FIELD`). Membership is the leading owner segment, so it survives generic monomorphization (`GenRef__u8` ↔ `GenRef__resolve__u8`) and textual-inclusion imports. `std/arena.mc` `GenRef<T>` and `std/pool.mc` `PoolRef<T>` are now `opaque`, minted/inspected only through their `impl` accessors, so a handle cannot be forged with a chosen generation/index. Verified: `tests/spec/opaque_field.mc` (plain + generic, construct/read/write) and the `pool-/genref-/wrap-/arena-/net-arena-test` runtime suites all pass. | Optionally extend the same opacity to other capability-bearing structs (page/DMA handles, grant tables). |
| `[x]` | Advanced packed ABI validation | `abi-test` (`tools/toolchain/abi-test.sh` + `tests/toolchain/abi_layout.mc`, wired into `m0`) is a three-layer golden test: MC's comptime layout model folds `sizeof`/`alignof`/`field_offset`/`bit_offset` asserts; the emitted C `_Static_assert`s the *same* sizes/alignments/offsets against clang's real `sizeof`/`_Alignof`/`offsetof` (host C ABI agreement); and it checks the C backend emits `volatile` MMIO registers with the correct `@offset` padding and that the LLVM backend agrees on the overlay byte-array and volatile load/store shape. Covers packed bits (u8/u16), overlay unions (mixed widths), a packed-bits field nested in a struct, an overlay nested in a struct, and an MMIO register block. | Optional: extend the layout model so a packed-bits type may itself be an overlay-union field (currently `UnsupportedCEmission`); add `[N]packed`/nested-array ABI cases. |
| `[~]` | Precise asm per compiler/architecture | Precise asm lowering is covered for current C/LLVM paths; MC-C2 calls out per-compiler/arch precision as advanced work. | Split asm fixtures by target/compiler constraints and add negative tests for unsupported constraint combinations. |

## OS integration roadmap derived from current tests

These are outside the MC language/backend spec finish line, but they are the
next practical OS milestones shown by the current kernel, host, and QEMU tests.

| Status | Item | Current code evidence | Next step |
|---|---|---|---|
| `[~]` | Endpoint-first IPC and blocking semantics | `endpoint-test`, `ipc-test`, `ipc2-test`, `service-test`, and `waitqueue-test` cover endpoint generation, receive filtering, service loops, and wait queues; raw pid paths still exist. | Mark raw-pid send/call as legacy and make blocking send/call return `Result` or timeout on dead/full targets. |
| `[~]` | Process lifecycle integration | QEMU tests cover process spawn/wait, exec, U-mode, ELF run, vmspace/vmctx, COW, demand paging, and scheduler integration. | Connect fork/exec/wait, fd inheritance, address-space lifecycle, and child-exit waitqueue wakeups into one production path. |
| `[~]` | User-mode service graph | Supervisor, registry v2, manifest, heartbeat/restart, liveupdate, userserver, fs-server, block-server, and net-server tests exist. | Add dependency graph ordering, quiescence, endpoint generation handoff, and restart/live-update compatibility checks. |
| `[~]` | VFS/POSIX completeness | VFS, fdspace, ramfs, diskfs, blockfs, pipes, permissions, shell, libc core, and fs syscall tests exist. | Add nested directories, inode metadata, `stat`, `readdir`, `dup`, `ioctl`, and external program execution from diskfs. |
| `[~]` | Network service completeness | UDP sockets, TCP parser/state/reasm/rtx/window, socket syscall, net server, virtio-net, and live RX tests exist. | Connect TCP to the socket syscall API, add ARP cache/routing/DHCP/DNS, and make IRQ-driven RX the default path. |
| `[~]` | Multi-architecture production path | RISC-V QEMU, OpenSBI, aarch64 boot, x86 boot/scheduler, SMP, IPI, and spinlock tests exist. | Add per-arch trap/paging/interrupt parity, real scheduler SMP integration, and TLB shootdown. |
