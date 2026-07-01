# Performance refactor plan

Status: **proposal / awaiting approval**. Owner: perf refactor. Baseline: master @ `01424e1` (m0 green, both backends).

This plan turns a four-surface performance review (compiler, kernel runtime, generated code,
WASM+std+build) into a phased, measurable, parity-gated refactor. Every finding below carries a
`file:line` anchor from the review and an impact/effort/risk estimate.

## Guiding rules

1. **Measure first, always.** No optimization lands without a before/after number from a repeatable
   benchmark. Phase 0 builds that harness; nothing else starts until baselines exist.
2. **Correctness is non-negotiable.** Every change must keep `m0` green on **both** backends (C + LLVM)
   and must not weaken the hardening suite (bounds/overflow/typestate checks). Codegen changes are
   parity-gated.
3. **Land small, land verified.** One optimization per commit, each with its benchmark delta in the
   message. Prefer reversible, additive changes; keep risky algorithmic swaps behind a flag until proven.
4. **Impact × breadth first.** A change on a path used by everything (mem copy, aggregate ABI) outranks
   a bigger win on a narrow path.

## Phase 0 — Measurement infrastructure (prerequisite, ~1–2 days)

You cannot refactor for performance without numbers. Build these first:

- **Per-gate compile-vs-runtime split.** `.wamr-cache/step-times.tsv` only has total wall time
  (WASM/build review C#8). Split each timed step into compile / link / QEMU-boot / run so we know where
  time actually goes. Extend `tools/toolchain/timed-step.sh`.
- **Microbenchmark harness.** A new `bench` tier: small MC programs that exercise one hot path
  (mem_copy of N bytes, M IPC round-trips, K heap alloc/free cycles, sbrk of P MiB, a WASM compute
  kernel) and print cycle counts via the existing `MC_TIME_STEPS` / rdcycle. Runs under QEMU, both
  backends, recorded to a `bench-baseline.tsv`.
- **Compiler self-timing.** `MC_TIME_PASSES=1` to dump per-pass wall time in `mcc` (lexer/parser/sema/
  monomorphize/lower). Establishes the compile-time baseline for Phase 1's compiler work.

Exit criteria: reproducible baseline numbers for every hot path named below.

## Phase 1 — Quick wins (low effort, broad impact, ~3–5 days)

| # | Change | Evidence | Impact | Risk |
|---|--------|----------|--------|------|
| 1.1 | **Word-aligned `mem_copy`/`mem_set`/`memmove`** — copy 8-byte words for the aligned bulk, byte tail for the ends. | `std/mem.mc:57-86`; `kernel/lib/freestanding.mc` (memcpy/memmove/memset) — flagged by BOTH kernel and std reviews | **6–8× on large copies**; touches ELF load, DMA, CoW, uaccess, **and every generated aggregate copy** (codegen emits these). Single highest-ROI change. | Low — pure impl swap behind existing tests; add a mem-bench + correctness gate (overlap, unaligned, tail). |
| 1.2 | **Enable `WASM_ENABLE_FAST_INTERP=1`** (direct-threaded dispatch). | `third_party/wamr/core/config.h:289`; add to `tools/lang/wamr-run-test.sh` WDEF | **~20–30% WASM interp speedup**; helps every qjs/wasm gate incl. the slow arm-qjs (134s). | Low–Med — must re-run the full WASM/JS gate family (both backends, S-mode, cross-arch) to confirm parity; keep classic interp as fallback flag. |
| 1.3 | **Reuse the compiler's `FixedBufferAllocator`** instead of re-creating a 64 KiB buffer per call in 7 hot sites. | `src/array_len.zig:64`, `src/monomorphize.zig:642`, `src/sema.zig:1148,1726`, `src/lower_c_emitter.zig:629`, `src/lower_llvm.zig:794`, `src/lower_llvm_reflect.zig:72` | **10–30% compile time** on generic-heavy modules. Faster dev iteration + m0. | Low — cache the buffer on the Checker/Rewriter/Lowerer struct. |
| 1.4 | **Mailbox O(1) take** — maintain a head/oldest pointer instead of the O(N) `oldest_slot` scan per take/post. | `kernel/lib/mailbox.mc:37-83` | 5–10% IPC latency; hot on every send+receive. | Low–Med — invariant care; covered by ipc/instrument gates. |
| 1.5 | **Provenance emit off the hot send path** — branchless sample check + default-disabled in production. | `kernel/core/proc_ipc.mc:68-80` (called at :191) | 5–15% IPC send latency when provenance on. | Low. |

## Phase 2 — Algorithmic / data-structure fixes (medium effort, ~1–2 weeks)

| # | Change | Evidence | Impact | Risk |
|---|--------|----------|--------|------|
| 2.1 | **Heap: kill the O(n²) coalesce.** Keep free blocks address-sorted (O(log n) neighbor find) or move to segregated-fit/buddy. | `kernel/core/heap.mc:157-230` (multi-pass scan over 64 slots per free) | 20–40% `heap_free` latency under fragmentation; steadier alloc/free. | Med — allocator swap; parity-gate + soak-test (already exists) + fragmentation bench. Behind a flag until proven. |
| 2.2 | **Scheduler run queues** — per-state/priority queues so `next_runnable`/`sched_next_priority` are O(1), and a per-parent child list so `proc_supervisor_scan` is O(children) not O(MAX_PROCS²). | `kernel/core/proc_sched.mc:19,210,683` | 20–50% context-switch latency; supervisor tick amortized. | Med — scheduler correctness; heavy gate coverage exists (preempt/scheduler/supervisor). |
| 2.3 | **`sys_sbrk` bulk map + batched TLB flush** — one `sfence.vma` per batch (or per grow) instead of per 4 KiB page; prefault interior tables. | `tests/qemu/proc/app_run_demo.mc:846-857` (16k iters + 16k fences for a 64 MiB grow) | **~20× on large grows** (~100 ms → ~5 ms). Directly helps the demand-grown-heap work. | Med — TLB-correctness; sbrk-grow/sbrk-cap gates + a large-grow bench. |
| 2.4 | **uaccess single-pass validate+copy** — cache the check pass's page translations and reuse in the copy pass instead of walking the page table twice. | `kernel/core/uaccess.mc:269-360` | 30–50% large-copy latency. | Med — **must preserve the re-validate-under-SMP contract**; keep double-validate when preemption/SMP is on, single-pass only in the cooperative case. |
| 2.5 | **Compiler: type-query memoization + conformance-map flatten.** Cache `resolveAliasType`/`classifyType`/move-type checks; replace nested trait-conformance double-lookup with a combined key. | `src/sema.zig` (178 type-query calls), `src/sema_move.zig`, `src/monomorphize.zig:598-605,304-430` | 5–15% compile time (adds to 1.3). | Low–Med. |

## Phase 3 — Codegen quality (medium–high effort, ~2–3 weeks; deepest, highest ceiling)

MC deliberately offloads optimization to clang/llc, which is sound for portability but leaves
*redundant* operations MC emits that the backend can't always recover. These are parity-gated and the
biggest long-term lever for generated-code speed.

| # | Change | Evidence | Impact | Risk |
|---|--------|----------|--------|------|
| 3.1 | **sret for large aggregate returns** — return structs >16 B via a hidden out-pointer instead of temp+`__builtin_memcpy`. Critical for `Result<T,E>` propagation chains. | `src/lower_c_call.zig:206-248` | 5–15% call overhead on aggregate-returning fns. | Med — ABI change; parity-gate both backends, full m0. |
| 3.2 | **Overlay-union memcpy narrowing** — copy only the accessed field's bytes, not `sizeof(union)`; direct load/store for scalar arms. | `src/lower_c_overlay.zig:52,90,113,129,151,183` | 30–50% on overlay ops (hot in TLS/crypto/secret types). | Low–Med — backend-only. |
| 3.3 | **MIR-level optimizer pass** — const-fold, DCE of sema-proven-unreachable code, block-local CSE, before lowering. | no MIR optimizer today; `src/lower_c_const.zig` only folds static inits | 3–10% code size, 5–15% compile time (fewer instrs to lower), cleaner IR for both backends; especially async/monomorphized output. | Med — new pass; must not change semantics (differential-test vs unoptimized emit). |
| 3.4 | **Bounds/overflow-check elision via range facts** — light interval analysis so `if (i<len) arr[i]` and proven-nonzero divisors elide the runtime check. | `src/mir.zig:2100-2108` (only literal ranges today); usage `src/lower_c_emitter.zig:3381,3924` | 10–20% in check-heavy loops (crypto/parsing/iteration). | Med — **must stay sound**: only elide on proven facts; hardening-suite must not weaken; parity-gate. |
| 3.5 | **Async future = union of children** — one tagged union slot instead of N per-await child fields (only one child is live at a time). | `src/async_lower.zig:12-24` | 20–50% future-struct size on deep await chains. | Med–High — union tagging soundness; async gate family must stay green. |
| 3.6 | **Tier-2 `*dyn` dispatch inline hints** on generated thunks/vtable wrappers. | `src/lower_c_dispatch.zig:162-175`, `src/lower_llvm.zig:3110-3118` | 5–10% on dyn-dispatched tight loops (Tier 1 already zero-cost). | Low. |

## Phase 4 — WASM deep + stretch (scoped separately)

- **4.1 WASM linear-memory growth without O(n) copy.** `tools/wamr/mc-platform/mc_platform.c:61` (`os_mremap`
  memcpy) + WAMR's realloc-the-whole-buffer growth. This is the same wall hit in the demand-grown-heap
  Increment 3: the real fix is kernel page-fault demand-paging + a reserve-max/commit-on-grow linear
  memory (WAMR mmap mode). Large, dependent on Phase 2.3. Tracked in `demand-grown-heap` notes.
- **4.2 Instruction-metering as a build variant** — keep on by default (confinement), offer a
  metering-off variant for trusted/non-fuel workloads (~5–8%). `tools/lang/wamr-run-test.sh:90`.

## Sequencing & effort

```
Phase 0 (measure)  ──►  Phase 1 (quick wins)  ──►  Phase 2 (data structures)  ──►  Phase 3 (codegen)
                                    └──────────────►  Phase 4 (WASM deep, parallel-able after 2.3)
```

Recommended cut for a first, high-confidence slice: **Phase 0 + Phase 1**. It's ~1 week, low risk, and
captures the two cross-cutting wins (word-aligned mem ops touching all of runtime + generated code; fast
interp touching all WASM) plus the compile-time speedup that makes every later phase faster to iterate.

## What NOT to do (explicit non-goals)

- No JIT/AOT for WASM (breaks W^X / determinism / audit replay — architectural).
- No giving up the C backend for LLVM-only (portability is a core property).
- No weakening the hardening suite for speed — check *elision* only on proven facts (3.4), never blanket removal.
- Don't chase the arch-QEMU gate times (arm-qjs 134s) — that's TCG emulation, an infra/parallelism concern, not an algorithm.

## Success metrics (fill from Phase 0 baseline)

- `mem_copy` throughput (bytes/cycle) — target ≥6× on ≥4 KiB copies.
- WASM compute bench (cycles) — target ≥20% faster with fast-interp.
- `mcc` compile time on a generic-heavy module — target ≥15% faster (Phase 1.3 + 2.5).
- IPC round-trip latency — target ≥10% faster (1.4 + 1.5).
- `heap_free` under fragmentation — target ≥25% faster (2.1).
- `m0` stays green both backends at every step; hardening gates unchanged.
