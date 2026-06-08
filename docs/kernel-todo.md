# Kernel roadmap — from typed driver demo to OS nucleus

**Status.** There is an **integrated kernel image** — `tests/qemu/kmain_demo.mc`
(`kmain`) boots once and brings up the heap, the char-device driver framework
(console), the leveled logger, the VFS over ramfs (a file round-trip), and the
process scheduler (two processes run + exit) together in one binary (gate
`kmain-test`: `123AB4` / `KERNEL-OK`). And `tests/qemu/kmain_net_demo.mc`
(`kmain_net`) goes further: the **same single image** runs those five subsystems
*and* brings up the virtio-net device + transmits a real UDP datagram (gate
`kmain-net-test`: `123AB4` / `KERNEL-NET-OK`, payload captured in the TX pcap) — one
kernel that boots, drives hardware, runs a filesystem, schedules processes, and
serves the network together. The value is proving MC's low-level contracts
(typestate, linear `move`, typed MMIO, DMA ownership) on real emulated hardware,
composed into a running system.

Gates today (all green in `zig build m0`): `net-test` (pings the gateway under
QEMU), `trap-test` (timer IRQ fires), `kernel-test` (riscv compile-check + 5
typestate reject fixtures), plus the language/std gates.

---

## Already done (this is *not* the GitHub snapshot)

Recent architecture work — many "short-term harden" items are already in:

- [x] **Typed errors on the driver path** — `nic_init`/`nic_ping_gateway` →
  `Result<bool, NetError>`; `kernel_main` handles them with exhaustive `switch`.
- [x] **Trap fails closed** — `handle_trap` halts on any non-timer cause (no blind
  `mret` into a fault loop); full integer-register `TrapFrame` saved by the stub.
- [x] **Timer actually fires** — CLINT `mtimecmp` armed through the `Hart` typestate;
  `trap-test` counts ticks under QEMU.
- [x] **Page allocator validation** — `MemoryMap<Unvalidated→Validated>` (aligned
  base+size, `base+size` overflow checked); linear `Page` (no use-after-free /
  double-free).
- [x] **RX length validation + reply matching** — `rx_receive` checks the received
  length before each parse; `nic_ping_gateway` verifies sender IP + ICMP ident/seq
  + IPv4 header checksum + protocol.
- [x] **Platform `Machine` object** — `kernel/platform/qemu_virt/machine.mc`
  centralizes IP/gateway/MAC.
- [x] **Typed addresses + packet cursor** — `Ipv4Addr` (threaded through the API),
  `PacketCursor`/`has(n)` in `kernel/net/packet.mc`; `be16/be32` (DMA byte-view)
  and `MacAddr` centralized.
- [x] **`NetDevice` device-class surface** — `{regs, rxq, txq}` bundle; net stack
  (ARP/IPv4/ICMP) only sees cpu-owned buffers, never the virtqueue.
- [x] **Real-time deadlines + target-aware fences** — `std/time` `timed_out`
  replaces `while spins < N`; `fence.*` builtins emit riscv `fence rw,w`.
- [x] **IRQ-line typestate** — `IrqLine<Unclaimed→Enabled→Pending>` (`plic.mc`);
  `complete` only on a `Pending` line; `claim_if_pending` checks the claimed id.
- [x] **Typed checked addresses (`std/addr`)** — `PAddr` ops (offset/align/diff/
  ordering/`PhysRange`) over MC's opaque address class; one audited usize boundary,
  overflow checked. `kernel/core/page_alloc.mc` refactored off raw `usize` onto
  `PAddr` (no more hand-rolled `USIZE_MAX` overflow check). Tests: `std-test`
  runtime assertions + `tests/c_emit_addr.mc`. **Follow-ups:** same shape for
  `VAddr` (page tables), `DmaAddr` (needs a `dma()` constructor for `vq_complete`),
  `UserAddr` (user mode).
- [x] **DMA addresses fully typed** — `std/dma`'s `cpu_addr` is `PAddr` (byte view
  uses checked `pa_offset`, not raw `phys(cpu_addr + off)`) and `dev_addr` is
  `DmaAddr` (the device bus address, distinct from a CPU `PAddr`); `device_addr`
  returns `DmaAddr`. `std/virtqueue` converts `DmaAddr ↔ u64` only at the
  descriptor word. No raw `usize` for any DMA address.
