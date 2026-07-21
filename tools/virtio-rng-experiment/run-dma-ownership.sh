#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-dma-ownership.sh LINUX MCC [OUT]}
mcc=${2:?usage: run-dma-ownership.sh LINUX MCC [OUT]}
out=${3:-/tmp/vrng-dma-ownership.ll}
source_dir="$linux/drivers/char/hw_random/virtio_rng_lang"
positive="$source_dir/vrng_dma_ownership.mc"
negative="$source_dir/vrng_dma_device_owned_read.mc"
negative_log=$(mktemp)
trap 'rm -f "$negative_log"' EXIT

"$mcc" check "$positive"
"$mcc" emit-llvm "$positive" --arch=x86_64 --checks=elide-proven \
	--linux-kernel -o "$out"

if "$mcc" check "$negative" >"$negative_log" 2>&1; then
	echo "device-owned CPU read unexpectedly passed semantic checking" >&2
	exit 1
fi
if ! grep -q 'E_NO_IMPLICIT_POINTER_CONVERSION' "$negative_log"; then
	cat "$negative_log" >&2
	echo "device-owned CPU read failed without the expected diagnostic" >&2
	exit 1
fi

echo "virtio-rng typed DMA ownership qualification passed"
