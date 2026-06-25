# Plan: run a QuickJS agent on the kernel, contained, via the userspace ABI

Status: **plan / not started.** This is the concrete, phased path to running QuickJS as a
genuinely-untrusted JavaScript agent on the MC kernel — the "step 0 target" named in
`docs/agent-sandbox-milestone.md`. It builds on substrate that already exists, so most of
the risk people fear is already retired.

## 0. End state

The agent is an isolated U-mode ELF — a QuickJS engine plus a **custom non-CLI front-end**
(`qjs_agent.c`, NOT the stock `qjs.c`, which expects `argc/argv` and a host filesystem). It
has no command line; it obtains its script through a **defined ingress** (§0) and runs:

```
[kernel] loads qjs-agent ELF into an isolated Sv39 space (kernel UNMAPPED)
   └─ qjs_agent _start -> JS_NewRuntime -> obtain script bytes (ingress) -> JS_Eval
   └─ JS reaches the kernel ONLY through ecall syscalls
   └─ all effects (fs/net/tools) go through the capability front door (PathCap/NetCap/
      tool allowlist + budget), audited to the ipc_trace ring, attributed to the agent
   └─ JS_FreeRuntime -> SYS_EXIT(rc)
```

There is no host shell on the kernel, so "`qjs-agent agent.js`" is conceptual; the script is
delivered by the ingress below, not an argv path.

### Script ingress (resolves "how does agent.js get in?")
Three options, in rising order of capability-integration:
1. **SYS_READ from a kernel-staged input channel (v0 default).** The kernel stages the
   script bytes (embedded in the boot image / a fixed input buffer) and the agent
   `SYS_READ`s them on fd 0 until EOF. Simplest; good enough to prove the spine.
2. **Capability FS path.** The agent is granted a read-only `PathCap` to a script file and
   reads it via `SYS_TOOL(op=READ)`. Goes through the same audited front door as every other
   effect — the right long-term answer.
3. **Host-side wrapper embeds it** at build time (a generated C array). Fine for fixtures/CI.

Pick (1) for the first running agent; move to (2) once the capability FS path is in. No
`argv`/`envp`/CLI parsing is needed in any of these — the front-end calls `JS_Eval` on the
ingested bytes directly. (If a stock `qjs.c` were ever used instead, the loader would have to
synthesize an initial stack with `argc/argv/envp` and an `auxv`; the custom front-end avoids
all of that.)

