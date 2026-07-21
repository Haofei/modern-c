#!/usr/bin/env bash
set -euo pipefail

kernel=${1:?usage: run-live-qemu.sh KERNEL INITRAMFS [LOG] [shadow|shadow-fault|shadow-pm|shadow-hotplug|no-shadow]}
initramfs=${2:?usage: run-live-qemu.sh KERNEL INITRAMFS [LOG] [shadow|shadow-fault|shadow-pm|shadow-hotplug|no-shadow]}
log=${3:-vrng-live-qemu.log}
mode=${4:-shadow}
kernel_args=""
qmp_args=()
controller_pid=""
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

cleanup()
{
	if [ -n "$controller_pid" ]; then
		kill "$controller_pid" 2>/dev/null || true
	fi
	if [ -n "${qmp_socket:-}" ]; then
		rm -f "$qmp_socket"
	fi
}
trap cleanup EXIT

case "$mode" in
	shadow|no-shadow) ;;
	shadow-fault) kernel_args="vrng_live_fault_matrix=1" ;;
	shadow-pm) kernel_args="vrng_live_pm_matrix=1 suspend.pm_test_delay=1" ;;
	shadow-hotplug)
		kernel_args="vrng_live_transport_matrix=1"
		qmp_socket="${log}.qmp"
		rm -f "$qmp_socket"
		qmp_args=(-qmp "unix:$qmp_socket,server=on,wait=off")
		;;
	*) echo "invalid live-test mode: $mode" >&2; exit 2 ;;
esac

: > "$log"
if [ "$mode" = shadow-hotplug ]; then
	python3 "$script_dir/qmp-hotplug.py" "$qmp_socket" "$log" &
	controller_pid=$!
fi

set +e
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
	-device virtio-rng-pci,rng=rng0,id=vrngdev \
	${qmp_args[@]+"${qmp_args[@]}"} | tee "$log"
qemu_status=${PIPESTATUS[0]}
set -e

controller_status=0
if [ -n "$controller_pid" ]; then
	wait "$controller_pid" || controller_status=$?
	controller_pid=""
fi
if [ "$qemu_status" -ne 0 ] || [ "$controller_status" -ne 0 ]; then
	echo "virtio-rng live process failed: qemu=$qemu_status controller=$controller_status" >&2
	exit 1
fi

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
if [ "$mode" = shadow-pm ]; then
	grep -q "VRNG-LIVE: suspend/restore matrix passed" "$log"
fi
if [ "$mode" = shadow-hotplug ]; then
	grep -q "VRNG-LIVE: transport hot-unplug/replug passed" "$log"
fi
if grep -Eq "BUG:|WARNING:|KASAN:|KCSAN:|UBSAN:|kernel BUG|possible circular locking|blocked for more than|enqueued on deprecated workqueue" "$log"; then
	echo "virtio-rng live test reported a kernel diagnostic" >&2
	exit 1
fi

echo "virtio-rng live $mode test passed"
