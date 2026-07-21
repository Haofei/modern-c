# C / Rust / MC virtio-rng experiment plan

Status: M0-M3 validated; M3.5 C-core control passes the current normal,
sanitizer, fault, suspend/restore, QMP transport hotplug, and three-architecture
KUnit gates; M4 remains blocked on the remaining candidate-control gates,
2026-07-20

Upstream target: Linux `v7.2-rc4`, commit
`1590cf0329716306e948a8fc29f1d3ee87d3989f`, which was both Torvalds `master`
and the latest mainline tag when the environment was created. The working
checkout is `/home/zoe/src/linux`, on branch `vrng-lang-experiment`;
experimental commits belong there, not in this repository. The current Linux
experiment commit is `2ed40c97aa7a0401ce9ef545af8fc9e1d421ae6f` (`docs: record
virtio-rng lifecycle stress gates`), based directly on the
upstream commit above. The prior M3 and initial M3.5 evidence was recorded at
`14a52a42241f` and `83a4ba9acbf6`, respectively.

Publication status: the M3 compiler changes, experiment plan, and
reproducibility tools were published in `Haofei/modern-c` at commit `3a06b1ab`.
The current Linux experiment is published at commit
`2ed40c97aa7a0401ce9ef545af8fc9e1d421ae6f` on
`Haofei/linux:vrng-lang-experiment`.

Current checkpoint:

- P0 ABI v1 is implemented and has been tightened after review: every non-null
  output is initialized first, followed by output-set, state, data-pointer,
  lifecycle, and phase validation. Pointer extent, alignment, aliasing, locking,
  IRQ eligibility, and nospec placement are normative in the shared header.
- M1's C, Rust, and MC candidates match the specification in directed and
  depth-seven BFS exploration at capacity three.
- M2 passes 12/12 tests on x86-64, arm64, and riscv64 QEMU kernels. The x86-64
  suite also passes KCSAN and a combined KASAN/UBSAN/lockdep configuration.
  C, Rust, and MC cross-build into correctly targeted objects on all three
  architectures.
- M0 is closed: MC's Linux-kernel LLVM profile produces objtool-clean x86 code
  with IBT/return thunks, no `.eh_frame`, and no hidden runtime helpers; arm64
  and RISC-V objects have no undefined symbols.
- MC's completion call graph satisfies `#[irq_context]`, but `#[no_lang_trap]`
  currently rejects C-layout `extern struct` field access as a possible
  `InvalidRepresentation` trap. This is preserved as an explicit language gap.
- The arm64 runtime exposed a missing MC BTI landing pad that object-only builds
  did not detect. The Linux LLVM profile now emits arm64 BTI attributes/module
  metadata, and Kbuild tracks both the `mcc` launcher and `mcc-real`.
- M3's published normal, KCSAN, and KASAN/UBSAN/lockdep runs each reported
  59,774 matching C/Rust/MC model events. Those runs did not compare model
  decisions with the original live-driver decisions and are retained only as
  normal-path cross-language evidence.
- M3.5 now makes the experimental C core control live completion, copy, and
  resubmission decisions. Rust and MC remain shadows. The glue uses request
  cookies whose contents remain immutable while queued, propagates queue-add
  failure, retries from preallocated work after an error is observed, recovers
  zero/oversize/stale completions, and serializes process transactions against
  removal. Fatal errors are persistent across readers, controlling-core copy
  outputs are validated before publication, and every controlling transition
  must exactly match an independent executable-specification state. Probe and
  restore ownership state is explicitly unwound and synchronized. The normal
  x86-64 gates include full and shadow-disabled KUnit, a forced driver-level
  partial-copy live path, synchronized blocked-reader unbind, KCSAN, and a
  combined KASAN/UBSAN/lockdep/DMA-debug configuration. The full 23-test suite
  passes on x86-64, arm64, and riscv64. A deterministic live matrix recovers
  from zero-length and oversized completions, stale generation, and queue-add
  failure without a mismatch or kernel diagnostic. A PM-debug live run also
  completes three device-level suspend/restore cycles and restores live reads
  after each cycle before synchronized unbind; the same matrix passes under
  KCSAN. A QMP PCI hot-unplug terminates a blocked reader, removes and re-adds
  the transport, restores live reads, and then passes synchronized unbind with
  zero mismatches.
