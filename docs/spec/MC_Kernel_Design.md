# MC Microkernel — Architecture Specification

> **Status:** Living document, derived from the current source tree. It describes
> *what the kernel is* (object model, ABIs, invariants, mechanisms) as a complement to
> [`MC_0.7_Final_Design.md`](MC_0.7_Final_Design.md) (the *language* the kernel is written
> in) and [`../agent-os-vision.md`](../agent-os-vision.md) (the *why* — the agent-OS north
> star). Where this spec and the vision doc disagree on "state today," **this spec
> reflects the code**.
>
> **Faithfulness rule:** normative claims must identify their implementation **scope**.
> **GATED** means the mechanism is exercised by required `emit-c` *and* `emit-llvm` backend
> tests. **DEMO-SCOPE** means it works but is limited by fixture scale, single-region /
> single-page assumptions, QEMU platform assumptions, or small fixed capacities. **MOCK**
> means the API shape exists but the intended isolation or IPC/service boundary does not.
> This document prioritizes source-faithful status over roadmap aspiration. The status
> taxonomy is defined in §2 and used consistently; the per-claim evidence is in §26.

---

## 1. Introduction & Scope

The MC microkernel is a **capability microkernel in the MINIX/seL4 lineage**, written
entirely in the MC language, whose intended and only workload is **AI agents** —
semi-trusted, long-running, communication-heavy principals. It is *not* a
general-purpose OS. It does **not** target POSIX compatibility or general-purpose hardware
breadth; those mechanisms (a POSIX-shaped syscall demo, drivers, filesystems, ELF loading,
TCP/IP, TLS) exist **only where they serve agent confinement, communication, storage, or
bootstrapping** — never for their own sake (see [vision § SKIP](../agent-os-vision.md)).

What distinguishes it from a production C kernel is that a large class of kernel bugs are
**compile errors** rather than runtime faults: opaque address classes, linear/`move`
capabilities, monotone rights attenuation, bounds/overflow traps, and IRQ-context
discipline are enforced by the MC type system. The kernel also holds a **dual-backend
parity** invariant: every gate runs on both the `emit-c` and `emit-llvm` lowerings and must
agree (§8.3 distinguishes this from CPU-architecture support).

### 1.1 Source map

| Area | Directory |
|------|-----------|
| Core (process, ipc, sched, capability, memory, agent, governance) | `kernel/core/` |
| Arch HAL (riscv64 primary, x86_64/aarch64 partial) | `kernel/arch/<arch>/` |
| Library types (resacct, granttab, supervisor, mailbox, fdspace, registry) | `kernel/lib/` |
| Filesystems & storage | `kernel/fs/` |
| Network stack | `kernel/net/` |
| Drivers | `kernel/drivers/` |
| Bus / device model | `kernel/bus/` |
| Address classes, libc subset, mem, rights | `std/` |

---

## 2. Status Taxonomy

