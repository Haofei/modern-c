# Kernel language comparison plan: C, Rust, and MC

Status: **K1 evidence complete for the bounded virtio-rng contract scenario.
K2 has reproducible cost and protocol-core performance measurements but is not
satisfied: the bounded MC microbenchmark is now within the predeclared material-
regression limit, but the TCB/reviewer/full-driver comparison is incomplete.
K3-K4 remain unclaimed**.

This document defines the evidence required to support a narrow claim:

> MC can be more suitable than C, and more direct than Rust in selected kernel
> machine-contract scenarios, when it provides stronger compile-time guarantees
> with a smaller trusted and annotation boundary and no material runtime cost.

It does not define compiler production readiness or appliance-kernel production
readiness. Those remain owned by:

- [`compiler-production-readiness.md`](compiler-production-readiness.md) for the
  qualified `mcc` supported subset;
- [`production-readiness-plan.md`](production-readiness-plan.md) for the focused
  agent-kernel product;
- [`virtio-rng-language-experiment-plan.md`](virtio-rng-language-experiment-plan.md)
  for the first C/Rust/MC protocol experiment.

The canonical T/M/P phase status lives only in
`compiler-production-readiness.md`. This document consumes those closure results;
it must not maintain a competing completion count.

The current bounded developer measurements and their negative K2 conclusion are
recorded in [`virtio-rng-comparison-evidence.md`](virtio-rng-comparison-evidence.md).

## 1. Claim boundary

### 1.1 Intended claim

MC is not intended to win by being a generally safer systems language than Rust
or by adding more surface syntax than C. Its differentiated target is a
**kernel machine-contract language** with first-class, auditable, zero-extra-
runtime-cost mechanisms for:

- explicit arithmetic domains;
- physical, virtual, DMA, MMIO, and user address classes;
- linear hardware and registration resources;
- DMA/cache ownership transitions;
- IRQ, atomic-context, sleep, trap, and bounded-execution constraints;
- explicit atomics, fences, and memory-order decisions;
- fail-closed ABI, representation, and lowering admission.

The comparison succeeds only if those mechanisms reduce hidden machine
contracts, trusted code, or reviewer burden relative to realistic C and Rust
implementations.

### 1.2 Claims explicitly out of scope today

Until the compiler readiness ledger closes or explicitly scopes the relevant
design risks, do not claim that MC has:

- stronger general memory or lifetime safety than Rust;
- a general borrow checker or complete alias model;
- safe concurrency for arbitrary shared-memory programs;
- greater Linux integration, ecosystem maturity, or production experience;
- better performance without controlled measurements;
- general superiority over C or Rust for systems programming.

The permitted current description is:

> MC is a qualified-subset research prototype exploring direct language support
> for kernel-specific machine contracts.

## 2. Compiler qualification prerequisites

Comparative results are meaningful only when the compiler cannot obtain a
positive result by backend guesswork or by silently accepting an unsupported
program.

### 2.1 Typed semantic authority

The authoritative pipeline is:

```text
source
  -> semantic analysis / typed facts
  -> typed MIR
       type and representation
       provenance and ownership
       effects and safety obligations
       ABI and memory ordering
  -> C and LLVM encoding mechanics
```

The required rule is already normative in the compiler readiness ledger:

```text
complete fact      -> both backends consume it
missing/unknown    -> conservative lowering or stable rejection
stale/retargeted   -> admission failure
backend rediscovery -> forbidden unless registered as mechanics-only policy
```

Comparison work may begin on already closed fact families. A broad MC-contract
claim requires the typed-fact T2 dispositions and the T3/T4 semantic-authority
audit to satisfy the exit rule in `compiler-production-readiness.md`.

The current product surfaces are:

```text
mcc facts
mcc lower-mir
mcc verify
python3 tools/toolchain/semantic-facts-inventory.py
```

Together they expose facts, verify MIR admission, and gate C/LLVM authority
parity; no second set of alias command names is needed.

### 2.2 Place/CFG move authority

Existing `MovePlace`, projection admission, conservative overlap, and bounded
CFG/worklist routes are qualified foundations, not a general borrow checker.
The following requirements are complete for the supported statement/projection
inventory:

