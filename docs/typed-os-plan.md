# Plan — `mc-kernel-riscv-net`: a minimal *typed* OS that can be pinged

> **Status (2026-06-07): all phases implemented and gated in `zig build m0`
> (18 gates).** The typed kernel boots on QEMU virt, drives a virtio-net device,
> and pings the gateway (ARP + IPv4 + ICMP over real DMA); the typed-CPU trap +
> CLINT timer interrupt fires under QEMU; the Hart / IrqLine / Page / DMA / queue
> typestates enforce their contracts at compile time (10 reject fixtures). Gates:
> `net-test` (ping), `trap-test` (timer IRQ), `kernel-test` (riscv compile +
> typestate rejects). The one piece not exercised in CI is **host→guest `ping`**:
> the inbound ARP/ICMP responder (`nic_serve`) is implemented and compile-checked,
> but driving it needs a tap netdev (user networking can't ping the guest).

## 0. Goal (one sentence)

A minimal kernel that boots on `qemu-system-riscv64 -machine virt`, logs over the
16550 UART, sets up trap/timer/IRQ, drives a virtio-net device, runs a tiny
ARP/IPv4/ICMP stack, and **answers a ping** — built so that the CPU state, MMIO
register permissions, IRQ lifecycle, DMA-buffer ownership, virtqueue descriptor
ownership, and packet lifecycle are all enforced by the type system.

The point is **not** features. It is to show that one runnable, networked system
can be assembled where the hazards a C kernel guards against by convention are
compile errors.

### Explicit non-goals (v1)
userspace · syscalls · processes · virtual memory · filesystem · PCI · USB ·
SMP · TCP/UDP · DHCP · scheduler · power management · hotplug. Single hart,
single address space, static memory, virtio-mmio only, poll-first.

---

## 1. What already exists (leverage, don't rebuild)

This plan extends a working base, not a blank repo. Already built and **running
under QEMU** (`zig build m0` is green):

- **Boot → QEMU-virt → UART**: `tests/qemu/virt.ld`, a bare-metal `_start`/runtime
  pattern, and observed 16550 output at `0x1000_0000` (`qemu-mmio-test`).
- **Typed MMIO**: `Reg<T, .read/.write/.read_write>`, `@offset(N)` register maps,
  `RegBits`/`packed bits`. Writing a read-only register is a compile error.
- **Linear `move` types** (§18.1): `E_USE_AFTER_MOVE` / `E_RESOURCE_LEAK`.
- **DMA ownership** (`std/dma.mc`): `CpuBuffer`/`DeviceBuffer` typestate.
- **virtio transport + virtqueue** (`std/virtio.mc`, `std/virtqueue.mc`): modern
  virtio-mmio handshake, feature negotiation, a split virtqueue, and a **TX smoke
  path that runs against a real `virtio-net-device`** (`virtio-test`, captures a
  TX pcap).
- **Locks/guards, ring, endian, barriers, time** (`std/sync`, `std/ring`,
  `std/endian`, `std/barrier`, `std/time`).
- **Inline asm** (precise, §23.2) — needed for CSR/trap.
- **Generics** incl. **phantom-typed typestate** (verified: `struct Hart<State>`
  → `Hart__Boot`/`Hart__TrapReady`, fields preserved) and multi-param generics.

### What MC can do today that this plan depends on (verified)
| Need | Status |
|------|--------|
| Phantom typestate `Type<State>` (Hart/VirtioDevice/VirtQueue) | ✅ monomorphizes correctly |
| Multi-param generics `Pair<A,B>` | ✅ |
| `Result<T,E>` + `?`, `never` (`-> !`), `*mut` | ✅ |
| Linear `move` resources | ✅ |
| Typed MMIO + `@offset` + inline asm | ✅ |

### Language gaps this plan must work around or close
| Gap | Decision |
|-----|----------|
| **No function pointers** | **Poll-first** event loop; keep `IrqLine<State>` as a typed lifecycle. Real handler dispatch is a later language add. |
| **No methods / fluent chaining** | Free functions only (verbose, fine). |
| **Linear typestate transition leaks the old handle** (leaf-consumer) | **Add a `drop`/`forget` intrinsic** (consume a `move` value, lower to nothing). This is the #1 enabler. Until then: phantom **plain-struct** typestate for device *state* + `move` only for *resources*. |
| **No typed view into a DMA buffer** (today it's `raw.store(phys(addr))`) | **Add `cpu_slice(&CpuBuffer) -> DmaSlice` + `write_be16`/`read_be16`** so packet build/parse stays typed. |
| **No declarative `kernel { … }` config DSL** | Skip. Express resource prerequisites as function parameter types (`init_net(dma: DmaAllocator<Ready>, irq: IrqLine<Registered>)`). |

---

## 2. The four type-closures to get right (the whole point)

Everything below serves these four loops. If these hold, the OS is "typed."

```text
1. Interrupt readiness   TrapVector<Installed> → IrqController<Ready>
                                              → IrqLine<Registered> → IrqLine<Enabled>
   (no enabling interrupts before the vector is installed)

2. DMA ownership         CpuOwned → DeviceOwned → CpuOwned
   (CPU and device never both own a buffer)

3. Descriptor lifecycle  Desc<Free> → Published → Used → Free
   (a descriptor is never overwritten while in flight, never double-freed)

4. Packet lifecycle      RxBuffer<DeviceOwned> → ReceivedPacket<CpuOwned> → NetStack
                       → TxBuffer<DeviceOwned> → TxComplete<CpuOwned>
```

Closure 3 (descriptor free-list) is the linchpin and does **not** exist yet — it
is Phase 0.5.

---

## 3. Repository layout (target)

Grow `kernel/` alongside the existing `std/` and `demo/`. Reuse `std/*` libraries.

```text
kernel/
  arch/riscv64/      entry.S  linker.ld  csr.mc  trap.mc  hart.mc
  platform/qemu_virt/ platform.mc  memory.mc
  hal/               irq.mc  timer.mc            (DMA/MMIO come from std/)
  drivers/
    uart/ns16550.mc
    irq/plic.mc
    timer/clint.mc
    virtio/          (re-exports std/virtio + std/virtqueue + a net driver)
  net/               ethernet.mc  arp.mc  ipv4.mc  icmp.mc  netif.mc
  core/              log.mc  panic.mc  page_alloc.mc
  main.mc
```

`std/` keeps the reusable, device-agnostic pieces (dma, virtqueue, sync, endian,
barrier, time); `kernel/` is the machine- and protocol-specific code.

---

## 4. Phased roadmap (with acceptance criteria)

Each phase ends green under a new `zig build` gate (compile-check at minimum, QEMU
run where observable). Phases are ordered so each unblocks the next.

### Phase 0.5 — language unlocks + the descriptor free-list — ✅ DONE (2026-06-07)
The prerequisites that gate everything net — all landed, gated in `m0`, with the
virtio-net TX path re-built on the free-list and still green under QEMU:
- **`drop(x)` intrinsic** — consumes a linear `move` value (use-after-drop →
  `E_USE_AFTER_MOVE`); makes pure-MC typestate transitions ergonomic. Fixture
  `tests/spec/drop_intrinsic.mc`.
- **`raw.load<T>(addr)`** (dual of `raw.store`, unsafe-gated) + **typed DMA
  byte-view** in `std/dma` (`read_u8`/`write_u8`/`*_be16`/`*_be32`, only on a
  `*CpuBuffer`, bounds-checked). Fixtures `tests/c_emit_raw_load.mc`,
  `demo/virtio-blk` (uses the byte-view).
- **Virtqueue descriptor free-list + multi-in-flight + RX** in `std/virtqueue`:
  `vq_alloc_desc`/`vq_free_desc` (free list via `desc.next`), an in-flight address
  record, `vq_submit_tx`/`vq_submit_rx` (consume the `DeviceBuffer` via `drop`,
  record its address), `vq_has_used`/`vq_used_len`/`vq_complete` (reconstruct the
  buffer with the device-written length). No more always-slot-0.

Original plan for reference:

- **`drop` intrinsic** — consume a `move` value (`drop(x)`), lowers to nothing;
  makes pure-MC linear typestate transitions ergonomic. Reject tests: dropping a
  non-move value is a no-op error; using after `drop` is `E_USE_AFTER_MOVE`.
- **Typed DMA byte-view** — `cpu_slice(&CpuBuffer) -> DmaSlice`, `write_u8/le/be`,
  `read_*`; only available on a `CpuBuffer` (not `DeviceBuffer`). Removes the
  `raw.store` bypass from packet building.
- **Virtqueue descriptor free-list + RX/TX tokens** — replace always-slot-0
  `vq_submit_tx`: a free list, `DescChain<Free→Published→Used→Free>`,
  `TxToken`/`RxToken`, `used.id → buffer` reclaim, multi-in-flight, queue-full →
  `Result`. Add an **RX** path (`submit_rx`, `complete_rx(len)`, refill).

**Accept:** N outstanding descriptors don't overwrite each other; completion
returns the right `id`/`len`; queue-full returns `Result`, not corruption;
compile-fail tests for descriptor reuse / cpu-read-of-device-owned.

### Phase 0 — boot + UART — ✅ DONE (2026-06-07)
`kernel/drivers/virtio/net_runtime.c` provides the riscv entry (`_start` → stack →
`test_main`), 16550 UART output, virtio discovery, and the bump DMA allocator;
`kernel/main.mc` is the typed `kernel_main`. **QEMU prints `MC typed kernel
booting` then `NET-PING-OK`** (gated by `net-test`).

### Phase 1 — typed CPU (Hart typestate + trap) — ✅ DONE + RUNNABLE (2026-06-07)
`kernel/arch/riscv64/csr.mc` (M-mode mtvec / mstatus.MIE / mie.MTIE via MC inline
asm) + `hart.mc`: a linear phantom-typestate `Hart<Boot> → Hart<TrapReady> →
Hart<IrqsOn>`. `enable_interrupts` consumes a `Hart<TrapReady>` that only
`install_trap_vector` produces, so **you cannot enable interrupts before the trap
vector is installed (compile error)** — verified by `kernel/bad/`. `trap.mc`
holds the MC `handle_trap`; `trap_runtime.c` the naked asm vector stub.
**`zig build trap-test` runs it under QEMU**: the typed kernel installs the
vector, enables interrupts, and the timer interrupt fires (`TICKS 3 / TIMER-OK`).

### Phase 2 — timer + PLIC + IRQ typestate — ✅ DONE (compile-gated, 2026-06-07)
`kernel/drivers/irq/plic.mc`: PLIC register access + a linear `IrqLine<Unclaimed
→ Enabled → Pending → Enabled>` typestate — **`complete` (ack) only accepts a
`Pending` line (compile error otherwise)**, verified by `kernel/bad/`.
`kernel/drivers/timer/clint.mc`: `timer_now` / `timer_set_alarm` (CLINT mtime/
mtimecmp). The timer IRQ is now wired through the live trap handler — **the timer
actually ticks under QEMU** (`trap-test`, `TICKS 3`).

### Phase 3 — page allocator — ✅ DONE (2026-06-07)
`kernel/core/page_alloc.mc`: `MemoryMap<Unvalidated> → Validated` (you can only
build an allocator from a validated region) + a linear `move Page` (freed exactly
once, no use-after-free, no double-free). Bump allocator (no reclaim yet; the
linear type carries the safety regardless). Verified by `kernel/bad/`
(`page_use_after_free`, `page_alloc_unvalidated`), gated by `kernel-test`. The DMA
allocator lives in the platform runtime (`net_runtime.c` bump allocator).

### Phase 4 — virtio-net RX/TX (on Phase 0.5) — ✅ DONE (2026-06-07)
`kernel/drivers/virtio/virtio_net.mc`: RX + TX virtqueues on the free-list,
`virtio_net_hdr`, RX buffer posting + refill, TX completion reclaim; multi-buffer
DMA via a bump allocator in `net_runtime.c`. **Gated by `zig build net-test`.**

### Phase 5 — ARP + IPv4 + ICMP — ✅ DONE (2026-06-07)
`kernel/net/{ethernet,arp,ipv4,icmp}.mc` build/parse frames over the typed
byte-view with the RFC 1071 ones-complement checksum (static MAC
`02:00:00:00:00:01`, IP `10.0.2.15`). **`net-test` proves the full stack over real
virtio-net DMA**: the guest resolves the gateway via ARP, sends an ICMP echo
request, and receives the echo reply (`NET-PING-OK`) — the guest pings the
gateway. The responder builders (`arp_write_reply`, `icmp_write_echo_reply`) exist
for the inbound path. Still to do for **host→guest ping**: a poll-and-respond loop
+ a tap netdev (user networking can't ping the guest, but gives the CI exchanges).

---

## 5. Type designs (sketch — MC-honest)

`move` = a resource (must be consumed once). Plain phantom `Type<State>` = a
state token (transition consumes the old via `drop` or an extern primitive).

```mc
// CPU / hart (phantom typestate)
struct Boot {}  struct TrapReady {}  struct IrqEnabled {}
struct Hart<State> { hartid: u32 }
fn install_trap_vector(h: Hart<Boot>) -> Hart<TrapReady>;
fn enable_interrupts(h: Hart<TrapReady>) -> Hart<IrqEnabled>;   // can't skip a step

// IRQ line lifecycle (phantom typestate; poll-first, no handler fn-ptr)
struct Unclaimed {} struct Registered {} struct Enabled {} struct Pending {}
struct IrqLine<State> { line: u32 }
fn ack(l: IrqLine<Pending>) -> IrqLine<Enabled>;               // only when pending

// DMA buffer (linear resource — already built as CpuBuffer/DeviceBuffer)
//   CpuBuffer → clean_for_device → DeviceBuffer → submit → reclaim → CpuBuffer

// virtqueue descriptor (linear resource — Phase 0.5)
move struct DescChain { head: u16, count: u16 }
fn vq_submit_tx(q: *mut VirtQueue, c: DescChain, b: DeviceBuffer) -> TxToken;
fn vq_complete(q: *mut VirtQueue, t: TxToken, u: Completion) -> DeviceBuffer;
```

The net stack is plain typed structs over a `DmaSlice` byte-view + `std/endian`.

---

## 6. The minimal QEMU target

```sh
qemu-system-riscv64 -machine virt -nographic -bios none \
  -global virtio-mmio.force-legacy=false \
  -kernel build/mc-kernel.elf \
  -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
  -object filter-dump,id=f0,netdev=net0,file=tx.pcap
```

**Network acceptance ladder** (each its own gate; user-net for 1–3, tap for ping):
1. virtio-net init reaches `DRIVER_OK`
2. RX queue receives a frame
3. TX frame appears in `tx.pcap`
4. ARP reply is correct
5. ICMP echo reply is correct
6. `ping <guest-ip>` succeeds

---

## 7. Target boot log (the demo)

```text
MC typed kernel booting
arch: riscv64   platform: qemu-virt
uart: ok        memory: 128 MiB
trap: installed plic: ok   timer: 100 Hz
dma: coherent
virtio-mmio: found net device   virtio-net: features ok
virtio-net: rxq ready   txq ready
net: mac 02:00:00:00:00:01   ip 10.0.2.15
kernel: entering event loop
arp: request -> reply sent
icmp: echo request -> echo reply sent
```

---

## 8. Risks & sequencing notes

- **Biggest single chunk:** Phase 0.5 virtqueue free-list + RX. Everything net
  depends on it; build and gate it *before* the kernel scaffolding.
- **`drop` intrinsic** is small but pivotal — without it, every linear typestate
  transition needs an `extern` primitive. Add it early.
- **Poll-first** keeps function pointers off the critical path; revisit
  interrupt-driven (needs fn-ptrs or compile-time dispatch) only after ping works.
- **Commit the current tree first.** The whole `demo/` suite, `std/*`, the virtio
  driver, and the backend fixes are currently uncommitted; start the `kernel/`
  subtree from a recorded baseline.
- **Estimate:** Phase 0.5 ≈ a few days; 0–2 ≈ a few days; 3–4 ≈ ~1 week; 5 ≈ a
  few days. Order so there is a runnable, observable QEMU milestone at the end of
  each phase.

## 9. First concrete step

Turn the existing virtio-net **TX-smoke into a real RX/TX driver on a descriptor
free-list**, then have the guest receive a broadcast and send an **ARP reply**
observable in the pcap. Shortest path to "the guest answers on the wire," and it
validates closures 2–4 at once. Everything else (trap/timer/PLIC, IPv4/ICMP) is
additive after that.
