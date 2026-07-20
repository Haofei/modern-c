#!/usr/bin/env bash
set -euo pipefail

linux_src=${1:-/home/zoe/src/linux}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
failed=0

check_command() {
  local command_name=$1
  if command -v "$command_name" >/dev/null 2>&1; then
    printf 'ok      %-28s %s\n' "$command_name" "$(command -v "$command_name")"
  else
    printf 'missing %-28s\n' "$command_name"
    failed=1
  fi
}

commands=(
  aarch64-linux-gnu-gcc
  bindgen
  bison
  clang
  flex
  gcc
  ld.lld
  llvm-as
  llvm-objdump
  llvm-readelf
  make
  mksquashfs
  pahole
  perf
  qemu-img
  qemu-system-aarch64
  qemu-system-riscv64
  qemu-system-x86_64
  riscv64-linux-gnu-gcc
  rustc
  rustfmt
  sparse
  zig
)

for command_name in "${commands[@]}"; do
  check_command "$command_name"
done

if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  echo "ok      /dev/kvm                     hardware acceleration available"
else
  echo "warning /dev/kvm                     unavailable; QEMU will use TCG"
fi

if [[ ! -d "$linux_src/.git" ]]; then
  echo "missing Linux source                 $linux_src"
  failed=1
else
  printf 'ok      Linux source                 %s\n' "$linux_src"
  git -C "$linux_src" describe --always --dirty
  make -s -C "$linux_src" LLVM=1 rustavailable || failed=1
fi

if [[ ! -x "$repo_root/zig-out/bin/mcc" ]]; then
  echo "warning $repo_root/zig-out/bin/mcc"
  echo "        build with: (cd $repo_root && zig build)"
else
  echo "ok      $repo_root/zig-out/bin/mcc"
fi

exit "$failed"