- the residual M1.1 formatted-key correctness authority to be retired;
- remaining M2 specialized transfer/merge authority to move to the common
  worklist;
- M4 to prove compatibility strings are indexing/debug data only;
- every unsupported projection to retain a stable diagnostic.

The benchmark must include fields, fixed and dynamic array elements, branches,
loops, early exits, `?`, deferred cleanup, partial initialization, replacement,
interprocedural summaries, and registration/unregistration tokens.

### 2.3 Pointer and shared-memory boundary

For the currently admitted matrix, a dereference must have exactly one declared
policy:

- a positive typed MIR provenance proof;
- race-tolerant conservative lowering;
- diagnosed unsupported source.

P1-P3 already establish this rule for the registered matrix. P4 is triggered
only when semantic-authority or move work exposes a new source-to-dereference
flow. Do not broaden positive provenance merely to increase a coverage number.

This prevents C/LLVM data-race UB from leaking through an absent proof. It does
not by itself prove temporal validity, non-aliasing, or object lifetime.

### 2.4 Temporal-safety boundary

The compiler readiness design-risk track remains authoritative. Before a broad
Rust comparison, MC must implement or explicitly scope high-value escape cases:

- stack, slice, view, closure, async, and arena lifetimes;
- borrows returned or stored across function boundaries;
- references protected by lock, RCU, device, module, callback, timer, or work
  registration lifetimes;
- optimizer semantics of `#[unsafe_contract]`.

A restricted kernel region model is implemented for Stack plus linear Guard,
RCU, Registration, and DMA tokens. Module/device/arena and general inferred
lifetimes remain outside the qualified profile. The exact boundary is in
[`kernel-region-and-ffi-contracts.md`](kernel-region-and-ffi-contracts.md).

## 3. MC-contract capabilities to qualify

These capabilities build on existing language features; they are not a request
to add unrelated syntax.

### 3.1 Linear kernel capabilities

Qualify move-only types for at least:

- `DmaBuffer<CpuOwned>` -> `DmaBuffer<DeviceOwned>` ->
  `DmaBuffer<CpuOwned>`;
- IRQ, timer, callback, and workqueue registration tokens;
- virtqueue descriptors and page ownership;
- lock and preemption guards;
- device/module-owned resources.

For each capability, prove duplicate consume, use-after-move, missing reclaim,
partial aggregate movement, and invalid cleanup are rejected or explicitly
outside the supported subset.

### 3.2 Compositional kernel effects

Extend the existing IRQ/DMA/MMIO/trap contracts through a documented effect
model rather than an independent set of annotations. Candidate effects include:

```text
may_sleep              atomic_context
preempt_disabled       irq_disabled
holds_lock<L>          requires_lock<L>
rcu_read_locked        may_allocate<GFP>
may_fault              user_access
mmio_access            dma_transition
bounded                no_lang_trap
no_unwind              no_recursion
stack_bound<N>
```

The qualification target is transitive propagation through direct and indirect
calls, stable diagnostics for unknown effects, and facts consumed consistently
by both backends. Existing `#[irq_context]`, `#[may_sleep]`, `#[bounded]`, and
`#[no_lang_trap]` evidence is the starting point.

### 3.3 Lock, IRQ, and RCU typestate

Evaluate typed guards and requirements such as:

- data accessible only through the matching lock guard;
- lock-order ranks, while retaining lockdep as a runtime backstop;
- references unable to escape a guard or RCU read-side region;
- CPU-local access requiring the appropriate preemption state;
- callback data outliving its registration token;
- module function pointers unable to outlive unload.

### 3.4 Machine-checkable FFI contracts

An extern boundary should declare compiler-consumable obligations where the
current ABI permits them:

```text
nonnull       aligned<N>       valid_read<N>
valid_write<N>                 nonoverlap
initialized   cpu_owned        device_owned
irq_safe      stable_until<Token>
```

Contract metadata should be usable by compiler admission, static analysis,
KUnit/fuzz harnesses, and debug runtime checks. Comments remain explanatory;
they are not proof artifacts.

