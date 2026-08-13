# MC Microkernel — Architecture Specification

> **Status:** Living document, derived from the current source tree. It describes
> *what the kernel is* (object model, ABIs, invariants, mechanisms) as a complement to
> [`MC_0.7_Final_Design.md`](MC_0.7_Final_Design.md) (the *language* the kernel is written
> in) and the live roadmap documents. Where this spec and a roadmap disagree on
> "state today," **this spec reflects the code**.
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

The MC microkernel is a **capability microkernel validation workload** in the MINIX/seL4
lineage, written entirely in the MC language. It exists to exercise the compiler on
freestanding, privilege-sensitive, low-level code. It is *not* a general-purpose OS and it
is not a product runtime. It does **not** target POSIX compatibility or general-purpose
hardware breadth; those mechanisms (a POSIX-shaped syscall demo, drivers, filesystems,
ELF loading, TCP/IP) exist only where they validate language/compiler behavior such as
address classes, privilege transitions, ABI layout, user-copy, async, ownership, and
backend parity.

What distinguishes it from a production C kernel is that a large class of kernel bugs are
**compile errors** rather than runtime faults: opaque address classes, linear/`move`
capabilities, monotone rights attenuation, bounds/overflow traps, and IRQ-context
discipline are enforced by the MC type system. The kernel also holds a **dual-backend
parity** invariant: every gate runs on both the `emit-c` and `emit-llvm` lowerings and must
agree (§8.3 distinguishes this from CPU-architecture support).

### 1.1 Source map

| Area | Directory |
|------|-----------|
| Core (process, ipc, sched, capability, memory, resource governance) | `kernel/core/` |
| Arch HAL (riscv64 primary, x86_64/aarch64 partial) | `kernel/arch/<arch>/` |
| Library types (resacct, granttab, supervisor, mailbox, fdspace, registry) | `kernel/lib/` |
| Filesystems & storage | removed from current core scope |
| Network stack | removed from current core scope |
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

- buggy or malicious **guest/user tasks** — unintentional exhaustion, crashes, malformed
  messages, and code actively trying to escape/escalate/exfiltrate within granted authority;
- compromised **userspace-shaped services**;
- **stale endpoints** and **revoked grants** (generation-checked, fail-closed);
- **malformed user pointers** and **untrusted ELF inputs** (validated, bounds-checked);
- **resource exhaustion by a live guest task** (§14).

**Out of scope today:**

- malicious kernel code or trusted runtime/compiler shims (they are validation
  dependencies — §4);
- malicious hardware / DMA outside the modeled drivers;
- physical attacks and side channels;
- a formal seL4-style refinement proof (the guarantees here are type-system + test based,
  not machine-checked proof);
- production multi-tenant hardening at scale.

The kernel validation workload tests mechanism, not product policy. Deciding whether a
guest task is *misbehaving* beyond concrete kernel invariants is outside this repository's
core language/compiler goal.

---

## 4. Validation Trust Inputs

For "many bugs become compile errors" to hold, the following must be trusted. They are
**not** verified by the kernel's own guarantees:

- the **MC compiler & type checker** (the source of the compile-time guarantees);
- the **`emit-c` and `emit-llvm` backends** (a miscompilation defeats parity);
- the **runtime C/asm shims** (`*_runtime.c`: trap vectors, context switch, naked
  functions, freestanding libc subset);
- the **arch trap/context-switch/paging** code;
- **QEMU / OpenSBI** assumptions for the demo/boot envelope;
- any **C-ABI struct mirrors** and the generated `_Static_assert` layout checks that guard
  them.

This trust base is small relative to a monolithic kernel, which is the point
(small, auditable dependencies for a semi-trusted workload) — but it is explicitly
*trusted*, not proven.

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
            │  Confined apps (validation workload only)   │
            ├─────────────────────────────────────────────────────────┤
   above    │  Policy plane / product runtime (out of current scope)│   ← not in kernel
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
5. **Subsystems** — logger, process table + scheduler, and focused driver/runtime workload.
6. **Report** — boot returns a stage bitmask; demos assert it.

