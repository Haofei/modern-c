# Kernel-Language Hardening — Actionable Backlog

A prioritized backlog for hardening MC **as a kernel language** — no hosted runtime, no GC, no
userland allocator, so hardening must be **static** (type system, zero runtime cost), **cheap
dynamic** (the trap model / sanitizers in the QEMU build), or **verification / hardware**.

Two parts: **Part I — Memory & UB**, **Part II — other kernel-language axes** (concurrency, the
trust boundary, parsing, capabilities/IFC, ABI, termination, side channels, fault isolation).
Each item is sized (PR / multi-PR / research) with **What / Where / Test / Prior art / Depends**.
`[ ]` = todo. IDs: Part I uses tier-dotted (`S0.1`, `D2.1`); Part II uses letter (`C1`, `A1`).

## What MC already has (harden the gaps, don't reinvent)
- **Spatial, trapping:** `mc_check_index_usize` (bounds), checked arithmetic, `__builtin_trap`,
  with **proof-based elision** (`range_facts`/`elided_bounds` in `src/mir.zig`).
- **Temporal (partial):** linear `move` types; `move-fuzz` asserts release-exactly-once.
- **Concurrency primitives:** `acquire`/`release`/`atomic`/`fence`/`spinlock`/`mutex`,
  `mc_race_load`/`mc_race_store`; an IRQ controller (`kernel/drivers/irq/plic.mc`), scheduler.
- **Trust boundary primitive:** `kernel/core/uaccess.mc`.
- **Capability primitives:** `Cap<>`, grants (`kernel/lib/granttab.mc`, `std/grant.mc`), `Mask32`.
- **Aliasing UB avoided** via the `memcpy`-reinterpret discipline; typed addresses (`std/addr.mc`).
- **Toolchain oracles:** `sanitize`/`fuzz-sanitize` (ASan+UBSan), `fuzz-trap` (trap-consistency),
  `fuzz-failclosed`, `fuzz-reference` (independent interpreter `tools/fuzz/mcref.py`),
  `fuzz-metamorphic`, `fuzz-determinism`.

The recurring shape: MC has the **mechanisms**; hardening pulls their **disciplines** into the
type system (static) or the trap/sanitizer model (cheap dynamic). The most on-thesis items
(**K**, **T2**) are what let the kernel run *untrusted agent code* with static guarantees.

---
# Part I — Memory & UB

## Tier 0 — Foundations & obvious gaps (cheap, do first)

- [ ] **S0.1 — Definite-initialization analysis** *(PR)* — reading `uninit` before assignment is a
  **compile error**, flow-sensitive. **Where:** sema (`src/hir.zig`). **Test:** `fuzz-failclosed`
  + fixtures; no false positives on the `var x:T=uninit; … x=v;` idiom. **Prior art:** Zig/Rust
  definite-assignment; KMSAN (dynamic counterpart, D2.2). **Depends:** none.
- [x] **S0.2 — Define & enforce the `unsafe` boundary** *(DONE `df72851`; MC already type-enforces `unsafe {}` + `#[unsafe_contract]` via sema `E_UNSAFE_REQUIRED` — added `unsafe-audit` lint + `docs/unsafe-boundary.md` inventory (146 sites, boundary clean). Follow-up: whole-function safe/unsafe effect typing)* — enumerate every
  UB-introducing construct (raw pointer arithmetic, `uninit`, `extern mmio`, memcpy-reinterpret,
  manual `move` overrides) behind an explicit greppable marker; the *safe* subset is provably free
  of them. **Where:** spec + sema. **Test:** safe code contains zero unsafe ops; an audited list of
  unsafe sites in `kernel/`. **Prior art:** Rust `unsafe` + RustBelt; Zig. **Depends:** none.