QuickJS sits **outside** the kernel trust boundary by construction (it is the contained
agent, not kernel code) — which is exactly the agent-sandbox design intent ("speak MCP /
run agents, enforce with MC capabilities; never drag an opaque runtime *inside* the trust
boundary").

## 1. What already exists (de-risking)

| Need | Status | Evidence |
|---|---|---|
| Drop to U-mode, ecall trap path, PMP | done | `kernel/arch/riscv64/usermode_runtime.c` |
| Syscall dispatch (fn-ptr table, bounds/ENOSYS) | done | `kernel/core/syscall.mc` |
| ISOLATION mechanism: a separate ELF in an isolated Sv39 space (kernel unmapped), entered confined | done | `agent_confined_runtime.mc` + `tests/qemu/proc/agent_confined_demo.mc` |
| Multi-segment ELF LOADER (text/rodata/data/bss, per-segment perms, stack+arena) | **DONE — gated.** The real loader maps every `PT_LOAD` at its vaddr with per-segment R/W/X perms, copies file bytes, zeroes bss | `elf-loader-test` (synthetic 2-segment image); `app-run-test` loads a real multi-segment app ELF |
| Page-table-aware uaccess (copy_from/to_user_pt over a UserAddrSpace) | **DONE — wired into the app runtime.** A loaded app runs confined in an isolated U-mode space and its `SYS_WRITE` goes through `copy_from_user_pt` over a per-agent `UserAddrSpace` | `kernel/core/uaccess_pt.mc` + `app-run-test` |
| Confined agent drives a capability tool front door (allow/deny, audited) | done | `agent_confined_tool_demo.mc` + the M1–M6 substrate (treefs/fs_toolserver/agent_fs/policy/netcap/mcp) |
| Vendor + freestanding-build a large third-party C library | done | `third_party/bearssl/` compiled with the riscv freestanding toolchain (`bearssl_smoke_runtime.c`) |
| Heap / allocator | partial | `std/alloc.mc` (alloc_bytes/free_bytes), kernel heap |
| libc core | minimal | `std/libc.mc`: memeq/strlen/atoi |
| libm | thin | `std/math.mc`: sqrt/sin/cos/exp/log/tanh only |
| Threads: a COOPERATIVE round-robin scheduler + context switch | done | `kernel/core/sched.mc` ("cooperative for now; timer-tick preemption is the next step"), `kernel/arch/riscv64/context.mc` |
| Timer-tick preemption | demonstrated in a demo runtime, NOT in the core scheduler | `tests/qemu/proc/preempt_demo.mc` (timer → `sched_yield`) |
| SMP per-core run-queue + work-steal | a PRIMITIVE only, not an integrated confined-U-mode SMP scheduler | `kernel/core/smprq.mc` |
| Message passing (Worker postMessage) | primitive present, NO internal locking | `kernel/lib/mailbox.mc` (post/take; blocking layered by the caller) |
| Real TCP/HTTP transport | present, but **SYNCHRONOUS / poll-mode + blocking** — `virtio_net` serves frames in "poll mode"; `net_fetch_tcp` blocks connect→send→recv | `kernel/drivers/virtio/virtio_net.mc:497`, `kernel/net/net_broker_tcp.mc` |
| Async I/O ABI: non-blocking submit + poll + completion path + front-end event loop | **PARTIAL (Phase 7)** — delivered: the JS event loop, the `SYS_SUBMIT`/`SYS_POLL` async ABI, Promise completion, backpressure/quotas, structured JS errors, and the real capability-checked FS broker from JS. PENDING: making **net-fetch completion-driven** (TCP/HTTP is still blocking poll-mode). | `qjs-async-test`, `qjs-io-test`, `qjs-agent-test`, `qjs-async-agent-test`, `qjs-realtool-test` |
| Userspace thread spawn + Workers (CPU-parallel) + concurrency hardening | NOT done (Phase 8 — optional) | — |

The two things people fear most — "can it run a big foreign C blob?" and "can it be
truly contained?" — are **already proven** (BearSSL; agent_confined). The remaining work is
a bounded porting job.

## 2. Architecture

```
  ┌─────────────────────────── isolated U-mode ELF (the agent) ──────────────────────────┐
  │  qjs_agent front-end → QuickJS core (quickjs.c, libregexp.c, libunicode.c, cutils.c)  │
  │        │                    │                                                         │
  │        │              freestanding libc shim (malloc/str*/snprintf) + libm            │
  │        │                    │                                                         │
  │        └────────────── quickjs-libc-mc.c (OS bindings → ecall) ───────────────────────┤
  │                              │  ecall(SYS_*)                                           │
  └──────────────────────────────┼───────────────────────────────────────────────────────┘
                                 ▼  (kernel UNMAPPED above; only the ecall vector is reachable)
  ┌──────────────────────────── kernel (M-mode) ─────────────────────────────────────────┐
  │  syscall_dispatch  →  thin ABI handlers  →  capability front door (agent_fs_call /     │
  │                                              net_fetch / mcp_call)  →  audited          │
  └───────────────────────────────────────────────────────────────────────────────────────┘
```

QuickJS never touches MMIO or kernel memory; every effect is an `ecall` that lands in a
capability-checked handler.

## 3. The syscall ABI (stable, versioned)

A single shared header of numbers + signatures, consumed by the kernel (registers
handlers) and the user runtime (wrappers).

### 3.1 Register/arity convention (constraint, not assumption)
The current handler type is `fn(u64, u64, u64) -> u64` and the trap forwards only the
syscall number + three args: `mc_syscall(a7, a0, a1, a2)`
(`kernel/core/syscall.mc`, `kernel/arch/riscv64/usermode_runtime.c:80`). The trap frame
*saves* a0..a7, so widening is a small change, but the ABI is designed to **fit three args**
rather than depend on a widening:
- **Simple syscalls fit in ≤3 args** and use the table as-is.
- **Compound syscalls (tool/net) take ONE arg: a pointer to a request struct** in user
  memory, copied in by the kernel (see §3.3). This sidesteps the arity limit *and* gives one
  uniform place to do checked copy-in.
- Optional alternative: widen `mc_syscall`/`syscall_dispatch`/the handler type to a0..a5
  (the frame already has them). Prefer the request-struct form — it also solves §3.3.

### 3.2 Calls

```
SYS_WRITE   (fd, ptr, len)            -> isize  (>=0 bytes, <0 = -errno)   // 3 args, fits
SYS_READ    (fd, ptr, len)            -> isize                              // 3 args, fits
SYS_EXIT    (code)                    -> noreturn
SYS_GETPID  ()                        -> u64
SYS_CLOCK   ()                        -> u64 (monotonic ns)                 // Date / timers
SYS_SBRK    (delta)                   -> usize (old break) | (usize)-1 err  // heap growth
SYS_TOOL    (req_ptr)                 -> isize  (>=0 result, <0 = -errno)   // req = ToolReq* (blocking)
SYS_NET     (req_ptr)                 -> isize                              // req = NetReq*  (blocking)
// --- async I/O (Phase 7; the concurrency a real agent needs) ---
SYS_SUBMIT  (req_ptr)                 -> handle | <0 err   // non-blocking submit of a Tool/Net request
SYS_POLL    (events_ptr, max, timeout)-> n_ready           // completed handles + results; blocks only if idle
```

**Return/error convention:** every value-returning syscall returns an `isize` in a0; a
non-negative value is the result (bytes, pid, …), a negative value is `-errno` from a fixed
enum (`E_DENIED`, `E_NOCAP`, `E_FAULT` (bad user pointer), `E_INVAL`, `E_AGAIN`, …). The user
wrappers map this back to a `Result`.

### 3.3 User pointers go through page-table-aware uaccess (NOT raw)
`agent_confined_tool_demo` deliberately passes a kernel-resolved `path_id` to **avoid** raw
user pointers. The real ABI must accept user-named paths/buffers, so the kernel must copy
them in/out through the agent's page table — never dereference a user pointer directly. The
primitive already exists: `kernel/core/uaccess.mc`'s `UserAddrSpace` +
`copy_from_user_pt`/`copy_to_user_pt`/`fetch_user_pt` (page-table-aware; validates PTE_U/R/W
per page; fails closed on an unmapped/kernel page). The confined app runtime must:
1. build a `UserAddrSpace` over the agent's page table at load time, and
2. for `SYS_TOOL`/`SYS_NET`, `copy_from_user_pt` the request struct, then `copy_from_user_pt`
   each path/input buffer it references (bounded by a max length), and `copy_to_user_pt`
   results back. A bad pointer ⇒ `-E_FAULT`, never a kernel fault.

```
struct ToolReq { op: u32, cap: u32, path_ptr: u64, path_len: u32, buf_ptr: u64, n: u32 }
struct NetReq  { op: u32, cap: u32, host_ptr: u64, host_len: u32, port: u16, buf_ptr: u64, n: u32 }
```

Each compound handler is the EXISTING capability path — `agent_fs_call` / `net_fetch` /
`mcp_call` — fed copied-in (kernel-owned) bytes, so the agent gets no authority the kernel
hasn't granted, and every call is audited + attributed to the agent pid. `SYS_MAX = 16` is
enough for this set.

### 3.4 Network: brokered, not raw egress (resolves the audit question)
Two layers exist: `net_egress_check` (a raw connect allow/deny gate, for when the agent
holds a socket) and a brokered request the kernel performs on the agent's behalf. For a JS
agent, **default to brokered** `SYS_NET(op=FETCH)`: the agent never holds a raw socket; the
kernel does the transport and returns the bytes as a **single audited fetch event**
(host+port+size, attributed). This is stronger containment and cleaner audit semantics than
gating raw connects. `net_egress_check` remains the lower-level primitive for a future
raw-socket capability if one is ever granted.

**Audit note (current reality):** FS/path-cap denials ARE audited (the `fs_toolserver`/
`agent_fs` path records denied attempts), but the **brokered net path audits only ADMITTED
egress** — `net_broker` states a denied destination "spends no budget, sends no packet, and
is NOT audited as a real egress." So "every forbidden effect is audited" is true for FS today
but NOT for brokered net. Phase 7 must add a **denied-at-submit audit record** for async
broker calls (a deny event tagged to the agent) to make the claim uniform; until then the
acceptance language distinguishes the two (see §5).

### 3.5 Async memory ownership (no retained user pointers)
A non-blocking `SYS_SUBMIT` opens a window between submit and completion during which the
agent's JS thread keeps running — it may move (GC), free, reuse, or (in principle) unmap the
buffers it named. **The kernel must therefore retain NO user pointer across that window:**
- **At submit:** `copy_from_user_pt` **all** referenced input bytes (the request struct AND
  every path/body it points at, each bounded by a max length) into **kernel-owned** buffers.
  After `SYS_SUBMIT` returns, the kernel holds only kernel memory — the agent may do anything
  to its own buffers.
- **The result** lives in a **kernel-owned** completion buffer (bounded; oversize ⇒ `E_2BIG`
  or a truncation flag).
- **At poll:** `SYS_POLL` takes **fresh user buffers supplied at poll time** (for example,
  each event entry names `handle/status/result_ptr/result_cap/result_len/flags`) and
  `copy_to_user_pt`s completed bytes into those buffers then — never a pointer captured at
  submit.
- A bad pointer at either step ⇒ `-E_FAULT`; the per-agent in-flight count and total async
  buffer bytes are **bounded** (a quota, tied to the policy plane) so an agent can't pin
  unbounded kernel memory by submitting and never polling.

## 4. Phases

### Phase 1 — Userspace SDK (QuickJS-agnostic; the spine) — **DELIVERED & GATED**
Goal: write `fn main() -> i32`, build it into a confined U-mode ELF, run it. Makes QuickJS
"just another app." Done end-to-end and gated by `elf-loader-test` + `app-run-test`
(both backends); the items below describe what was built.
- `user/abi.mc` — the stable `SYS_*` numbers (shared kernel↔user).
- `user/sys.mc` — typed ecall wrappers (`write`, `read`, `exit`, `getpid`, …) via MC inline asm.
- `user/start.*` — `crt0`: set sp, call `main()`, `exit(rc)`.
- **A real ELF loader** (replaced the toy). The loader iterates **every** `PT_LOAD`; maps each
  at its own `p_vaddr` with **per-segment permissions** (text R|X, rodata R, data R|W) in the
  agent's isolated page table; **zeroes bss** (`p_memsz > p_filesz`); and maps a **stack** and
  an initial **heap arena** region; honoring alignment and rejecting overlaps/out-of-range.
  The gating prerequisite for any real binary (QuickJS has text/rodata/data/bss) — done, gated
  by `elf-loader-test` (synthetic 2-segment image) and `app-run-test` (real app ELF). (The
  earlier flat-`PT_LOAD` `elf_load_run` in `tests/qemu/proc/agent_confined_demo.mc` was the toy
  it replaced.)
- `tests/qemu/proc/app_runtime.mc` — ONE reusable kernel-side runtime: isolated-Sv39 setup
  (kernel unmapped, reuse `agent_confined`), the real ELF loader above, a **`UserAddrSpace`
  built over the agent's page table** (so every user pointer is copied via
  `copy_from_user_pt`/`copy_to_user_pt` per §3.3 — no raw deref), the ABI-handler registrations
  (wired to the capability front door), and `enter_user` at the ELF entry.
