#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-host-differential.sh LINUX_TREE MCC [CORPUS_DIR]}
mcc=${2:?usage: run-host-differential.sh LINUX_TREE MCC [CORPUS_DIR]}
corpus_dir=${3:-tests/virtio-rng-corpus/generated}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
host_dir="$script_dir/host"
source_dir="$linux/drivers/char/hw_random/virtio_rng_lang"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vrng-host.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

for source in vrng_core_abi.h vrng_core_spec.h vrng_core_c.c \
	vrng_core_spec.c vrng_core_rust.rs vrng_core_mc.mc; do
	test -f "$source_dir/$source"
done

rustc --edition=2021 --crate-name kernel --crate-type rlib \
	"$host_dir/kernel_stub.rs" -o "$tmp/libkernel.rlib"
rustc --edition=2021 --crate-name vrng_rust_host --crate-type staticlib \
	-C panic=abort --extern kernel="$tmp/libkernel.rlib" \
	"$source_dir/vrng_core_rust.rs" -o "$tmp/libvrng_rust.a"

"$mcc" emit-llvm "$source_dir/vrng_core_mc.mc" --arch=x86_64 \
	--checks=elide-proven -o "$tmp/vrng_core_mc.ll"
clang -c -x ir "$tmp/vrng_core_mc.ll" -o "$tmp/vrng_core_mc.o"

clang -std=gnu11 -O2 -g -Wall -Wextra -Werror \
	-I"$host_dir/include" -I"$source_dir" \
	"$host_dir/vrng-host.c" "$source_dir/vrng_core_c.c" \
	"$source_dir/vrng_core_spec.c" "$tmp/vrng_core_mc.o" \
	"$tmp/libvrng_rust.a" -ldl -lpthread -lm -o "$tmp/vrng-host"

"$tmp/vrng-host" enumerate "$corpus_dir"
for corpus in tests/virtio-rng-corpus/*.vrng; do
	"$tmp/vrng-host" replay "$corpus"
done

synthetic_dir="$tmp/synthetic"
set +e
"$tmp/vrng-host" enumerate "$synthetic_dir" --inject c:begin_submit
capture_status=$?
set -e
if [ "$capture_status" -ne 2 ]; then
	echo "synthetic mismatch was not persisted" >&2
	exit 1
fi
synthetic_corpus=$(find "$synthetic_dir" -type f -name '*.vrng' -print -quit)
test -n "$synthetic_corpus"
diff -u tests/virtio-rng-corpus/synthetic-begin-submit.vrng "$synthetic_corpus"
"$tmp/vrng-host" replay "$synthetic_corpus"
set +e
"$tmp/vrng-host" replay "$synthetic_corpus" --inject c:begin_submit
replay_status=$?
set -e
if [ "$replay_status" -ne 2 ]; then
	echo "synthetic mismatch did not reproduce" >&2
	exit 1
fi

echo "virtio-rng host differential and corpus replay passed"
