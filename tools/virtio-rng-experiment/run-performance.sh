#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-performance.sh LINUX MCC OUTPUT [M7_RESULTS]}
mcc=${2:?usage: run-performance.sh LINUX MCC OUTPUT [M7_RESULTS]}
output=${3:?usage: run-performance.sh LINUX MCC OUTPUT [M7_RESULTS]}
m7_results=${4:-}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
host_dir="$script_dir/host"
source_dir="$linux/drivers/char/hw_random/virtio_rng_lang"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vrng-perf.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$output"
timings="$output/build-times.csv"
arch=$(uname -m)
case "$arch" in
	x86_64) mc_arch=x86_64 ;;
	aarch64|arm64) mc_arch=aarch64 ;;
	*) echo "unsupported benchmark host architecture: $arch" >&2; exit 2 ;;
esac

python3 "$script_dir/time-command.py" --output "$timings" --label rust-stub -- \
	rustc --edition=2021 --crate-name kernel --crate-type rlib \
	"$host_dir/kernel_stub.rs" -o "$tmp/libkernel.rlib"
python3 "$script_dir/time-command.py" --output "$timings" --label rust-core -- \
	rustc --edition=2021 --crate-name vrng_rust_host --crate-type staticlib \
	-C opt-level=2 -C panic=abort -C llvm-args=-stack-size-section \
	--extern kernel="$tmp/libkernel.rlib" \
	"$source_dir/vrng_core_rust.rs" -o "$tmp/libvrng_rust.a"
python3 "$script_dir/time-command.py" --output "$timings" --label mc-core -- \
	"$mcc" emit-llvm "$source_dir/vrng_core_mc.mc" --arch="$mc_arch" \
	--checks=elide-proven -o "$tmp/vrng_core_mc.ll"
python3 "$script_dir/time-command.py" --output "$timings" --label llvm-object -- \
	clang -O2 -fstack-size-section -c -x ir "$tmp/vrng_core_mc.ll" \
	-o "$output/vrng_core_mc.o"
python3 "$script_dir/time-command.py" --output "$timings" --label c-core -- \
	clang -std=gnu11 -O2 -g -fstack-size-section -Wall -Wextra -Werror \
	-I"$host_dir/include" -I"$source_dir" -c "$source_dir/vrng_core_c.c" \
	-o "$output/vrng_core_c.o"

rust_object=$(find "$tmp" -type f -name '*vrng_rust_host*.o' -print -quit)
if [ -z "$rust_object" ]; then
	# Extract the language object from the static library for section comparison.
	(cd "$tmp" && ar x libvrng_rust.a)
	rust_object=$(find "$tmp" -type f -name '*vrng_rust_host*.o' -print -quit)
fi
test -n "$rust_object"
cp "$rust_object" "$output/vrng_core_rust.o"

clang -std=gnu11 -O2 -g -Wall -Wextra -Werror \
	-I"$host_dir/include" -I"$source_dir" \
	"$host_dir/vrng-bench.c" "$output/vrng_core_c.o" \
	"$output/vrng_core_mc.o" "$tmp/libvrng_rust.a" -ldl -lpthread -lm \
	-o "$tmp/vrng-bench"
"$tmp/vrng-bench" > "$output/microbench.csv" 2> "$output/microbench.stderr"

live_args=()
if [ -n "$m7_results" ]; then
	for control in c rust mc; do
		live_args+=(--live "builtin-$control=$m7_results/evidence/normal-$control.log")
		live_args+=(--live "random-$control=$m7_results/evidence/rng-random-$control.log")
	done
fi
report_args=(
	--linux "$linux"
	--modern-c "$(cd "$script_dir/../.." && pwd)"
	--output "$output"
	--host-context "${VRNG_PERF_HOST_CONTEXT:-containerized benchmark; see environment metadata}"
)
if [ -n "${VRNG_PERF_LINUX_COMMIT:-}" ]; then
	report_args+=(--linux-commit "$VRNG_PERF_LINUX_COMMIT")
fi
python3 "$script_dir/performance-report.py" "${report_args[@]}" \
	"${live_args[@]}"

echo "virtio-rng performance evidence written to $output"