Legacy M-mode QEMU demos (`-bios none`, kernel at `0x8000_0000`) and S-mode/OpenSBI demos now
**coexist**: the M-mode path remains for the bare-metal bring-up demos, while a full set of
S-mode gates runs under REAL OpenSBI — `sbi-boot-test`, `smode-user-test`,
`smode-timer-test`, PLIC interrupt gates, BootInfo/FDT, and UART-driver
validation. The former S-mode virtio block/network data-path and IRQ fixtures
were removed from the core workload. Until paging is explicitly enabled, kernel
and tasks execute in physical address space. **Status: GATED** by the retained focused
M-mode/S-mode validation steps · riscv64 only.

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
| **x86_64** | ✓ multiboot | ✓ ring-3 confined user app | ✓ (ring-3, `int 0x80`) | ✓ 4-level | ✓ LAPIC timer + PCI (CAM) | **GATED (boot/paging/user/IRQ); not full-kernel parity** |
| **aarch64** | ✓ QEMU virt (EL1) | ✓ EL0 confined user app | ✓ (EL0, `svc #0`) | ✓ stage-1 4 KB | ✗ (no GIC/timer IRQ yet) | **GATED (boot/paging/user); IRQ pending** |

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
non-trapping walk returning `LeafMapping { phys, flags }` with permission accessors. Gates:
`page-test`.

### 9.5 Removed VM product layer

Anonymous mmap, demand paging, copy-on-write, per-process address-space switching, and
fault-isolation QEMU demos were removed from the compiler-core workload. The retained kernel
surface validates typed paging primitives and user-access boundaries; it does not define an OS
virtual-memory product layer.

### 9.6 Resource accounting — GATED

`kernel/lib/resacct.mc`. `ResourceAccount { used, limit }`. `resacct_charge(n)` is
**all-or-nothing**: on overflow or over-limit it returns `err(MemError.OverQuota)` with
`used` unchanged. Each `Process` owns a `macct` with `MEM_QUOTA_DEFAULT = 0x100000` (1 MiB),
reset on spawn and on death. See §14 for the live-reclaim keystone. **Scope caveat:** the
gate proves the mechanism under **explicit charge sites**; the allocator→charge call-site
wiring inside `heap.mc` (so that *every* allocation path charges automatically) is
follow-up work.

### 9.7 TLB — validation boundary

Multi-core TLB shootdown bookkeeping has been removed from the core validation
workload. Retained paging tests focus on language, address-space, and backend
lowering behavior; production multi-core shootdown policy belongs to a separate
kernel product profile.

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
    wait_slot, wait_gen,
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
reused; `endpoint_slot` fails `DeadEndpoint` on generation mismatch. Gate: `endpoint-test`.

### 10.3 Runtime ABI fixtures — GATED, not a kernel product layer

The dedicated kernel policy runtime and network broker fixtures have been removed. Kernel tests
now use smaller runtime ABI fixtures to exercise userspace calls, async polling, isolation, and
C/LLVM lowering. These fixtures are not a production capability broker and do not define a
native OS surface.

Gates: `cap-test`, `uaccess-pt-test`.

## 11. Scheduler — validation-scale

`kernel/core/proc_sched.mc` and `sched.mc` remain as validation-scale scheduler
mechanisms. The former SMP run-queue/work-stealing fixture was removed from the
current core workload.

- **Selection:** round-robin, priority (ties → lower pid), and **fair-share**
  (`proc_pick_fair`: least effective ticks, cost = `(ticks + throttle_penalty) /
  max(priority,1)`).
- **Preemption:** timer-driven via the CLINT trap path (`preempt_runtime.c`,
  `TICK_INTERVAL`); `proc_tick_notify` sends `TAG_QUANTUM` to the scheduler endpoint.
- **Blocking:** `proc_block`/`proc_unblock`; `proc_yield_or_idle` sleeps (`wfi`) rather than
  spins.
- **Throttle / pause:** `proc_throttle` (deprioritize), `proc_pause`/`proc_resume`
  (`BLOCK_PAUSED`).

---

## 12. Capability Model — GATED (the heart of the kernel)

### 12.1 Capabilities

`kernel/core/capability.mc`:

- **`BootAuthority`** — opaque linear setup token. Creating it is the audited authority
  root seam; ordinary code cannot mint capabilities just by importing the module.
- **`Cap<R>`** — `opaque move struct`. Unforgeable (private field; only
  `cap_mint(auth, ...)` constructs), linear (`move` — single owner), revoked by
  consuming (`cap_revoke`).