- [x] **Physical frame allocator with reclaim** — `page_alloc` now pulls from an
  intrusive LIFO free list (O(1) alloc/free, real reclaim) then bumps; `page_free`
  returns the frame. Runnable gate `page-test` (bump + reclaim + LIFO reuse over a
  real pool). *Supersedes the bump-only allocator.*
- [x] **Panic diagnostics (fail closed)** — `kernel/core/console.mc` (UART via
  `raw.store`, isolated unsafe) + `kernel/core/panic.mc` (`panic_trap` prints
  `mcause`/`mepc`/`mtval` then halts via the `mc_halt` platform primitive).
  `handle_trap` now panics on any unhandled cause instead of a silent halt;
  the asm stub passes `mtval`. `trap-test` verifies an M-mode ecall hits
  `PANIC c=0x…b`. **Compiler fix it required:** `numericExprTypeForEmission` now
  recovers a shift's result type (`u64 >> u32`), so `(v >> shift) & mask` lowers
  in a cast position (regression `tests/c_emit_shift_cast.mc`).

---

## Short-term — finish hardening the demo kernel's boundaries

- [x] **Typed device-init errors** — `virtio_init` → `Result<bool, VirtioError>`
  (`NotVirtio`/`UnsupportedVersion`/`WrongDeviceId`/`ResetTimeout`/
  `FeaturesUnsupported`/`FeaturesNotAccepted`); `vq_setup` →
  `Result<bool, VqError>`. Callers (kernel + demo `nic_init`) handle them with
  exhaustive `switch`. No more `bool` on the device-init path.
- [x] **Kernel heap** — `kernel/core/heap.mc`: aligned bump byte-allocator over a
  `PhysRange` (all math via std/addr, checked). Gate `heap-test`. (Next: free-list/
  slab; then move the C-runtime DMA/vring pools onto it.)
- [ ] **Recycling DMA allocator** — `mc_dma_free` reuses buffers so `nic_serve`'s
  event loop can't exhaust the one-shot pool.
- [ ] **Panic path** — decode + print `mcause`/`mepc`/`mtval` + a register dump on
  an unexpected trap (today it just halts via `unreachable`).
- [ ] **Trap-cause decode** — a `TrapCause` enum (timer / external / software /
  illegal-instruction / load+store fault / ecall) instead of "timer or halt".
- [ ] **virtio-net interrupt path** — drive RX/TX off the PLIC external interrupt
  instead of polling (needs the PLIC wired live + an IRQ handler dispatch).
- [ ] **UART/console driver in MC** — replace the C runtime's `puts_` with a typed
  `kernel/drivers/uart` + a `core::log` facade for boot/panic output.
- [ ] **More `kernel/bad/` reject fixtures** — lock the new typestates/contracts.

---

## Mid-term — a minimal OS nucleus

### Memory management (highest priority)
- [x] Typed `PAddr`/`VAddr`/`DmaAddr` with checked arithmetic (`std/addr`) — no
  more raw `usize` address math.
- [x] Physical frame allocator with intrusive free-list reclaim (`page-test`).
- [x] Kernel heap: aligned bump over a `PhysRange` (`heap-test`).
- [x] Page tables: Sv39 `map` + `translate` (`kernel/arch/riscv64/paging.mc`,
  `paging-test`). **Follow-ups:** `unmap`/`protect`; load `satp` + `sfence` to
  activate under QEMU; a page-fault handler (the panic path already decodes the
  cause — route load/store/instruction faults to a handler).
- [ ] Allocator upgrades: buddy/zone frame allocator; slab/`kmalloc` heap;
  DMA-safe allocator (contiguous, coherent) to replace the C-runtime pools.

### Trap / interrupt subsystem
- [ ] PLIC/CLINT routing wired live; per-hart timer.
- [ ] IRQ-safe locking (the `IrqOff` witness already exists in `std/sync`).
- [ ] Interrupt nesting policy; interrupt-driven drivers.

### Threads + scheduler
- [x] Interrupt-shared state as an explicit `atomic<T>` cell — `g_ticks` is now
  `atomic<u32>` (ISR `fetch_add(.acq_rel)`, readers `load(.acquire)`); required a
  compiler fix to allow global atomics (`tests/c_emit_global_atomic.mc`).
