# Async/await scope

Current scope: compiler async lowering and the pure `std/task.mc` future vocabulary remain in the
language core. The former kernel completion-broker runtime and QEMU broker gates were removed from
the compiler-core workload.

Retained evidence:

- compiler diagnostics for invalid `await` placement and unresolved future expressions;
- C/LLVM differential fixtures for generated async state-machine shapes;
- host fixtures for cancellation, lazy child construction, branch/loop lowering, nested awaits,
  try-await, and task combinators;
- `std/task.mc` as a fixed-size, no-hidden-heap future vocabulary with injected completion and
  cancellation callbacks.

Out of scope for the core goal:

- kernel park/wake completion brokers;
- IRQ-backed async runtime demos;
- broker-backed `ReqFut` leaves;
- select/cancel-the-loser over real kernel slots;
- device IRQ integration.

Those are validation/runtime product surfaces, not the language definition. Reintroducing them would
require a separate validation profile and must not become a compiler-core gate.