- `tools/user/build-app.sh <app.mc>` — compile app + user runtime → isolated U-mode ELF, run
  under QEMU. No per-app C glue.
- `examples/apps/hello.mc` — `fn main() { write(1, "hello\n"); return 0; }`.
- Gate: `app-run-test` / `llvm-app-run-test` (both backends, QEMU; `tests/qemu/proc/app_run_demo.mc`).

**Status: DELIVERED.** The bespoke `*_user_runtime` glue is factored into one runtime, and the
real multi-segment loader + `UserAddrSpace` wiring (the substantive work) is done and gated by
`elf-loader-test` + `app-run-test` — it pays off for every app, not just QuickJS.

### Phase 2 — Freestanding libc shim (`user/libc/`)
Provide exactly what C programs need, backed by the SDK syscalls:
- `malloc/realloc/free/calloc` — over a static arena first (simplest), then `SYS_SBRK`.
- `memcpy/memset/memmove/memcmp`, `strlen/strcmp/strncmp/strcpy/strchr`, `qsort`, `bsearch`.
- `snprintf/vsnprintf` (QuickJS uses these), `abort`, `assert` → trap.
- Stub the file/stdio surface QuickJS's core touches (most goes through quickjs-libc, Phase 4).

**Effort: M.** Drive it empirically: build, read the undefined symbols, fill them.

