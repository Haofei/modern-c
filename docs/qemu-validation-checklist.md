# QEMU Validation Checklist

Use this for the retained RISC-V OpenSBI/QEMU language-validation surrogate.

## Local

- Run `zig build test` for compiler/unit coverage before platform gates.
- Run `zig build riscv-qemu-validation` for the focused RISC-V OpenSBI/QEMU
  surrogate. On macOS, set `LLD` when Homebrew installs it outside `PATH`, for
  example `LLD=/opt/homebrew/opt/lld/bin/ld.lld zig build riscv-qemu-validation`.
- Run `zig build m0-full` before broad milestone or release claims.

## Required Tools

- Zig 0.16.0.
- `clang`, `llc`, and `ld.lld`.
- `qemu-system-riscv64`.

## Evidence Bar

- The command exits 0.
- CI/local logs do not contain `SKIP:` for the QEMU surrogate.
- Retained RISC-V OpenSBI/QEMU gates pass when FDT, BootInfo, interrupt, MMIO,
  or backend-lowering code changes.

QEMU evidence is a surrogate. It keeps selected OpenSBI, FDT, interrupt, MMIO,
and backend paths honest, but it is not hardware qualification or a
long-duration soak result.
