#!/usr/bin/env bash
set -euo pipefail

kernel=${1:?usage: run-live-qemu.sh KERNEL INITRAMFS [LOG] [shadow|shadow-fault|shadow-register-fault|shadow-teardown-fault|shadow-pm|shadow-hotplug|shadow-multidev|no-shadow]}
initramfs=${2:?usage: run-live-qemu.sh KERNEL INITRAMFS [LOG] [shadow|shadow-fault|shadow-register-fault|shadow-teardown-fault|shadow-pm|shadow-hotplug|shadow-multidev|no-shadow]}
log=${3:-vrng-live-qemu.log}
mode=${4:-shadow}
kernel_args=""
qmp_args=()
extra_device_args=()
controller_pid=""
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
kernel_diagnostic_pattern='BUG:|WARNING:|KASAN:|KCSAN:|UBSAN:|kernel BUG|Oops:|Kernel panic|general protection fault|scheduling while atomic|sleeping function called from invalid context|possible circular locking|blocked for more than|soft lockup|hard LOCKUP|rcu[^:]*stall|refcount_t:|DMA-API:.*(error|warning|invalid)|enqueued on deprecated workqueue'
lifecycle_record_pattern='VRNG-LIFECYCLE: sequence=[1-9][0-9]* device=[1-9][0-9]* error=0 stage=4 avail=0 events=[1-9][0-9]* mismatches=0'

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
	shadow-register-fault)
		kernel_args="vrng_live_register_fault_matrix=1 virtio_rng.lang_fail_register_once=1"
		;;
	shadow-teardown-fault) kernel_args="vrng_live_teardown_fault_matrix=1" ;;
	shadow-multidev)
		kernel_args="vrng_live_multidev_matrix=1"
		extra_device_args=(-object rng-builtin,id=rng1 -device virtio-rng-pci,rng=rng1,id=vrngdev2)
		;;
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
	-smp 2 \
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
	${extra_device_args[@]+"${extra_device_args[@]}"} \
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

if [ "$mode" = shadow-register-fault ]; then
	grep -q "VRNG-LIVE: registration-failure degraded state passed" "$log"
	grep -Eq "VRNG-LIVE: driver lifecycle teardown passed sequence=[1-9][0-9]* events=[1-9][0-9]*" "$log"
	grep -Eq "$lifecycle_record_pattern" "$log"
	grep -Eq "language shadow control=(C|Rust|MC) matched all [1-9][0-9]* protocol and [1-9][0-9]* driver lifecycle events" "$log"
	if grep -Eq "$kernel_diagnostic_pattern" "$log"; then
		echo "virtio-rng registration-fault test reported a kernel diagnostic" >&2
		exit 1
	fi
	echo "virtio-rng live $mode test passed" | tee -a "$log"
	exit 0
fi

grep -q "VRNG-LIVE: normal reads passed" "$log"
grep -q "VRNG-LIVE: nonblocking read passed" "$log"
grep -q "VRNG-LIVE: small-block reads passed" "$log"
grep -q "VRNG-LIVE: driver partial-copy path passed" "$log"
grep -q "VRNG-LIVE: removal readers terminated" "$log"
grep -q "VRNG-LIVE: complete" "$log"
if [ "$mode" != no-shadow ]; then
	grep -Eq "VRNG-LIVE: (blocked-reader|post-core publication) synchronization reached" "$log"
	grep -q "VRNG-LIVE: teardown publication ordering passed" "$log"
	if [ "$mode" = shadow-teardown-fault ]; then
		grep -q "VRNG-LIVE: teardown error oracle detected injected failure" "$log"
		grep -Eq "VRNG-LIFECYCLE: sequence=[1-9][0-9]* device=[1-9][0-9]* error=-[1-9][0-9]* stage=4 avail=0 events=[1-9][0-9]* mismatches=0" "$log"
		grep -Eq "language shadow control=(C|Rust|MC) teardown failed=-[1-9][0-9]* after [1-9][0-9]* protocol and [1-9][0-9]* driver lifecycle events" "$log"
	else
		grep -Eq "VRNG-LIVE: driver lifecycle teardown passed sequence=[1-9][0-9]* events=[1-9][0-9]*" "$log"
		grep -Eq "$lifecycle_record_pattern" "$log"
		grep -Eq "language shadow control=(C|Rust|MC) matched all [1-9][0-9]* protocol and [1-9][0-9]* driver lifecycle events" "$log"
	fi
	if grep -Eq "language shadow( control=(C|Rust|MC))? mismatches=" "$log"; then
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
	grep -q "VRNG-LIVE: transport hot-unplug teardown checked" "$log"
	grep -q "VRNG-LIVE: transport hot-unplug/replug passed" "$log"
fi
if [ "$mode" = shadow-multidev ]; then
	grep -Eq "VRNG-LIVE: first multi-device teardown checked device=[1-9][0-9]*" "$log"
	grep -Eq "VRNG-LIVE: second multi-device teardown checked device=[1-9][0-9]*" "$log"
fi
if grep -Eq "$kernel_diagnostic_pattern" "$log"; then
	echo "virtio-rng live test reported a kernel diagnostic" >&2
	exit 1
fi

echo "virtio-rng live $mode test passed" | tee -a "$log"
