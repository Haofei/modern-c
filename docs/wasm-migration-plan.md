# WASM migration plan: from the QuickJS host to a general WASM/WASI runtime

Status: **direction document + live implementation log.** The plan is being implemented; each
phase section carries its own **Status:** line. Snapshot:

- **Landed (gated on both backends in `m0`):** Phase 0 (`wasm-run-test`), Phase 1
  (`wasm-wasi-hello-test`), Phase 2 (`wasm-realtool-test`), Phase 3a + net-deny audit
  (`wasm-nettool-test`), Phase 4a JS-executes-on-WASM (`wasm-js-agent-test`), Phase 4b
  JS-agent-drives-broker (`wasm-js-nettool-test`), Phase 5 native async
  (`wasm-async-agent-test`/`wasm-cancel-test`/`wasm-quota-agent-test`/`wasm-spurious-agent-test`),
  **Phase 6 full parity sweep** — basic agent (`wasm-agent-test`), agent-smoke, cancel-edges,
  broker-agent; real-TCP (`wasm-net-realtool-test`); all five S-mode peers
  (`wasm-smode-{confined,agent,async-agent,net-irq-tool,blk-irq-tool}-test`); and cross-arch
  (`arm-wasm-async-test`, `x86-wasm-async-test`). Every Group-A row is ☑; every Group-B row
  has a confirmed disposition. **Phase 7 JS benchmark (v0)** — `wasm-js-bench-test` gates
  native-QuickJS vs QuickJS-on-WASM functional parity + emits the comparison report.
- **Open:** Phase 5 remainder (fuel / quota-errno / linear-memory cap / P2 worlds);
  Phase 8 (retire `qjs_host.c` — gated on a target-board perf measurement; Phase-7 QEMU data
  says keep native QuickJS behind a flag, not delete).

The remaining phases are still forward-looking; the prose in those sections describes intended
work, not landed work, except where a **Status:** line says otherwise. The parity matrix in §5
(Phase 6) tracks every gate's state.

