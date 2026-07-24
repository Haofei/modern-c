#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-comparison-metrics.sh LINUX MCC [REPORT]}
mcc=${2:?usage: run-comparison-metrics.sh LINUX MCC [REPORT]}
report=${3:-/tmp/vrng-comparison-metrics.tsv}
benchmark_report=${report%.tsv}-benchmark.tsv
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir="$linux/drivers/char/hw_random/virtio_rng_lang"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vrng-metrics.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

source_lines()
{
	awk 'NF && $1 !~ /^(\/\/|\/\*|\*|\*\/)/ { count++ } END { print count + 0 }' "$1"
}

matching_lines()
{
	pattern=$1
	file=$2
	grep -Ec "$pattern" "$file" || true
}

bytes()
{
	wc -c <"$1" | tr -d ' '
}

c_core="$source_dir/vrng_core_c.c"
rust_raw="$source_dir/vrng_core_rust.rs"
mc_raw="$source_dir/vrng_core_mc.mc"
rust_safe="$source_dir/vrng_dma_ownership.rs"
mc_contract="$source_dir/vrng_dma_ownership.mc"

clang -std=gnu11 -O2 -I"$script_dir/host/include" -I"$source_dir" \
	-c "$c_core" -o "$tmp/c-core.o"
rustc --edition=2021 --crate-name kernel --crate-type rlib \
	"$script_dir/host/kernel_stub.rs" -o "$tmp/libkernel.rlib"
rustc --edition=2021 --crate-name vrng_rust_metrics --crate-type lib \
	-C opt-level=2 --emit=obj --extern kernel="$tmp/libkernel.rlib" \
	"$rust_raw" -o "$tmp/rust-raw.o"
"$mcc" emit-llvm "$mc_raw" --arch=x86_64 --checks=elide-proven \
	-o "$tmp/mc-raw.ll"
clang -O2 -c -x ir "$tmp/mc-raw.ll" -o "$tmp/mc-raw.o"
rustc --edition=2021 --crate-type lib -C opt-level=2 --emit=obj \
	"$rust_safe" -o "$tmp/rust-safe.o"
"$mcc" emit-llvm "$mc_contract" --arch=x86_64 --checks=elide-proven \
	--linux-kernel -o "$tmp/mc-contract.ll"
clang -O2 -c -x ir "$tmp/mc-contract.ll" -o "$tmp/mc-contract.o"

# MC LLVM carries source-level debug metadata by default, while these C and
# Rust commands do not. Compare deployable code/data rather than charging only
# MC for debug sections.
llvm_strip=${LLVM_STRIP:-llvm-strip}
"$llvm_strip" --strip-debug "$tmp/c-core.o" "$tmp/rust-raw.o" \
	"$tmp/mc-raw.o" "$tmp/rust-safe.o" "$tmp/mc-contract.o"

rustc --edition=2021 --crate-name vrng_rust_benchmark --crate-type staticlib \
	-C opt-level=2 -C panic=abort --extern kernel="$tmp/libkernel.rlib" \
	"$rust_raw" -o "$tmp/libvrng-rust-benchmark.a"
clang -std=gnu11 -O2 -D_POSIX_C_SOURCE=200809L \
	-I"$script_dir/host/include" -I"$source_dir" \
	"$script_dir/host/vrng-host.c" "$source_dir/vrng_core_c.c" \
	"$source_dir/vrng_core_spec.c" "$tmp/mc-raw.o" \
	"$tmp/libvrng-rust-benchmark.a" -ldl -lpthread -lm \
	-o "$tmp/vrng-host"

printf 'implementation\tcomponent\tsource_loc\ttrusted_markers\tobject_bytes\ttrusted_definition\n' >"$report"
printf 'C baseline\tprotocol core\t%s\t%s\t%s\traw pointer declarations/accesses\n' \
	"$(source_lines "$c_core")" "$(matching_lines '\*' "$c_core")" \
	"$(bytes "$tmp/c-core.o")" >>"$report"
printf 'Rust raw FFI\tprotocol core\t%s\t%s\t%s\tunsafe blocks/functions\n' \
	"$(source_lines "$rust_raw")" "$(matching_lines 'unsafe' "$rust_raw")" \
	"$(bytes "$tmp/rust-raw.o")" >>"$report"
printf 'MC raw\tprotocol core\t%s\t%s\t%s\tunsafe blocks plus extern declarations\n' \
	"$(source_lines "$mc_raw")" "$(matching_lines 'unsafe|extern fn' "$mc_raw")" \
	"$(bytes "$tmp/mc-raw.o")" >>"$report"
printf 'Rust safe typestate\tDMA ownership fixture\t%s\t%s\t%s\tunsafe blocks/functions\n' \
	"$(source_lines "$rust_safe")" "$(matching_lines 'unsafe' "$rust_safe")" \
	"$(bytes "$tmp/rust-safe.o")" >>"$report"
printf 'MC contract\tDMA ownership fixture\t%s\t%s\t%s\tunsafe blocks plus extern declarations\n' \
	"$(source_lines "$mc_contract")" "$(matching_lines 'unsafe|extern fn' "$mc_contract")" \
	"$(bytes "$tmp/mc-contract.o")" >>"$report"

cat "$report"
"$tmp/vrng-host" benchmark "${VRNG_BENCHMARK_ITERATIONS:-1000000}" \
	| tee "$benchmark_report"
max_ratio=${VRNG_BENCHMARK_MAX_MC_RATIO:-1.25}
if [ "$max_ratio" != 0 ]; then
	awk -F '\t' -v max_ratio="$max_ratio" '
		$1 == "c" { c = $8 }
		$1 == "rust" { rust = $8 }
		$1 == "mc" { mc = $8 }
		END {
			if (!c || !rust || !mc)
				exit 2
			if (mc > c * max_ratio || mc > rust * max_ratio) {
				printf "MC median regression: %.3f ns/event; C %.3f; Rust %.3f; limit %.2fx\n",
					mc, c, rust, max_ratio > "/dev/stderr"
				exit 1
			}
		}
	' "$benchmark_report"
fi
echo "virtio-rng comparison metrics captured (source/object/TCB markers and protocol-core throughput)"
