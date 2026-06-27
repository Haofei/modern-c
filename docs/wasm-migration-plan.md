# WASM migration plan: from the QuickJS host to a general WASM/WASI runtime

Status: **roadmap / direction document**.

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

Note one current asymmetry the migration must account for: **FS denials are
audited, but net-broker denials are not** — `net_broker.mc` records only admitted
egresses (`net_policy_admit` audits after the allowlist check passes; a denied
destination "spends no budget, sends no packet, and is not audited"). See Phase 3.

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
| Tool op catalog | `user/abi.mc` (`TOOL_OP_*` values) | **Append-only** — adds `TOOL_OP_RANDOM` (Phase 1); `TOOL_OP_NET_*` only if general sockets are later opted into (Phase 3 default reuses `TOOL_OP_NET_FETCH`) |
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
| `random_get` | (new `TOOL_OP_RANDOM` over kernel rng) | — |
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
| **QuickJS baseline (image size + JS hello latency + RSS)** | recorded, not bounded — this *is* the reference all other rows are set from. **Measured (`qjs-run-test`, C backend, bare-metal `virt.ld`):** engine `.text` ≈ **780 KB** (799,490 B), `.data` 4,320 B, ELF file 1.84 MB; `.bss` 8.0 MB is the reserved heap/stack region in `virt.ld`, not steady-state footprint. JS hello = the `1+2*3==7` eval; end-to-end QEMU run is dominated by boot, not eval. (Confined `qjs_host` agent image to be measured at Phase 2.) | Phase 0, step 0 | n/a (measurement) |
| U-mode image size (engine + shim) | ≤ _N×_ the current `qjs_host` image; must fit `user.ld` at base `0x10000`. **Measured (`wasm-run-test`, C backend, bare engine, no shim yet):** wasm3 `.text` ≈ **89 KB** (90,946 B) vs QuickJS 780 KB → **N ≈ 0.11×** (~8.8× smaller). Guest `hello.wasm` 440 B. Huge headroom; revisit once the WASI shim + a real guest land (Phase 1–4). | Phase 0 | Prefer wasm3 (interpreter, tiny); if still over, AOT-trim or abort |
| Per-instance linear memory | ≤ the agent's `heap-bytes` budget (`future-kernel-plan.md` §7) | Phase 1 | Cap instance memory; deny with the quota errno (see note) |
| WASI hello latency vs native | ≤ _Mx_ the QuickJS hello path | Phase 1 | Acceptable for I/O-bound agents (most agent time is awaiting brokered I/O); if compute-bound, evaluate AOT (WAMR/w2c2) |
| **JS-on-WASM (Javy) memory** | ≤ _P×_ native QuickJS | Phase 4 | See below — keep native QuickJS host behind a flag (Phase 7) |
| **JS-on-WASM (Javy) latency** | ≤ _Q×_ native QuickJS | Phase 4 | Same |

**The Javy double-layering cost is real and must be measured, not assumed away.**
Running JS via Javy means QuickJS is compiled to WASM and then interpreted by the
WASM engine — two interpreter layers stacked (engine → QuickJS bytecode → JS),
with QuickJS's heap living *inside* the WASM linear memory. Expect a meaningful
memory and latency penalty versus today's native QuickJS host. Phase 4 must
quantify it; §9 Q4 ("JS perf on WASM") is decided by these two rows, and Phase 7
keeps the native QuickJS host behind a build flag if the JS path regresses past
budget.

### Abort / rollback criteria

The migration has a defined off-ramp — it is not all-or-nothing:

- The QuickJS host stays the gated default throughout (the migration-safety rule),
  so "abort" simply means "stop advancing the WASM path"; nothing is lost.
- **Hard aborts:** the engine cannot be built JIT-free for a target arch; or the
  Phase-0 image cannot be made to fit `user.ld`; or no engine meets the image
  budget even at wasm3's footprint.
- **Soft stop (ship WASM for non-JS, keep native QuickJS for JS):** if Phase-4
  Javy memory/latency regresses past budget but Phases 0–3 meet theirs, ship the
  WASM runtime for `wasm` bundles and keep the native QuickJS host for `js`
  bundles. This still delivers multi-language agents; only the "retire the host"
  goal (Phase 7) is deferred.

---

## 5. Phases

