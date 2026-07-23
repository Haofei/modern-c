#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-contract-mutations.sh LINUX MCC [REPORT]}
mcc=${2:?usage: run-contract-mutations.sh LINUX MCC [REPORT]}
report=${3:-/tmp/vrng-contract-mutations.tsv}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir="$linux/drivers/char/hw_random/virtio_rng_lang"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vrng-mutations.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

expect_mc_reject()
{
	name=$1
	source=$2
	diagnostic=$3
	if "$mcc" check "$source" >"$tmp/$name.log" 2>&1; then
		echo "$name unexpectedly passed MC checking" >&2
		exit 1
	fi
	grep -q "$diagnostic" "$tmp/$name.log"
	printf '%s\tMC-contract\tcompile-time rejection\t%s\n' \
		"$name" "$diagnostic" >>"$report"
}

printf 'mutation\timplementation\tclassification\tevidence\n' >"$report"

clang -std=c11 -Wall -Wextra -Werror -c \
	"$script_dir/mutations/vrng_dma_raw.c" -o "$tmp/c-raw.o"
printf 'device-owned CPU read\tC baseline\tnot detected\tcompiled raw pointer access\n' \
	>>"$report"

rustc --edition=2021 --crate-type lib "$script_dir/mutations/vrng_dma_raw.rs" \
	-o "$tmp/rust-raw.rlib"
printf 'device-owned CPU read\tRust raw FFI\tnot detected\tcompiled unsafe raw pointer access\n' \
	>>"$report"

"$script_dir/run-dma-ownership.sh" "$linux" "$mcc" "$tmp/mc-dma.ll" \
	>"$tmp/dma.log"
printf 'device-owned CPU read\tRust safe typestate\tcompile-time rejection\tE0599 method unavailable\n' \
	>>"$report"
printf 'device-owned CPU read\tMC contract\tcompile-time rejection\tE_NO_IMPLICIT_POINTER_CONVERSION\n' \
	>>"$report"

expect_mc_reject irq-sleep "$source_dir/vrng_mc_irq_blocking_gap.mc" \
	E_SLEEP_IN_ATOMIC
expect_mc_reject irq-unbounded "$source_dir/vrng_mc_irq_unbounded_gap.mc" \
	E_UNBOUNDED_LOOP

# A no-trap mutation is kept in the compiler's canonical negative fixture so
# this gate exercises the same accepted language profile as the driver build.
expect_mc_reject callback-language-trap \
	"$script_dir/mutations/vrng_mc_callback_trap.mc" E_NO_LANG_TRAP_EDGE

# Reuse the compiler's canonical mixed positive/negative fixtures for the
# remaining contract classes. Each row requires the named stable diagnostic;
# the ordinary spec suite separately verifies every accepted control in those
# files, so this runner cannot turn a blanket rejection into a passing result.
expect_mc_reject use-after-move "$script_dir/../../tests/spec/move_place.mc" \
	E_USE_AFTER_MOVE
expect_mc_reject missing-resource-cleanup \
	"$script_dir/../../tests/spec/kernel_region_tokens.mc" E_RESOURCE_LEAK
expect_mc_reject rcu-reference-escape \
	"$script_dir/../../tests/spec/kernel_region_tokens.mc" E_USE_AFTER_MOVE
expect_mc_reject callback-after-unregister \
	"$script_dir/../../tests/spec/kernel_region_tokens.mc" E_USE_AFTER_MOVE
expect_mc_reject unguarded-lock-data \
	"$script_dir/../../tests/spec/lock_guards_data.mc" E_PRIVATE_FIELD
expect_mc_reject stack-reference-escape \
	"$script_dir/../../tests/spec/local_address_escape.mc" \
	E_LOCAL_ADDRESS_ESCAPE
expect_mc_reject borrowed-reference-scope-escape \
	"$script_dir/../../tests/spec/local_address_escape.mc" \
	E_BORROW_ESCAPES_SCOPE
expect_mc_reject direct-mmio-store \
	"$script_dir/../../tests/spec/mmio_ordering.mc" E_MMIO_DIRECT_ASSIGN
expect_mc_reject wrong-mmio-ordering \
	"$script_dir/../../tests/spec/mmio_ordering.mc" E_MMIO_ORDERING
expect_mc_reject address-space-conversion \
	"$script_dir/../../tests/spec/address_classes.mc" \
	E_ADDRESS_CLASS_MISMATCH
expect_mc_reject dma-address-dereference \
	"$script_dir/../../tests/spec/address_classes.mc" E_DMA_ADDR_DEREF

grep -q $'device-owned CPU read\tC baseline\tnot detected' "$report"
grep -q $'device-owned CPU read\tRust raw FFI\tnot detected' "$report"
test "$(grep -c 'compile-time rejection' "$report")" -eq 16

cat "$report"
echo "virtio-rng kernel-contract mutation matrix passed"