### Phase 3 — Freestanding libm (the real gap)
QuickJS needs full `double` math: `pow fmod floor ceil round trunc fabs sqrt sin cos tan
asin acos atan atan2 exp log log2 log10 hypot copysign nextafter isnan isinf signbit`.

**Hardware-FP prerequisite (done).** The kernel/app target was integer-only (`rv64imac`); JS
numbers and libm are doubles, so any `double` arithmetic needs FP. Resolved the clean way (QEMU
virt has F/D): apps are now built with `-march=rv64imafdc -mabi=lp64d`, and the kernel enables
the FPU for U-mode by setting `mstatus.FS = Initial` in `enter_user` before `mret`
(`usermode_runtime.c`). The kernel stays integer-only (`rv64imac`) and never touches FP
registers, so the app's FP state survives across syscalls with **no save/restore** needed (a
single-agent simplification; SMP/preemption would need lazy FP context — Phase 8). The app ELF
is separate from the kernel image, so the lp64d/lp64 ABIs never link together; the syscall
boundary passes only integers.

**Exact half (done).** `user/libc/math.c` implements the bit-exact functions — `fabs copysign
signbit isnan isinf isfinite floor ceil trunc round fmod scalbn ldexp` (integer bit-twiddling
on the IEEE-754 double, no approximation) and `sqrt` (hardware `fsqrt.d`, correctly rounded).
Gated by `examples/apps/mathtest.c` (`math-app-test` / `llvm-math-app-test`, in m0): runs
confined, computes on real doubles, asserts bit-exact results.