- [x] **S0.3 — Pin down inherited C UB in the C backend** *(DONE `ef14ee4`; `docs/c-ub-matrix.md` + `-fno-strict-aliasing`/`-fwrapv`/`-fno-delete-null-pointer-checks` on emitted C + 9 UBSan-clean fixtures; only `-fno-strict-aliasing` is load-bearing — MMIO type-pun)* — a UB-class matrix (signed
  overflow, strict aliasing, OOB, shift≥width, INT_MIN/-1, null deref, uninit, eval order): for
  each, "MC forbids / checks+traps / defines away." Emit with `-fno-strict-aliasing`/`-fwrapv`
  where checks don't cover it. **Where:** `src/lower_c.zig` + `tools/toolchain/mcc-cc.sh`. **Test:**
  the matrix + `fuzz-sanitize` clean. **Prior art:** MISRA C, Frama-C, Regehr's UB work. **Depends:**
  none. *(LLVM backend mostly sidesteps this.)*

## Tier 1 — Static type system: temporal safety (highest leverage, zero runtime cost)

- [ ] **T1.1 — Lexical region/scope borrows** *(multi-PR)* — a reference may not outlive the region
  of the value it borrows (catch use-after-scope/dangling). Start lexical. **Where:** borrow pass
  (`src/hir.zig`). **Test:** escaping-reference fixtures rejected (`fuzz-failclosed`); kernel still
  type-checks; `move-fuzz` borrow cases. **Prior art:** Rust borrow checker, Cyclone regions,
  **RustBelt**. **Depends:** S0.2.
- [ ] **T1.2 — Use-after-move for derived aliases** *(PR)* — invalidate any pointer/alias derived
  from a moved-out value (not just double-free of the owner). **Where:** move checker (`src/ir.zig`).
  **Test:** `move-fuzz` stale-alias cases. **Prior art:** Rust move/affine types. **Depends:** T1.1.
- [ ] **T1.3 — Lifetime-parameterized references** *(research → multi-PR)* — for fns returning/storing
  borrows. **Where:** type system. **Test:** differential + `fuzz-failclosed`. **Prior art:** Rust
  lifetimes, RustBelt. **Depends:** T1.1.
- [ ] **T1.4 — Soundness spec for the safe subset** *(doc, research)* — "well-typed safe MC has no
  UB," proof obligations per construct (informal first). **Prior art:** RustBelt, seL4. **Depends:**
  S0.2, T1.1.

## Tier 2 — Cheap dynamic sanitizers in the QEMU build (best near-term ROI)

- [x] **D2.1 — KASAN-style shadow memory** *(DONE `9078889`; opt-in `--checks=ksan`; 1:8 shadow, `raw.load`/`raw.store` instrumented + heap poison-on-free; QEMU demo catches UAF/OOB on ACCESS, both backends. Coverage: heap-tracked raw deref only — array-index/struct-field/stack/MMIO accesses not yet shadowed)* — instrument
  loads/stores against a shadow map; poison freed heap (`kernel/core/heap.mc` free path), redzone
  allocations, trap on poisoned access. **Where:** an emit profile/instrument pass + shadow runtime
  + heap hooks. **Test:** a QEMU boot demo triggering UAF + OOB → trap → `KASAN-OK` (mirror the
  `*-test.sh`/`m0` wiring). **Prior art:** **Linux KASAN**, ASan. **Depends:** none.
- [ ] **D2.2 — KMSAN-style uninit-use detection** *(multi-PR, opt-in)* — shadow-track
  initialized-ness; trap on use of uninit (dynamic complement to S0.1). **Where:** instrument +
  shadow. **Test:** QEMU demo reads uninit heap → trap. **Prior art:** **Linux KMSAN**, MSan.
  **Depends:** D2.1.
- [ ] **D2.3 — KCSAN-style data-race detection** *(multi-PR, opt-in)* — build on
  `mc_race_load`/`store` to detect conflicting concurrent accesses. **Test:** racy demo flagged.
  **Prior art:** **Linux KCSAN**, TSan. **Depends:** D2.1. *(Dynamic complement to Part II/C.)*