## 4. Fair implementation matrix

Every comparative driver must include natural implementations, not only a
shared raw-pointer ABI that suppresses one language's strengths.

| Implementation | Purpose |
|---|---|
| C baseline | Idiomatic Linux-style implementation with normal annotations and runtime tooling. |
| Rust raw FFI | Same low-level ABI and pointer contract as the raw comparison. |
| Rust safe abstraction | Ownership, typestate, safe wrappers, and available kernel abstractions; narrow `unsafe` boundary. |
| MC raw | Minimal direct ABI implementation for backend and calling-convention parity. |
| MC contract | Move capabilities, effects, address types, DMA/IRQ typestate, and checked extern contracts. |

Shared C may own only infrastructure deliberately excluded from the experiment.
If common glue owns publication, teardown, DMA lifetime, or registration, the
result must say that those defects were not compared across languages.

## 5. Driver progression

Use increasing protocol and concurrency complexity:

1. virtio-rng lifecycle and publication repair;
2. simple GPIO or watchdog;
3. I2C/SPI controller subset;
4. virtio-blk queue subset;
5. virtio-net queue subset;
6. NVMe queue subset.

Each implementation must cover, where applicable:

```text
probe and registration
allocation failure and error unwind
interrupt and callback completion
DMA handoff/reclaim and cache maintenance
queue ownership and publication
reset, remove, and callback cancellation
suspend/resume and restore failure
hot-unplug and concurrent I/O/remove
```

The experiment boundary and trusted common glue must be listed before results
are collected.

## 6. Mutation benchmark

Correct programs running successfully are not language-safety evidence. Every
driver stage needs intentional mutations drawn from this taxonomy:

| Mutation class | Representative mutations |
|---|---|
| Linear ownership | Duplicate handoff, use after move, double unregister, missing reclaim, partial-moved aggregate cleanup. |
| Temporal safety | Stack/slice escape, callback after object destruction, timer/work lifetime violation, module pointer after unload. |
| Context/effects | Sleep or `GFP_KERNEL` allocation in IRQ/atomic context, unbounded callback, language trap on IRQ path. |
| Address/access | Physical/MMIO/DMA/user pointer confusion, ordinary load for MMIO, CPU access while device-owned. |
| Concurrency | Missing lock, wrong lock, reversed lock order, RCU escape, missing acquire/release or teardown drain. |
| Arithmetic/input | Overflow, truncation, untrusted length/index, invalid ABI representation. |
| Lifecycle | Probe unwind omission, double teardown, ignored transition error, registration failure leaving invalid bound state. |

Classify every result as:

```text
compile-time rejection
link/admission rejection
runtime diagnostic or sanitizer
test-only detection
not detected
false positive / safe program rejected
```

Mutation tests must demonstrate teeth: change the compiler or contract under
test so at least one known mutation is accepted, and require the gate to fail.

## 7. Measurement model

Correctness counts alone are insufficient. Record:

- source and generated LOC;
- unsafe/raw-pointer LOC;
- extern contracts and trusted assumptions;
- common glue excluded from comparison;
- contract annotation count;
- error-unwind branch count;
- diagnostic actionability and false positives;
- build and incremental-build time;
- object size and maximum stack use;
- runtime throughput, tail latency, and IRQ latency;
- reviewer time to understand the safety argument;
- time to diagnose and repair each mutation.

Report the trusted computing boundary explicitly:

```text
TCB = raw pointer/unsafe code
    + extern contract implementations
    + retained aliases outside typed capabilities
    + handwritten runtime
    + backend and optimizer assumptions
    + shared glue outside the language comparison
```

Do not publish a percentage such as “MC catches 95%” without the per-bug-class
matrix, denominator, false-positive rate, and experiment boundary.

## 8. Evidence and reproducibility rules

Every published result requires:

- pinned compiler, Linux/kernel, QEMU, Rust, LLVM, and herdtools revisions;
- committed configs, source, mutation patches, corpora, and runner scripts;
- both C and LLVM MC backends where the feature is supported;
- missing/stale fact and conservative-fallback tests for relevant MIR facts;
- KUnit plus live fault injection for driver lifecycle claims;
- KASAN, UBSAN, KCSAN, lockdep, DMA-debug, and LKMM where relevant;
- generated object/assembly and stack-usage capture;
- shortest deterministic failure reproduction where possible;
- a clear separation between project-reported and independently reproduced
  evidence;