**Transcendentals via vendored openlibm (done).** openlibm (FreeBSD msun, the standalone
libm) is vendored at `third_party/openlibm/` (BearSSL precedent). `tools/user/build-openlibm.sh`
compiles every `src/*.c` that builds freestanding (`-march=rv64imafdc -mabi=lp64d`) into a
cached `libopenlibm.a` (209 objects); the long-double/complex/Bessel/lgamma files that don't
build are skipped — JS Math references none of them, and any real miss would surface as a loud
undefined-symbol at app link, not a silent stub. The archive is linked LAST so the linker pulls
only the referenced members. This supersedes the hand-rolled exact `user/libc/math.c`, which
was removed (openlibm provides those exactly too). Gated by `examples/apps/transcendental.c`
(`trig-app-test` / `llvm-trig-app-test`, in m0): `pow/exp/log/log2/log10/sin/cos/tan/atan2/
cbrt/hypot` run confined and produce correct results.

**Phase 3 complete.** Full double libm (exact + transcendental) runs confined under hardware FP.

### Phase 4 — Vendor + build QuickJS
- `third_party/quickjs/` — the engine core only: `quickjs.c libregexp.c libunicode.c
  cutils.c`. **Do NOT use the stock `qjs.c`** (CLI/argv/host-FS front-end).
- `qjs_agent.c` — a small **custom front-end**: `JS_NewRuntime`/`JS_NewContext` → obtain
  script bytes via the §0 ingress (SYS_READ or capability FS) → `JS_Eval` → drain pending
  jobs → `SYS_EXIT(rc)`. No argv, no host FS.
- Build flags: riscv64 freestanding with hardware FP (`--target=riscv64-unknown-elf
  -march=rv64imafdc -mabi=lp64d -nostdlib -ffreestanding -mcmodel=medany`) — doubles require the
  F/D unit, enabled for U-mode in Phase 3.
- Config: disable heavy/unsupported features — **no bignum** (`CONFIG_BIGNUM` off, drops
  `__int128`), **no os/std modules** (replaced by our binding), and **Workers DISABLED in
  Phase 4** — the `Worker` constructor stubs to `E_UNSUPPORTED`. Workers are flipped on in
  Phase 8, once the spawn/mailbox substrate exists, so Phase 4 has no forward dependency.
- **`quickjs-libc-mc.c`** replaces `quickjs-libc.c`: implement only the `js_*` hooks the
  agent exposes (a `print`/console binding, and a `Tool`/`fetch` binding) against
  `SYS_WRITE`/`SYS_TOOL`/`SYS_NET` — this is the actual "QuickJS-with-the-ABI" glue, and it
  is small. The JS-visible effect surface is exactly what the capabilities permit.

**Effort: M.** Bounded by config-flag tuning + the binding + front-end. Precedent: BearSSL builds clean.

### Phase 5 — Memory provisioning
QuickJS wants MBs for non-trivial scripts.
- Start: a large static arena (e.g. 8–16 MB) handed to the malloc shim — simplest, deterministic.
- Then: `SYS_SBRK`/demand paging for a growable heap (the kernel already has demand-paging/COW
  tests). Cap it per-agent so a runaway script is bounded (ties into the policy plane).

**Effort: M.**

### Phase 6 — qjs_agent as a confined agent + capability wiring
- Build `qjs_agent + QuickJS + libc + libm + quickjs-libc-mc + user runtime` into one isolated
  U-mode ELF; load it with the Phase-1 app loader/runtime (kernel unmapped).
- Wire the JS-visible effect surface (a `Tool` global / `print` / a fetch-like API) through
  `SYS_TOOL`/`SYS_NET` → `agent_fs_call`/`net_fetch` → the PathCap/NetCap/allowlist/
  budget gates. JS can do nothing the agent's capabilities don't permit; admitted effects are
  audited to `ipc_trace` and attributed to the agent pid, FS denials are audited today, and
  brokered-net denial audit is added in Phase 7 (§3.4); the policy plane can throttle/kill.
- Gate: `qjs-agent-test` — run a fixed `agent.js` that (a) prints, (b) does an allowed
  `/workspace` write, (c) is DENIED an `/etc` write and an un-granted net egress, under QEMU,
  both backends. The acceptance shape mirrors `agent_confined_tool_demo`.

**Effort: M.** The hard parts (isolation, capability front door) are done; this is integration.

### Phase 7 — Async I/O + event loop (REQUIRED — the real-agent concurrency model)
A real agent is I/O-bound (think → call tools → wait → think), fires **concurrent** tool/fetch
calls, and streams — a sequential *blocking* loop is too weak. No JS engine supports
shared-memory threads inside one runtime (QuickJS included), so the agent's logic stays
single-threaded JS; concurrency comes from an **async event loop over non-blocking I/O**,
which is the standard model (Node/browser) and is what makes the agent actually work.
- **Non-blocking ABI:** `SYS_SUBMIT(req)` queues a Tool/Net request and returns a handle
  immediately; `SYS_POLL(events, max, timeout)` returns the completed handles + results,
  blocking the agent **only when it has nothing else to do**. (The blocking `SYS_TOOL`/
  `SYS_NET` remain for simple synchronous use.) Memory ownership follows §3.5 — submit copies
  all inputs into kernel-owned buffers, poll copies results into a poll-time user buffer; no
  user pointer is retained across the async window.