- [x] **D2.4 — Guard pages + heap redzones + stack canaries** *(redzones+canary DONE `eed0482`; guard pages deferred — need paging)* — unmapped guard pages around
  stacks, redzone the kernel heap, optional canaries. **Where:** `kernel/core/heap.mc` + stack
  setup. **Test:** stack/heap-overflow demo traps. **Prior art:** Linux stackguard, glibc canaries.
  **Depends:** none.
- [x] **D2.5 — Explicit safe vs release profile** *(DONE `efbe0f4`; `--checks=all` (safe, default) / `--checks=elide-proven` (release); formalizes existing proven-dead elision; `safe-release-parity` gate proves functional equivalence)* — safe keeps all trap checks; release elides
  proven-dead ones (machinery exists). Kernel default = safe. **Where:** `src/mir.zig` + profile +
  `build.zig`. **Test:** parity gate that safe & release agree functionally. **Prior art:** Zig
  ReleaseSafe/ReleaseFast. **Depends:** none.

## Tier 3 — Verification / translation validation (the compiler is a UB source)
> The overlay-read miscompile was found by fuzz luck, not structurally. Push the existing oracle
> culture toward real validation.

- [x] **V3.1 — Per-construct translation validation** *(DONE `8319ec6`; reference interpreter `mcref.py` now independently evaluates @offset layout, overlay reads (scalar/byte/non-byte/expr-position), and the switch families — fuzz-reference PASS 300, no compiler-vs-interpreter divergence)* — extend `tools/fuzz/mcref.py` /
  `fuzz-reference` to assert each MIR construct's lowering matches reference semantics, focused on
  the separate-per-backend-path constructs (offset/overlay/switch-family). **Test:** the suite;
  would have caught the overlay bug structurally. **Prior art:** translation validation (Pnueli),
  CompCert. **Depends:** the reference oracle.
- [x] **V3.2 — Lowering coverage instrumentation** *(DONE `bec15f0`; function-level — lower_c 72.5%, lower_llvm 85.3%; uncovered MMIO-read/overlay/atomics paths reported in `docs/lowering-coverage.md`)* — measure which `lower_c`/`lower_llvm`
  branches the fixtures+fuzzer hit, to surface untested divergence-prone paths (the overlay bug
  lived in an uncovered branch). **Test:** a coverage gate. **Prior art:** lcov/kcov, mutation
  testing. **Depends:** none.
- [x] **V3.3 — Memory-op metamorphic checks** *(DONE `ac3fb0b`; field-reorder@offset, overlay read recompose + position-swap, sizeof/offset identities, slice/index equivalence; fuzz-metamorphic PASS 600 seeds — no divergence)* — semantics-preserving transforms over
  layout/offset/overlay/slice ops must not change results. **Where:** `fuzz-metamorphic`. **Depends:**
  the offset/overlay generator surface (added).
- [ ] **V3.4 — Machine-checked soundness of a core subset** *(research)* — formal semantics + a proof
  that well-typed safe programs have no UB (and/or lowering refinement). **Prior art:** **seL4**,
  **CompCert**, RustBelt, RefinedC/Iris. **Depends:** T1.4.

## Tier 4 — Hardware-assisted (future; aligns with the capability thesis)

- [ ] **H4.1 — CHERI target** *(research)* — hardware capabilities = spatial **and** temporal safety
  at pointer granularity; the kernel is already a *capability* microkernel. **Where:** a backend
  behind `src/backend.zig`. **Prior art:** CHERI/Morello, CheriBSD. **Depends:** the backend
  abstraction; ideally a native backend.
- [ ] **H4.2 — ARM MTE heap tagging** *(research)* — cheap probabilistic UAF/OOB in production.
  **Where:** `kernel/core/heap.mc` + aarch64. **Prior art:** Android/Linux arm64 MTE. **Depends:**
  aarch64 maturity.

---
# Part II — Other kernel-language axes