- [x] **Function pointers (compiler)** — `fn(P) -> R` value types: a function name
  is a fn-pointer value; callbacks, struct **vtable** fields, and fn-pointer
  returns all work; calls are sound (arity + signature checked,
  `E_FN_POINTER_SIGNATURE_MISMATCH`); lower to a C typedef + indirect call. Gates
  `fnptr-test` + `tests/spec/fn_pointer.mc`. *Unblocks thread entries, the
  scheduler runnable set, IRQ-handler tables, and device-class vtables.*
- [x] **Context-switch primitive** — `kernel/arch/riscv64/context.mc`: typed
  `Context` (ra/sp/s0-s11) + `mc_switch_context` (naked-asm save/restore) +
  `mc_thread_init` (primes a context with a `fn() -> void` entry). Demo: `main` and
  a worker ping-pong cooperatively (`tests/qemu/thread_demo.mc`); gate
  `thread-test` checks the `MWMWMW` interleave under QEMU. (Compiler fix it needed:
  extern fns are now forward-declared, so an imported `extern fn` used before its
  merged-in declaration resolves.)
- [x] **Round-robin scheduler** — `kernel/core/sched.mc`
  (`sched_init`/`sched_spawn`/`sched_yield` over a fixed `[N]Context` table).
  `tests/qemu/sched_demo.mc` runs 3 threads with **per-thread stacks from the
  kernel heap** and `fn() -> void` entries; gate `sched-test` checks the
  `ABCABCABC` rotation under QEMU. (Two compiler fixes it surfaced: order-stable
  `struct_` name-mangling for `[N]Struct` fields, and `&s.field[i]` on a
  struct-field array now indexes `.elems` with a bounds check.)
- [x] **Timer-tick preemption** — the timer IRQ drives `sched_yield`, so threads
  preempt without cooperative yield. `tests/qemu/preempt_demo.mc`: 3 non-yielding
  workers all run (`ABC`) and the bootstrap regains control (`PREEMPT-OK`); gate
  `preempt-test`. Key pieces: a trampoline enables interrupts on a freshly-switched
  thread, and the trap vector saves/restores **mepc + mstatus per frame** (they are
  global CSRs, so switching threads mid-trap otherwise resumes a thread on the
  wrong PC). Compiler fix it surfaced: a const-global operand in a sequenced
  loop condition (`while tick_count() < LIMIT`) now type-resolves.
- [ ] Sleep/priority queues; per-thread state typestate.
- [ ] Blocking primitives: mutex, semaphore, wait queue.
- [ ] Express thread state as typestate: `Thread<Ready/Running/Blocked>`; guard the
  scheduler critical section with an `IrqOff` witness.

