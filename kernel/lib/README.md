# kernel/lib — validation helpers

This directory is part of the freestanding validation workload. It exists to
exercise language/compiler behavior that needs a small privileged setting:
resource accounting, wait queues, blocking contracts, IPC-shaped data flow, and
typed ownership across kernel-flavored APIs.

It is not a reusable OS framework layer. Code belongs here only when it needs a
kernel-shaped validation context and would make `std/` less generic.

Generic freestanding primitives should stay in `std/`. Kernel deliverable features,
subsystems, and driver stacks should not be added here unless they are required
to validate a specific language, MIR, ABI, ownership, or unsafe-boundary rule.
