#!/usr/bin/env bash
set -euo pipefail

kernel=${1:?usage: run-live-qemu.sh KERNEL INITRAMFS [LOG] [shadow|shadow-fault|no-shadow]}
initramfs=${2:?usage: run-live-qemu.sh KERNEL INITRAMFS [LOG] [shadow|shadow-fault|no-shadow]}
log=${3:-vrng-live-qemu.log}
mode=${4:-shadow}
kernel_args=""

case "$mode" in
	shadow|no-shadow) ;;
	shadow-fault) kernel_args="vrng_live_fault_matrix=1" ;;
	*) echo "invalid live-test mode: $mode" >&2; exit 2 ;;
esac

timeout 180 qemu-system-x86_64 \
	-nodefaults \
	-m 2048 \
	-kernel "$kernel" \
	-initrd "$initramfs" \
	-append "console=ttyS0 rdinit=/init panic=-1 $kernel_args" \
	-no-reboot \
	-nographic \
	-accel kvm \
	-accel tcg \
	-serial stdio \
	-object rng-builtin,id=rng0 \
	-device virtio-rng-pci,rng=rng0 | tee "$log"

grep -q "VRNG-LIVE: normal reads passed" "$log"
grep -q "VRNG-LIVE: small-block reads passed" "$log"
grep -q "VRNG-LIVE: driver partial-copy path passed" "$log"
grep -q "VRNG-LIVE: removal readers terminated" "$log"
grep -q "VRNG-LIVE: complete" "$log"
if [ "$mode" != no-shadow ]; then
	grep -q "VRNG-LIVE: blocked-reader synchronization reached" "$log"
	grep -Eq "language shadow matched all [1-9][0-9]* protocol events" "$log"
	if grep -q "language shadow mismatches=" "$log"; then
		echo "virtio-rng language shadow reported a mismatch" >&2
		exit 1
	fi
fi
if [ "$mode" = shadow-fault ]; then
	grep -q "VRNG-LIVE: fault matrix passed" "$log"
fi
if grep -Eq "BUG:|WARNING:|KASAN:|KCSAN:|UBSAN:|kernel BUG|possible circular locking|blocked for more than|enqueued on deprecated workqueue" "$log"; then
	echo "virtio-rng live test reported a kernel diagnostic" >&2
	exit 1
fi

echo "virtio-rng live $mode test passed"
