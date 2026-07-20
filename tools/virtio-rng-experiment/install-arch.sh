#!/usr/bin/env bash
set -euo pipefail

# Host packages for the C/Rust/MC virtio-rng experiment on Arch Linux.
# This intentionally uses the distribution Rust/LLVM pair, as recommended by
# the Rust-for-Linux documentation.
packages=(
  base-devel
  bc
  bison
  busybox
  ccache
  clang
  cpio
  dtc
  flex
  git
  jq
  libelf
  lld
  llvm
  numactl
  openssl
  pahole
  perf
  python
  qemu-img
  qemu-system-aarch64
  qemu-system-riscv
  qemu-system-x86
  rng-tools
  rust
  rust-bindgen
  rust-src
  socat
  sparse
  squashfs-tools
  stress-ng
  trace-cmd
  zig
  aarch64-linux-gnu-binutils
  aarch64-linux-gnu-gcc
  riscv64-linux-gnu-binutils
  riscv64-linux-gnu-gcc
)

sudo pacman -Syu --needed "${packages[@]}"

echo
echo "Host packages installed. Run:"
echo "  tools/virtio-rng-experiment/check-environment.sh /home/zoe/src/linux"