- The host differential gate links the executable specification and the actual
  C, Rust, and MC implementations, explores 30 unique states to depth seven,
  and replays committed `.vrng` event corpora. A synthetic C mismatch proves
  that the shortest failing path is persisted deterministically and reproduces
  under replay.
- The MC representation-proof gap, selectable Rust/MC control, and later
  milestones remain open.

## 1. Question and scope

The experiment asks which defects C, in-kernel Rust, and MC prevent, detect, or
leave expressible when implementing the single-buffer virtio-rng protocol.

M1-M4 compare a **logical buffer and virtqueue protocol state machine**. They do
not claim language-enforced ownership of the physical DMA allocation: the common
C glue still allocates, maps, queues, resets, and frees that buffer. Real
Rust/MC-owned DMA handles are a later, separately reported experiment.

The experiment must not use the C implementation as the correctness oracle. A
small executable specification is the oracle; C, Rust, and MC are three
implementations checked against it.

Excluded from the first comparison:

- a rewrite of the whole Linux driver;
- changes to `virtio_ring.c` or transport internals;
- callbacks crossing directly into an unstable aggregate/function-pointer ABI;
- language-owned DMA allocation before the logical protocol is stable;
- claims that checked arithmetic alone mitigates speculative execution.

## 2. Fixed architecture

The common C/Linux glue owns:

- `struct virtio_driver`, `struct hwrng`, PM callbacks, and Linux error/logging;
- the virtqueue and the C callback entry point;
- DMA buffer allocation, alignment/group annotations, mapping, and freeing;
- request cookies passed to `virtqueue_add_inbuf()`;
- completion wakeups and hot-remove lifetime synchronization;
- one spinlock serializing core state transitions;
- process-context serialization between read/resubmit and removal;
- fault injection, preallocated tracing, and shadow-mode arbitration.

Each language core owns exactly the same pure protocol decisions:

- legal phases and transitions;
- generation/epoch validation;
- produced-length validation;
- checked index/remaining-length calculations;
- how much may be copied;
- whether a new request is required;
- deterministic error mapping and invariant validation.

The state is never concurrently entered by two core calls. The C glue enforces
that condition before Rust constructs an exclusive reference or MC mutates the
state. IRQ-callable core functions must be non-blocking, allocation-free,
bounded, and trap/panic-free.

## 3. State and ABI contract

Use two conceptual dimensions rather than pretending logical removal instantly
drains a virtqueue:

```text
Lifecycle: Active | Quiescing | Dead
Buffer:    Empty | DeviceOwned(generation) | Ready(generation, index, available)
```

`Quiescing` forbids new access/submission but may coexist briefly with a device
owned descriptor. `Dead` is entered only after device reset and `del_vqs` have
drained the queue.

Required transitions:

```text
Active/Empty
  --begin_submit(generation)--> Active/DeviceOwned
  --abort_submit(generation)--> Active/Empty       [queue add failed]

Active/DeviceOwned
  --complete(valid nonzero)--> Active/Ready
  --complete(zero/oversize)--> Active/Empty + resubmit/error

Active/Ready
  --partial copy--> Active/Ready
  --final copy----> Active/Empty + resubmit

Active/*
  --begin_remove--> Quiescing/*
  --reset + del_vqs in C glue--> Dead/Empty
```

The glue performs `begin_submit` before publishing the descriptor. If
`virtqueue_add_inbuf()` fails it calls `abort_submit`. This closes the failure
rollback hole while making an early device completion observe DeviceOwned.

