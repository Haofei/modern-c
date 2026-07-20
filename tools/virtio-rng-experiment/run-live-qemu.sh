#!/usr/bin/env bash
set -euo pipefail

kernel=${1:?usage: run-live-qemu.sh KERNEL INITRAMFS [LOG]}
initramfs=${2:?usage: run-live-qemu.sh KERNEL INITRAMFS [LOG]}
log=${3:-vrng-live-qemu.log}

timeout 180 qemu-system-x86_64 \
	-nodefaults \
	-m 2048 \
	-kernel "$kernel" \
	-initrd "$initramfs" \
	-append "console=ttyS0 rdinit=/init panic=-1" \
	-no-reboot \
	-nographic \
	-accel kvm \
	-accel tcg \
	-serial stdio \
	-object rng-builtin,id=rng0 \
	-device virtio-rng-pci,rng=rng0 | tee "$log"

grep -q "VRNG-LIVE: readers passed" "$log"
grep -Eq "language shadow matched all [1-9][0-9]* protocol events" "$log"
if grep -q "language shadow mismatches=" "$log"; then
	echo "virtio-rng language shadow reported a mismatch" >&2
	exit 1
fi

echo "virtio-rng live shadow test passed"