## C — Concurrency discipline (static; complements D2.3/KCSAN)
> Data races + deadlocks + sleep-in-atomic are the worst kernel bug class. Primitives exist;
> nothing enforces their use.

- [ ] **C1 — Lock-guards-data** *(multi-PR)* — associate data with its lock (data inside the lock);
  access requires static proof the lock is held. **Where:** `std/sync` + a check pass. **Test:**
  `fuzz-failclosed` (unlocked access rejected); migrate kernel locks incrementally. **Prior art:**
  Rust `Mutex<T>`, Rust-for-Linux **klint**, lockdep. **Depends:** none.
- [ ] **C2 — IRQ/atomic-context discipline** *(PR)* — mark fns IRQ-context vs sleepable; a sleepable
  op (mutex/alloc) from IRQ context is a compile error. **Where:** an effect/attribute +
  `kernel/core/sched.mc`/`kernel/drivers/irq/`. **Test:** sleep-in-IRQ fixture rejected. **Prior art:**
  Linux `might_sleep`/lockdep, Rust-for-Linux context types. **Depends:** none.
- [ ] **C3 — Static lock ordering (deadlock-freedom)** *(multi-PR)* — a partial order over locks;
  out-of-order acquisition rejected. **Where:** lock types + check. **Test:** cyclic acquisition
  rejected. **Prior art:** lockdep, Abadi–Flanagan. **Depends:** C1.
- [ ] **C4 — Concurrency model checking** *(research)* — bounded model-checking (Loom/Coyote-style)
  of IPC/scheduler vs the memory model. **Where:** harness over `kernel/core/proc_ipc.mc`/`sched.mc`.
  **Prior art:** Loom, Coyote, CDSChecker. **Depends:** C1.

## U — Trusted/untrusted boundary (the #1 attack surface)

- [x] **U1 — User-pointer type** *(DONE `5072599`; `UserPtr<T>` opaque address class — deref/index/arithmetic already rejected, FOUND+FIXED a real hole: `.field` through a UserPtr was a kernel deref of user memory, now `E_USER_PTR_DEREF`. uaccess copy-in/out is the only path)* — a `UserPtr<T>` that **cannot be dereferenced**; only
  checked copy-in/out yields a value. **Where:** `kernel/core/uaccess.mc` + `kernel/core/syscall.mc`
  + the user_runtime path. **Test:** direct deref rejected (`fuzz-failclosed`); syscall paths adopt
  it. **Prior art:** Linux `__user`+sparse, Rust-for-Linux `UserSlice`/`UserPtr`. **Depends:** none.
- [x] **U2 — No double-fetch / TOCTOU** *(DONE `29c700d`; `UserSnapshot<T>` + `fetch_user` copy-once frozen value (structural defense) + `double-fetch-audit` lint flagging same-`UserPtr` re-reads; current kernel clean, self-test flags a textbook double-fetch)* — a copied-in value is an immutable snapshot;
  re-reading the same user datum (the double-fetch CVE class) is flagged. **Where:** uaccess + lint.
  **Test:** double-fetch fixture flagged. **Prior art:** double-fetch CVEs, Bochspwn. **Depends:** U1.
- [ ] **U3 — Taint untrusted lengths/indices** *(PR)* — values from `UserPtr` are untrusted ints,
  bounds-validated before use as length/index/loop bound. **Where:** a taint pass. **Test:**
  unvalidated user length used as index rejected. **Prior art:** taint analysis, IFC (K2). **Depends:**
  U1.

## P — Untrusted-input parsing (we now parse attacker bytes: TCP/IP/DNS/TLS, ELF, fs)