This document describes how to migrate the agent runtime from the current
hand-written QuickJS C host (`examples/apps/qjs_host.c`) to a general WASM
engine running in U-mode behind the same narrow syscall ABI. It is a companion
to `docs/future-kernel-plan.md` (§5 architecture, §11.2 "do not add WASM before
the broker is solid") and `docs/quickjs-agent-plan.md`.

Related:

- `docs/future-kernel-plan.md` — capability-native runtime direction.
- `docs/quickjs-agent-plan.md` — how the current QuickJS host is built/confined.
- `docs/platform-portability-plan.md` — cross-arch backend/runtime parity.
- `docs/async-plan.md` — the submit/poll async model the runtime drives.

---

## 1. Why migrate

The broker is now solid: capability gates (`agent_fs_call` allowlist → budget →
path-cap), FS audit on both allow and deny, device-backed async, and a versioned
`SYS_SUBMIT`/`SYS_POLL` ABI. The strong broker/runtime gates are RISC-V
(QEMU/OpenSBI) on both backends (C + LLVM); x86_64 and AArch64 have confined
QuickJS + user-path seeds but still carry real-FS-broker and runtime parity as
remaining work (`docs/platform-portability-plan.md`,
`docs/future-kernel-plan.md` §9.1/§19). The precondition that §11.2 set for WASM
("do not add WASM before the capability broker is solid") is satisfied.

Historical asymmetry the migration had to account for (now resolved): **FS denials were
audited, but net-broker denials were not** — `net_broker.mc` recorded only admitted egresses.
Phase 3b fixed this: `net_policy_admit` now records a denied destination as a distinct
`NET_DENY_TAG` event (it still spends no budget and sends no packet — only audit *coverage*
grew), reaching FS-deny parity. See Phase 3.

The current QuickJS host is a JS-only, hand-written C host. It works and is the
differential oracle, but it has two limits:

- **Single language.** Agents must be JavaScript. A WASM runtime lets agents be
  written in any language that targets `wasm32` (Rust, C, Zig, Go via TinyGo,
  AssemblyScript, and JS-via-Javy), and lets reusable pure-compute components be
  shared across agents.
- **Bespoke host glue.** `qjs_host.c` is a custom marshalling layer specific to
  QuickJS. A WASM engine + a WASI shim is a standard, reusable boundary: the
  same shim serves every guest language.

**Security delta (honest accounting).** The switch is net-positive but not free.
It *adds*: WASM's module memory-safety/isolation of the guest, and a clean
fuel/memory metering point. It *costs*: the U-mode payload (a WASM engine) is a
larger, more complex attack surface than the small `qjs_host.c` glue. Crucially
this does **not** grow the *kernel* TCB — the engine is untrusted and confined
exactly like QuickJS is today (page-table isolation, six-syscall boundary). It
grows the agent-side payload only, where a compromise harms that one agent, not
the kernel. The trade is a bigger untrusted runtime in exchange for multi-language
support and a standard capability surface.

### What is explicitly NOT changing

This is the most important framing for the whole migration. The migration
replaces **one U-mode component** — the host glue — and changes nothing below it
except strictly append-only additions (new `TOOL_OP_*` values and a net-broker
deny-audit record). The *invariants* are: **no new syscall numbers, no
`ToolReq`/`ToolEvent` layout changes, and no change to existing allow/deny
decisions.** Audit *coverage* may expand (Phase 3 adds a deny record on the net
path), but no request that is allowed today becomes denied, or vice versa.

| Layer | File(s) | Changes? |
|---|---|---|
| Syscall ABI (numbers + struct layout) | `user/abi.mc` (`SYS_*` numbers, `ToolReq`/`ToolEvent` layout) | **No** — frozen invariant |
| Tool op catalog | `user/abi.mc` (`TOOL_OP_*` values) | **Append-only** — will add `TOOL_OP_RANDOM` when real entropy is wired (not yet; current Phase 1 `random_get` is a test-only deterministic stub, so `user/abi.mc` has no `TOOL_OP_RANDOM` today); `TOOL_OP_NET_*` only if general sockets are later opted into (Phase 3 default reuses `TOOL_OP_NET_FETCH`) |
| Kernel syscall dispatch | `kernel/core/syscall.mc`, the `sys_submit`/`sys_poll` handlers | **No** |
| Capability broker (allow/deny decisions) | `kernel/fs/agent_fs.mc`, `kernel/fs/fs_toolserver.mc`, `kernel/net/net_broker.mc`, `kernel/net/netcap.mc` | **Decisions unchanged**; Phase 3 *adds* net-deny audit coverage (and a new net op handler only if general sockets are later opted into) |
| Audit | `kernel/core/ipc_trace.mc` | **No** (reused by the new net-deny record) |
| Device-backed async | `kernel/lib/async.mc`, virtio-blk/net IRQ completion | **No** |
| ELF loader / confinement | `kernel/core/elf_loader.mc`, isolated Sv39 page tables | **No** |
| U-mode runtime / crt0 / libc | `user/runtime/crt0.mc`, `user/runtime/app_traps.mc`, `user/libc/*` | **Mostly no** (engine reuses them) |
| **U-mode host glue** | `examples/apps/qjs_host.c` | **Replaced** by a WASM engine + WASI shim |
| Agent program | pure JS source | Becomes a `.wasm` module (or JS-on-WASM via Javy) |

The kernel never gains a WASM engine. The engine is an ordinary confined U-mode
payload, exactly like `qjs_host.c` is today: a fixed ELF that reads the agent via
`SYS_READ`, runs it, and reaches **brokered effects** only through
`SYS_SUBMIT`/`SYS_POLL` — lifecycle and console use the existing `SYS_READ`/
`SYS_WRITE`/`SYS_EXIT` calls.

This keeps the trusted computing base unchanged. The WASM engine is untrusted,
same as the agent it runs.

**Instance model is unchanged: one agent per confined process.** The WASM engine
hosts a single agent instance per U-mode process, exactly as `qjs_host.c` does
today. WASM engines *can* multiplex many instances in one process; this migration
deliberately does **not** — multi-tenant-in-one-process is out of scope and would
weaken the per-agent confinement boundary.

---

## 2. Target architecture

```
                 agent bundle
       wasm module + manifest + policy   (or JS source → Javy → wasm)
                         |
                         v
   isolated U-mode payload: WASM engine + WASI shim   <-- NEW (replaces qjs_host.c)
                         |
            WASI imports resolved by the shim
                         |
                  ToolPump (submit/poll)   <-- UNCHANGED boundary (user/agent_async.mc)
                         |
                         v
  narrow syscall ABI: submit, poll, read, write, exit, getpid   <-- UNCHANGED (user/abi.mc)
                         |
                         v
              kernel capability broker        <-- UNCHANGED
        policy check + quota check + audit record
                         |
        +----------------+----------------+
        v                v                v
    tool broker      net broker       fs/device broker
```

The shim is the only new code on the hot path. It translates WASI host calls
into the existing `ToolReq` submit/poll protocol — the same protocol the JS
`host_*` functions use today via `__host_*_raw`.

### WASI maps onto the broker, not onto the trap boundary

A WASI host call is **not** a syscall. The trap boundary stays at the existing
six syscalls (`SYS_WRITE/READ/GETPID/EXIT/SUBMIT/POLL`, `user/abi.mc`).
WASI functions are resolved inside the U-mode shim and turned into `TOOL_OP_*`
requests that flow through the existing brokers:

| Guest / shim surface | Existing path today | Broker / cap |
|---|---|---|
| `fd_write` (stdout/stderr) | `SYS_WRITE` | console |
| `proc_exit` | `SYS_EXIT` | — |
| `clock_time_get`, `poll_oneoff` (timeout) | `TOOL_OP_TIMEOUT` + `SYS_POLL` | — |
| `random_get` | eventual `TOOL_OP_RANDOM` over kernel rng (current Phase 1: test-only deterministic stub) | — |
| `path_open` + `fd_read` on a preopen | `TOOL_OP_FS_READ` | `PathCap` (`fs_toolserver.mc`) |
| `path_open` + `fd_write` on a preopen | `TOOL_OP_FS_WRITE` | `PathCap` |
| `path_create_directory` | `TOOL_OP_FS_MKDIR` | `PathCap` |
| outbound fetch to an allowlisted endpoint | `TOOL_OP_NET_FETCH` (fetch-only surface, see Phase 3) | `NetCap` (`net_broker.mc`) |

The WASI **preopen** model is a natural fit for capabilities: a WASI guest can
only touch a directory the host preopened for it. The shim maps each preopen
onto a `PathCap`, so "no preopen = no filesystem" is literally "no cap = no
access." The network side is the same in spirit — the guest reaches the network
only if a `NetCap` authorizes the destination — but general WASI sockets are
deliberately *not* exposed early. Phase 3 ships a constrained **fetch-only**
surface mapped onto the existing pre-registered endpoint-id model; arbitrary
runtime-chosen sockets are a later, separately-scoped opt-in (Phase 3 "Deferred").

### Sync guest over async kernel

WASI Preview 1 is synchronous from the guest's point of view. The kernel ABI is
async (submit/poll). The shim bridges this the same way a blocking `read()` works
in libc: **submit, then poll until that id completes**, blocking the
single-threaded guest in between. This is the same drain already implemented in
`user/agent_async.mc` (`ToolPump`/`ToolFut`) — the shim reuses it. Native async is
deferred to a later phase: the **P2** `wasi:io/poll` pollable model (multiple
in-flight ops) maps cleanly onto the existing out-of-order `SYS_POLL` drain, and
the **P3** futures/streams model can map on later.

---

## 3. Engine selection

Constraints, from the codebase:

- Must build **freestanding** (no host OS), like the QuickJS payload already does.
- Must link against `user/libc/*` and `user/runtime/crt0.mc`, or bring a tiny
  self-contained allocator, and fit the fixed user image at base `0x10000`
  (`user/runtime/user.ld`).
- Must run as **U-mode interpreter or AOT**; a JIT is undesirable here. A JIT
  needs writable-then-executable pages, which breaks the W^X property the
  confinement relies on, enlarges the attack surface, and makes execution timing
  data-dependent (harder to reason about for fuel-based budgets and audit replay).
  Interpreter or ahead-of-time is preferred.
- License compatible (Apache-2.0 / MIT / BSD).
- No Go/Rust *runtime* dependency in the payload itself (the agent inside can be
  any language; the engine binary must link into our freestanding C/MC image).

Candidates:

| Engine | Lang | Footprint | Fit | Verdict |
|---|---|---|---|---|
| **wasm3** | C | tiny interpreter | builds freestanding trivially, QuickJS-shaped | **Phase-0 spike engine** |
| **WAMR** (wasm-micro-runtime) | C | small, embedded-targeted | libc-wasi, interp + AOT, platform porting layer, Apache-2.0, active | **Production target** |
| w2c2 / wasm2c | C (AOT source) | n/a (emits C) | compiles `.wasm` → C, goes through our own MC/C toolchain; aligns with the C backend | Backend-aligned alternative; evaluate in Phase 5 |
| wasmi | Rust, `no_std` | small | built-in fuel metering, but pulls a Rust toolchain into the payload build | Deferred (toolchain friction) |
| wasmtime | Rust | large | full component model; too big / JIT | Host oracle only, not on-device |

Recommendation:

- **Spike with wasm3** to prove the architecture end-to-end with the least code.
  It builds freestanding almost exactly like the QuickJS payload.
- **Target WAMR for production** because it ships a real WASI layer, an AOT mode
  (better determinism + no JIT), an explicit platform porting layer (a small set
  of functions we implement against our libc/syscalls), and per-instance memory
  and fuel limits that map onto our budgets.
- Keep **w2c2** in view: emitting C and running it through MC's own C backend
  would make WASM modules first-class objects in the existing build/parity
  machinery. Worth a Phase-5 evaluation, not the first bet.

---

## 4. Performance and footprint budget

Engine choice (and whether the migration proceeds at all) is gated on size and
speed, not just correctness. The numbers below are **placeholders to be set from
the Phase-0/Phase-4 measurements** against the current QuickJS host as the
baseline; fill them in before committing to WAMR over wasm3 (or vice versa).

| Metric | Budget (set from baseline) | Measured at | Action if exceeded |
|---|---|---|---|
| **QuickJS baseline (image size + JS hello latency + RSS)** | recorded, not bounded — this *is* the reference all other rows are set from. **Measured (`qjs-run-test`, C backend, bare-metal `virt.ld`):** engine `.text` ≈ **780 KB** (799,490 B), `.data` 4,320 B, ELF file 1.84 MB; `.bss` 8.0 MB is the reserved heap/stack region in `virt.ld`, not steady-state footprint. JS hello = the `1+2*3==7` eval; end-to-end QEMU run is dominated by boot, not eval. (The confined `qjs_host` agent image was not separately measured; the bare-engine `.text` above bounds the engine cost, and the confined arena requirement is captured in Phase 4's note.) | Phase 0, step 0 | n/a (measurement) |
| U-mode image size (engine + shim) | ≤ _N×_ the current `qjs_host` image; must fit `user.ld` at base `0x10000`. **Measured (`wasm-run-test`, C backend, bare engine, no shim yet):** wasm3 `.text` ≈ **89 KB** (90,946 B) vs QuickJS 780 KB → **N ≈ 0.11×** (~8.8× smaller). Guest `hello.wasm` 440 B. Huge headroom; revisit once the WASI shim + a real guest land (Phase 1–4). | Phase 0 | Prefer wasm3 (interpreter, tiny); if still over, AOT-trim or abort |
| Per-instance linear memory | ≤ the agent's `heap-bytes` budget (`future-kernel-plan.md` §7) | Phase 1 | Cap instance memory; deny with the quota errno (see note) |
| WASI hello latency vs native | ≤ _Mx_ the QuickJS hello path | Phase 1 | Acceptable for I/O-bound agents (most agent time is awaiting brokered I/O); if compute-bound, evaluate AOT (WAMR/w2c2) |
| **JS-on-WASM (Javy) memory** | ≤ _P×_ native QuickJS | Phase 7 benchmark | See below — keep native QuickJS host behind a flag if exceeded |
| **JS-on-WASM (Javy) latency** | ≤ _Q×_ native QuickJS | Phase 7 benchmark | Same |

**The Javy double-layering cost is real and must be measured, not assumed away.**
Running JS via Javy means QuickJS is compiled to WASM and then interpreted by the
WASM engine — two interpreter layers stacked (engine → QuickJS bytecode → JS),
with QuickJS's heap living *inside* the WASM linear memory. Expect a meaningful
memory and latency penalty versus today's native QuickJS host. Phase 4a proves JS
executes on WASM; **Phase 7 is the benchmark decision point** for whether
JS-on-WASM can replace native QuickJS for JS bundles. §9 Q4 ("JS perf on WASM") is
decided by these two rows, and Phase 8 keeps the native QuickJS host behind a
build flag if the JS path regresses past budget.

### Abort / rollback criteria

The migration has a defined off-ramp — it is not all-or-nothing:

- The QuickJS host stays the gated default throughout (the migration-safety rule),
  so "abort" simply means "stop advancing the WASM path"; nothing is lost.
- **Hard aborts:** the engine cannot be built JIT-free for a target arch; or the
  Phase-0 image cannot be made to fit `user.ld`; or no engine meets the image
  budget even at wasm3's footprint.
- **Soft stop (ship WASM for non-JS, keep native QuickJS for JS):** if the Phase-7
  benchmark shows JS-on-WASM memory/latency regresses past budget but Phases 0–6
  meet their parity gates, ship the WASM runtime for `wasm` bundles and keep the
  native QuickJS host for `js` bundles. This still delivers multi-language agents;
  only the "retire the host" goal (Phase 8) is deferred.

---

## 5. Phases

Each phase lands a deliverable plus one or more gates, on **both backends**
(C + LLVM) per project convention, validated in Docker (host skips
LLVM/QEMU/kernel gates; run a gate in Docker via
`docker compose run --rm dev zig build <gate>`, e.g. `wasm-run-test`). The wasm gate
scripts live under `tools/lang/` (e.g. `tools/lang/wasm-confined-test.sh`); new gates
wire into `build/qemu.zig` and `build/tiers.zig` next to the existing `qjs-*` gates.

New **build-host-only** toolchain dependencies this introduces (none ship on the
device): a `wasm32-wasi` toolchain (wasi-sdk / clang) from Phase 1 to produce
`.wasm` modules, and **Javy** from Phase 4 to compile JS to WASM. Add these to
`future-kernel-plan.md` §15's required-tools list; like the QEMU/LLVM gates they
may be skipped on a bare host but must be present (not silently skipped) for the
`wasm-*` milestone tier.

The overriding rule (mirroring §9.1's "M-mode QEMU remains green until S-mode
reaches agent parity"):

> **The QuickJS host stays the default and stays fully gated until the WASM path
> reaches gate parity. QuickJS is the differential oracle for the migration.**

### Phase 0 — Spike: a WASM module prints

Status: **DONE.** wasm3 0.5.2 is vendored (`third_party/wasm3`, MIT) and builds
freestanding against the all-MC libc + openlibm. `examples/apps/wasm_agent.c` instantiates
it, links a minimal WASI-shaped `fd_write`→`SYS_WRITE` / `proc_exit` import set, and runs a
real wasm32 module (`examples/apps/wasm/hello.c`, built by `clang --target=wasm32` + `wasm-ld`)
that prints `WASM=ok`. Gated as `wasm-run-test` / `llvm-wasm-run-test`, both in `m0`. Engine
`.text` ≈ 89 KB (vs QuickJS 780 KB). Only ABI-safe change required: two append-only float
math declarations (`copysignf`, `rintf`) in `user/libc/include/math.h` (openlibm already
provides the symbols). No kernel, syscall, or broker change.

Goal: prove a freestanding WASM engine runs as a confined U-mode payload and
reaches the kernel.

- **Step 0 — record the QuickJS baseline.** Before any WASM work, measure and
  write down the current `qjs_host` reference numbers: built image size (the
  `user.ld` ELF), a JS hello-world end-to-end latency under QEMU, and peak RSS /
  linear-heap use. These become the denominators for §4's `N×/Mx/P×/Q×` budgets,
  which stay placeholders until this is filled in. (Record them in §4's table or
  alongside it.)
- Vendor wasm3 (or WAMR minimal) under `examples/apps/` or `third_party/`, built
  freestanding against `user/libc` + `user/runtime/crt0.mc`, linked with
  `user.ld` like `qjs_host.c`.
- New fixed host `examples/apps/wasm_host.c` (analogue of `qjs_host.c`): reads a
  `.wasm` module via `SYS_READ`, instantiates it, runs `_start`.
- Minimal import: `fd_write(stdout)` → `SYS_WRITE`. `proc_exit` → `SYS_EXIT`.
- A tiny hand-built `.wasm` (or a Rust/Zig `wasm32-unknown-unknown` hello).

**Gate:** `wasm-run-test` / `llvm-wasm-run-test` — module prints, exits clean.
Mirrors `qjs-run-test`.

### Phase 1 — Minimal WASI Preview 1 shim

Status: **DONE.** `examples/apps/wasm/wasi_shim.c` implements the WASI P1 import set
(`fd_write`/`fd_read`→`SYS_WRITE`/`SYS_READ`, `fd_close`, `fd_seek`, `fd_fdstat_get`,
`proc_exit`, `clock_time_get` (monotonic counter, not wall-clock), `clock_res_get`,
`random_get` (**test-only deterministic stub — NOT cryptographic**; real entropy awaits
`TOOL_OP_RANDOM`), `environ_*`/`args_*` empty, `fd_prestat_get`→`EBADF` (no preopens yet),
`sched_yield`, `poll_oneoff`→`ENOTSUP`), with a
centralized kernel-errno→WASI-errno table (`wasi.h`). The generic `examples/apps/wasm_host.c`
links the shim into any guest. A **stock `wasm32-wasi` `printf` hello**, built unmodified by
`zig cc -target wasm32-wasi` (zig's wasi-libc), runs **confined** in an isolated Sv39 U-mode
space, reaching the kernel only via `SYS_WRITE`/`SYS_EXIT`. Gated as `wasm-wasi-hello-test` /
`llvm-wasm-wasi-hello-test`, both in `m0`. No kernel/syscall/broker change; no new
`TOOL_OP_*` (the hello path never calls `random_get`, so `TOOL_OP_RANDOM` is deferred to the
first guest that needs real entropy — `clock_time_get` uses a monotonic counter and
`random_get` a documented non-crypto stub until then).

Goal: a real `wasm32-wasi` module built by an off-the-shelf toolchain runs.

- Implement the WASI P1 import set needed for a hello-world `wasm32-wasi`
  program: `fd_write`, `fd_read` (stdin via `SYS_READ`), `proc_exit`,
  `clock_time_get`, `random_get`, `environ_*`/`args_*` (empty), `fd_close`,
  `fd_fdstat_get`.
- `clock`/sleep routed through `TOOL_OP_TIMEOUT` + `SYS_POLL`.
- Add `TOOL_OP_RANDOM` to `user/abi.mc` + a broker handler over the kernel rng,
  if `random_get` needs entropy. (One ABI append — safe, see §7.)
- **Errno translation.** WASI has its own `__wasi_errno_t` enum whose values
  differ from the kernel's Linux-style `-E_*` (`user/abi.mc`). The shim must map
  kernel results to WASI errno (e.g. `-E_DENIED` → `__WASI_ERRNO_ACCES`,
  `-E_FAULT` → `__WASI_ERRNO_FAULT`, `-E_AGAIN` → `__WASI_ERRNO_AGAIN`,
  `-E_NOCAP` → `__WASI_ERRNO_NOBUFS`/`PERM`). Centralize this in one table in the
  shim so every WASI call returns conformant codes.

**Gate:** `wasm-wasi-hello-test` / `llvm-…` — a standard `wasm32-wasi` hello
binary runs unmodified. Mirrors `qjs-confined-test`.

### Phase 2 — Filesystem via preopen → PathCap

Status: **DONE.** The shim (`wasi_shim.c`) now exposes a single `/ws` **preopen** (fd 3) via
`fd_prestat_get`/`fd_prestat_dir_name`, with `path_open` resolving guest-relative paths under
it and `fd_read`/`fd_write`/`fd_seek`/`fd_close`/`fd_fdstat_get`/`path_create_directory`
routed to `TOOL_OP_FS_READ`/`FS_WRITE`/`FS_MKDIR` over `SYS_SUBMIT`/`SYS_POLL` (a synchronous
submit-then-poll bridge; `tool_abi.h` mirrors the `ToolReq`/`ToolEvent` layout). A **stock
`wasm32-wasi`** guest doing POSIX `open`/`write`/`read`/`close` + `mkdir`
(`examples/apps/wasm/wasi_fs.c`) drives the real broker: the write/read round-trip is
**allowed** (returns `hi`), and `mkdir` is **denied** (`TOOL_OP_FS_MKDIR` not in the agent's
allowlist) — the guest observes `EACCES` (mapped from the broker's `-E_DENIED`) and the deny is
recorded by `agent_fs_call`→`ipc_trace`, exactly as the JS path. The guest also attempts a path
with **no matching preopen** (`/etc/passwd`) and the WASI preopen sandbox refuses it (`ENOENT`)
before it reaches the host — the "no preopen = no cap = no access" mapping. Gated as `wasm-realtool-test`
/ `llvm-wasm-realtool-test`, both in `m0`, reusing the confined harness with the FS broker
already wired in `app_run_demo.mc`. No kernel/syscall/broker/ABI change. (The kernel FS tool is
whole-file — no offset in the `ToolReq` ABI — so the shim buffers writes and flushes on close,
and serves reads from a per-fd cache; large/seekable files need an offset wire, a future
broker-side item, not a Phase 2 requirement.)

Goal: WASI filesystem calls flow through the existing capability FS broker.

- Map WASI preopened directories to `PathCap`s minted by the kernel for the
  agent (the host receives them the same way the JS path does).
- Implement `path_open`, `fd_read`, `fd_write`, `fd_seek`, `path_create_directory`,
  `fd_filestat_get` over `TOOL_OP_FS_READ`/`FS_WRITE`/`FS_MKDIR` through
  `agent_fs_call` (allowlist → budget → path-cap).
- Verify the **two distinct denial layers**: (a) a **broker** deny — an op the agent is not
  allowlisted for (`mkdir`/`TOOL_OP_FS_MKDIR`) returns a WASI `errno` derived from `-E_DENIED`
  and is audited (`ipc_trace.mc`) exactly like the JS path; (b) a **preopen** deny — a path with
  no matching preopen (outside `/ws`) is refused by the WASI preopen sandbox itself
  ("no preopen = no cap = no access"), before the request reaches the host or broker.

**Gate:** `wasm-realtool-test` / `llvm-…` — file write+read through the broker; **plus** the
broker `mkdir` deny (audited) **and** the outside-preopen escape refusal. Mirrors
`qjs-realtool-test`.

### Phase 3 — Network via a fetch-only WASI surface → NetCap

Status: **Phase 3a + net-deny audit DONE; real-TCP and S-mode-IRQ variants OPEN.** The shim
exposes a fetch-only `net_fetch(endpoint, token)` MC host tool (module `mc`, not general WASI
sockets) mapping to `TOOL_OP_NET_FETCH` through the net broker (egress allowlist → budget →
endpoint); a WASM guest (`examples/apps/wasm/wasi_net.c`) reaches endpoint 1 (107/108), is
**denied** endpoint 9 (EDENIED), and is **budget-bounded** (EAGAIN) — the mirror of
`qjs-nettool-test`, gated as `wasm-nettool-test` / `llvm-` in `m0`. The required **net-deny
audit** is implemented: `net_broker.mc`'s `net_policy_admit` now records a blocked egress as a
distinct `NET_DENY_TAG` event (append-only audit *coverage*; the decision is unchanged — still
Denied, no budget, no packet), reaching FS-deny audit parity. The `agent-net-test` /
`agent-net-real-test` gates assert the deny record; the WASM guest triggers the same audited deny
path. **Remaining for Phase 3:** real-TCP (`wasm-net-realtool-test`) and S-mode IRQ
(`wasm-smode-net-irq-tool-test`) variants.

Goal: WASI network egress flows through the net broker — **without reopening the
network model.** General WASI sockets do not fit the current network op, and
arbitrary outbound egress is exactly the ambient-authority shape this kernel
rejects. So Phase 3 ships a **constrained fetch-only surface first**, riding the
existing endpoint-id + `NetCap` machinery, and treats general sockets as a later,
separately-scoped opt-in (see "Deferred" below).

Why general sockets do not fit today: `TOOL_OP_NET_FETCH` is an endpoint-id
selector — `arg = endpoint id` (an index into the kernel's pre-registered
allowlist), `flags = request token/audit size`, result a single `u32`
(`user/abi.mc:71`, `net_fetch`/`net_policy_admit` in `net_broker.mc`). It has no
field for an arbitrary host/port or a request/response body. WASI
`sock_connect`/`sock_send`/`recv` assume exactly that arbitrary destination, so
mapping them directly would force a new request encoding **and** new
per-request destination policy — a much larger surface.

**Phase 3 scope (the default path):**

- **Fetch-only WASI surface.** The WASI shim exposes only an outbound call to
  **named, pre-registered, allowlisted endpoints** — it maps a guest "fetch
  endpoint N" onto `TOOL_OP_NET_FETCH` and the existing `net_policy_admit`
  (allowlist → budget → endpoint). Note the scope this implies: reusing
  `TOOL_OP_NET_FETCH` as-is means **endpoint fetch/tool-call parity** (an endpoint
  id + a token/audit-size scalar in, a scalar `u32` result out), **not** arbitrary
  HTTP request/response bodies — the current op has no payload buffers wired for
  general bodies. Any guest attempt to open an arbitrary socket
  (`sock_open`/`sock_connect` to a runtime-chosen host:port) is **not provided /
  refused**. This is precisely what JS agents can do today, so it reaches parity
  with **zero change to the kernel network model** — no new ops, no struct
  changes, no new destination policy. (Carrying real HTTP bodies, like arbitrary
  sockets, belongs to the deferred general-net work below.)
- **Net-deny audit (required) — DONE (Phase 3b).** The net broker previously did **not**
  audit denied destinations (`net_policy_admit` recorded only admitted egresses), unlike the
  FS broker. For an audit-focused kernel a blocked exfil attempt must be observable, so
  `net_policy_admit` now records a deny-path audit event (`NET_DENY_TAG`) in `net_broker.mc`,
  reaching FS-deny parity. (Append-only audit *coverage*; no allow/deny decision changed — the
  call is still Denied, no budget spent, no packet sent. Broker work, not WASM work; the
  `agent-net-test` / `agent-net-real-test` gates assert the deny record.)
- Mock transport first (mirrors `qjs-nettool-test`), then real TCP over
  virtio-net (mirrors `qjs-net-realtool-test`), then S-mode IRQ-backed
  completion through `SYS_POLL` (mirrors `qjs-smode-net-irq-tool-test`).

**Gates:** `wasm-nettool-test`, `wasm-net-realtool-test`,
`wasm-smode-net-irq-tool-test` (+ `llvm-` peers). Mirror the `qjs-*` net gates,
**plus** a denied-destination case asserting a net-deny audit event (new — see
above; this also retro-strengthens the existing `qjs-nettool-test` path), **plus**
a case asserting a guest's arbitrary-socket attempt is refused (the fetch-only
boundary holds).

**Deferred — general WASI sockets (`TOOL_OP_NET_*`):** only if a real agent
genuinely needs arbitrary outbound connections. It would add new append-only
`TOOL_OP_NET_*` op(s) carrying destination + payload in the `ToolReq`
`in_payload`/`out_ptr` buffers (bounded by `MAX_REQ_BYTES`/`MAX_RES_BYTES`,
chunked if larger) plus matching per-destination `net_broker.mc` policy. This is
a conscious, separately-audited expansion of the network model — **not** a Phase 3
requirement, and not a side effect of "making WASM work." Decide it on its own
merits when a guest demands it.

### Phase 4 — JS-on-WASM (the QuickJS-host equivalence proof)

Status: **Phase 4a (engine equivalence) DONE; Phase 4b (JS-agent broker parity) DONE.**
JavaScript *executes* on the WASM path (4a) **and a JS agent drives the kernel broker** (4b). The plan defines Javy as "QuickJS-ng compiled to
`wasm32-wasi`"; the Javy binary isn't available in this build environment, so the repo's
already-vendored QuickJS (`third_party/quickjs`) is compiled to `wasm32-wasi` with the toolchain
we have (`zig cc -target wasm32-wasi`, linking zig's wasi-libc) — the **same QuickJS-on-wasm
artifact**, with no opaque prebuilt tool. `examples/apps/wasm/wasi_js.c` evals a representative
JS program (recursion + objects + arrays + JSON + closures → `82`) and runs **confined** on the
wasm3 host + WASI shim. Gated as `wasm-js-agent-test` / `llvm-`, both in `m0`. This proves the
engine-equivalence half: JS is preserved on the WASM runtime ("keep JS, retire the hack").
**Phase 4b is now also done:** `examples/apps/wasm/wasi_js_net.c` (QuickJS-on-wasm) registers a
`net_fetch()` JS global backed by the `mc.net_fetch` import; the JS observes the broker's allow
(107/108) / **deny** (EDENIED) / **budget** (EAGAIN) decisions — full JS-agent broker parity, the
WASM mirror of `qjs-nettool-test` driven from JavaScript. Gated as `wasm-js-nettool-test` /
`llvm-`, both in `m0`.

The **Javy double-layering cost** the plan flagged in §4 is now measured and real: wasm3
allocates per-function M3 code pages for the ~1 MB QuickJS module *plus* QuickJS's own JS heap
inside the wasm linear memory. That pushed the confined agent's libc arena from 8 MiB to
14 MiB (`user/libc/alloc.mc`) — still under the elf_loader's 16 MiB-per-segment cap
(`MAX_SEGMENT_PAGES`), so no loader/hardening change was needed. A larger JS heap (beyond the
16 MiB segment cap) would need a kernel-grown heap (sbrk) — a noted future item, not required
for the keystone. **Phase 4b root cause (found and fixed).** The JS-drives-broker prototype
initially hard-crashed with an illegal-instruction trap. Debugged via a U-mode trap-cause dump +
`objdump`, and after ruling out — each by controlled test — **arena size** (24 MiB still crashed),
**native stack** (4 MiB), **the syscalls** (a stubbed `net_fetch` still crashed), and **link
failure**, the fault was localized to MC's **`memmove`** (`user/libc/cstr.mc`), reached from
wasm3's `op_MemCopy` (the wasm `memory.copy` handler). The bug: `memmove`'s `d < s` branch
delegated to `mem_copy` (`std/mem.mc`), which `unreachable`-**traps on any overlapping range** — it
is a non-overlapping primitive. But a **forward** copy is correct under overlap when `d < s`, so a
large overlapping `memory.copy` (here QuickJS-on-wasm relocating a ~9 MiB buffer downward) trapped.
**Fix:** `memmove` now does its own forward byte copy for `d < s` instead of calling `mem_copy`
(`user/libc/cstr.mc`). The keystone never exercised that copy, which is why it surfaced only with
the JS-drives-broker guest.

A second, independent **hardening bug was fixed along the way**: `malloc` called the *infallible*
`heap_alloc`, which traps on allocation failure — a C-contract violation reachable from any
untrusted guest. `user/libc/alloc.mc` now routes through the fallible `heap_try_alloc` and returns
NULL on failure.

So Phase 4 is complete: JS executes on WASM (`wasm-js-agent-test`) **and** a JS agent drives the
broker with allow/deny/budget parity (`wasm-js-nettool-test`). The broker path is independently
proven from C guests (`wasm-realtool-test`, `wasm-nettool-test`).

Goal: prove existing JS agents survive the migration, so retiring the JS-specific
host loses no capability.

- Build the JS agents as WASM via **Javy** (QuickJS-ng compiled to `wasm32-wasi`)
  or `componentize-js`. The JS source is the same; only the packaging changes.
- The JS `host_async`/`host_fs_*`/`host_net_fetch` surface is re-exposed to the
  guest by the Javy host bindings, which the shim resolves to the same
  `TOOL_OP_*` as today.
- Run the existing JS agent scenarios on the WASM path.

**Gate (4a, landed):** `wasm-js-agent-test` / `llvm-…` — JavaScript (QuickJS compiled to
`wasm32-wasi`) executes on the WASM runtime, confined. Demonstrates JS is preserved (the
"keep JS, retire the hack" direction).

**Gate (4b, landed):** `wasm-js-nettool-test` / `llvm-…` — a JS *agent* (QuickJS-on-wasm) calls
`net_fetch()` and observes the broker's allow/deny/budget decisions, the same broker outcome as the
QuickJS host's `qjs-nettool-test`, driven from JavaScript. (FS-from-JS can be added the same way;
the net path establishes the JS→broker mechanism.)

### Phase 5 — Async, fuel, budgets, P2 worlds

Status: **Native async + linear-memory cap + quota-errno + CPU-runaway watchdog DONE; deterministic fuel + P2 worlds OPEN.** The shim exposes an async
tool surface — `mc.tool_submit(op, arg, flags)` and `mc.tool_poll(out)` (`wasi_shim.c`) — the
WASM analogue of the JS host's async path / `agent_async.mc`'s `ToolPump`: a guest keeps
multiple ops in flight and drains completions by id. Four guests mirror the QuickJS async
agents and are gated (both backends, in `m0`): `wasm-async-agent-test` (12 overlapping SUM ops →
ok=8 / rejected=4 back-pressure), `wasm-cancel-test` (`TOOL_OP_CANCEL` → `-E_CANCELED` while a
peer resolves), `wasm-quota-agent-test` (9th submit on a full queue → exactly `-E_AGAIN`),
`wasm-spurious-agent-test` (a bogus completion id is detected). **Still open:** fuel metering
and curated WASI Preview 2 worlds.

Goal: use WASM's strengths and align with the resource-budget model.

- **Fuel metering** → CPU-ticks/event-loop budget (`future-kernel-plan.md` §7). **Coarse
  watchdog DONE; deterministic fuel OPEN (engine constraint).** A machine-timer **CPU-runaway
  watchdog** is now implemented + gated — `wasm-watchdog-test` / `llvm-wasm-watchdog-test` (in
  `m0`): the M-mode runtime arms a timer that preempts the U-mode agent every ~100 ms and, past
  an opt-in `mc_watchdog_ticks()` budget, KILLS a runaway agent (`wasi_runaway.c` — an infinite
  loop that never syscalls), so an untrusted agent cannot wedge the system (it fails closed
  instead of hanging). It is **opt-in** (weak default 0 → disarmed → zero change for other
  confined gates). This is a coarse, wall-clock liveness bound, **not** deterministic fuel:
  **deterministic per-instruction fuel remains OPEN** and needs an engine-level mechanism.
  **Engine-swap spike DONE — WAMR chosen (see `tools/wamr/README.md`).** WAMR has native
  instruction metering (`wasm_runtime_set_instruction_count_limit` — exactly the missing fuel) and,
  unlike wasmi (Rust, impractical for the `-nostdlib` U-mode agent), is freestanding-C. The
  decisive risk — *does WAMR build freestanding against the all-MC libc?* — is **answered: yes.** A
  from-scratch `mc` platform port (`tools/wamr/mc-platform/`, ~80 lines) gets **16/17 WAMR core
  files compiling** freestanding (riscv64 lp64d); the lone gap is `strtok_r` (a one-function libc
  add). Remaining (multi-session, additive — wasm3 + all gates stay green until WAMR passes the
  family): a `wamr_host.c` over WAMR's ~8-call `wasm_export.h` API, port the ~30 WASI/broker
  imports to WAMR `NativeSymbol`s, a `wamr-run-test` gate, then the payoff `wamr-fuel-test`
  (deterministic instruction-limit termination), then migrate the family / make WAMR default.
- **Quota errno. DECIDED: map to the existing errno set (option b); no `E_QUOTA` added.** The
  frozen errno set — `E_AGAIN` (-11), `E_DENIED` (-13), `E_FAULT` (-14), `E_NOCAP` (-105),
  `E_TIMEDOUT` (-110), `E_CANCELED` (-125) — already expresses the two real cases: **transient
  backpressure → `-E_AGAIN`** (exactly what `wasm-quota-agent-test`'s 9th-submit assertion
  checks) and **a hard cap → `-E_NOCAP`**. This keeps the errno set frozen (zero ABI surface
  change); if a future policy genuinely needs "budget exceeded" distinct from both, `E_QUOTA`
  remains available as an append-only addition (`future-kernel-plan.md` §7).
- **Linear-memory cap** → JS/WASM heap-bytes budget. **DONE** — `wasm-memcap-test` /
  `llvm-wasm-memcap-test` (both in `m0`): a confined guest (`wasi_memcap.c`) allocates until the
  wasm linear memory (grown from the agent's libc arena) is exhausted; at the cap `memory.grow`
  returns -1, wasi-libc's `malloc` returns NULL, and the guest stops cleanly — proving the heap
  is **bounded** and OOM is a **graceful, confined** error (no trap, no host-memory exhaustion),
  consistent with the Phase-7 finding (the WASM JS heap is materially tighter than native).
- **Native async**: multiple in-flight WASI ops mapped onto the out-of-order
  `SYS_POLL` drain (reuse `ToolPump`'s by-id stash); cancellation via
  `TOOL_OP_CANCEL` (mirrors `qjs-cancel-test`).
- **Curated WASI Preview 2 worlds**: define a WIT world that exposes only
  `wasi:io/poll`, `wasi:filesystem` (preopen-scoped), `wasi:clocks`,
  `wasi:random`, and a **fetch-only egress world** (outbound to allowlisted
  endpoints, NetCap-scoped) — consistent with the Phase 3 fetch-only position,
  and bounded by the same endpoint fetch/tool-call parity unless body-carrying
  lands. A real `wasi:http` world (arbitrary request/response bodies) and full
  `wasi:sockets` are exposed **only if the deferred general-net work (Phase 3
  "Deferred") is accepted**. Deliberately omit anything that
  implies ambient authority (no `wasi:cli` environment, no arbitrary fs root, no
  raw sockets by default). Document the omissions explicitly (a `log()`-style
  "what we don't implement" note), so the curated surface is a stated policy, not
  an accident.

**Gates:** `wasm-quota-agent-test`, `wasm-cancel-test`, `wasm-async-agent-test`,
`wasm-smode-async-agent-test` (+ `llvm-` peers). Mirror the `qjs-*` async/quota
gates.

### Phase 6 — Differential parity sweep

Status: **OPEN** (in progress — 5 of the Group-A substrate rows below are ☑; the rest, plus
cross-arch, remain).

Goal: the WASM path matches the QuickJS path on every scenario, both backends,
all relevant architectures.

- For each `qjs-*` gate, ensure a `wasm-*` peer asserting the same broker outcome
  and audit trace.
- Cross-arch: run the WASM agent on riscv64, x86_64, aarch64 (the engine is C, so
  it rides the same per-arch user path the QuickJS host already proved).
- Add the `wasm-*` family to `m0` so it is non-skippably gated, exactly as the
  async family was hardened.

**Gate:** the full `wasm-*` family green in `m0` on both backends; the parity
matrix below marked complete.

**Parity matrix.** The contract for Phase 8 is: every `qjs-*` gate is either
matched by a `wasm-*` peer (same broker outcome + same audit trace, both
backends) **or** explicitly classified as not needing one, with a reason. The
gates split into two groups.

**A. Runtime-substrate gates — each needs a `wasm-*` peer** (these test the
confinement/syscall/broker/async machinery the WASM engine must independently
prove):

| Scenario | QuickJS gate | WASM peer | Status |
|---|---|---|---|
| Run + print | `qjs-run-test` | `wasm-run-test` | ☑ (Phase 0 landed; both backends in `m0`) |
| Confined eval | `qjs-confined-test` | `wasm-wasi-hello-test` | ☑ (Phase 1 landed; both backends in `m0`) |
| S-mode confined | `qjs-smode-confined-test` | `wasm-smode-confined-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| Agent (syscall-driven) | `qjs-agent-test` | `wasm-agent-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| Agent smoke | `qjs-agent-smoke-test` | `wasm-agent-smoke-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| S-mode agent | `qjs-smode-agent-test` | `wasm-smode-agent-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| Async agent | `qjs-async-agent-test` | `wasm-async-agent-test` | ☑ (Phase 5 landed; both backends in `m0`) |
| S-mode async agent | `qjs-smode-async-agent-test` | `wasm-smode-async-agent-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| Broker agent | `qjs-broker-agent-test` | `wasm-broker-agent-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| FS tool (allow + deny audit) | `qjs-realtool-test` | `wasm-realtool-test` | ☑ (Phase 2 landed; both backends in `m0`) |
| Net fetch (mock) | `qjs-nettool-test` | `wasm-nettool-test` | ☑ (Phase 3a landed; both backends in `m0`) |
| Net fetch (real TCP) | `qjs-net-realtool-test` | `wasm-net-realtool-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| S-mode net IRQ | `qjs-smode-net-irq-tool-test` | `wasm-smode-net-irq-tool-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| S-mode blk IRQ | `qjs-smode-blk-irq-tool-test` | `wasm-smode-blk-irq-tool-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| Quota / backpressure | `qjs-quota-agent-test` | `wasm-quota-agent-test` | ☑ (Phase 5 landed; both backends in `m0`) |
| Cancel | `qjs-cancel-test` | `wasm-cancel-test` | ☑ (Phase 5 landed; both backends in `m0`) |
| Cancel edges | `qjs-cancel-edges-test` | `wasm-cancel-edges-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| Spurious completion id | `qjs-spurious-agent-test` | `wasm-spurious-agent-test` | ☑ (Phase 5 landed; both backends in `m0`) |
| Cross-arch x86_64 | `x86-qjs-test` / `x86-qjs-async-test` | `x86-wasm-async-test` | ☑ (Phase 6 landed; both backends in `m0`) |
| Cross-arch aarch64 | `arm-qjs-test` / `arm-qjs-async-test` | `arm-wasm-async-test` | ☑ (Phase 6 landed; both backends in `m0`) |

**B. QuickJS-engine / JS-language gates — no direct WASM-engine peer**; JS
behavior is instead proven collectively on the WASM path by the Phase-4a gate
`wasm-js-agent-test` (Javy = QuickJS-on-WASM — JS *executes*) plus `wasm-js-nettool-test`
(Phase 4b — a JS agent drives the broker), or is engine-internal and replaced
by the WASM engine's own bring-up:

| QuickJS gate | What it tests | Why no direct WASM peer |
|---|---|---|
| `qjs-alloc-test` | QuickJS arena allocator | Engine-internal; the WASM engine has its own allocator (proven in Phase 0). QuickJS's allocator still runs *inside* `wasm-js-agent-test`. |
| `qjs-async-test` | pure JS async/await semantics | JS-language behavior → covered by `wasm-js-agent-test` (landed: QuickJS-on-wasm runs real JS); runtime-level async is covered by `wasm-async-agent-test` above. |
| `qjs-io-test` | QuickJS JS I/O feature | JS-language behavior → `wasm-js-agent-test`. |
| `qjs-worker-test` | QuickJS worker feature | JS-language behavior → `wasm-js-agent-test` (verify Javy supports it; if not, document as a JS feature absent on the WASM path). |
| `qjs-mc-host-test` | MC-hosted QuickJS variant (host front-end `examples/apps/qjs_host.mc`, in MC instead of the C `qjs_host.c`) | **Classified: QuickJS-host-specific, no direct WASM peer.** It exercises the *host glue* — the exact layer the migration replaces with the wasm3 engine + WASI shim (a standard C boundary; the plan defines no MC-hosted WASM variant). The underlying property — *MC can host a confined, untrusted engine* — is already proven on the WASM path by `wasm-run-test` / `wasm-wasi-hello-test`, where wasm3 is built freestanding against the all-MC libc and run confined. Disposition: retired with `qjs_host.c`/`qjs_host.mc` in Phase 8; kept until then as a QuickJS-path regression test. |

Keep both tables current as `qjs-*` gates are added. Phase 8 may not start until
every Group A row is ☑ and every Group B row has a confirmed disposition.

**Phase 6 status: COMPLETE.** Every Group-A runtime-substrate row has a green WASM
peer on both backends (M-mode + S-mode + real-TCP + cross-arch aarch64/x86-64), and
every Group-B row has a confirmed disposition (the rows above are covered collectively
by `wasm-js-agent-test`/`wasm-js-nettool-test` or are engine-internal/host-specific).
The Phase-8 precondition (all Group-A ☑, all Group-B dispositioned) is satisfied.

### Phase 7 — JS performance benchmark: QuickJS-on-WASM vs native QuickJS

Status: **v0 LANDED** — gate `wasm-js-bench-test` / `llvm-wasm-js-bench-test` (both in `m0`).
It runs the SAME deterministic JS workload (`examples/agents/agent_bench.js` ≡
`examples/apps/wasm/wasi_js_bench.c`) on both confined paths and emits
`zig-out/wasm-js-bench-<backend>.json`. The gate is **functional-parity-based** (both paths
must reach the SAME numeric result — deterministic) plus report completeness; QEMU timings
are recorded but **not** gated on a ratio (QEMU wall time is not deterministic), with only a
generous absolute sanity cap.

**Measured under QEMU (TCG; indicative only — the production decision must use the
target-board profile):** on the compute-dominated workload, native QuickJS and
QuickJS-on-WASM agree on the result; QuickJS-on-WASM runs ≈ **11–12× slower** wall-clock
(wasm3 interprets the engine), its confined U-mode image is ≈ **66%** of native (wasm3 +
the wasm module vs the full native QuickJS), and it has a markedly **tighter JS heap** — an
800-object + JSON workload that native handled threw `InternalError: out of memory` on the
WASM path (the QuickJS heap is bounded by the wasm linear memory carved from the libc arena).

**Phase-8 implication:** correctness parity holds, but the WASM JS path is materially slower
and more memory-constrained on this profile. Per §4/§8 this means **keep native QuickJS behind
a build/runtime flag for `manifest.runtime = js`** rather than deleting `qjs_host.c` outright;
the retire-vs-keep call is deferred to a target-board (not QEMU) measurement. Remaining v1
work (heavier corpus: cold-start, warm-throughput, alloc/GC, host-API latency) is optional
follow-up and does not block the Phase-8 disposition above.

Goal: decide with data whether JS bundles can default to QuickJS-on-WASM, or
whether the native QuickJS host must remain for performance-sensitive JS agents.
This is a release gate before retiring `qjs_host.c`; correctness parity alone is
not enough.

- Add a benchmark runner that executes the **same JS corpus** on both paths:
  native QuickJS (`qjs_host.c`) and QuickJS compiled to `wasm32-wasi` running on
  the WASM host. Use identical backend, QEMU mode, agent policy, and input data.
- Benchmark at least:
  - cold start + first eval latency;
  - warm eval throughput;
  - allocation/GC-heavy JS;
  - JSON/object/array-heavy agent logic;
  - JS host-API calls (`host_async`, `host_fs_*`, `host_net_fetch`) once Phase 4b
    lands, measuring both latency and broker/audit parity.
- Record memory separately from latency: U-mode image size, configured libc arena,
  peak used heap/linear memory, and any loader segment pressure. The current 14 MiB
  QuickJS-on-WASM arena requirement is a measured input, not an acceptable default
  forever.
- Produce a stable report artifact, e.g. `zig-out/wasm-js-bench.json`, containing
  native values, WASM values, ratios, backend, QEMU mode, and git commit.
- Decide explicit thresholds before Phase 8: `_P×_` memory and `_Q×_` latency from
  §4. If JS-on-WASM exceeds them, keep native QuickJS behind a build/runtime flag
  for `manifest.runtime = js`; do not retire `qjs_host.c`.

**Gates:** `wasm-js-bench-test` / `llvm-wasm-js-bench-test` — emit the comparison
report and fail if required measurements are missing or exceed the configured
retirement thresholds. These gates should be deterministic enough for release
qualification; they may use generous CI thresholds, but the production decision
must use the target-board profile.

### Phase 8 — Retire the QuickJS host (not QuickJS)

Status: **OPEN** (gated on Phase 6 green + the Phase 7 benchmark decision).

Goal: remove the hand-written JS-specific host once WASM has parity.

- Make the WASM host the **default** agent runtime.
- **Remove** `examples/apps/qjs_host.c` (the hand-written glue / "the hack").
- **Keep** QuickJS-the-engine, reborn as a WASM guest via Javy (Phase 4). JS
  agents keep working.
- Optionally keep the native QuickJS host behind a build flag **only** if Phase-5
  resource work or Phase-7 benchmark data shows the WASM JS path is unacceptable
  for a target board; otherwise
  delete it. Decide with data, not by default.
- Update `docs/future-kernel-plan.md` §11.1/§11.2, `docs/quickjs-agent-plan.md`,
  and `docs/todo.md` to reflect WASM as the primary runtime.

> Do not start Phase 8 until Phase 6 is green **and** the Phase-7 benchmark decision
> is recorded. The QuickJS host is the only fully gated runtime and the migration's
> differential oracle; it must not be removed while it is still proving the WASM path
> or while JS-on-WASM performance is unresolved.

---

## 6. Bundle format impact

`future-kernel-plan.md` §12 already specifies `runtime type: js | wasm` in the
agent bundle. This migration makes `wasm` real:

- `manifest.runtime = wasm` selects the WASM host.
- `manifest.runtime = js` can be served by Javy-on-WASM (Phase 4+) — i.e. `js`
  becomes a packaging convenience that compiles to `wasm`, not a separate native
  runtime.
- Declared capabilities in the manifest become the preopens / NetCap allowlist /
  fuel + memory budgets handed to the instance. The WASI world a bundle requests
  must be a subset of what its capabilities authorize, checked at admission.

This dovetails with signed-bundle admission (`production-ops-test`) — the runtime
type and requested world are part of the signed, version-checked metadata.

---

## 7. ABI discipline

The migration must **not** widen the trap surface. Rules:

- The six syscalls (`SYS_WRITE/READ/GETPID/EXIT/SUBMIT/POLL`) stay frozen.
- New capability operations are added as `TOOL_OP_*` values (append-only) in
  `user/abi.mc`, never as new syscalls. Appending a future `TOOL_OP_RANDOM` (not yet added) or
  finer-grained FS/net ops is safe; renumbering existing ops or structs is not
  (the C host mirrors offsets byte-for-byte — see `user/abi.mc` ↔ `qjs_host.c`).
- `ToolReq` (40 B) and `ToolEvent` (24 B) layouts are stable. If a WASI op needs
  more than the `MAX_REQ_BYTES`/`MAX_RES_BYTES` (256 B) payload, it must chunk,
  not grow the struct.
- New **errno values** (e.g. `E_QUOTA` for budget failures, §5) are append-only
  additions to the `user/abi.mc` errno set and are ABI-safe; reusing an existing
  value as an overload is also allowed if documented. Never renumber an existing
  errno.
- Every new `wasm-*` gate asserts the same audit (`ipc_trace`) behavior as its
  `qjs-*` peer — audit parity is part of the definition of parity.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| WASM engine bloats the U-mode image / won't fit `user.ld` | Spike with wasm3 (tiny); measure early in Phase 0; AOT (WAMR) trades engine size for module size |
| Engine pulls in host-OS assumptions (mmap, threads, JIT) | Use the engine's platform porting layer; interpreter/AOT only, no JIT; implement the porting shims against our libc/syscalls |
| WASI surface creep reintroduces ambient authority | Curated WIT world (Phase 5); preopen-only fs; **fetch-only egress to allowlisted endpoints — no general sockets** until a consciously-scoped opt-in (Phase 3); explicitly document omitted interfaces |
| Sync WASI over async kernel deadlocks the single-threaded guest | Reuse `ToolPump` submit-then-drain; the pattern is already proven by `user/agent_async.mc` |
| Losing JS capability | Phase 4a proves JS *executes* on WASM (`wasm-js-agent-test`) and Phase 4b proves a JS agent drives the broker (`wasm-js-nettool-test`); the Phase 6 sweep and Phase 7 JS performance benchmark are still required before any QuickJS-host removal (Phase 8 is gated on Phase 6 + Phase 7) |
| Backend/arch divergence | Every gate runs on both backends; Phase 6 sweeps all three arches before `m0` inclusion |
| Removing the oracle too early | Phase 8 is gated on Phase 6 green plus the Phase-7 benchmark decision; migration-safety rule forbids early removal |

---

## 9. Open questions

1. **WASI version target.** P1 first (simplest, widest toolchain support) then a
   curated P2 world — or jump straight to P2/component-model? P1 is the cheaper
   proof; P2 is the better long-term capability fit. Lean P1 → P2.
2. **Engine: wasm3 vs WAMR for production.** Spike wasm3; benchmark WAMR AOT on a
   target board profile before committing.
3. **w2c2 path.** Is compiling `.wasm` → C through MC's own C backend worth the
   parity-machinery integration? Evaluate in Phase 5.
4. **JS perf on WASM.** Does QuickJS-on-WASM meet target-board memory and latency
   budgets, or must a native QuickJS host survive behind a flag? Decide with
   Phase-7 benchmark data.
5. **Fuel source.** WAMR instruction budget vs wasmi fuel vs interpreter-tick
   counting — which integrates cleanest with the existing budget manager?

---

## 10. First concrete step

The cheapest move that de-risks everything: **Phase 0 spike** — vendor wasm3,
build it freestanding like `qjs_host.c`, and get a hand-built `.wasm` to print
through `SYS_WRITE` under QEMU, gated as `wasm-run-test` on both backends. That
single gate proves the engine confines, links, and reaches the kernel — the
whole rest of the plan is then incremental shimming against an unchanged syscall
boundary (with only append-only tool-op and audit-coverage additions below it).