Each phase lands a deliverable plus one or more gates, on **both backends**
(C + LLVM) per project convention, validated in Docker (host skips
LLVM/QEMU/kernel gates; run the full gates in Docker via the
`tools/toolchain/*.sh` scripts). New gates wire into
`build/tiers.zig` next to the existing `qjs-*` gates.

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
`proc_exit`, `clock_time_get`, `clock_res_get`, `random_get`, `environ_*`/`args_*` empty,
`fd_prestat_get`→`EBADF` (no preopens yet), `sched_yield`, `poll_oneoff`→`ENOTSUP`), with a
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
recorded by `agent_fs_call`→`ipc_trace`, exactly as the JS path. Gated as `wasm-realtool-test`
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
- Verify denial paths: a path outside the preopen returns a WASI `errno` derived
  from the broker's `-E_DENIED`/`-E_NOCAP`, and the denial is audited
  (`ipc_trace.mc`) exactly like the JS path.

**Gate:** `wasm-realtool-test` / `llvm-…` — file write+read through the broker;
**plus** a denied-path case asserting an audit deny event. Mirrors
`qjs-realtool-test`.

### Phase 3 — Network via a fetch-only WASI surface → NetCap

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
- **Net-deny audit (required, currently absent).** Unlike the FS broker, the net
  broker does **not** audit denied destinations — `net_policy_admit` records only
  admitted egresses. For an audit-focused kernel, a blocked exfil attempt should
  be observable. Add a deny-path audit record to `net_broker.mc` so net reaches
  FS-deny parity. (Append-only audit *coverage*; no allow/deny decision changes.
  Broker work, not WASM work, but Phase 3 depends on it.)
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

Goal: prove existing JS agents survive the migration, so retiring the JS-specific
host loses no capability.

- Build the JS agents as WASM via **Javy** (QuickJS-ng compiled to `wasm32-wasi`)
  or `componentize-js`. The JS source is the same; only the packaging changes.
- The JS `host_async`/`host_fs_*`/`host_net_fetch` surface is re-exposed to the
  guest by the Javy host bindings, which the shim resolves to the same
  `TOOL_OP_*` as today.
- Run the existing JS agent scenarios on the WASM path.

**Gate:** `wasm-js-agent-test` / `llvm-…` — an existing JS agent runs on the WASM
runtime and produces the same observable broker/audit trace as the QuickJS host.
This is the keystone gate: it demonstrates JS is preserved (per the
already-decided "keep JS, retire the hack" direction).

### Phase 5 — Async, fuel, budgets, P2 worlds

Goal: use WASM's strengths and align with the resource-budget model.

- **Fuel metering** → CPU-ticks/event-loop budget (`future-kernel-plan.md` §7).
  WAMR per-instance instruction budget or wasmi fuel; deny with the quota errno
  (see note below).
