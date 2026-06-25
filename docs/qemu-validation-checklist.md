# QEMU Validation Checklist

Use this when VisionFive 2 hardware is unavailable.

## Local

- Run `zig build test` for compiler/unit coverage before platform gates.
- Run `zig build riscv-qemu-validation` for the focused RISC-V OpenSBI/QEMU
  surrogate. On macOS, set `LLD` when Homebrew installs it outside `PATH`, for
  example `LLD=/opt/homebrew/opt/lld/bin/ld.lld zig build riscv-qemu-validation`.
- Run `tools/qemu/riscv-qemu-soak-smoke.sh` before making a durability claim from
  QEMU-only evidence. Set `MC_SOAK_ITERS=N` to raise the repeat count.
- Run `zig build m0` before broad milestone or release claims.

## Required Tools

- Zig 0.16.0.
- `clang`, `llc`, and `ld.lld`.
- `qemu-system-riscv64`.

## Evidence Bar

- The command exits 0.
- CI/local logs do not contain `SKIP:` for the QEMU surrogate.
- `visionfive2-readiness-test` and `llvm-visionfive2-readiness-test` pass when
  board-profile or FDT/BootInfo code changes.

QEMU evidence is a surrogate. It keeps the OpenSBI, FDT, interrupt, storage,
network, and agent paths honest, but it is not a VisionFive 2 hardware boot or
real long-duration soak result.