- external review or independent rerun before a strong comparative claim.

Passing tests do not override an open compiler closure boundary. Conversely, an
accepted, diagnosed, documented limitation can support a narrow claim without
requiring an unrestricted general-language proof.

## 9. Claim ladder

Use the strongest claim whose prerequisites and evidence are satisfied:

| Level | Permitted claim |
|---|---|
| K0 | MC can express and execute the selected protocol. |
| K1 | MC rejects named kernel-contract mutations that C accepts, within a declared supported subset. |
| K2 | MC-contract reduces trusted/implicit contract surface relative to C without material runtime regression. |
| K3 | MC expresses selected DMA/MMIO/IRQ/resource protocols more directly than the matched Rust-safe implementation, with equivalent detected-defect coverage. |
| K4 | Independent complete-driver evidence supports MC for the named device class and deployment profile. |

K3 is not a claim of general superiority to Rust. K4 is not a claim that MC is
ready for unrestricted Linux driver development.

## 10. Execution order

### P0: preserve claim integrity — complete for the supported subset

1. Keep the compiler readiness T/M/P matrices canonical and closed for every
   feature used by an experiment.
2. Complete T2 dispositions, T3 classification, and T4 semantic-authority audit
   required by the selected MC-contract features.
3. Retire residual move formatted-key and specialized CFG correctness authority
   used by the selected capabilities.
4. Trigger pointer P4 only for newly exposed flows and record MIR,
   conservative, or diagnostic policy.
5. Resolve the relevant temporal-safety and `unsafe_contract` design-risk rows,
   or narrow the experiment claim explicitly.

### P1: qualify differentiated mechanisms

6. Complete symmetric MC and Rust DMA typestate variants. **Complete.**
7. Extend and qualify compositional IRQ/atomic/sleep effects. **Complete for the
   current strict IRQ/may-sleep/bounded/no-trap lattice.**
8. Qualify lock/RCU/callback registration lifetimes for one driver. **Complete
   as linear capability-token fixtures; external dispatch remains trusted.**
9. Emit and consume machine-checkable FFI contract metadata. **Complete for
   bounded pointer/slice/address parameter records; arbitrary validity formulas
   remain explicit extern obligations.**

### P2: produce comparative evidence

10. Run the five-implementation matrix on full driver lifecycles.
11. Run the mutation taxonomy with teeth and false-positive controls. **The
    executable bounded slice covers DMA owner access, IRQ sleep/boundedness,
    callback trap freedom, move/resource misuse, restricted RCU/callback/guard
    and stack regions, MMIO ordering/access, and address classes. Missing atomic
    barriers and whole-driver temporal faults remain runtime/model-checking
    cases rather than claimed compile-time detections.**
12. Capture TCB, reviewer-cost, build, codegen, stack, and runtime metrics.
    **Source/object/trusted-marker and optimized protocol-core throughput are
    reproducible now. The result is deliberately not promoted to K2: reviewer
    time, stack/tail/IRQ cost, and full-driver performance remain unmeasured.
    The rotated-median MC microbenchmark is within the predeclared 1.25-times
    material-regression limit relative to both C and Rust on the development
    host.**
13. Repeat under sanitizers, LKMM, hot-unplug, PM, and real-hardware soak.
14. Obtain an independent reproduction and audit.

## 11. Exit criteria

This research plan is complete for a named kernel scenario only when:

- the compiler features used by MC-contract satisfy their canonical closure or
  documented supported-subset limitation;
- all five implementations cover the same declared lifecycle boundary;
- mutation, false-positive, TCB, reviewer-cost, and performance results are
  reproducible;
- common glue and surviving raw aliases are explicitly trusted;
- the conclusion is conditional and no broader than the measured scenario;
- an independent party can rerun the evidence from pinned artifacts.

Until then, report capabilities and qualification evidence, not language
superiority.