The request token is an embedded C cookie containing a device pointer, epoch,
`u64` generation, and test-only request identifier. The callback obtains the
cookie from `virtqueue_get_buf()` and passes its generation to the core. A
generation is never inferred from mutable current state. This contract trusts
the virtqueue to map a used entry to its currently outstanding token. It does
not claim to identify arbitrary used-ring replay after descriptor/token reuse;
the local stale injection validates generation rejection, not transport-level
replay resistance.

Proposed direct-call ABI:

```c
int vrng_core_init(struct vrng_core_state *state, u32 capacity, u64 epoch);

int vrng_core_begin_submit(
    struct vrng_core_state *state,
    u64 *generation);

int vrng_core_abort_submit(
    struct vrng_core_state *state,
    u64 generation);

int vrng_core_complete(
    struct vrng_core_state *state,
    u64 generation,
    u32 produced,
    u32 *need_resubmit);

int vrng_core_copy(
    struct vrng_core_state *state,
    const u8 *dma_buffer,
    u8 *destination,
    u32 requested,
    u32 *copied,
    u32 *need_resubmit);

int vrng_core_begin_remove(struct vrng_core_state *state);
int vrng_core_finish_remove(struct vrng_core_state *state);
int vrng_core_validate(const struct vrng_core_state *state);
```

Every function defines and implements this validation order:

1. initialize every non-null writable output;
2. validate that the complete output-pointer set is present;
3. validate the state pointer and representation;
4. validate remaining pointer presence;
5. apply lifecycle and phase rules;
6. perform the transition.

Extents, alignment, and non-aliasing are caller preconditions. For `copy`, the
state object, every output object, the DMA source range, and the destination
range are pairwise non-overlapping. The shared contract also defines:

- which lock/lifecycle preconditions C must satisfy;
- whether it is IRQ-callable (`complete` and transactional `abort_submit` are);
- state and output values on every error;
- no partial mutation on rejected transitions unless explicitly specified;
- exact errno mapping;
- pointer alignment, validity, and non-aliasing requirements.

The shared header includes size, alignment, and offset static assertions. Rust
uses `#[repr(C)]`; MC and Rust implementations export unique, prefixed symbols
so all implementations can coexist in shadow builds.

## 4. Normative invariants

For every observable state:

```text
capacity > 0
index <= capacity
available <= capacity
index + available <= capacity       [checked, never wrapping]
```

Additional rules:

- Empty has `index == 0` and `available == 0`.
- DeviceOwned exposes no language-side CPU read operation.
- Ready has `available > 0`; only Ready may copy DMA bytes.
- Quiescing rejects submit, copy, and blocking waits.
- Dead has no queued request and accepts only validation/idempotent teardown.
- `copied <= requested`, `copied <= available`, and all output pointers are
  initialized on both success and failure.
- Invalid, zero-length, stale, duplicate, and post-remove completions have
  separately specified outcomes.
- Backend-provided indices and lengths are never used as speculative array
  selectors without an explicit nospec decision in the common boundary.

## 5. Repository layout in the Linux experiment branch

```text
drivers/char/hw_random/virtio_rng_lang/
├── Kconfig
├── Makefile
├── README.rst
├── vrng_core_abi.h
├── vrng_core_spec.c
├── vrng_core_c.c
├── vrng_core_rust.rs
├── vrng_core_mc.mc
├── vrng_linux_glue.c
├── vrng_shadow.c
├── vrng_trace.h
└── vrng_kunit.c

tools/testing/selftests/virtio_rng_lang/
├── Makefile
├── exhaustive.c
├── qemu-smoke.sh
├── qmp-hotplug.sh
├── stress.sh
└── perf.sh
```

Generated MC `.o`, LLVM IR, maps, and disassembly go under the out-of-tree build
directory. Architecture-specific binary objects are never committed as source.

Kconfig provides one controlling implementation choice plus an independent
shadow option. Shadow mode clones pre-event state, gives each implementation a
private canary destination, compares results, state, declared output, copied
bytes, and untouched tails, records a bounded event trace, and publishes only
the validated reference output to the real destination.

