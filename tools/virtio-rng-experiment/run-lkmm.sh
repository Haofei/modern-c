#!/usr/bin/env bash
set -euo pipefail

linux=${1:?usage: run-lkmm.sh LINUX}
memory_model="$linux/tools/memory-model"
never_tests=(
	"litmus-tests/VRNG+data-publish-release-acquire.litmus"
	"litmus-tests/VRNG+completion-wakeup-lock.litmus"
)
sometimes_tests=(
	"litmus-tests/VRNG+data-publish-once.litmus"
)

command -v herd7 >/dev/null || {
	echo "herd7 7.58 or newer is required" >&2
	exit 2
}

for test in "${never_tests[@]}"; do
	output=$(cd "$memory_model" && herd7 -conf linux-kernel.cfg "$test")
	printf '%s\n' "$output"
	if ! grep -Eq '^Observation .* Never ' <<<"$output"; then
		echo "LKMM did not prohibit the bad outcome: $test" >&2
		exit 1
	fi
done

for test in "${sometimes_tests[@]}"; do
	output=$(cd "$memory_model" && herd7 -conf linux-kernel.cfg "$test")
	printf '%s\n' "$output"
	if ! grep -Eq '^Observation .* Sometimes ' <<<"$output"; then
		echo "LKMM negative control did not expose the bad outcome: $test" >&2
		exit 1
	fi
done

echo "virtio-rng LKMM publication contracts passed"
