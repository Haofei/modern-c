#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-control-matrix.sh LINUX MCC INITRAMFS BUILD_ROOT}
mcc=${2:?usage: run-control-matrix.sh LINUX MCC INITRAMFS BUILD_ROOT}
initramfs=${3:?usage: run-control-matrix.sh LINUX MCC INITRAMFS BUILD_ROOT}
build_root=${4:?usage: run-control-matrix.sh LINUX MCC INITRAMFS BUILD_ROOT [RESULTS]}
results=${5:-$build_root/results}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
kunitconfig="$linux/drivers/char/hw_random/virtio_rng_lang/.kunitconfig"
record_args=()

for control in c rust mc; do
	case "$control" in
		c) symbol=CONFIG_HW_RANDOM_VIRTIO_LANG_CONTROL_C=y ;;
		rust) symbol=CONFIG_HW_RANDOM_VIRTIO_LANG_CONTROL_RUST=y ;;
		mc) symbol=CONFIG_HW_RANDOM_VIRTIO_LANG_CONTROL_MC=y ;;
	esac

	build="$build_root/control-$control"
	mkdir -p "$build"
	python3 "$linux/tools/testing/kunit/kunit.py" run \
		--build_dir="$build" \
		--kunitconfig="$kunitconfig" \
		--kconfig_add="$symbol" \
		--kconfig_add=CONFIG_PM_DEBUG=y \
		--make_options LLVM=1 \
		--make_options "MCC=$mcc" \
		--arch=x86_64 \
		--jobs="${JOBS:-$(nproc)}" \
		--timeout=180 \
		--summary \
		"virtio-rng-lang-core*"
	record_args+=(--case "kunit-$control=$build/test.log")
	record_args+=(--artifact "config-$control=$build/.config")

	kernel="$build/arch/x86/boot/bzImage"
	for mode in shadow shadow-fault shadow-pm shadow-hotplug; do
		"$script_dir/run-live-qemu.sh" "$kernel" "$initramfs" \
			"$build/live-$mode.log" "$mode"
		record_args+=(--case "$mode-$control=$build/live-$mode.log")
	done
done

python3 "$script_dir/record-results.py" \
	--output "$results" \
	--linux "$linux" \
	--modern-c "$(cd "$script_dir/../.." && pwd)" \
	--qemu-args '-nodefaults -m 2048 -accel kvm -accel tcg -object rng-builtin -device virtio-rng-pci' \
	"${record_args[@]}"

echo "virtio-rng C/Rust/MC control matrix passed"
