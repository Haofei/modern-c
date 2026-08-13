# MC Kernel Validation Scope

The `kernel/` tree is a validation workload for the MC language and compiler. It is
not the core product, not an OS product specification, and not a compatibility
contract. Keep kernel work small and tied to compiler evidence.

## What remains in scope

- freestanding entry, trap, context-switch, and syscall ABI fixtures;
- typed address classes, user-pointer copy boundaries, and unsafe-boundary checks;
- page allocator, heap, paging, and simple process/scheduler mechanics where they
  exercise ownership, effects, ABI layout, or backend lowering;
- focused RISC-V/QEMU boot and MMIO/interrupt fixtures;
- small library fixtures such as mailbox, grant, rights, resource accounting,
  lock/guard, and ring/slotmap examples.

## What is out of scope

- network stacks, filesystems, block storage, PCI, RNG services, and device
  registries;
- kernel IPC policy, endpoint rendezvous protocols, service supervision, fdspace,
  and process capability masks;
- async kernel brokers, SMP product fixtures, VM products, isolation products, and
  update/checkpoint/recovery products;
- product release, shipped-version, or device-certification claims.

If a kernel feature does not directly validate language semantics, compiler
lowering, ABI boundaries, or unsafe contracts, remove it or move it out of the
core gate path.

## Retained evidence

The retained kernel fixtures should answer narrow compiler questions:

- Does MC represent low-level address spaces and unsafe operations explicitly?
- Do C and LLVM lowerings agree on the supported freestanding subset?
- Do ownership and `move` resource rules catch common low-level protocol errors?
- Do ABI layout and call boundaries stay stable across emitted code?
- Do QEMU/OpenSBI smoke tests exercise the retained trap/MMIO/runtime paths?

The kernel validation workload should not grow into a second product roadmap.
