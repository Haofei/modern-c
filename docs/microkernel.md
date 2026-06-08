# MINIX-style microkernel architecture

The kernel has a microkernel **core** and the four defining MINIX mechanisms, each
gated under QEMU. Services run as ordinary processes that communicate only through
kernel-mediated messages; least privilege is enforced by the type system; crashed
servers are restartable.

## The privileged core (`kernel/core/`)
- **Scheduler + processes** (`process.mc`): the round-robin/preemptible scheduler,
  process lifecycle (spawn/exit/wait/reap), and per-process address spaces.
- **IPC** (`ipc.mc` + `process.mc`): a fixed-size `Message { from, tag, a0..a2 }` and
  `ipc_send`/`ipc_receive`. Rendezvous via a `BlockedRecv` state — `receive` blocks
  (yields) until a message arrives; `send` delivers into a one-slot mailbox and wakes a
  blocked receiver. The kernel stamps `from` (the sender pid), so it is **unforgeable**.
- **Capabilities** (`capability.mc`): `Cap<R>` is an unforgeable (`cap_mint` is the only
  constructor) **linear** (`move`) grant over a resource R. A process without the cap
  cannot name the resource — least privilege enforced at compile time, stronger than
  MINIX's runtime privilege table.

That is the whole trusted path: scheduling, IPC, capabilities. Everything else is a
service.

## The four MINIX mechanisms (gated)
| Mechanism | Demo | Gate |
|---|---|---|
| Message-passing IPC | client ↔ "doubler" service, 21·2=42 round-trip | `ipc-test` (CSR, IPC-OK) |
| Driver as a user-mode server | console server holds the console cap, prints `[HI]`; client prints only via IPC | `cap-test` (CAP-OK) |
| Capability least privilege | the client holds no `Cap` and cannot touch the UART | `cap-test` |
| Reincarnation (restart) | a crashed server (`X`) is reaped + restarted (`R`) by a supervisor | `restart-test` (RESTART-OK) |

## The subsystems, now as servers (gated)
Each major subsystem has a user-mode server reached only through IPC — clients never
call the subsystem directly:
| Subsystem → server | What the client does over IPC | Gate |
|---|---|---|
| Console driver | print bytes; only the server holds the console `Cap` | `cap-test` |
| Storage driver (block) | write + read a 512 B block by (block#, buffer addr) | `block-server-test` |
| Filesystem (VFS/ramfs) | open / write / read / close a file | `fs-server-test` |
| Network (UDP sockets) | bind a port, inject + receive a datagram | `net-server-test` |

Servers wrap the proven subsystem logic (`vfs`/`ramfs`, the UDP socket layer, a
block-device region) behind a receive-loop that switches on the request `tag`; the
trusted core never grows. A client driving the FS server, which in turn drives the
block server, is the MINIX layered-server stack.

## What "MINIX-style" buys us, expressed in MC
- **Typed protocols**: a server `switch`es exhaustively on `Message.tag` — the IPC
  protocol is checked, not a blob of bytes.
- **Capabilities as linear types**: `Cap<R>` is `move`, so it has exactly one owner and
  cannot be copied; possession is the access right, and the compiler enforces it. MINIX
  checks privileges dynamically; here a driver that lacks `Cap<Mmio>` can't compile the
  access.
- **Isolation complements the type safety** we already had: `move`/`Arc`/generational
  handles catch bugs *within* a component at compile time; the server model + restart
  contain faults *across* components at runtime.

## Migration status (honest)
- **Done**: the microkernel core (scheduler + IPC + capabilities + restart), and a
  **user-mode server for every major subsystem** — console driver, storage/block
  driver, filesystem, and the UDP network layer — each reached only through IPC and (for
  the device drivers) guarded by a capability. All gated.
- **Relationship to the old code**: the servers reuse the existing subsystem modules
  (`vfs`/`ramfs`, the socket layer, a block region) as their internal implementation,
  now behind an IPC boundary. The monolithic modules still exist and are still used by
  the legacy integrated image (`kmain`) and the lower-level unit tests; the microkernel
  path is the server stack above.
- **Remaining isolation step**: servers are kernel-scheduled processes that share the
  kernel address space — the IPC and capability boundaries are enforced, but each server
  does not yet run behind its own MMU mapping. The per-process page-table machinery
  exists (`vmspace`/`sched-vm`); the next step is to run each server with its own `satp`
  and carry IPC over the `ecall` trap, plus a `Grant<R>` for bounded cross-AS buffer
  sharing (today buffers are passed by address because the AS is shared).

## Next steps (dependency-ordered)
1. Migrate `virtio-blk` to a block server (request tags: read/write block), granted the
   device cap; the block-backed FS becomes its client.
2. A `Grant<R>` (bounded, revocable memory share) so a client can hand a server a buffer
   by reference — MINIX memory grants, as a `move` + generational handle.
3. Run servers in their own address spaces (per-server `satp`), IPC over `ecall`.
4. A name/registry server so clients find services by name instead of a fixed pid.