- **Kernel-side concurrency — what actually needs a thread, and what doesn't:**
  - **Interrupt/DMA-backed I/O needs NO per-request thread** — record the pending request,
    kick the device, return; a completion ISR (or the existing serve loop) posts the result;
    `SYS_POLL` collects it (the `epoll`/`io_uring` model). While the agent has nothing to do,
    the *scheduler* runs other agents — that is multitasking, not a per-I/O thread.
  - **The current net path is NOT yet completion-driven.** `virtio_net` serves in **poll
    mode** and `net_fetch_tcp` **blocks** connect→send→recv. So part of Phase 7 is making the
    transport non-blocking: drive completion from the serve/poll loop (or add RX-IRQ) and turn
    `net_fetch_tcp` into a submit→advance→complete state machine over the socket layer.
  - **A kernel worker thread is needed ONLY for genuinely-blocking ops with no completion
    event** (a slow synchronous device, heavy CPU). The in-memory capability FS is fast, so FS
    tool calls just complete synchronously in the handler (mark complete immediately) — no
    thread.
- **Front-end event loop:** `qjs_agent` runs `JS_ExecutePendingJob` (QuickJS's Promise/async
  job queue) interleaved with `SYS_POLL`; an I/O completion resolves the JS Promise that
  `SYS_SUBMIT` returned. Now `await tool(...)` and `Promise.all([...])` work, and N tool calls
  run concurrently from one JS thread.
- **Containment:** every submitted request still goes through the capability front door,
  attributed; async changes *when* the result returns, not *what is allowed*. **Add the
  denied-at-submit audit** for brokered net (per §3.4) so denied async egress is recorded +
  attributed like FS denials — required for the §5 acceptance to hold uniformly.
- Gate: `qjs-async-test` — proving REAL overlap, not a synchronous queue: `agent.js` submits
  **two DELAYED tool calls** (deterministic mock tools that complete after a set tick, or two
  real net fetches) via `Promise.all`, plus one denied call; the test asserts **both handles
  were submitted before either completion is consumed**, both results then arrive, and the
  denied one is recorded + rejected. Under QEMU, both backends.

**Effort: M–H.** The ABI + event loop are moderate; the substantive part is making the net
transport completion-driven (it is blocking/poll-mode today) and the async memory/quota
bookkeeping. **This phase, not Workers, is what a real agent needs** — do it before Phase 8.