- [x] **P1 — Total, bounds-checked parser primitives** *(DONE `33b3e82`; `std/bytes.mc` reads were already bounds-checked — added non-trapping `br_try_*` + adopted in DNS/TCP parsers; `parser-fuzz` oracle: 4.82M malformed parses, 0 over-reads, teeth verified)* — a parser API (over
  `std/bytes.mc` `ByteReader`) where every read is bounds-checked and a parser is a **total
  function** over a finite buffer (no read past end, no infinite loop). Adopt in `kernel/net/*`,
  `kernel/core/elf.mc`, fs decode. **Where:** `std/bytes.mc` + the parsers. **Test:** a **parser fuzz
  oracle** — truncated/malformed input must reject cleanly, never OOB/hang. **Prior art:**
  **EverParse**, langsec, nom. **Depends:** none.
- [x] **P2 — Never trust a length field** *(DONE `c25eb99`; `br_validate_len` gates rdlength (DNS), IP total-length, UDP length, ELF phnum×phentsize + filesz before they drive loops/copies; 196K hostile-length fuzz cases rejected, 0 over-reads)* — wire length/count fields validated against the
  remaining buffer before driving a copy/loop. **Where:** parser type + check. **Test:**
  unvalidated-length fixture rejected. **Prior art:** Heartbleed. **Depends:** P1.
- [ ] **P3 — Verified parsers for the wire formats** *(research)* — generate TCP/IP/DNS/TLS-record
  parsers from a spec with machine-checked safety. **Prior art:** EverParse/miTLS. **Depends:** P1.

## K — Capability & information-flow in the type system (on-thesis)

- [x] **K1 — Unforgeable, monotonic capability types** *(DONE `c6ba536`; FOUND+FIXED a forgeable `Cap` (public field → struct-literal forge) by making it `opaque`; added `std/rights.mc` opaque narrow-only `Rights` + `RCap<R>` — forging/widening now `E_PRIVATE_FIELD`. Grant attenuation already runtime-enforced)* — `Cap<T, Rights>` constructible
  only by the kernel; rights only **narrow**, never widen; no ambient authority. The
  attenuated-subgrant property becomes a *type law*. **Where:** the `Cap<>`/grant types
  (`kernel/lib/granttab.mc`, `std/grant.mc`, `std/mask.mc`). **Test:** forging/widening rejected
  (`fuzz-failclosed`); parent⊇child mask law as a test. **Prior art:** **seL4** capability calculus.
  **Depends:** none.
- [ ] **K2 — Information-flow / taint for secret & untrusted data** *(research)* — label data; secret
  cannot flow to an untrusted sink (the agent-exfiltration threat, lifted to types). **Where:** an
  IFC pass. **Test:** labeled-flow fixture; metamorphic. **Prior art:** **Jif, HiStar, Flume**.
  **Depends:** K1. *(Pairs with U3.)*

## A — ABI / FFI layout safety (proven gap — the Virtq drift bug)
> A `std/virtqueue.mc` struct mirrored in a C runtime drifted → BSS corruption → boot hang.

- [x] **A1 — Auto-generated layout assertions for shared structs** *(DONE `1f538e5`; `mcc emit-layout` → `_Static_assert(sizeof/offsetof)`; also FIXED real Virtq drift in 3 C mirrors that were ~32B short)* —
  emit `static_assert(sizeof==…, offsetof(f)==…)` for every MC struct mirrored in a C runtime, so
  drift is a **compile error**. Would have caught the Virtq bug. **Where:** the C emit + `*_runtime.c`
  headers. **Test:** deliberately drift a struct → build fails; regression fixture. **Prior art:**
  `cbindgen`, Rust `#[repr(C)]` layout tests. **Depends:** none.
- [x] **A2 — Single source of truth for shared structs** *(DONE `175684f`; `mcc emit-c-struct` generates the full C struct from MC; the virtqueue structs are no longer hand-written — `grep "typedef struct Virtq"` finds only the generated header → drift structurally impossible)* — generate the C mirror from the MC
  struct (or vice-versa) — drift becomes impossible. **Where:** a header-codegen step. **Test:**
  generated header matches; no hand-edit path. **Prior art:** `bindgen`. **Depends:** A1.

## T — Termination & bounded resources / the agent-program verifier (on-thesis)