### Syscalls
- [x] **Syscall dispatch skeleton** — `kernel/core/syscall.mc`: a `SyscallTable`
  backed by a `[N]fn(u64,u64)->u64` function-pointer table; `syscall_register` /
  `syscall_dispatch` (bounds + registration checked, unknown number → `ENOSYS`,
  fail closed). `tests/qemu/syscall_demo.mc` + `syscall_runtime.c` route `ecall`
  (number in a7, args a0/a1, result→a0, mepc+=4) to the table; gate `syscall-test`
  verifies `sys_add`→7, `sys_putc`→'X', unknown→ENOSYS. Uses the function-pointer
  feature in real kernel dispatch. (Compiler fix: `typeSuffix` mangles
  function-pointer element types so arrays of distinct signatures don't collide.)
  **Next:** issue ecalls from U-mode (user mode); grow the ABI.

### Storage + a first FS
- [x] **In-memory filesystem (ramfs)** — `kernel/fs/ramfs.mc`: named files over
  flat name/data pools + a metadata table (offsets/lengths, no nested arrays);
  `ramfs_create`/`write`/`read`/`find`/`size`, typed `FsError`, bounds-checked,
  byte input through the std/bytes reader. Gate `ramfs-test`: create / write /
  read-back / lookup / file independence / not-found all verified.
- [x] **virtio-blk kernel driver** — `kernel/drivers/virtio/virtio_blk.mc`:
  `blk_init` (handshake + queue) and `blk_read_sector` issue a real virtio-blk
  request as a **three-descriptor chain** (header / data / status) via the new
  `vq_submit_chain3` + `vq_complete_chain` (std/virtqueue), with little-endian
  request fields (`write_le32/le64` added to std/dma) and a deadline-bounded wait,
  typed `BlkError`. Gate `blk-test`: reads sector 0 of a disk image under QEMU and
  gets back the bytes (`DISK`). Same transport/queue/DMA layering as net.
- [x] **Block-backed file store** — `kernel/fs/blockdev.mc`: a `BlockDevice` (512 B
  blocks behind read/write function pointers + ctx, so a RAM disk *or* the virtio-blk
  driver can back it) with bounds-checked `bd_read_block`/`bd_write_block`, and a
  `BlockFs` placing each file in a contiguous block run with all I/O through the
  device — file bytes live on the device, not a RAM pool. Gate `blockfs-test`:
  multi-block write/read through the vtable, data confirmed on the backing store,
  files on distinct blocks.
- [ ] Block cache; point the `BlockDevice` read/write at the real virtio-blk driver;
  back the VFS by the block store.
- [x] **Minimal VFS (fd table over ramfs)** — `kernel/fs/vfs.mc`:
  `vfs_open`/`read`/`write`/`close` over an fd table; each fd carries a read/write
  position (open creates-or-finds, writes append + advance, reads advance, EOF
  returns 0); typed `VfsError`, bad-fd / use-after-close rejected. Gate `vfs-test`.
  (ramfs gained `ramfs_read_at` for positional reads.)
- [x] **File syscalls over the VFS** — extended the syscall ABI to 3 args
  (a0/a1/a2; `fn(u64,u64,u64)->u64` handlers); `sys_open`/`sys_fwrite`/`sys_fread`/
  `sys_fclose` (`tests/qemu/fs_syscall_demo.mc`) validate + copy user pointers via
  copy_{from,to}_user and dispatch to the VFS. Gate `fs-syscall-test`: a U-mode
  program writes a file and reads it back entirely through syscalls (`FHI`). The
  full user→syscall→VFS→ramfs→user round trip.
- [ ] Path lookup / `stat`; more of the ABI (mmap, dup, etc.).

---

## Long-term — userspace, FS, network stack, tooling

- [x] **User mode (privilege drop)** — `user_runtime.c`: M-mode grants U-mode
  memory (PMP), installs the trap vector, and `mret`s into a user task with MPP=U.
  The task reaches the kernel only via `ecall` (traps as mcause 8), routed through
  the MC syscall table; trap entry swaps to a dedicated kernel stack via `mscratch`
  so a user trap never runs on user memory. Gate `user-test`: the user task prints
  `USR` (syscalls only) and exits from U-mode (`USER-EXIT from U`).
- [x] **`copy_{from,to}_user` with address checks** — `kernel/core/uaccess.mc`:
  a `UserSpace` region + bounds/overflow-checked copies over the opaque `UserPtr`
  class; an out-of-range request returns a typed `OutOfRange` and copies nothing
  (fail closed). Demonstrated in `user-test`'s `sys_write`: the U-mode task's valid
  buffer is copied in and printed (`FROMUSER`), an out-of-range pointer is rejected
  (`R`). Compiler fix: `&g_global_array[i]` now indexes `.elems` with a bounds check.
- [x] **Process lifecycle (spawn/run/exit/wait)** — `kernel/core/process.mc`: a
  `ProcTable` of `Process{context, state: ProcState, pid, parent, exit_code}`;
  `proc_spawn` (records the parent), round-robin `proc_yield`, `proc_exit(code)`
  (records the code + becomes a `Zombie`, switches to the next runnable), and
  `proc_reap(parent_pid)` — a non-blocking `wait` that returns an exited child's
  (pid, code) and frees its slot (typed `ReapError`: no children / none exited yet).
  `process-test`: 3 processes print + exit with codes (`ABC`), the bootstrap reaps
  all three (`123`, `PROC-OK 3`). Three compiler fixes it surfaced (array-of-struct +
  enum patterns): `structTypeName` derefs pointers; `operandEmitType` resolves
  `table[i].field` types; enum-literal comparisons/assignments to array-element
  fields now lower.
- [x] **ELF64 loader** — `std/bytes.mc` (bounds-checked byte reader, LE/BE reads —
  the "packet reader / endian helpers" abstraction) + `kernel/core/elf.mc`:
  validated ELF64 header + program-header parse (typed `ElfError`, fail closed) and
  `elf_load_segment` (copy a PT_LOAD segment's filesz bytes, then zero-fill the bss
  tail to memsz). Gate `elf-test`: parses an ELF64, loads a segment and checks the
  copied bytes + bss zero-fill, rejects bad magic / truncation.
- [x] **ELF load-and-run** — `elf_load_run` parses + loads a PT_LOAD segment and
  returns the entry; `usermode_runtime.c` (factored shared trap vector / `enter_user`
  / `do_ecall` / `usermode_setup`) drops to U-mode there. Gate `elf-run-test`: the
  kernel builds a tiny ELF64 of hand-assembled RV64 code, loads it, runs it in
  U-mode — the loaded program prints `OK` via syscalls and exits (`USER-EXIT from U`).
- [x] **satp activation (Sv39 paging live)** — `tests/qemu/paging_activate_demo.mc`
  builds a page table (two identity gigapages for devices + the kernel, via the new
  `page_table_map_gigapage`, plus a 4 KiB translation-only mapping at 3 GiB);
  `paging_runtime.c` delegates traps + opens PMP, drops M→S, then loads `satp` +
  `sfence.vma`. Gate `paging-activate-test`: in S-mode it reads VA 3 GiB (reachable
  only through the page table) and gets the mapped frame's value — real
  virtual→physical translation, paging on. Foundation for per-process address spaces.
- [x] **Per-process address spaces (satp switch)** — `tests/qemu/paging_switch_demo.mc`
  builds two independent Sv39 tables mapping the same VA (3 GiB) to different frames;
  `paging_switch_runtime.c` activates one `satp`, reads the VA, switches `satp` to the
  other + `sfence.vma`, and reads again. Gate `vm-switch-test`: the same virtual
  address yields `0x11111111` then `0x22222222` — independent address spaces, the
  basis of per-process memory.
- [x] **`exec`** — `tests/qemu/exec_demo.mc`: `sys_exec(elf_ptr, len)` parses + loads
  the ELF's PT_LOAD segment into the kernel load area (`icache_flush` after) and
  `enter_user`s at its entry — replacing the caller, never returning. Gate
  `exec-test`: program A prints `A`, execs program B which prints `B` and exits
  (`AB`); A's post-exec failure marker never runs, proving exec replaced the image.
- [x] **Blocking `wait`** — `proc_wait(parent_pid)` in `kernel/core/process.mc`:
  loops reap → if a child exited return it, else `proc_yield` (run the children) and
  retry; `NoChildren` returns immediately. `process-test` now uses it: the bootstrap
  blocking-waits for all three children (running them, then reaping `123`) with no
  explicit yield.
- [x] **Per-process page tables** — `Process` gained a `satp` field +
  `proc_set_satp`/`proc_satp` (`kernel/core/process.mc`). `tests/qemu/vmspace_demo.mc`
  builds a distinct Sv39 table per process (each mapping VA 3 GiB to its own frame),
  storing each as that process's satp; `vmspace_runtime.c` switches between processes
  by loading `proc_satp(idx)`. Gate `vmspace-test`: processes 0/1/2 read
  `0xAAAA0000`/`0xBBBB0001`/`0xCCCC0002` at the *same* VA — independent address spaces
  per process. (The satp load is the operation a context switch performs.)
- [x] **Address-space-switching context switch** — `vmctx_runtime.c`
  `mc_switch_context_vm(old, new, new_satp)`: saves the old thread's callee-saved
  registers, loads the new thread's `satp` (+ `sfence.vma`), then its registers — so
  changing threads changes the active page table (what a scheduler does with
  `proc_satp`). Gate `vmctx-test` (S-mode): two threads read the *same* VA and see
  `0xA` vs `0xB` because the switch loaded each one's address space.
- [x] **Scheduler with per-process address spaces** — `proc_yield_vm` (process.mc)
  switches process *and* address space: it loads the next process's `satp` as part of
  the context switch (`mc_switch_context_vm`, declared in context.mc). Gate
  `sched-vm-test`: in S-mode, two scheduled processes each read the same VA and see
  their own frame (`0xA` / `0xB`) — the scheduler driving per-process virtual memory.
- [ ] **Userspace, cont.**: map the user image through page tables instead of PMP;
  multi-segment ELF; full ABI; demand paging.
- [x] **UDP layer** — `kernel/net/udp.mc`: build + parse UDP datagrams (RFC 768)
  over bounds-checked byte readers/writers (`std/bytes` gained a `ByteWriter` —
  completing the packet reader/writer abstraction), with the IPv4 pseudo-header
  internet checksum. Gate `udp-test`: build/parse fields + checksum validation +
  corruption detection.
- [x] **TCP segment layer** — `kernel/net/tcp.mc`: build + parse TCP segments
  (ports/seq/ack/flags/window) with the IPv4 pseudo-header checksum, flag constants
  (SYN/ACK/FIN/RST/PSH) + `tcp_has_flag`. The internet checksum is now shared with
  UDP in `kernel/net/inet_checksum.mc` (no duplication). Gate `tcp-test`.
- [x] **TCP connection state machine** — `kernel/net/tcp_conn.mc`: the RFC 793
  states (CLOSED/LISTEN/SYN_SENT/SYN_RECEIVED/ESTABLISHED/FIN_WAIT1·2/CLOSE_WAIT/
  LAST_ACK/TIME_WAIT) + seq tracking; `tcp_listen`/`connect`/`on_segment`/`close`
  return the next state + the control segment to emit; unhandled segments ignored
  (fail safe). Gate `tcp-conn-test`: passive + active open 3-way handshakes and both
  4-way close paths transition correctly.
- [x] **Send UDP over virtio-net** — `demo/virtio-net/udp_send.mc`: builds a full
  Ethernet + IPv4 + UDP + payload frame into a TX buffer (L2/L3 via the net
  byte-view helpers; the UDP header + pseudo-header checksum via `udp_write` through
  a `ByteWriter` over the *same* buffer memory — one UDP implementation, real
  checksum) and pushes it through the DMA ownership cycle. Gate `udp-net-test`: the
  datagram is transmitted over the real virtio-net device and its payload is captured
  in the TX pcap under QEMU.
- [x] **UDP socket layer** — `kernel/net/udp_socket.mc`: `socket_bind` (with
  port-conflict rejection), `socket_deliver` (demultiplexes an incoming datagram to
  the socket bound to its destination port, typed `NoListener` when none), and
  `socket_recv` (dequeues the next datagram for a socket, copies the payload out, and
  records the sender). Flat metadata queue + byte pool (no nested arrays). Gate
  `socket-test`: bind/conflict, deliver/demux/no-listener, per-socket recv with
  payload + sender.
- [x] **recvfrom syscall over the socket layer** — `tests/qemu/socket_syscall_demo.mc`:
  `sys_recvfrom(sock, buf, len)` calls `socket_recv` and copies the demultiplexed
  payload out via the validated `copy_to_user`. Gate `socket-syscall-test`: the kernel
  binds a socket + delivers a datagram (loopback RX), a U-mode program `recvfrom`s it
  (`RHELLO`) and exits — the full socket → syscall → copy_to_user → user path.
- [x] **TCP data plane (send/recv window)** — `kernel/net/tcp_window.mc`: the RFC 793
  sequence variables (`snd_una`/`snd_nxt`/`snd_wnd`/`rcv_nxt`); `tcp_win_send_space`
  (window − in-flight), `tcp_win_on_send`, `tcp_win_on_ack` (advances on new acks,
  *rejects* duplicate + unsent-data acks), `tcp_win_on_recv` (in-order acceptance),
  window updates. All sequence math is 32-bit modular via new `std/math` wrapping
  helpers (`wrapping_add/sub_u32`). Gate `tcp-window-test` incl. sequence wraparound.
- [x] **TCP reassembly + retransmit** — `kernel/net/tcp_reasm.mc`: a `Reassembler`
  that delivers the in-order prefix, buffers out-of-order segments, and coalesces them
  when the gap fills (modular seq math; old/duplicate dropped). `tcp_win_rtx_reset`
  (tcp_window) does go-back-N: rewind `snd_nxt` to `snd_una` so the unacked window is
  resent. Gate `tcp-reasm-test`: out-of-order buffering + multi-segment coalesce +
  go-back-N retransmit.
- [x] **RX demux path → sockets** — `kernel/net/net_rx.mc`: `net_rx_deliver` parses a
  received Ethernet→IPv4→UDP frame (bounds-checked reader) and hands the payload to
  `socket_deliver` — what the NIC RX completion calls per frame. Non-IPv4/non-UDP/
  malformed frames dropped with a typed reason; unbound ports surface `NoListener`.
  Gate `net-rx-test`: a built frame parses → delivers → `recv` returns the payload +
  sender; a frame to an unbound port is dropped. (`sendto` = the proven `udp_transmit`
  build+TX path.)
- [x] **TCP retransmit timer** — `kernel/net/tcp_rtx.mc`: an `RtxTimer` armed when
  unacked data is sent, firing at `now + RTO` to trigger a go-back-N retransmit
  (`tcp_win_rtx_reset`) and re-arm, disarmed once everything is acked. Time is a tick
  count (caller passes `read_ticks()`). Gate `tcp-rtx-test`: arm on send, quiet before
  RTO, fire + re-arm at RTO, disarm on full ack.
- [x] **Real RX queue → demux** — driver `nic_rx_into` copies a received frame off
  the virtio-net RX queue (decoupled from the protocol layers), and `nic_arp_resolve`
  resolves a MAC. `tests/qemu/net_rx_live_demo.mc` brings up the NIC, ARPs the gateway
  (slirp replies, a real frame on the RX queue), and routes that frame through
  `net_rx_deliver`. Gate `net-rx-live-test`: a real 64-byte frame off the actual RX
  queue is classified by the production demux (`RX-FRAME … routed`).
- [ ] **Network stack, cont.**: an inbound UDP source (slirp DNS) → recv to a socket;
  ARP cache, full IPv4 validation; interrupt-driven RX/TX, `netif`.
- [x] **Driver framework (char-device registry)** — `kernel/core/device.mc`: a
  `CharRegistry` of `CharDevice{putc: fn(u64,u8)->void, ctx, present}`; drivers
  `register_chardev` their write op (a function pointer) + context, and
  `chardev_putc` dispatches through the vtable — decoupling the console from the
  concrete device. Gate `driver-test`: a 16550 UART driver is registered and `DRV`
  is written through the registry under QEMU. (Function pointers in real driver use.)
- [ ] **Driver framework, cont.**: FDT/device-tree parser, platform bus, probe
  ordering, IRQ binding, MMIO mapping, shared DMA/queue infra
  for net/blk/console/rng (transport=`std/virtio`, queue=`std/virtqueue`, dma=
  `std/dma` are already shared).
- [ ] **Filesystems**: FAT/ext2 or a small custom FS; mount points; pipes; perms.
- [x] **SMP bring-up** — multiple harts boot at the kernel entry, each takes its
  own stack (indexed by `mhartid`) and runs `hart_main`; they synchronize on a
  shared global `atomic<u32>` (acquire/release, no locks) and the boot hart waits
  until all have checked in. Gate `smp-test` (QEMU `-smp 2`): both harts report in
  (`SMP-OK 2`). (`smp_runtime.c`/`smp_demo.mc`.)
- [x] **Spinlock (ticket lock)** — `std/spinlock.mc`: a fair FIFO lock built on the
  atomic cell (`fetch_add` for the ticket, acquire load to wait, release store to
  hand off); needs no compare-exchange. **Compiler:** taught the C backend to lower
  `atomic<T>` *struct fields* (`lock.next.fetch_add(...)` → `__atomic_*(&lock->next,
  …)`), so the lock is a reusable struct, not a global singleton. Gate
  `smp-lock-test` (QEMU `-smp 2`): two harts do 2000 locked increments each of a
  non-atomic shared counter; the result is exactly 4000 — mutual exclusion, no lost
  updates.
- [x] **IPIs (CLINT software interrupts)** — `tests/qemu/ipi_demo.mc`: `ipi_send`/
  `ipi_clear` reach the CLINT MSIP registers through typed addresses (phys +
  raw.store); delivery is tracked with atomics. `ipi_runtime.c`: hart 1 installs a
  machine-software-interrupt vector + arms MSIE/MIE; hart 0 raises an IPI on hart 1,
  which traps (mcause = machine software interrupt), clears MSIP, and counts it. Gate
  `ipi-test` (QEMU `-smp 2`): `IPI-OK`.
- [ ] **SMP, cont.**: per-hart kernel state, per-hart run queues / affinity, a
  global TLB-shootdown IPI.
- [x] **Tracing**: a trace ring buffer — `kernel/core/trace.mc`: fixed-capacity,
  O(1) wrap-around recording of (seq, id, value) events with monotonic sequence
  numbers for drop detection; a passive sink safe to call from any context.
  Gate `trace-test` (ordered retention, wrap-around, sequencing).
- [x] **Symbolized backtraces** — `kernel/core/symbols.mc`: a sorted symbol table
  with `symbolize(pc)` (binary search → containing function index + byte offset,
  typed `SymError`, rejects below-first/unsorted). `backtrace_runtime.c` walks the
  RISC-V frame-pointer chain ([fp-8]=ra, [fp-16]=caller fp) to capture return
  addresses and symbolizes each. Gates `symbols-test` (host: exact/mid/last/below-
  first/unsorted) + `backtrace-test` (QEMU: 4 frames unwound, inner frames resolved).
- [x] **Log levels + named tracepoints** — `kernel/core/log.mc`: a `Logger` over the
  trace ring with severities (Debug/Info/Warn/Error) and a runtime-settable
  threshold; sub-threshold events are filtered and *counted* (`dropped`, never
  silently lost), the rest recorded with the level packed into the tracepoint id.
  Gate `log-test`: threshold filtering + level/id/value recording + raising verbosity
  admits lower levels.
- [x] **Packet-parser fuzzing** — `tests/qemu/net_fuzz_demo.mc` + gate `net-fuzz-test`:
  drives `net_rx_deliver` with 40000 pseudo-random and random-UDP-shaped frames of
  every length; the bounds-checked reader returns a typed result for all of them with
  zero out-of-bounds reads (an OOB would `__builtin_trap`). The fuzzer also caught a
  real overflow — xorshift's `<<` overflowing under MC's *checked* shift — fixed by
  adding `wrapping_shl_u32` to std/math (the wraparound the PRNG intends).
- [ ] **Debugging, cont.**: route the logger to the serial console; GDB scripts,
  syscall fuzzing, crash dumps; embed a real linker symbol table for the backtrace.

---

## MC language / stdlib work that keeps `kernel/` lean

Blockers hit while doing the above (fixing these removes kernel workarounds):

- [ ] **Function pointers / a dispatch mechanism** — no closures and no polymorphic
  device-class vtables today; blocks a generic `NetDevice`/`BlockDevice` interface
  and `poll_until(fn)`. (Worked around with `Deadline` + concrete structs.)
- [ ] **`mmio.map(...)` emit** — `mmio.map(...)?` fails the MIR verifier
  (`E_TRY_REQUIRES_RESULT_OR_NULLABLE`, currently allowlisted) and `if let` won't
  narrow `?MmioPtr`, so a typed `MmioPtr` can only be built at the C boundary —
  **virtio discovery is stuck in the platform runtime** instead of an MC bus layer.
- [ ] **Move tracking through `switch`/`if let` patterns** — a `move` value bound by
  a pattern isn't tracked, so `page_alloc` can't return `Result<Page, _>` without
  losing use-after-free detection. (Kept `page_alloc` infallible because of this.)
- [ ] **Empty-struct literal `.{}`** — `ok(.{})` for a `Result<Unit, E>` mis-emits
  (treated as an array literal). Worked around with `Result<bool, E>` + `ok(true)`;
  a `Unit`/`void` ok payload should just work.
- [ ] **`Result<GenericStruct<…>, E>` C-name mangling** — `typeSuffix` adds a
  `struct_` prefix order-dependently, so `Result<MemoryMap<Validated>, E>` fails to
  lower. Blocks fallible typestate transitions.
- [ ] **Comparison-as-return with mixed widths** — `return call() == literal` can
  hit `UnsupportedCEmission`; use an `if` guard. Worth fixing in the backend.
- [ ] **Stdlib profile**: `std.mem` (allocator/slice/align/address math),
  `std.result` conventions, `std.log`/`std.fmt`, `std.addr` (typed addresses),
  `std.atomic`/`std.volatile`, `std.driver` (MMIO/IRQ/DMA/poll helpers),
  `std.collections` (list/queue/bitmap/free-list/rb-tree).
- [ ] **MIR optimizer**: range propagation, bounds-check elimination, checked-arith
  optimization, contract-region verification, `#[no_lang_trap]` proofs, alias/
  address-class analysis, C-backend ↔ MIR-verifier consistency.
- [ ] **Backend/toolchain** (long-term): LLVM/cranelift backend, target triples,
  debug info, LSP, formatter, package manager, release builds, cross-compile,
  QEMU/hardware CI matrix.

---

## Recommended next three (the highest-leverage moves)

The next big step is **not** another driver — it's the kernel substrate:

1. **Memory management** — frame allocator (with real `page_free` reclaim), page
   tables, kernel heap, typed `PhysAddr`/`VirtAddr`. Everything else needs it.
2. **Trap/IRQ subsystem** — full cause decode + panic, PLIC wired live,
   interrupt-driven (not polled) drivers, IRQ-safe locking.
3. **Threads + round-robin scheduler** — kernel threads, context switch,
   preemption, blocking primitives — expressed with MC typestate/linear resources.

Those three turn this from a "language-feature demo kernel" into a kernel that can
actually grow.