- **`RCap<R>`** — `Cap<R>` + opaque `Rights`. `rcap_allows(c, bit)` checks authority;
  **`rcap_attenuate(c, keep)` is the only derivation** — result = `parent ∩ keep`. **No
  widening operation exists in the API.**

### 12.2 Rights — GATED

`std/rights.mc`: `opaque struct Rights { bits: u32 }`. Minting from raw bits is
privileged and requires a `RightsAuthority` root token (`rights_grant(auth, ...)`
or `rights_single(auth, ...)`); every other combinator is **narrow-only**
(`rights_attenuate` = `∩`, `rights_without`, `rights_none`). `rights_subset_of`
checks `child ⊆ parent`. Opacity makes "restore a dropped right" unrepresentable
outside the module.

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
`Mask32` on each `Process`. `kcall(t, op, arg)` checks `kcall_mask`. Attenuated spawn
intersects both masks.

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

## 14. Resource Governance — GATED

The kernel validation workload keeps a small resource-governance path: **a runaway task should
not OOM/starve the host in the explicit accounting fixture.**

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

The standalone OOM policy fixture was removed from the core workload. The retained gates focus
on fault containment and explicit reclaim paths needed by the language/runtime validation
surface. **Deferred (ABSENT):** comprehensive live accounting across all allocation paths.

---

## 15. Supervisor & Service Manifests — REMOVED

The service-supervisor and manifest runtime was removed from the validation kernel scope. It
was OS policy surface, not language-core evidence. Process, IPC, capability, and scheduler
mechanisms remain covered by narrower fixtures.

---

## 16. Syscall ABI & User Boundary

`kernel/core/syscall.mc`. `SyscallTable { handlers[SYS_MAX], registered[SYS_MAX] }`,
`SYS_MAX = 16`. `syscall_dispatch(number, a0, a1, a2)` is bounds-checked and returns
`SYS_ENOSYS = 0xFFFF_FFFF_FFFF_FFFF` for unregistered/out-of-range numbers. RISC-V
convention: **`a7` = number, `a0/a1/a2` = args, `a0` = return**; the U-mode trap
(`usermode_runtime.c`) decodes `mcause == 8`, dispatches, bumps `mepc += 4`, `mret`s.

**Status:** the syscall table mechanism remains a language/runtime validation boundary. The
former POSIX/VFS demo surface was removed from the core workload. A production syscall surface
is **ABSENT**; the user-boundary safety machinery (§9.3) is GATED.

---

## 17. Filesystem & Storage

`kernel/fs/` is retained only for the minimal `BlockDevice` trait used by low-level driver
validation. The product-style VFS, mount table, in-memory hierarchy, disk filesystem,
block-backed file store, write-back cache, blob store, and persistence demos were removed
from the core workload.

| File | Role | Capacity |
|------|------|----------|
| `blockdev.mc` | `trait BlockDevice` (512 B) via `*dyn` dispatch. | — |


---

## 19. Network Validation — removed from core scope

The former `kernel/net/` link/IP helpers and virtio-net ARP/ICMP QEMU validation
were removed with the OS product-surface cleanup. Network protocol and NIC
product work belongs to a separate validation/product profile if it is revived.

---

## 20. Drivers

`kernel/drivers/`. **QEMU-oriented** (paravirtual/emulated), not real-silicon breadth.

| Driver | Hardware | Status |
|--------|----------|--------|
| `virtio/virtio_blk` | VirtIO block | **GATED** — 3-descriptor chains, 5 s deadline. |
| `pci` | ECAM config | **IMPLEMENTED** — bus scan, BAR0. |
| `irq/plic` | RISC-V PLIC | **GATED** — typestate `IrqLine<State>`, `#[irq_context]`-checked. |
| `timer/clint` | RISC-V CLINT | **GATED** — `mtime`/`mtimecmp`. |

DMA buffers use `move` semantics so CPU↔device ownership transitions are compile-checked.
Standalone virtio net/block device data-path gates were removed from the core
workload; retained driver validation is language/backend scoped. Gate:
`driver-test`.

---

## 21. Driver Binding Scope

The former bus/registry/plugin model was removed from the core workload. Driver validation now
uses focused device fixtures directly; dynamic loading and service discovery are **ABSENT**.

---

## 22. Code Loading, Live Update & Checkpoint