## 6. Milestones and gates

### P0 — freeze the experiment contract

Deliverables:

- this plan copied or linked from the Linux experiment branch;
- versioned ABI header and errno table;
- executable state-transition specification;
- threat model: buggy or malicious protocol-conforming backend,
  guest-root-triggered races, hot-remove/reset, and non-coherent DMA platform;
- trusted transport boundary: the virtqueue maps each used entry to its current
  outstanding token; arbitrary used-ring identifier replay after token reuse is
  not claimed by the local generation-cookie defense;
- explicit statement of what remains trusted in C glue.

Gate: every event has one deterministic state/result definition, including
zero, oversize, duplicate, stale, add failure, remove, and reset.

### M0 — toolchain and direct-call Kbuild proof

Build one trivial C-callable scalar MC function into the kernel for x86-64,
arm64, and riscv64. Verify:

- kernel code model and flags, no red zone or floating-point/SIMD use;
- stack protector, CFI/KCFI, unwind metadata, and symbol visibility behavior;
- `modpost`, objtool where supported, `llvm-readelf`, and `llvm-objdump`;
- no undeclared runtime symbols, allocation, constructors, or trap helpers;
- a KUnit direct-call test returns the expected scalar result.

Gate: all three architectures build; x86-64 boots and executes the call. Any
unsupported hardening mode is recorded, not silently disabled.

### M1 — executable specification and host differential engine

Implement the spec model first. Add C, Rust, and MC cores without Linux device
calls. Generate events over small abstract capacities and use BFS with state
deduplication rather than only fixed-depth brute force.

Event families:

- init, begin/abort submit, valid completion, zero completion, oversize
  completion, partial/final/zero copy;
- add failure, duplicate completion, wrong generation, generation limit;
- begin/finish remove and reset/new epoch;
- boundary values around 0, capacity, `U32_MAX`, and `U64_MAX`.

Gate: each implementation matches the spec for all explored states; mutation
and outputs on error satisfy the transaction contract. Coverage includes every
transition and error class.

### M2 — KUnit integration

Compile all three cores into one kernel configuration with distinct symbols.
KUnit runs the same vector corpus against each implementation and the spec.
Add deterministic interleaving tests using completions/barriers, but treat KCSAN
stress—not KUnit alone—as the data-race authority.

Gate: x86-64 KUnit passes under normal, KASAN, UBSAN, and KCSAN-oriented builds.

### M3 — real driver shadow mode

Add the common C glue beside the production driver. The original production C
path controls the queue and data decisions. Candidate calls consume cloned
state and private output.
Tracing is fixed-size and preallocated; IRQ mismatches are rate-limited and
detailed reporting is deferred to process context.

Gate: sustained `/dev/hwrng` reads produce zero mismatches for each candidate;
shadow mode adds no sleeping/allocation warning in callback context.

Status: normal-path language-model agreement passed on x86-64 QEMU with the
built-in RNG backend. The normal, KCSAN, and memory/locking sanitizer kernels
each mirrored 59,774 events with zero language-model mismatches. This does not
establish semantic equivalence with the original live-driver decisions.

### M3.5 — experimental C core controls live logic

The experimental C core controls logical submission, completion, copy, and
resubmission. Rust and MC consume the same events as shadows. Common C glue owns
the virtqueue and DMA allocation and provides:

- device/epoch/generation/request cookies that remain immutable while queued;
- probe failure on initial queue-add failure and deterministic runtime retry;
- process-context resubmission for zero/oversize/stale completions;
- persistent fatal-device handling when submission rollback, consumed-
  completion recovery, or controlling-core output validation fails;
- pre-publication comparison of every C controlling return, output, post-state,
  and copied byte against the executable specification, with positive returns
  and any divergence converted to persistent `-EPROTO`;
- one process mutex covering copy/resubmit and the begin-remove boundary;
- a documented lock order: process mutex before a core call; core spinlock is
  never held while taking the process mutex;