Every feature in this document carries one of these labels (composable — e.g. "GATED ·
demo-scale capacity"). The point is to separate *implemented* from *production-scope*: a
mechanism can be real, parity-tested, and still bounded to a small fixed table, a single
region, or the QEMU envelope.

| Label | Meaning |
|-------|---------|
| **IMPLEMENTED** | Code path exists and is exercised. |
| **GATED** | Covered by a required test/demo gate, on both `emit-c` and `emit-llvm`. (Implies IMPLEMENTED.) |
| **DEMO-SCOPE** | Mechanism works, but only under a narrow fixture, small-capacity, single-region/single-page, or QEMU-bound envelope. |
| **MOCK** | Placeholder transport/API shape; the real isolation or service boundary is not implemented. |
| **ABSENT** | Not implemented. |

"Small fixed capacities" are pervasive and deliberate (no hidden allocation on hot paths):
`MAX_PROCS = 8`, `IPC_SLOTS = 4`, `IPC_TRACE_CAP = 16`, `GRANTTAB_MAX = 8`, `MAX_TOOLS = 8`,
`SVC_MAX = 8`. These are scaffold-scale, not architectural ceilings, and are called out as
**demo-scale capacity** wherever they bound a claim.

---

## 3. Threat Model

**In scope** (the kernel aims to defend against these today):

- buggy or malicious **agents** — unintentional exhaustion, crashes, malformed messages,
  and code actively trying to escape/escalate/exfiltrate within granted authority;
- **hijacked** agents (tier 3 of the vision threat model) — prompt-injected agents wielding
  their *legitimate* authority maliciously; defended by bounding blast radius (governance)
  and total provenance (observability), not by reachability alone;
- compromised **userspace-shaped services**;
- **stale endpoints** and **revoked grants** (generation-checked, fail-closed);
- **malformed user pointers** and **untrusted ELF inputs** (validated, bounds-checked);
- **resource exhaustion by a live agent** (the governance keystone, §14).

**Out of scope today:**

- malicious kernel code or trusted runtime/compiler shims (they are in the TCB — §4);
- malicious hardware / DMA outside the modeled drivers;
- physical attacks and side channels;
- a formal seL4-style refinement proof (the guarantees here are type-system + test based,
  not machine-checked proof);
- production multi-tenant hardening at scale.

The kernel is the **sensor + actuator** (see everything, act instantly); deciding whether
an agent is *misbehaving* is a policy plane **above** the kernel (vision § Policy plane). A
tier-3 agent acts within its authority, so no kernel rule fires by construction — that
verdict is not the kernel's job.

---

## 4. Trusted Computing Base

For "many bugs become compile errors" to hold, the following must be trusted. They are
**not** verified by the kernel's own guarantees:

- the **MC compiler & type checker** (the source of the compile-time guarantees);
- the **`emit-c` and `emit-llvm` backends** (a miscompilation defeats parity);
- the **runtime C/asm shims** (`*_runtime.c`: trap vectors, context switch, naked
  functions, freestanding libc subset);
- the **arch trap/context-switch/paging** code;
- **QEMU / OpenSBI** assumptions for the demo/boot envelope;
- vendored **BearSSL** (TLS — opaque C);
- any **C-ABI struct mirrors** and the generated `_Static_assert` layout checks that guard
  them.

This TCB is small relative to a monolithic kernel, which is the point (small, auditable
trust base for a semi-trusted workload) — but it is explicitly *trusted*, not proven.

---

## 5. Design Principles & Invariants

1. **Capabilities are unforgeable and linear.** Authority is held in `move` (linear)
   opaque types; possession cannot be copied or fabricated outside the minting module.
2. **Authority only narrows.** Every derivation (rights attenuation, grant delegation,
   attenuated spawn) computes an **intersection** — a child can never exceed its parent.
   There is no widening operation in the API surface.
3. **Address classes never confuse.** `PAddr`, `VAddr`, and `UserPtr<T>` are opaque
   classes; cross-class confusion and dereference of a physical/user pointer are compile
   errors. All pointer arithmetic flows through a single audited `usize` boundary where
   MC's checked arithmetic catches overflow.
4. **Typed mediation of messages and recognized authority.** Every cross-principal message
   and every **kernel-recognized authority check** (mask check, grant open, capability use,
   dispatched tool call) flows through a typed mediation point that can observe and gate it.
   This is *not* a claim that every byte an agent touches is mediated — in-process MOCK tool
   handlers (§10.3) are explicitly **not** a trust boundary.
5. **Mechanism, not policy.** The kernel provides sensors (provenance) and actuators
   (revoke / throttle / pause / OOM-kill / checkpoint). *Deciding* when to pull a lever
   lives above the kernel.
6. **Bounded by construction.** Tables are fixed-capacity (no hidden allocation on hot
   paths); failures are typed `Result` values, not sentinels or silent drops.
7. **Dual-backend parity.** `emit-c` and `emit-llvm` must produce equivalent behavior;
   every kernel gate has a `*-test` and an `llvm-*-test` variant.

---

## 6. System Overview

```
            ┌─────────────────────────────────────────────────────────┐
            │  Agents (semi-trusted; JS/QuickJS today, future: WASM)   │
            ├─────────────────────────────────────────────────────────┤
   above    │  Policy plane / agent runtime (anomaly detection, verdict)│   ← not in kernel
 ───────────┼─────────────────────────────────────────────────────────┤
            │  Services (service-shaped, kernel-linked today;          │
            │            migration target: userspace processes)        │
            │            VFS · net server · tool server                │
   kernel   ├─────────────────────────────────────────────────────────┤
            │  CORE: process · scheduler · IPC · capability · grants   │
            │        memory (page/heap/paging) · governance · agent    │
            │        supervisor · provenance/audit                     │
            ├─────────────────────────────────────────────────────────┤
            │  Arch HAL: boot · trap/syscall · context switch · paging │
            │            timer (CLINT) · IRQ (PLIC)                     │
            └─────────────────────────────────────────────────────────┘
                         riscv64 (full) · x86_64 / aarch64 (partial)
```

Today the "services" band is **kernel-linked and service-*shaped*** (registry + supervisor
+ manifests give it MINIX structure), with migration to true userspace processes as a
roadmap item. The diagram's placement reflects intent, not present privilege separation.

---

## 7. Boot & Initialization

**Primary path: riscv64.** Entry is the arch runtime (`kernel/arch/riscv64/kmain_runtime.c`),
which hands a physical region to `kmain(region_base, region_len)`. Ordered bring-up:

1. **Heap** — initialize over the provided physical region (`heap_new`). Demo images use a
   statically-reserved 256 KiB region (`kmain_runtime.c:14`); the size is the region you
   pass, not a hard limit (§9).
2. **Console/UART** — character device + UART driver (QEMU virt UART @ `0x1000_0000`).
3. **Hart bring-up** — typestate `Hart<Boot> → TrapReady → IrqsOn` (`hart.mc`): claim boot
   hart, `install_trap_vector` (sets `mtvec`), `enable_interrupts`.
4. **Timer** — arm CLINT (`timer_set_alarm`, `TICK_INTERVAL = 1_000_000` ≈ 100 ms @ 10 MHz).
5. **Subsystems** — logger, VFS+ramfs round-trip, process table + scheduler, workload.
6. **Report** — boot returns a stage bitmask; demos assert it (e.g. `0x3F`).

Legacy M-mode QEMU demos (`-bios none`, kernel at `0x8000_0000`) and S-mode/OpenSBI demos now
**coexist**: the M-mode path remains for the bare-metal bring-up demos, while a full set of
S-mode gates runs under REAL OpenSBI — `sbi-boot-test`, `smode-user-test`, `smode-timer-test`,
`blk-smode-test`, `net-smode-test`, `bearssl-smode-test`, `https-smode-test`, and the
`qjs-smode-{confined,agent,async-agent}-test` agents. Until paging is explicitly enabled, kernel
and tasks execute in physical address space. **Status: GATED** (`kmain-test` / `llvm-kmain-test`
for M-mode; the `*-smode-*` steps above for S-mode) · riscv64 only.

---

## 8. Architecture HAL & Multi-Arch Support

The arch seam has three layers: **typed interface** (`kernel/arch/<arch>/*.mc`: `Context`,
paging, CSR ops), **runtime** (`*_runtime.c`: inline asm, naked functions, trap vectors),
and **platform** (drivers: CLINT/PLIC/UART).

### 8.1 Context switch

| Arch | `Context` | Size | Switch |
|------|-----------|------|--------|
| riscv64 | `ra, sp, s0..s11` (14×u64) | 112 B | `mc_switch_context`, `mc_switch_context_vm` (loads `satp` + `sfence.vma`) |
| x86_64 | `rsp, rbx, rbp, r12..r15` (7×u64) | 56 B | same pair (loads `cr3`) |

`mc_thread_init(ctx, stack_top, entry)` primes a fresh context to enter via a trampoline
that enables interrupts then jumps to `entry`.

### 8.2 Support status (honest)

| Arch | Boot | Run | User mode | Paging | Interrupts | Verdict |
|------|------|-----|-----------|--------|------------|---------|
| **riscv64** | ✓ M+S | ✓ full | ✓ (U-mode ecall dispatch) | ✓ Sv39 | ✓ CLINT+PLIC | **primary; GATED** |
| **x86_64** | ✓ multiboot | ✓ ring-3 user + confined QuickJS¹ | ✓ (ring-3, `int 0x80`) | ✓ 4-level | ✓ LAPIC timer + PCI (CAM) | **GATED (boot/paging/user/IRQ; QuickJS¹); not full-kernel parity** |
| **aarch64** | ✓ QEMU virt (EL1) | ✓ EL0 user + confined QuickJS¹ | ✓ (EL0, `svc #0`) | ✓ stage-1 4 KB | ✗ (no GIC/timer IRQ yet) | **GATED (boot/paging/user; QuickJS¹); IRQ pending** |

¹ QuickJS gating is per-backend: **x86 sync + async** = C+LLVM-gated; **AArch64 sync + async** =
C+LLVM-gated. The former LLVM tracking cases were promoted after target-aware `va_list` storage,
target triples/data layouts, and explicit AArch64 `va_arg` lowering were proven under QEMU.

### 8.3 "Both backends" ≠ "both architectures"

A recurring clarification: **"both backends" means the two compiler lowerings, `emit-c` and
`emit-llvm`.** Every kernel gate runs through both and must agree. This is **not** a claim
of x86_64/aarch64 full-kernel parity — all e2e kernel gates currently target the **riscv64
QEMU** gate unless a test explicitly states otherwise. x86_64/aarch64 exercise
codegen/portability, not the full kernel.

---

## 9. Memory Model

### 9.1 Physical page allocator — GATED

`kernel/core/page_alloc.mc`. `PAGE_SIZE = 4096`. `PageAllocator { next, end, free_head,
free_count }` is a bump frontier plus an **intrusive LIFO free list**. A frame is a linear
`move struct Page { addr: PAddr }` — once freed it cannot be reused. `page_alloc` traps on
exhaustion; `page_free` is **O(1) real reclaim** (not a no-op). Gate: `page-test`.

### 9.2 Heap — GATED

`kernel/core/heap.mc`. First-fit free list (`HEAP_FREE_SLOTS = 64`) over a bump frontier,
with **coalescing** on free. `heap_free` is fully implemented with coalescing — the vision
doc's "`heap_free` is a no-op bump allocator" describes an older tree. Hardened profiles:
`heap_new_redzoned` (16-byte poisoned guard bands) and `heap_new_ksan` (KASAN shadow).
Gates: `heap-test`, `ksan-test`.

### 9.3 Address classes — GATED (compile-time) (a headline guarantee)

`std/addr.mc`, `kernel/core/uaccess.mc`:

- **`PAddr` / `VAddr`** — opaque. No raw `+`/`-`/ordering/deref; operations go through
  checked helpers. Confusing physical with virtual is a compile error
  (`E_ADDRESS_CLASS_MISMATCH`).
- **`UserPtr<T>`** — opaque built-in. Non-dereferenceable in the kernel
  (`E_USER_PTR_DEREF`), no arithmetic, no confusion with kernel addresses. Access only via
  validated copy paths.
- **`copy_from_user` / `copy_to_user`** — bounds-check against the user space `[base,
  limit)` (or per-page `PTE_U/R/W` in the page-table-aware path), fail-closed.
- **`UserSnapshot<T>`** (TOCTOU defense — no re-fetch API) and **`Tainted<T>`** (user-derived
  lengths/indices must pass `checked_len`/`checked_index`).

These are enforced at compile time by the type checker and exercised by spec fixtures.

### 9.4 Virtual memory — GATED (Sv39)

`kernel/arch/riscv64/paging.mc`. Three-level Sv39, 4 KiB pages + 1 GiB gigapages. PTE bits
`V=1, R=2, W=4, X=8, U=16`. `page_table_try_map` returns `Result<bool, MapError>`
(`MisalignedAddress`, `AlreadyMapped`, `ConflictWithLargePage`). `page_table_lookup` is a
non-trapping walk returning `LeafMapping { phys, flags }` with permission accessors. Each
`Process` holds its own `satp`. Gates: `page-test`, `paging-activate-test`.

### 9.5 mmap / demand paging / COW

- **`mmap_anon` / `munmap`** — GATED (`mmap-test`): allocate a frame, map at a VA.
- **Demand paging** — DEMO-SCOPE (`demand.mc`, `demand-test`): a **single global region**;
  fill faults inside it, fail-closed outside.
- **Copy-on-write** — DEMO-SCOPE (`cow.mc`, `cow-test`): **one shared read-only page**; the
  write-fault handler copies and remaps writable. Fork-wide COW (share counts, COW PTEs on
  every fork) is **ABSENT**.

### 9.6 Resource accounting — GATED

`kernel/lib/resacct.mc`. `ResourceAccount { used, limit }`. `resacct_charge(n)` is
**all-or-nothing**: on overflow or over-limit it returns `err(MemError.OverQuota)` with
`used` unchanged. Each `Process` owns a `macct` with `MEM_QUOTA_DEFAULT = 0x100000` (1 MiB),
reset on spawn and on death. See §14 for the live-reclaim keystone. **Scope caveat:** the
gate proves the mechanism under **explicit charge sites**; the allocator→charge call-site
wiring inside `heap.mc` (so that *every* allocation path charges automatically) is
follow-up work.

### 9.7 TLB — IMPLEMENTED (bookkeeping)

`kernel/core/tlb_shootdown.mc`. Arch-neutral `Shootdown { va, len, targets, acked }`
(`Mask32`, up to `TLB_MAX_CORES = 32`) tracks which cores must flush and which acked.
Single-hart `sfence.vma` lives in `paging.mc`; per-arch IPI dispatch is separate.

---

## 10. Process & Agent Model

### 10.1 The `Process` object — GATED · demo-scale capacity (`MAX_PROCS = 8`)

`kernel/core/process.mc`. `IPC_SLOTS = 4`.

```
struct Process {
    context: Context, state: ProcState,    // Unused|Ready|Running|BlockedRecv|Zombie|Dead
    pid, gen,                              // gen bumps on slot reuse → invalidates stale endpoints
    parent, parent_slot, parent_gen, exit_code,
    satp,                                  // address space (0 = share kernel's)
    inbox: Mailbox<Message, IPC_SLOTS>,
    block_reasons: Mask32,                 // runnable iff empty (derived state)
    wait_slot, wait_gen, pending_sig: Mask32,
    allow_mask: Mask32,                    // bit p = may IPC-send to pid p
    kcall_mask: Mask32,                    // bit op = may invoke kernel call op
    priority, quantum, ticks, sched_endpoint,
    fds: FdSpace,                          // inherited on spawn, preserved on exec
    macct: ResourceAccount,
}
```

Block reasons: `BLOCK_RECV=0`, `BLOCK_SEND=1`, `BLOCK_WAIT=2`, `BLOCK_PAUSED=3`.
Runnability is **derived** (`Ready|Running` ∧ `block_reasons == 0`), never set ad hoc.

### 10.2 Lifecycle — GATED

| Function | Effect |
|----------|--------|
| `proc_spawn(t, stack_top, entry) -> pid` | Create `Ready`; **empty masks** (least privilege); inherit fd copies; reuse free slot with `gen++`. |
| `proc_spawn_attenuated(…, allow_subset, kcall_subset)` | `child.mask = parent.mask ∩ subset`. Monotone — child ≤ parent. |
| `proc_exec(t, slot, stack_top, entry)` | Reset context to new entry; preserve identity + fds; reset accounting. |
| `proc_exit(code)` | Mark `Zombie`, run `proc_death_cleanup`, wake waiting parent, switch away. |
| `proc_wait` / `proc_reap` | Blocking / non-blocking reap → `Result<ReapInfo, ReapError>`. |

`Endpoint { slot, gen }` is the safe reference: a bare pid is insufficient because slots are
reused; `endpoint_slot` fails `DeadEndpoint` on generation mismatch. Gates: `exec-test`,
`endpoint-test`.

### 10.3 Agent runtime — GATED mechanism, **MOCK tool transport**

`kernel/core/agent.mc`. An **agent = attenuated process + tool layer**:

```
struct Sandbox { slot: usize, tools: Mask32, calls_left: u32 }
```

`agent_spawn(…, allow_subset, kcall_subset, tool_mask, call_budget)` builds the process via
`proc_spawn_attenuated` and adds a **tool allowlist** and a **call budget**. The tool-call
ABI is the single checked entry point:

```
agent_tool_call(t, reg, sb, tool_id, arg) -> Result<u32, ToolError>
  1. Denied      — tool_id ∉ allowlist     (no budget spent; see §15 for audit policy)
  2. Exhausted   — calls_left == 0
  3. NoSuchTool  — not in registry         (checked after deny → no info leak)
  4. Audit       — record (agent pid, tool_id) into cap_audit
  5. Dispatch    — calls_left--, run handler, return ok(result)
```

> **Trust boundary note:** tool handlers are currently **in-process function pointers**
> (`MAX_TOOLS = 8`) and are therefore **NOT a trust boundary** — an in-process handler runs
> with kernel authority. The intended real form is **IPC to a tool server** (a separate
> principal), which is where a future native tool catalog or a QuickJS host-bridge plugs in.
> Until then, the agent-tool model bounds *which tool ids* an agent may name and *how many*
> calls it may make, not what a (trusted) handler does.

**Two distinct tool paths — do not conflate them:**
- **Legacy cooperative `agent_tool_call`** (this section, `kernel/core/agent.mc`): a **MOCK,
  in-process** transport. The caller is trusted MC; the "agent" is cooperative; handlers are
  in-process function pointers. It demonstrates the *allowlist + budget + audit* checks, not a
  real trust boundary.
- **Confined-JS effect broker** (the agent-sandbox milestone, `qjs-realtool-test`): a pure-JS
  agent in U-mode drives the **real** capability-checked **FS** path through
  `SYS_SUBMIT`/`SYS_POLL` into `agent_fs_call` (allow/deny/audit) under S-mode. This *is* a
  real path on RISC-V/S-mode for the FS vector; the secret/sum demo paths and the in-process
  mock above still coexist. A real TCP-backed network broker path exists; the production
  JS/tool-catalog now exposes `host_net_fetch` over the broker control plane, with TCP-backed
  transport integration gated. Both `host_net_fetch` and `host_fs_read` have S-mode
  IRQ-backed `SYS_POLL` completion gates.

Gates: `cap-test`, `agent-e2e-test` (legacy mock); `qjs-realtool-test` (confined-JS FS broker).

### 10.4 Signals — IMPLEMENTED (kernel primitive only)

`kernel/core/proc_signals.mc`. Signals 0..31 are bits in `pending_sig`. `proc_kill` (raw
pid) and `proc_kill_ep` (generation-safe) set a bit and wake a `BLOCK_RECV` process;
`proc_sigtake` clears+returns the lowest pending. **No user-mode handler dispatch** — a
process-manager service would build POSIX signal semantics on top.

---

## 11. Scheduler — GATED · SMP scaffold-scale

`kernel/core/proc_sched.mc` (policy + mechanism), `sched.mc` (legacy RR), `smprq.mc` (SMP).
The kernel owns *mechanism*; policy can be set externally (`proc_schedctl`).

- **Selection:** round-robin, priority (ties → lower pid), and **fair-share**
  (`proc_pick_fair`: least effective ticks, cost = `(ticks + throttle_penalty) /
  max(priority,1)`).
- **Preemption:** timer-driven via the CLINT trap path (`preempt_runtime.c`,
  `TICK_INTERVAL`); `proc_tick_notify` sends `TAG_QUANTUM` to the scheduler endpoint.
- **Blocking:** `proc_block`/`proc_unblock`; `proc_yield_or_idle` sleeps (`wfi`) rather than
  spins; `proc_yield_vm` switches address space.
- **SMP:** `smprq.mc` per-core FIFO `RunQueues` (`NCORES=2`, `RQ_CAP=8`) with work stealing.
  **DEMO-SCOPE** — scaffold-scale, not production multi-core hardening.
- **Throttle / pause:** `proc_throttle` (deprioritize), `proc_pause`/`proc_resume`
  (`BLOCK_PAUSED`).

---

## 12. Capability Model — GATED (the heart of the kernel)

### 12.1 Capabilities

`kernel/core/capability.mc`:

- **`Cap<R>`** — `opaque move struct`. Unforgeable (private field; only `cap_mint`
  constructs), linear (`move` — single owner), revoked by consuming (`cap_revoke`).
- **`RCap<R>`** — `Cap<R>` + opaque `Rights`. `rcap_allows(c, bit)` checks authority;
  **`rcap_attenuate(c, keep)` is the only derivation** — result = `parent ∩ keep`. **No
  widening operation exists in the API.**

### 12.2 Rights — GATED

`std/rights.mc`: `opaque struct Rights { bits: u32 }`. Minting from raw bits is privileged
(`rights_grant`); every other combinator is **narrow-only** (`rights_attenuate` = `∩`,
`rights_without`, `rights_none`). `rights_subset_of` checks `child ⊆ parent`. Opacity makes
"restore a dropped right" unrepresentable outside the module.

### 12.3 Memory grants — GATED

`std/grant.mc`, `kernel/lib/granttab.mc`. A `Grant { base, len, gen }` is a bounded,
revocable region; a `GrantRef` is a copyable-but-untrusted handle whose authority comes from
the live `Grant`. `gen` bumps on revoke → stale refs fail (use-after-revoke caught). The
kernel `GrantTable` (`GRANTTAB_MAX = 8`) keys grants by **(owner_slot, owner_gen)** and
supports make/ref/open/copy_out (bounds-checked), `grant_table_delegate` (child region `⊆`
parent's), `grant_table_revoke_owner` (on death), and `grant_table_revoke_cascade` (revoke a
grant **and its entire delegation subtree**). Gates: `grant-test`, `granttab-test`.

### 12.4 Per-process authority masks — GATED

`allow_mask` (which pids you may IPC) and `kcall_mask` (which kernel ops you may invoke) are
`Mask32` on each `Process`. `kcall(t, op, arg)` checks `kcall_mask` and **audits the
attempt** (allowed or denied) into `cap_audit` (§15). Attenuated spawn intersects both masks.

---

## 13. IPC — GATED

`kernel/core/ipc.mc`, `proc_ipc.mc`. Fixed-size inline messages (no out-of-band buffers):

```
struct Message { from, from_gen, call_id, tag, a0, a1, a2 }
```

`from`/`from_gen` is the **kernel-stamped, unforgeable** sender endpoint. `call_id`
correlates synchronous request↔reply. Per-process `Mailbox<Message, IPC_SLOTS=4>` is a FIFO
with filtered receive.

| Operation | Notes |
|-----------|-------|
| `ipc_send_try` / `ipc_send` / `ipc_send_result` | Permission-checked vs `allow_mask`; typed `SendError { Denied, DeadTarget, Timeout }`. |
| `ipc_send_ep` / `ipc_notify_ep` | Endpoint-validated, fail-closed `DeadEndpoint` on stale slot. |
| `ipc_call` / `ipc_call_ep` | Synchronous send+receive matched by `call_id` (MINIX rendezvous). |
| `ipc_receive` / `_timeout` / `_from` | Blocking/filtered receive (sleeps, doesn't spin). |
| `ipc_reply` | Replies to the *requester's endpoint* (slot+gen); dropped if reused (fail-closed). |

Reserved tags: `TAG_DEAD = 0xDEAD` (synthesized when an awaited endpoint dies, so a receiver
never blocks forever) and `TAG_QUANTUM = 0xDEAD+1`. IPC is **synchronous rendezvous with
async notify**; messages are **copied, not zero-copy** (an optimized fast path is roadmap —
vision § fast transport). Gates: `ipc-test`, `ipc-result-test`, `endpoint-test`.

---

## 14. Resource Governance — GATED (the safety keystone)

The agent-OS P0 keystone: **a runaway or hijacked agent must not OOM/starve the host.**

- **Accounting & quota** (§9.6): `resacct_charge` fails closed (`OverQuota`) with no partial
  reservation.
- **Reclaim-on-death:** `proc_death_cleanup` (shared by exit/OOM/fault) runs the death hook,
  clears IPC + signals + wait state, closes fds, and **resets the memory account to zero**,
  then wakes anyone blocked receiving from the dead incarnation.
- **Live OOM-kill** (reclaim from a *live* agent): `proc_oom_victim` (highest-usage live,
  non-bootstrap offender), `proc_oom_kill` (force a non-current victim through the death
  path; `OOM_KILLED_CODE = 0xDEAD_00F0`), `proc_oom_reclaim` (select + kill; the allocator's
  pressure entry point).
- **Fault containment (F1):** a `g_fault_domain` marker records "this agent owns the CPU." On
  a synchronous trap, `proc_fault_contain` classifies: attributable to an agent →
  `proc_fault_kill` (`FAULT_KILLED_CODE = 0xDEAD_00F1`) kills + reclaims it and the kernel
  survives; kernel's own fault (`NoVictim`) → stays fatal.

> **Calibrated claim:** resource-accounting primitives, victim selection, OOM-kill,
> fault containment, and reclaim-on-death are **implemented and parity-gated**. The current
> gates prove the governance **mechanism under explicit charge sites** — they do **not** yet
> prove comprehensive live memory enforcement across all allocation paths, because the
> allocator→charge wiring inside `heap.mc` is follow-up work (§9.6).

**What `agentos-test` proves under QEMU:** spawn three never-exiting agents A/B/C; charge
memory (C the runaway); an over-quota charge on C fails closed; `proc_oom_victim` selects C;
`proc_oom_reclaim` kills C (now a `Zombie`, `used == 0`, fds released) **while A and B stay
live with accounts intact**; C reaps cleanly. Output: `1ABC2 → AGENTOS-OK`. Gates:
`agentos-test`, `contain-test`, `fault-isolation-test`. **Deferred (ABSENT):** CPU / IPC /
accelerator accounting (vision P0.6 — remote-inference lane first).

---

## 15. Observability & Provenance — GATED

`kernel/core/ipc_trace.mc`. An `IpcTrace` is a bounded ring (`IPC_TRACE_CAP = 16`) of
`IpcEvent { seq, from, to, tag, size }`. `ipc_trace_record` is **O(1), non-blocking,
allocation-free**, overwrites the oldest on overflow (bumping `dropped`), and hands out a
monotonic `seq` so a drainer can detect gaps. Two disjoint instances:

- **`g_ipc_trace`** — message provenance. Sampling (`ipc_provenance_set_sample(n)`) and
  per-channel opt-out keep it off the future fast path.
- **`g_cap_trace`** (`cap_audit`) — authority use.

**Exact audit coverage (faithful to code):** `g_cap_trace` records **every `kcall` attempt,
allowed or denied**, and **every *dispatched* tool call**. Note the deliberate asymmetry —
for tool calls, only dispatched calls are recorded; **Denied / Exhausted / NoSuchTool
attempts are *not* audited today.** (Auditing denied tool attempts with reason codes would be
a reasonable hardening step for an agent OS, but it is not the current behavior, and this
spec reflects the code.) Recording is observe-only — zero effect on delivery semantics or
return values.

---

## 16. Supervisor & Service Manifests — GATED · demo-scale capacity (`SVC_MAX = 8`)

`kernel/lib/supervisor.mc`. Privileges are **data**: a `ServiceManifest { name_key, endpoint,
allowed_ipc, allowed_kcalls, restart, priority }` declares identity, least-privilege
authority, and restart policy (`Never` = core/fatal, `OnFailure` = auto-restart). The
`Supervisor` registers services with a spawn closure, starts them in **dependency
(topological) order**, and `supervisor_tick` restarts failed `OnFailure` services. Applying a
manifest = `proc_set_allow_mask` + `proc_set_kcall_mask` + `proc_set_priority`; the kernel's
per-op checks then enforce it.

---

## 17. Syscall ABI & User Boundary

`kernel/core/syscall.mc`. `SyscallTable { handlers[SYS_MAX], registered[SYS_MAX] }`,
`SYS_MAX = 16`. `syscall_dispatch(number, a0, a1, a2)` is bounds-checked and returns
`SYS_ENOSYS = 0xFFFF_FFFF_FFFF_FFFF` for unregistered/out-of-range numbers. RISC-V
convention: **`a7` = number, `a0/a1/a2` = args, `a0` = return**; the U-mode trap
(`usermode_runtime.c`) decodes `mcause == 8`, dispatches, bumps `mepc += 4`, `mret`s.

**Status:** the **table mechanism is GATED** (`fs-syscall-test`); the *registered* surface is
a small POSIX **DEMO-SCOPE** layer (`posix.mc`): `getpid`, `open`, `read`, `write`, `close`
over a single in-memory file. A production syscall surface is **ABSENT**; the user-boundary
safety machinery (§9.3) is GATED.

---

## 18. Filesystem & Storage

`kernel/fs/`. All **IMPLEMENTED/GATED**. The flat key/value stores (`kvstore.mc`,
`blobstore.mc`, `ramfs.mc`, `diskfs.mc`) remain; **hierarchical** paths now exist for real in
`treefs.mc` (`treefs-test`: nested mkdir/create, `.`/`..` traversal, path resolution, `getdents`
listing, typed errors), and `fs_toolserver.mc` (`fs-toolserver-test`) layers workspace-scoped,
capability-checked, audited path access over it (M1 walking skeleton — the start of the native
agent tool catalog, not yet the full read/ls/grep/edit/find surface).

| File | Role | Capacity |
|------|------|----------|
| `vfs.mc` | fd table over ramfs; `open/read/write/close/dup/stat`. | `MAX_FDS=16`, 512 B/file |
| `vfsmount.mc` | mount table, one-byte prefix → fs type. | `MNT_MAX=4` |
| `ramfs.mc` | flat in-memory files; typed errors, no silent truncation. | `MAX_FILES=8`, 4 KiB pool |
| `diskfs.mc` | persistent superblock+inode fs (magic `MCFS`); survives remount. | one block/file |
| `blockdev.mc` | `trait BlockDevice` (512 B) via `*dyn` dispatch. | — |
| `bcache.mc` | 4-slot write-back block cache + hit/miss counters. | `NSLOTS=4` |
| `kvstore.mc` | mutable `u64 → bytes` agent-state map, delete-compaction. | `MAX_KEYS=8`, 4 KiB |
| `blobstore.mc` | durable `u32 → bytes` checkpoint sink; `blob_reopen`. | `MAX_BLOBS=8`, 4 KiB |

`blobstore` + `kvstore` are the agent-OS durable sinks. Gates: `diskfs-test`, `bcache-test`,
`blockfs-test`, `fs-server-test`.

---

## 19. Network Stack — GATED

`kernel/net/`. A **substantial QEMU-tested TCP/IP stack supporting real DNS, TCP, HTTP, and
TLS demos over slirp** (gateway `10.0.2.2`); TLS via vendored **BearSSL**.

> **Scope honesty:** "substantial," not "complete." The TCP connection logic implements the
> RFC 793 state machine, modular send/recv windowing, out-of-order reassembly (8 segments),
> and an RTO retransmit timer — enough for real single-connection DNS/HTTP/TLS demos. It is
> **not** a claim of congestion control, PMTU discovery, IPv4 fragmentation/reassembly, full
> TCP options, multi-connection stress hardening, or production resolver/TLS-verification
> completeness. Treat per-protocol coverage as "demo-exercised," not "RFC-complete."

- **Link/IP:** `ethernet`, `arp` + `arp_cache` (8-entry), `ipv4` (RFC 1071 checksum),
  `icmp`, `inet_checksum`, `packet` (typed `Ipv4Addr` + bounds cursor), `net_rx`.
- **UDP:** `udp`, `udp_socket` (`MAX_SOCKETS=8`, typed `NoListener`).
- **TCP:** `tcp`, `tcp_conn` (RFC 793 state machine), `tcp_window`, `tcp_reasm`, `tcp_rtx`,
  `tcp_socket` (integration + segment-hold), `tcp_tx`.

Gates: `dns-test`, `net-test`, `http-get-test`, `https-get-test`, `google-https-test`,
`tcp_*` demos (each C and LLVM). See the network/TLS notes for which are hard gates vs
best-effort.

---

## 20. Drivers

`kernel/drivers/`. **QEMU-oriented** (paravirtual/emulated), not real-silicon breadth.

| Driver | Hardware | Status |
|--------|----------|--------|
| `virtio/virtio_net` | VirtIO 1.0 NIC | **GATED** — handshake, split virtqueues, `move`-checked DMA ownership, TX/RX, 1 s deadline. |
| `virtio/virtio_blk` | VirtIO block | **GATED** — 3-descriptor chains, 5 s deadline. |
| `pci` | ECAM config | **IMPLEMENTED** — bus scan, BAR0. |
| `e1000` | Intel 82540EM | **MOCK / probe-only** — no rings. |
| `fb` | linear framebuffer | DEMO-SCOPE (16×16). |
| `irq/plic` | RISC-V PLIC | **GATED** — typestate `IrqLine<State>`, `#[irq_context]`-checked. |
| `timer/clint` | RISC-V CLINT | **GATED** — `mtime`/`mtimecmp`. |

DMA buffers use `move` semantics so CPU↔device ownership transitions are compile-checked;
VirtIO I/O carries real-time deadlines that fail closed. Gates: `nic-test`, `blk-test`,
`driver-test`, `e1000-test` (probe).

---

## 21. Bus & Device Model — IMPLEMENTED (static)

`kernel/bus/` + `kernel/lib/registry*.mc`. A MINIX-style plug model: platforms list devices
(`DeviceId`, `ResourceSet`); `bus_probe_attach` matches each to the first `Provider { probe,
attach, class }` whose probe succeeds and records an endpoint in the `Registry`; services
discover dependencies by name hash via `registry_client`. **Static registration today;
dynamic loading is ABSENT.** Gate: `driver-test`.

---

## 22. Code Loading, Live Update & Checkpoint

- **ELF** — `kernel/core/elf.mc`: bounds-checked ELF64 parser; untrusted
  `phoff/phnum/phentsize` validated up front. **GATED** (`elf-test`, `elf-run-test`).
- **Dynamic linking** — `dynlink.mc`: `R_RISCV_RELATIVE` relocations for PIE. **DEMO-SCOPE**
  — no symbol resolution / PLT-GOT (`dynlink-test`).
- **Service live-update** — `liveupdate.mc`: MINIX-style checkpoint→update-code→restore of
  simple `ServiceState`. **DEMO-SCOPE** (`liveupdate-test`).
- **Agent checkpoint/restore/migrate** — `checkpoint.mc`: serialize `{ pid, FdSpace,
  ResourceAccount }` to a durable blob; restore spawns a **fresh** slot; `migrate` =
  save(src)→restore(dst)→exit(src), atomic on failure. **IMPLEMENTED** for fd-space +
  account; full context capture is ABSENT.

---

## 23. Safety & Hardening

Beyond the type-system guarantees, the kernel ships an **opt-in hardening suite**: static
analyses (UserPtr/Cap/Rights/Secret taint, definite-init, borrow-escape) and sanitizer
profiles (ksan/kmsan/kcsan, heap redzones + stack canary), all **parity-gated**. Struct-layout
drift between MC and mirrored C structs is a compile error via generated
`_Static_assert(sizeof/offsetof)`. Current roadmap: [`../todo.md`](../todo.md);
hardening campaign record: [`../hardening-todo.md`](../hardening-todo.md).

---

## 24. Testing & Verification

Every kernel capability has a gate, wired in `build.zig` (≈297 steps) and aggregated by the
master `m0` step. The gates come in two forms: many **boot under QEMU on both compiler
backends** (`*-test` + `llvm-*-test`), while several capability layers run as **host fixtures**
through `tools/lib/host-harness.sh` (e.g. `treefs-test`, `fs-toolserver-test`, `agent-fs-test`,
`policy-test`, `netcap-test`, `agent-containment-test`) — they exercise the host-compiled MC
logic directly, not under QEMU. The confined-agent **acceptance bar** (§6: a genuinely
isolated U-mode agent under QEMU) is therefore met only by selected QEMU boots, not by the
host fixtures. Fixtures are self-verifying (assert expected output / exit codes / typed
errors). For the QEMU-gated, dual-backend capabilities the parity requirement means a
behavioral divergence between `emit-c` and `emit-llvm` is a build failure. (Recall §8.3: "both
backends" is the two lowerings, on the riscv64 gate — not multi-architecture parity.)

---

## 25. Status Summary

| Subsystem | Status |
|-----------|--------|
| riscv64 boot, trap, context switch, Sv39 paging | **GATED** |
| x86_64 / aarch64 full kernel | **PARTIAL / DEMO-SCOPE** |
| Page allocator, heap (+ coalescing, redzone/KASAN) | **GATED** |
| Address classes (PAddr/VAddr/UserPtr) + uaccess defenses | **GATED (compile-time)** |
| mmap / demand paging / COW | mmap **GATED**; demand paging & COW **DEMO-SCOPE** (single-region / one-page) |
| Process lifecycle, attenuation, endpoints | **GATED** · demo-scale (`MAX_PROCS=8`) |
| Scheduler (RR/priority/fair-share, preemption) | **GATED**; SMP **DEMO-SCOPE** (`NCORES=2`) |
| Agent sandbox + tool-call ABI | **GATED**. Legacy `agent_tool_call` transport **MOCK** (in-process, not a trust boundary); confined-JS **FS** broker **REAL** on RISC-V/S-mode (§10.3); brokered JS `host_net_fetch` is gated over the network broker control plane, the real TCP-backed transport (`qjs-net-realtool-test` / LLVM), and S-mode IRQ-backed `SYS_POLL` completion from virtio-net (`qjs-smode-net-irq-tool-test` / LLVM); JS `host_fs_read` is gated through S-mode IRQ-backed `SYS_POLL` completion from virtio-blk (`qjs-smode-blk-irq-tool-test` / LLVM); real TCP-backed network broker **GATED** in the RISC-V agent-net demo; out-of-process tool-server transport **pending** |
| Capabilities, grants + delegation/cascade | **GATED** |
| IPC (sync rendezvous + notify, endpoint-safe) | **GATED** (copying, not zero-copy) |
| Resource governance: quota + OOM-kill + fault containment | **GATED** (mechanism under explicit charge sites; full allocator wiring follow-up) |
| Provenance + cap audit | **GATED** (kcall audits allowed+denied; tool calls audit dispatched only) |
| Supervisor + manifests | **GATED** · demo-scale (`SVC_MAX=8`) |
| Syscall table mechanism | **GATED**; registered surface **DEMO-SCOPE** (5 POSIX calls) |
| Filesystems / storage | **GATED**; flat KV stores + **hierarchical `treefs`** (mkdir/`..`/getdents) + capability-checked `fs_toolserver` (M1 skeleton) |
| Network stack (real DNS/TCP/HTTP/TLS demos) + BearSSL | **GATED** (demo-exercised, not RFC-complete) |
| Drivers: virtio net/blk, plic, clint | **GATED**; pci **IMPLEMENTED**; e1000 **MOCK** |
| ELF load | **GATED**; dynlink / liveupdate **DEMO-SCOPE**; agent checkpoint/migrate **IMPLEMENTED** |

---

## 26. Evidence Matrix

Per the faithfulness rule, representative normative claims with their source, gate, and
scope. Gate names are verified against `build.zig`.

| Claim | Source | Gate(s) | Scope |
|-------|--------|---------|-------|
| Endpoint generation prevents stale-slot IPC misdelivery | `process.mc`, `proc_ipc.mc` | `endpoint-test`, `llvm-endpoint-test` | riscv64 QEMU |
| OOM victim selection kills highest-usage live agent; others survive | `process.mc:404-472` | `agentos-test`, `llvm-agentos-test` | explicit-charge fixture |
| A faulting agent is killed + reclaimed; kernel survives | `process.mc:474-553` | `contain-test`, `fault-isolation-test` | riscv64 QEMU |
| Rights/capabilities attenuate only (child = parent ∩ keep) | `capability.mc`, `std/rights.mc` | `cap-test`, `llvm-cap-test` | compile-time + QEMU |
| Grant revoke invalidates outstanding refs; cascade revokes subtree | `kernel/lib/granttab.mc` | `grant-test`, `granttab-test` | riscv64 QEMU |
| `UserPtr<T>` cannot be dereferenced in the kernel | `uaccess.mc` + compiler diagnostic `E_USER_PTR_DEREF` | compile-time spec fixtures | compile-time |
| Real DNS + TCP + HTTPS over slirp (no mocks on the wire) | `kernel/net/*`, `third_party/bearssl` | `dns-test`, `https-get-test`, `google-https-test` | QEMU + live internet |
| `page_free` is real O(1) reclaim (not a no-op) | `page_alloc.mc` | `page-test`, `llvm-page-test` | riscv64 QEMU |

---

## 27. Roadmap

The safety keystone (governance) has landed. The open frontier, per the vision doc:

- **Hierarchical VFS** — *partially delivered*: `treefs.mc` provides real paths (nested
  mkdir/create, `.`/`..`, `getdents`); the remaining work is mounting it as the primary VFS
  surface and broadening the catalog (read/ls/grep/edit/find over real paths).
- **Native tool catalog over `agent_tool_call`** — *skeleton delivered*: `fs_toolserver.mc`
  (`fs-toolserver-test`) is a workspace-scoped, capability-checked, audited FS tool server
  (M1 walking skeleton). The remaining frontier is making the transport fully IPC-isolated
  and expanding beyond the FS tools into a real, broad trust boundary.
- **Agent code execution** — *delivered*: QuickJS runs as a confined userspace ELF on all three
  arches (riscv64 M+S-mode, x86_64 ring-3, AArch64 EL0), evaluating pure-JS agents under kernel
  confinement (BearSSL was the C-linking precedent). The remaining roadmap is broader: wider
  capability-tool coverage, exposing the real network broker as a production JS/tool-catalog
  operation, cross-arch real-broker parity (x86/AArch64 still need confined-agent runtimes that
  reuse the shared broker), and optionally a second runtime (e.g. WASM).
- **Allocator→charge wiring** — close the §9.6/§14 gap so governance enforces on every
  allocation path, not only explicit charge sites.
- **IPC fast path** — co-designed with sampling provenance.
- **Accelerator/CPU/IPC accounting** — extend governance beyond memory for on-host inference.

Current roadmap: [`../todo.md`](../todo.md). Hardening campaign record:
[`../hardening-todo.md`](../hardening-todo.md).
