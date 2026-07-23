#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-dma-ownership.sh LINUX MCC [OUT]}
mcc=${2:?usage: run-dma-ownership.sh LINUX MCC [OUT]}
out=${3:-/tmp/vrng-dma-ownership.ll}
source_dir="$linux/drivers/char/hw_random/virtio_rng_lang"
positive="$source_dir/vrng_dma_ownership.mc"
negative="$source_dir/vrng_dma_device_owned_read.mc"
rust_positive="$source_dir/vrng_dma_ownership.rs"
rust_negative="$source_dir/vrng_dma_device_owned_read.rs"
negative_log=$(mktemp)
rust_negative_log=$(mktemp)
rust_out=$(mktemp)
trap 'rm -f "$negative_log" "$rust_negative_log" "$rust_out"' EXIT

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

rustc --edition=2021 --crate-type lib "$rust_positive" -o "$rust_out"
if rustc --edition=2021 --crate-type lib "$rust_negative" \
	-o "$rust_out" >"$rust_negative_log" 2>&1; then
	echo "Rust device-owned CPU read unexpectedly compiled" >&2
	exit 1
fi
if ! grep -q 'no method named `as_mut_slice`' "$rust_negative_log"; then
	cat "$rust_negative_log" >&2
	echo "Rust device-owned CPU read failed without the typestate diagnostic" >&2
	exit 1
fi

echo "virtio-rng symmetric MC/Rust typed DMA ownership qualification passed"