### Phase 8 — Threads / Workers (OPTIONAL — CPU-parallel subtasks)
Workers are *not* the agent's concurrency model (that is Phase 7); they are an optional add
for **CPU-parallel** subtasks (e.g. heavy parsing/crypto in the background). QuickJS has **no
internal multithreading within one runtime**
([QuickJS os module](https://bellard.org/quickjs/quickjs.html#os-module)), so the model is
**Web-Worker-style**: each `Worker` is a SEPARATE `JS_Runtime` on its own kernel thread,
communicating only by **cloned messages** — no shared JS heap, no interpreter locking. The
kernel pieces (cooperative scheduler, context switch, run-queue primitive, mailbox) exist but
are **not yet an integrated, concurrency-hardened, confined-U-mode SMP scheduler** — Phase 8
builds that integration. Scoped in two steps:

**v0 — single-core, contained (the deliverable):**
- **User ABI:** `SYS_SPAWN(entry, arg) -> tid` (a new U-mode thread sharing the agent's ONE
  satp / page table + capabilities; per-thread stack/context) and `SYS_MSG_SEND/RECV` over a
  per-worker mailbox.
- **Scheduler integration (the real work):** make `sched`/`context` schedule **multiple U-mode
  threads that share one satp**, switching only the saved register context (not the page
  table) between an agent's threads, and accounting all of them to the one agent. The core
  scheduler is **cooperative today**; v0 runs threads cooperatively (yield at the JS event
  loop / message wait) on a single hart, with optional timer-tick preemption (the mechanism
  `preempt_demo` shows) layered in.
- **QuickJS binding:** `Worker` → `SYS_SPAWN`; `postMessage` → `SYS_MSG_SEND`; the worker
  event loop → `SYS_MSG_RECV`. Structured-clone the message bytes through the kernel
  (`copy_*_user_pt`), so the two runtimes never share heap.
- **Worker source resolution (no host FS):** QuickJS's `Worker(module_filename)` expects a
  filename; with no host filesystem, resolve it via either a **named-module registry** the
  agent is granted (capability-FS read through `SYS_TOOL`) or a custom **`Worker.fromSource`**
  that takes the module text directly. Pick `Worker.fromSource` for v0 (no FS dependency);
  move to capability-FS named modules alongside the §0 script-ingress upgrade.
- **Containment:** all worker threads share the agent's sandbox + capabilities; every effect
  is attributed to the one agent pid, and the policy budget is **shared** (workers cannot
  widen authority or escape the quota).
- Gate: `qjs-worker-test` — a fixed `agent.js` `Worker.fromSource(...)`s a worker,
  round-trips a `postMessage`, asserts the reply; **single-core**, under QEMU, both backends.

**v1 — true SMP parallelism (deferred, explicitly gated on hardening):**
Running an agent's workers on multiple harts in parallel requires concurrency-hardening that
does NOT exist yet: `mailbox.mc` has **no internal lock**, and `kernel/core/uaccess.mc` notes
that under preemption/SMP the address space must be **locked against concurrent unmap / TLB
shootdown** during `copy_*_user_pt`. So v1 adds: mailbox locking, address-space/map locking,
and SMP run-queue (`smprq`) integration — and only then claims parallel execution. Until then
Worker concurrency is preemptive-on-one-core, which is correct and sufficient for an agent.

**Sync (if shared memory is ever added):** `SharedArrayBuffer`/atomics over `std/sync`
(spinlock/rwlock/seqlock) + atomics — a v1+ item; v0 is message-passing only (simpler, safer).

**Effort: M (v0) / M–H (v1).** v0 is the spawn ABI + shared-satp scheduler integration + the
worker binding; v1 is the concurrency-hardening (locks) before SMP-parallel.

## 5. Acceptance criteria
- `examples/apps/hello.mc` builds and runs as a confined U-mode ELF (Phase 1 gate).
- A trivial `agent.js` (`print(1+2)`) runs through QuickJS on the kernel and prints `3`.
- `agent.js` doing fs/net effects: allowed ops succeed; forbidden ops are denied at the
  capability boundary it cannot bypass (kernel unmapped). **FS/path-cap denials are audited +
  attributed today; brokered-net denials are audited only after Phase 7 adds the
  denied-at-submit broker audit** (§3.4) — until then, assert net denials by their rejection,
  not by an audit record.
- **(Phase 7 — the real-agent bar)** `agent.js` submits TWO **independently-completing**
  calls (deterministic delayed mock tools, or two real net fetches) via `Promise.all`, plus
  one denied call; the test asserts **both handles were submitted before either completion is
  consumed** (proving real overlap, not a synchronous queue), both results then arrive, and
  the denied one is recorded + rejected.
- (Phase 8 v0, optional) `agent.js` `Worker.fromSource(...)`s a worker, `postMessage`s a value, the
  worker replies, and the main runtime asserts the round-trip — contained, **single-core**
  (true SMP-parallel execution is Phase 8 v1, gated on mailbox + address-space locking).
- All gates pass on **both** backends under QEMU; joined to `m0`.

## 6. Risks & how to retire each (early)
| Risk | Retire by |
|---|---|
| libm completeness / accuracy | one `nm` on a QuickJS test build → exact reference set; vendor openlibm |
| `__int128` / GCC-isms in QuickJS | `CONFIG_BIGNUM` off; build-and-fix; clang 18 handles the rest |
| `setjmp`/`longjmp` | QuickJS uses its own exception machinery; provide a minimal setjmp if anything in libc needs it |
| heap pressure / runaway script | static arena bound first; then SYS_SBRK + per-agent quota via the policy plane |
| binary size of the ELF | confinement holds at any size; only the static-arena RAM budget matters |
| multi-segment ELF layout (text/rodata/data/bss) | **DONE** — real loader (per-segment vaddr+perms+bss), gated by `elf-loader-test` + `app-run-test` |
| raw user pointers faulting the kernel | **DONE** — `UserAddrSpace` + `copy_*_user_pt` wired (`app-run-test`); a bad pointer is `-E_FAULT`, never a kernel fault |
| syscall arity (>3 args) | compound calls take one request-struct pointer (§3.1); no trap widening needed |
| script ingress / no argv | custom non-CLI front-end + SYS_READ/capability-FS ingress (§0); no initial-stack/auxv synthesis |

## 7. Sequencing
**1 → 2 → 3 → 4 → 5 → 6 → 7, then optionally → 8.** Phases 1–6 deliver a single-threaded
*blocking* JS agent (runs a script, sequential tool calls). **Phase 7 (async I/O + event
loop) is what makes it a *real* agent** — concurrent tool calls, streaming, responsiveness —
and is REQUIRED, not optional; it stays single-JS-threaded and leans on the kernel's existing
network transport + scheduler while Phase 7 adds the missing completion-driven path. **Phase 8 (Workers) is optional**, for CPU-parallel
subtasks, and its true-SMP-parallel half (v1) waits on the locking hardening it calls out.
Phase 1 (the SDK) is the highest-leverage and unblocks
everything after it: once apps are confined ELFs built from a reusable runtime, QuickJS is
not a special case — it is the largest app, dropped onto the same spine. Phases 2–3 (libc/
libm) are the bulk of the porting effort and are independently testable (build a tiny C
program that calls `pow`/`malloc`, run it as an app). Phases 4–6 are integration on proven
substrate.

## 8. Where this connects
This is the missing **step 0** of `docs/agent-sandbox-milestone.md` (untrusted execution):
the M1–M6 capability substrate (treefs, fs_toolserver, agent_fs, policy, netcap, mcp) is
already built and gated; it has been driven so far by hand-built confined ELFs. QuickJS is
the real untrusted *interpreter* those capabilities were designed to contain. Finishing this
plan turns the substrate from "demonstrated with a toy agent" into "runs an actual JS agent,
sandboxed."

## 9. Review findings folded in (2026-06-20)
- **F1 (syscall arity):** §3.1 — table stays 3-arg; tool/net take one request-struct pointer (widening to a0..a5 noted as the alternative).
- **F2 (raw user pointers):** §3.3 — all user pointers go through `copy_*_user_pt` over a per-agent `UserAddrSpace`. **DELIVERED:** wired in `tests/qemu/proc/app_runtime.mc`, gated by `app-run-test` (a loaded app's `SYS_WRITE` copies through `copy_from_user_pt`).
- **F3 (toy loader):** §1 + Phase 1 — a real multi-segment loader (per-segment perms, bss, stack/arena). **DELIVERED:** gated by `elf-loader-test` (synthetic 2-segment image) + `app-run-test` (real multi-segment app ELF).
- **F4 (front-end/argv):** §0 + Phase 4 — custom `qjs_agent.c` (no argv); script ingress defined.
- **Open Q (script ingress):** §0 — SYS_READ staged channel for v0, capability FS path long-term.
- **Open Q (network layer):** §3.4 — brokered `net_fetch` is the default (single audited fetch event); `net_egress_check` is the lower raw-connect primitive.

### Threads/Workers review (2026-06-20)
- **Worker config dependency:** Phase 4 keeps `Worker` stubbed `E_UNSUPPORTED`; enabled only in Phase 8 (no forward dependency).
- **Scheduler reality:** §1 + Phase 8 corrected — the core scheduler is COOPERATIVE (`sched.mc`); timer preemption is a demo-runtime mechanism; `smprq` is a primitive. Phase 8 v0 explicitly builds the confined-U-mode (shared-satp) scheduler integration.
- **SMP claim:** split into v0 (single-core, contained) and v1 (true SMP-parallel) which is explicitly gated on mailbox locking + address-space/TLB-shootdown locking (`uaccess.mc` note) — not claimed before that lands.
- **Worker source w/o host FS:** §Phase 8 — `Worker.fromSource(text)` for v0, capability-FS named modules later; matches QuickJS's separate-runtime + cloned-message semantics.
- **Real-agent concurrency (this review):** §3.2 + Phase 7 added an async-I/O event-loop model (non-blocking SYS_SUBMIT/SYS_POLL + front-end loop driving QuickJS jobs) as the REQUIRED concurrency for a real agent — single-JS-threaded, backed by a Phase-7 completion path over the existing kernel transport/scheduler substrate. No JS engine supports shared-memory threads in one runtime, so "threads" for the agent means async I/O, not JS threads. Workers (shared-nothing, CPU-parallel) demoted to optional Phase 8.

### Async I/O review (2026-06-20)
- **Async memory lifetime (High):** §3.5 — submit copies all inputs into kernel-owned bounded buffers (no retained user pointer); result in a kernel buffer; `SYS_POLL` copies into a poll-time user buffer; in-flight count + async bytes are quota-bounded.
- **Net is not interrupt-driven (Medium):** §1 + Phase 7 corrected — real TCP/HTTP exists but is **poll-mode/blocking** (`virtio_net.mc:497`, `net_fetch_tcp`); making the transport completion-driven is Phase 7 work. Also clarified that IRQ/DMA I/O needs no per-request thread; a kernel worker is only for blocking ops without a completion event.
- **Async gate could pass synchronously (Medium):** Phase 7 + §5 — the gate now uses two **independently-completing** (delayed/real) calls and asserts **both submitted before either completion is consumed**, so a synchronous queue cannot pass it.
- **Brokered-net denials unaudited (Medium):** §3.4 + §5 — `net_broker` audits only admitted egress (a denied destination "is NOT audited"). Phase 7 adds a denied-at-submit broker audit; until then acceptance distinguishes FS/path denials (audited) from brokered-net denials (asserted by rejection).