- **ELF** — `kernel/core/elf.mc`: bounds-checked ELF64 parser; untrusted
  `phoff/phnum/phentsize` validated up front. **GATED** (`elf-test` plus retained loader
  validation).
- **Dynamic linking** — removed from the core workload.
- **Agent checkpoint/restore/migrate** — absent from the core workload.

---

## 23. Safety & Hardening

Beyond the type-system guarantees, the kernel ships an **opt-in hardening suite**: static
analyses (UserPtr/Cap/Rights/Secret taint, definite-init, borrow-escape) and sanitizer
profiles (ksan/kmsan/kcsan, heap redzones + stack canary), all **parity-gated**. Struct-layout
drift between MC and mirrored C structs is a compile error via generated
`_Static_assert(sizeof/offsetof)`. Current roadmap: [`../todo.md`](../todo.md).

---

## 24. Testing & Verification

Retained kernel validation capabilities have gates wired through the build graph. The gates come in two forms: selected **boot under QEMU on both compiler
backends** (`*-test` + `llvm-*-test`), while several capability layers run as **host fixtures**
through `tools/lib/host-harness.sh` — they exercise the host-compiled MC
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
| User isolation + runtime ABI | **DEMO-SCOPE**. Remaining request ops exercise syscall/async/runtime mechanics, not part of a product broker. |
| Capabilities, grants + delegation/cascade | **GATED** |
| IPC (sync rendezvous + notify, endpoint-safe) | **GATED** (copying, not zero-copy) |
| Resource governance: quota + OOM-kill + fault containment | **GATED** (mechanism under explicit charge sites; full allocator wiring follow-up) |
| Provenance + cap audit | **GATED** (kcall audits allowed+denied; tool calls audit dispatched only) |
| Syscall table mechanism | **GATED**; production syscall surface absent |
| Filesystems / storage | **GATED**; low-level block/cache/blob validation only |
| Network validation | **GATED**; link/IP/driver validation only |
| Drivers: virtio net/blk, plic, clint | **GATED**; pci **IMPLEMENTED** |
| ELF parse/load | **GATED**; dynamic linking absent |

---

## 26. Evidence Matrix

Per the faithfulness rule, representative normative claims with their source, gate, and
scope. Gate names are verified against `build.zig`.

| Claim | Source | Gate(s) | Scope |
|-------|--------|---------|-------|
| Endpoint generation prevents stale-slot IPC misdelivery | `process.mc`, `proc_ipc.mc` | `endpoint-test`, `llvm-endpoint-test` | riscv64 QEMU |
| Rights/capabilities attenuate only (child = parent ∩ keep) | `capability.mc`, `std/rights.mc` | `cap-test`, `llvm-cap-test` | compile-time + QEMU |
| Grant revoke invalidates outstanding refs; cascade revokes subtree | `kernel/lib/granttab.mc` | `grant-test`, `granttab-test` | riscv64 QEMU |
| `UserPtr<T>` cannot be dereferenced in the kernel | `uaccess.mc` + compiler diagnostic `E_USER_PTR_DEREF` | compile-time spec fixtures | compile-time |
| `page_free` is real O(1) reclaim (not a no-op) | `page_alloc.mc` | `page-test`, `llvm-page-test` | riscv64 QEMU |

---

## 27. Roadmap

The safety keystone (governance) has landed. The open frontier, per the vision doc:

- **Hierarchical VFS** — *partially delivered*: `treefs.mc` provides real paths (nested
  mkdir/create, `.`/`..`, `getdents`); the remaining work is mounting it as the primary VFS
  surface and broadening the catalog (read/ls/grep/edit/find over real paths).
- **Native tool catalog** — out of current language-kernel scope. The kernel tree now keeps only
  demo-scope tool ops needed to exercise the userspace ABI and async runtime.
- **Confined app execution** — retained only as validation workload: userspace ELF loading, syscall confinement, and C/LLVM backend parity are exercised by narrow app fixtures. Product runtimes and extra language engines are out of current scope.
- **Allocator→charge wiring** — close the §9.6/§14 gap so governance enforces on every
  allocation path, not only explicit charge sites.
- **IPC fast path** — co-designed with sampling provenance.
- **Accelerator/CPU/IPC accounting** — extend governance beyond memory for on-host inference.

Current roadmap: [`../todo.md`](../todo.md).
