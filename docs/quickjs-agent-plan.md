# Plan: run a QuickJS agent on the kernel, contained, via the userspace ABI

Status: **plan / not started.** This is the concrete, phased path to running QuickJS as a
genuinely-untrusted JavaScript agent on the MC kernel — the "step 0 target" named in
`docs/agent-sandbox-milestone.md`. It builds on substrate that already exists, so most of
the risk people fear is already retired.

## 0. End state

```
$ qjs-agent agent.js                 # an MC-kernel "app": QuickJS in an isolated U-mode ELF
  └─ runs JS, reaches the kernel ONLY through ecall syscalls
  └─ kernel is UNMAPPED in its address space (the MMU is the boundary)
  └─ all effects (fs/net/tools) go through the capability front door (PathCap/NetCap/
     tool allowlist + budget), audited to the ipc_trace ring, attributed to the agent
```

QuickJS sits **outside** the kernel trust boundary by construction (it is the contained
agent, not kernel code) — which is exactly the agent-sandbox design intent ("speak MCP /
run agents, enforce with MC capabilities; never drag an opaque runtime *inside* the trust
boundary").

## 1. What already exists (de-risking)

| Need | Status | Evidence |
|---|---|---|
| Drop to U-mode, ecall trap path, PMP | done | `kernel/arch/riscv64/usermode_runtime.c` |
| Syscall dispatch (fn-ptr table, bounds/ENOSYS) | done | `kernel/core/syscall.mc` |
| Load a SEPARATE ELF into an ISOLATED Sv39 space (kernel unmapped), run confined | done | `agent_confined_runtime.c` + `tests/qemu/proc/agent_confined_demo.mc` |
| Confined agent drives a capability tool front door (allow/deny, audited) | done | `agent_confined_tool_demo.mc` + the M1–M6 substrate (treefs/fs_toolserver/agent_fs/policy/netcap/mcp) |
| Vendor + freestanding-build a large third-party C library | done | `third_party/bearssl/` compiled with the riscv freestanding toolchain (`bearssl_smoke_runtime.c`) |
| Heap / allocator | partial | `std/alloc.mc` (alloc_bytes/free_bytes), kernel heap |
| libc core | minimal | `std/libc.mc`: memeq/strlen/atoi |
| libm | thin | `std/math.mc`: sqrt/sin/cos/exp/log/tanh only |

The two things people fear most — "can it run a big foreign C blob?" and "can it be
truly contained?" — are **already proven** (BearSSL; agent_confined). The remaining work is
a bounded porting job.

## 2. Architecture

```
  ┌─────────────────────────── isolated U-mode ELF (the agent) ──────────────────────────┐
  │  qjs front-end  →  QuickJS core (quickjs.c, libregexp.c, libunicode.c, cutils.c)      │
  │        │                    │                                                         │
  │        │              freestanding libc shim (malloc/str*/snprintf) + libm            │
  │        │                    │                                                         │
  │        └────────────── quickjs-libc-mc.c (OS bindings → ecall) ───────────────────────┤
  │                              │  ecall(SYS_*)                                           │
  └──────────────────────────────┼───────────────────────────────────────────────────────┘
                                 ▼  (kernel UNMAPPED above; only the ecall vector is reachable)
  ┌──────────────────────────── kernel (M-mode) ─────────────────────────────────────────┐
  │  syscall_dispatch  →  thin ABI handlers  →  capability front door (agent_fs_call /     │
  │                                              net_egress_check / mcp_call)  →  audited   │
  └───────────────────────────────────────────────────────────────────────────────────────┘
```

QuickJS never touches MMIO or kernel memory; every effect is an `ecall` that lands in a
capability-checked handler.

## 3. The syscall ABI (stable, versioned)

A single shared header of numbers + signatures, consumed by the kernel (registers
handlers) and the user runtime (wrappers). Start minimal; everything QuickJS needs:

```
SYS_WRITE   (fd, ptr, len)            -> bytes written            // console / output channel
SYS_READ    (fd, ptr, len)            -> bytes read               // script / agent input
SYS_EXIT    (code)                    -> noreturn
SYS_GETPID  ()                        -> pid                      // agent identity
SYS_CLOCK   ()                        -> monotonic ns             // Date / timers (optional)
SYS_SBRK    (delta)                   -> old break                // heap growth (or: static arena)
// capability tools (reuse the M1–M6 surface), one entry, op-coded:
SYS_TOOL    (op, path_ptr, path_len, buf, n, cap)  -> Result      // fs_tool_*/agent_fs_call
SYS_NET     (op, addr, port, buf, n, cap)          -> Result      // net_egress_check
```

`kernel/core/syscall.mc`'s table is `SYS_MAX = 16`, enough for this. Each handler is the
EXISTING capability path — `agent_fs_call`, `net_egress_check`, `mcp_call` — so the agent
gets no authority the kernel hasn't granted, and every call is audited+attributed.

## 4. Phases

### Phase 1 — Userspace SDK (QuickJS-agnostic; the spine)
Goal: write `fn main() -> i32`, build it into a confined U-mode ELF, run it. Makes QuickJS
"just another app."
- `user/abi.mc` — the stable `SYS_*` numbers (shared kernel↔user).
- `user/sys.mc` — typed ecall wrappers (`write`, `read`, `exit`, `getpid`, …) via MC inline asm.
- `user/start.*` — `crt0`: set sp, call `main()`, `exit(rc)`.
- `kernel/arch/riscv64/app_runtime.c` — ONE reusable kernel-side runtime: U-mode setup +
  registers the ABI handlers (wired to the capability front door) + loads/enters the app ELF
  (reuse `agent_confined` isolation).
- `tools/user/build-app.sh <app.mc>` — compile app + user runtime → isolated U-mode ELF, run
  under QEMU. No per-app C glue.
- `examples/apps/hello.mc` — `fn main() { write(1, "hello\n"); return 0; }`.
- Gate: `app-hello-test` / `llvm-app-hello-test` (both backends, QEMU).

**Effort: M.** Mostly factoring the existing bespoke `*_user_runtime.c` glue into one reusable runtime.

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
Options, in order of preference:
1. **Vendor openlibm or musl `src/math`** into `third_party/` and build freestanding (same
   path as BearSSL). Cleanest, most correct.
2. Implement/stub only the subset QuickJS references (smaller, but accuracy risk on edge cases).

**Effort: M–H.** This is the largest single chunk; the BearSSL vendoring pattern applies.

### Phase 4 — Vendor + build QuickJS
- `third_party/quickjs/` — `quickjs.c libregexp.c libunicode.c cutils.c` (+ `qjs.c` front-end).
- Build flags: riscv64 freestanding (`--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
  -nostdlib -ffreestanding -mcmodel=medany`), `-DCONFIG_VERSION` etc.
- Config: disable the heavy/unsupported features — **no bignum** (drops `__int128`), **no
  worker threads**, **no os/std modules** (replaced by our binding). `CONFIG_BIGNUM` off.
- Replace `quickjs-libc.c` with **`quickjs-libc-mc.c`**: implement `js_std_*` console/eval
  hooks against `SYS_WRITE/READ/CLOCK` and the capability tools — this is the actual
  "QuickJS-with-the-ABI" glue, and it's small.

**Effort: M.** Bounded by config-flag tuning + the binding file. Precedent: BearSSL builds clean.

### Phase 5 — Memory provisioning
QuickJS wants MBs for non-trivial scripts.
- Start: a large static arena (e.g. 8–16 MB) handed to the malloc shim — simplest, deterministic.
- Then: `SYS_SBRK`/demand paging for a growable heap (the kernel already has demand-paging/COW
  tests). Cap it per-agent so a runaway script is bounded (ties into the policy plane).

**Effort: M.**

### Phase 6 — qjs as a confined agent + capability wiring
- Build `qjs + QuickJS + libc + libm + quickjs-libc-mc + user runtime` into one isolated
  U-mode ELF; load it with the `agent_confined` loader (kernel unmapped).
- Wire the JS-visible effect surface (a `Tool` global / `print` / a fetch-like API) through
  `SYS_TOOL`/`SYS_NET` → `agent_fs_call`/`net_egress_check` → the PathCap/NetCap/allowlist/
  budget gates. JS can do nothing the agent's capabilities don't permit; every effect is
  audited to `ipc_trace` and attributed to the agent pid; the policy plane can throttle/kill.
- Gate: `qjs-agent-test` — run a fixed `agent.js` that (a) prints, (b) does an allowed
  `/workspace` write, (c) is DENIED an `/etc` write and an un-granted net egress, under QEMU,
  both backends. The acceptance shape mirrors `agent_confined_tool_demo`.

**Effort: M.** The hard parts (isolation, capability front door) are done; this is integration.

## 5. Acceptance criteria
- `examples/apps/hello.mc` builds and runs as a confined U-mode ELF (Phase 1 gate).
- A trivial `agent.js` (`print(1+2)`) runs through QuickJS on the kernel and prints `3`.
- `agent.js` doing fs/net effects: allowed ops succeed, forbidden ops are denied at the
  capability boundary it cannot bypass (kernel unmapped), all audited+attributed.
- All gates pass on **both** backends under QEMU; joined to `m0`.

## 6. Risks & how to retire each (early)
| Risk | Retire by |
|---|---|
| libm completeness / accuracy | one `nm` on a QuickJS test build → exact reference set; vendor openlibm |
| `__int128` / GCC-isms in QuickJS | `CONFIG_BIGNUM` off; build-and-fix; clang 18 handles the rest |
| `setjmp`/`longjmp` | QuickJS uses its own exception machinery; provide a minimal setjmp if anything in libc needs it |
| heap pressure / runaway script | static arena bound first; then SYS_SBRK + per-agent quota via the policy plane |
| binary size of the ELF | confinement holds at any size; only the static-arena RAM budget matters |

## 7. Sequencing
**1 → 2 → 3 → 4 → 5 → 6.** Phase 1 (the SDK) is the highest-leverage and unblocks
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