- completion-length, stale-generation, and queue-add fault-injection controls;
- full restore-registration failure unwind for queue, work, and core state;
- a held-completion synchronization point for deterministic blocked-reader
  removal tests.
- a test-only copy chunk limit that forces repeated driver-level partial copies
  from one completion; user-space `dd bs=1/3/7` alone exercises hwrng buffering
  and is not accepted as evidence for this driver path.

Gate: pointer/state/output cross-product KUnit tests pass for all languages;
blocked-reader unbind, injected completion errors, queue-add failure, normal,
KCSAN, and KASAN/UBSAN/lockdep QEMU runs pass with no kernel diagnostics.

Status: the full suite passes 23/23 KUnit tests on x86-64, arm64, and riscv64;
the shadow-disabled x86-64 suite passes 11/11. Forced driver-level three-byte
partial-copy live tests pass in both x86-64 configurations. The normal,
KCSAN, and combined KASAN/UBSAN/lockdep/DMA-debug shadow runs reached the held-
completion synchronization point before unbind with 1,213, 1,213, and 1,216
matching protocol events, respectively. The deterministic live fault matrix
recovered from zero-length and oversized completions, a stale generation, and
one queue-add failure with 1,243 matching events and no kernel diagnostic. The
PM-debug live gate completes three device-level suspend/restore cycles,
restores live reads after each cycle, and then passes synchronized unbind with
zero mismatches; the same lifecycle matrix also passes under KCSAN. The QMP
transport gate deletes a PCI device while a reader is blocked, observes the old
instance close after 1,213 matching events, re-adds the device, restores live
reads, and closes the new instance after 106 matching events. The host gate
also explores 30 unique protocol states across the executable specification
and all three implementations, replays every committed corpus, and proves
deterministic capture/reproduction with an injected mismatch. M4 remains
blocked on the MC representation-proof gap and the candidate-control gates
below.

### M4 — selectable controlling core

Enable the C/Rust/MC Kconfig choice. The glue uses begin/abort submission,
generation cookies, core locking, and two-stage removal. Test queue-add failure
and every completion error while the candidate controls the device.

Gate: normal reads, partial reads, nonblocking reads, unload/hot-unplug, and
suspend/restore pass independently for all implementations.

### M5 — concurrency and memory-order experiment

Start from the common-lock baseline. Then change one synchronization dimension
at a time: published Ready phase, completion wakeup ordering, and any language
atomic wrapper. Express the intended outcome as LKMM litmus tests before
replacing the lock-protected publication path.

Gate: litmus tests prohibit the bad outcomes; KCSAN stress finds no race; lockdep
and DEBUG_ATOMIC_SLEEP remain clean. Results distinguish CPU memory ordering
from DMA/cache maintenance supplied by virtio and the common glue.

### M6 — genuine DMA ownership experiment

Only after M4 is stable, create a separate variant in which the language core
retains an opaque persistent buffer handle. For MC, use `CpuBuffer` and
`DeviceBuffer` move states or add a narrowly audited adoption API for a
C-allocated Linux DMA buffer. For Rust, use an owning abstraction whose CPU
slice is unavailable while the descriptor is device-owned.

Gate: the intentionally invalid device-owned read fails at compile time in the
typed variants. If external aliases in C make that guarantee incomplete, report
the exact trusted boundary rather than counting it as a prevented defect.

### M7 — QEMU architecture and lifecycle matrix

Architectures:

- x86-64 with KVM and TCG;
- arm64 with TCG initially, KVM where host hardware permits;
- riscv64 with TCG.

Device/backend matrix:

- `virtio-rng-pci` and applicable `virtio-rng-device` transport;
- `rng-builtin` for reproducibility;
- `rng-random` for host-backed integration;
- fixed QEMU byte/period limits recorded in every result.

Scenarios:

