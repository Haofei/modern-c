#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-control-matrix.sh LINUX MCC INITRAMFS BUILD_ROOT}
mcc=${2:?usage: run-control-matrix.sh LINUX MCC INITRAMFS BUILD_ROOT}
initramfs=${3:?usage: run-control-matrix.sh LINUX MCC INITRAMFS BUILD_ROOT}
build_root=${4:?usage: run-control-matrix.sh LINUX MCC INITRAMFS BUILD_ROOT}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
kunitconfig="$linux/drivers/char/hw_random/virtio_rng_lang/.kunitconfig"

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

	kernel="$build/arch/x86/boot/bzImage"
	for mode in shadow shadow-fault shadow-pm shadow-hotplug; do
		"$script_dir/run-live-qemu.sh" "$kernel" "$initramfs" \
			"$build/live-$mode.log" "$mode"
	done
done

echo "virtio-rng C/Rust/MC control matrix passed"