- **Quota errno.** `user/abi.mc` does **not** currently define `E_QUOTA` — the
  errno set is `E_AGAIN` (-11), `E_DENIED` (-13), `E_FAULT` (-14), `E_NOCAP`
  (-105), `E_TIMEDOUT` (-110), `E_CANCELED` (-125). Two choices: (a) **add
  `E_QUOTA` as an append-only errno** (`future-kernel-plan.md` §7 already
  anticipates it, and it keeps "budget exceeded" distinct from "denied by
  policy") — recommended; or (b) **map to existing errno**: hard caps → `-E_NOCAP`,
  transient backpressure → `-E_AGAIN`. Adding an errno value is append-only and
  ABI-safe (§7); pick (a) unless you want zero ABI surface change, in which case
  use (b) and document the overload. Until decided, this plan writes "quota errno"
  rather than assuming `-E_QUOTA` exists.
- **Linear-memory cap** → JS/WASM heap-bytes budget.
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

**Parity matrix.** The contract for Phase 7 is: every `qjs-*` gate is either
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
| S-mode confined | `qjs-smode-confined-test` | `wasm-smode-confined-test` | ☐ |
| Agent (syscall-driven) | `qjs-agent-test` | `wasm-agent-test` | ☐ |
| Agent smoke | `qjs-agent-smoke-test` | `wasm-agent-smoke-test` | ☐ |
| S-mode agent | `qjs-smode-agent-test` | `wasm-smode-agent-test` | ☐ |
| Async agent | `qjs-async-agent-test` | `wasm-async-agent-test` | ☐ |
| S-mode async agent | `qjs-smode-async-agent-test` | `wasm-smode-async-agent-test` | ☐ |
| Broker agent | `qjs-broker-agent-test` | `wasm-broker-agent-test` | ☐ |
| FS tool (allow + deny audit) | `qjs-realtool-test` | `wasm-realtool-test` | ☑ (Phase 2 landed; both backends in `m0`) |
| Net fetch (mock) | `qjs-nettool-test` | `wasm-nettool-test` | ☑ (Phase 3a landed; both backends in `m0`) |
| Net fetch (real TCP) | `qjs-net-realtool-test` | `wasm-net-realtool-test` | ☐ |
| S-mode net IRQ | `qjs-smode-net-irq-tool-test` | `wasm-smode-net-irq-tool-test` | ☐ |
| S-mode blk IRQ | `qjs-smode-blk-irq-tool-test` | `wasm-smode-blk-irq-tool-test` | ☐ |
| Quota / backpressure | `qjs-quota-agent-test` | `wasm-quota-agent-test` | ☐ |
| Cancel | `qjs-cancel-test` | `wasm-cancel-test` | ☐ |
| Cancel edges | `qjs-cancel-edges-test` | `wasm-cancel-edges-test` | ☐ |
| Spurious completion id | `qjs-spurious-agent-test` | `wasm-spurious-agent-test` | ☐ |
| Cross-arch x86_64 | `x86-qjs-test` / `x86-qjs-async-test` | `wasm-*` x86_64 peers | ☐ |
| Cross-arch aarch64 | `arm-qjs-test` / `arm-qjs-async-test` | `wasm-*` aarch64 peers | ☐ |

**B. QuickJS-engine / JS-language gates — no direct WASM-engine peer**; JS
behavior is instead proven collectively on the WASM path by the Phase-4 keystone
`wasm-js-agent-test` (Javy = QuickJS-on-WASM), or is engine-internal and replaced
by the WASM engine's own bring-up:

| QuickJS gate | What it tests | Why no direct WASM peer |
|---|---|---|
| `qjs-alloc-test` | QuickJS arena allocator | Engine-internal; the WASM engine has its own allocator (proven in Phase 0). QuickJS's allocator still runs *inside* `wasm-js-agent-test`. |
| `qjs-async-test` | pure JS async/await semantics | JS-language behavior → covered by `wasm-js-agent-test`; runtime-level async is covered by `wasm-async-agent-test` above. |
| `qjs-io-test` | QuickJS JS I/O feature | JS-language behavior → `wasm-js-agent-test`. |
| `qjs-worker-test` | QuickJS worker feature | JS-language behavior → `wasm-js-agent-test` (verify Javy supports it; if not, document as a JS feature absent on the WASM path). |
| `qjs-mc-host-test` | MC-hosted QuickJS variant | **TBD — classify in Phase 6** (confirm whether this exercises host glue that has a WASM analogue, or is QuickJS-host-specific and retired with the host). |

Keep both tables current as `qjs-*` gates are added. Phase 7 may not start until
every Group A row is ☑ and every Group B row has a confirmed disposition.

### Phase 7 — Retire the QuickJS host (not QuickJS)

Goal: remove the hand-written JS-specific host once WASM has parity.

- Make the WASM host the **default** agent runtime.
- **Remove** `examples/apps/qjs_host.c` (the hand-written glue / "the hack").
- **Keep** QuickJS-the-engine, reborn as a WASM guest via Javy (Phase 4). JS
  agents keep working.
- Optionally keep the native QuickJS host behind a build flag **only** if Phase-5
  perf data shows the WASM JS path is unacceptable for a target board; otherwise
  delete it. Decide with data, not by default.
- Update `docs/future-kernel-plan.md` §11.1/§11.2, `docs/quickjs-agent-plan.md`,
  and `docs/todo.md` to reflect WASM as the primary runtime.

> Do not start Phase 7 until Phase 6 is green. The QuickJS host is the only fully
> gated runtime and the migration's differential oracle; it must not be removed
> while it is still proving the WASM path.

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
  `user/abi.mc`, never as new syscalls. Appending a `TOOL_OP_RANDOM` (Phase 1) or
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
| Losing JS capability | Phase 4 keystone gate proves JS-on-WASM parity before any QuickJS-host removal |
| Backend/arch divergence | Every gate runs on both backends; Phase 6 sweeps all three arches before `m0` inclusion |
| Removing the oracle too early | Phase 7 is gated on Phase 6 green; migration-safety rule forbids early removal |

---

## 9. Open questions

1. **WASI version target.** P1 first (simplest, widest toolchain support) then a
   curated P2 world — or jump straight to P2/component-model? P1 is the cheaper
   proof; P2 is the better long-term capability fit. Lean P1 → P2.
2. **Engine: wasm3 vs WAMR for production.** Spike wasm3; benchmark WAMR AOT on a
   target board profile before committing.
3. **w2c2 path.** Is compiling `.wasm` → C through MC's own C backend worth the
   parity-machinery integration? Evaluate in Phase 5.
4. **JS perf on WASM.** Does Javy-on-WASM meet target-board latency, or must a
   native QuickJS host survive behind a flag? Decide with Phase-5 data.
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