- sustained and multi-process reads;
- QMP hot-unplug/replug;
- module unload/reload where modular;
- suspend/restore;
- delayed, zero, oversize, duplicate, and stale completion injection;
- completion/remove and read/remove stress.

Gate: automated scripts produce TAP/JUnit-style results and retain kernel log,
QEMU command line, config, compiler versions, and exact commits.

### M8 — deliberate defect campaign

Maintain one small patch per defect. Record compile result, diagnostic, runtime
detector, and whether the defect lies outside the language-owned boundary.

Required defects:

- wrapping index/available/generation arithmetic;
- CPU read while logically and genuinely device-owned;
- oversized and zero completion;
- missing acquire/release or lock;
- blocking/allocation/unbounded loop in callback;
- MC trap and Rust panic-capable callback path;
- double/stale completion;
- remove-after-reference/use-after-free;
- cacheline sharing and missing non-coherent maintenance;
- speculative index hardening omission.

Gate: results are reproducible from named commits; “not expressible by the
language” and “delegated to C glue” are valid, distinct outcomes.

### M9 — performance and engineering evaluation

Measure both isolated core cost and end-to-end behavior. Pin vCPUs, fix governor
and QEMU rate limits, warm up, repeat runs, and report distributions rather than
a single value.

Metrics:

- transition and copy nanoseconds/cycles in a microbenchmark;
- completion-to-wakeup latency;
- `/dev/hwrng` throughput and CPU instructions per 64 bytes;
- branches/misses, maximum stack, `.text/.data`, and runtime dependencies;
- clean/instrumented build time;
- unsafe/FFI/glue lines, manual layouts, diagnostic quality, and debugger stack
  readability.

The initial 95% throughput, 110% callback latency, and 120% text-size figures
are hypotheses/targets, not pass criteria fixed before baseline variance is
known.

Gate: raw data, scripts, environment manifest, and statistical summary are
checked in or archived together.

## 7. Build and test configurations

Keep separate configs rather than enabling every sanitizer simultaneously:

1. `baseline`: release-like comparison build;
2. `kunit`: minimal KUnit/UML or QEMU build;
3. `memory`: KASAN + UBSAN + DMA API debug;
4. `concurrency`: KCSAN with an appropriate preemption/SMP setup;
5. `locking`: PROVE_LOCKING + DEBUG_ATOMIC_SLEEP + debug objects;
6. `hardening`: stack protector, CFI/KCFI where supported, fortify;
7. `size`: stable optimization/debug settings for section comparison.

Every result manifest records `.config`, `make` variables, compiler versions,
QEMU version/arguments, host kernel/CPU, implementation choice, shadow setting,
Linux commit, MC commit, and dirty-tree status.

## 8. Immediate execution order

1. Finish host/container setup and run `make LLVM=1 rustavailable`.
2. Build the current MC compiler and run its existing DMA/IRQ/no-trap tests.
3. Create `vrng-lang-experiment` from the recorded Linux master commit.
4. Write P0 specification, ABI assertions, and error table before driver code.
5. Complete M0 on x86-64, then cross-build arm64/riscv64.
6. Complete host M1 and KUnit M2 before touching the live virtqueue path.
7. Land normal-path shadow M3 and record its limited evidence boundary.
8. Requalify C-controlled M3.5, fault recovery, and blocked-reader removal.
9. Proceed to selectable cores, concurrency, and genuine DMA ownership only as
   their preceding gates pass.

## 9. Stop/review conditions

Pause the next milestone and document the issue if:

- MC requires an undeclared runtime, trap edge, executable stack, unsupported
  relocation, or architecture-specific checked-in object;
- Rust or MC FFI requires concurrent exclusive access to shared state;
- a proposed ownership claim is defeated by a surviving C alias;
- shadow mode changes queue behavior or timing enough to invalidate comparison;
- a sanitizer failure cannot be reduced to a deterministic event sequence;
- a performance claim is dominated by QEMU throttling or backend entropy cost.

These are experimental findings, not reasons to hide or route around a result.