- [ ] **T(term)1 — Bounded-loop / no-unbounded-recursion check for critical code** *(PR)* — loops in
  critical sections + IRQ handlers must be statically bounded; no unbounded recursion. **Where:** a
  check pass + region marking. **Test:** unbounded loop in a critical region rejected. **Prior art:**
  eBPF verifier, SPARK. **Depends:** C2.
- [ ] **T(term)2 — Agent-program verifier (the eBPF-verifier analog)** *(multi-PR → research) —
  agent-OS capstone* — before a loaded agent program runs, statically verify it is memory-safe,
  bounded/total, and only invokes its **granted capabilities**. The loader gate that lets the kernel
  run untrusted agent code. **Where:** a verify pass + the agent loader (deferred R3) +
  `kernel/core/agent.mc`. **Test:** unsafe/unbounded/over-privileged agent rejected at load;
  conforming one runs confined. **Prior art:** the **eBPF verifier**, proof-carrying code, seL4.
  **Depends:** K1, T(term)1, the agent loader.

## S — Constant-time / secret types (side channels; relevant since TLS landed)

- [ ] **S(secret)1 — `secret<T>` type** *(multi-PR)* — forbids secret-dependent branches, indexing,
  and memory access (timing/cache side channels) for key/crypto material; apply to the TLS/key path.
  **Where:** a type + constant-time check + the TLS glue. **Test:** secret-dependent branch rejected;
  constant-time lint. **Prior art:** **FaCT**, HACL*/Vale, Rust `subtle`. **Depends:** none.
  *(BearSSL is already constant-time; this covers MC's own secret handling.)*

## F — Fault isolation / panic discipline

- [x] **F1 — Classify traps + contain agent faults** *(DONE `1e88424`; real M-mode trap from an illegal op classified by fault domain → faulting agent killed+reclaimed, kernel+others survive. Honest limit: from-trap context-switch INTO another agent's saved register context not yet wired — agents are inline-driven, as elsewhere)* — traps classified recoverable vs fatal;
  a recoverable fault in an agent is contained to its capability/fault domain (reuse
  `proc_oom_kill`/death path), not a kernel halt. **Where:** `kernel/arch/riscv64/trap_runtime.c` +
  the process fault path. **Test:** a faulting-agent demo — kernel survives, agent killed, others run
  (extends the OOM-kill keystone). **Prior art:** microkernel fault model, Tock. **Depends:** none.

---
# Unified critical path

1. **Cheap, evidence-backed foundations:** **A1** (retires the Virtq drift class), **S0.1**
   (definite-init), **S0.2** (`unsafe` boundary), **U1** (user-pointer type), **P1** (parser
   totality).
2. **Biggest dynamic ROI:** **D2.1** (KASAN-in-QEMU) — reuses the boot gates.
3. **Worst bug class:** **C1 + C2** (concurrency discipline), with **D2.3** (KCSAN) as the dynamic net.
4. **Codegen-is-a-UB-source:** **V3.2** (coverage) + **V3.1** (translation validation).
5. **On-thesis isolation:** **K1** (capability types) + **F1** (fault containment).
6. **Temporal safety:** **T1.1 → T1.2** (region/move borrows).
7. **Agent-OS capstone:** **T(term)2** (agent-program verifier; needs K1 + T(term)1 + the loader).
8. Everything else (S0.3, T1.3/4, D2.2/4/5, V3.3/4, H4.*, C3/C4, U2/U3, P2/P3, K2, A2, S(secret)1)
   trails by dependency.

The throughline: MC has the mechanisms; hardening pulls their disciplines into the type system
(static, zero-cost) or the trap/sanitizer model (cheap dynamic). **K** + **T(term)2** are what make
this an *agent* OS — static guarantees for running untrusted agent code.

See also `docs/mcfuzz-coverage-todo.md` (fuzzer generator surface), `docs/agent-os-vision.md`, and
memory `differential-testing.md`.
