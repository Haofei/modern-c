#!/usr/bin/env bash
set -euo pipefail

expected_zig="${MC_ZIG_VERSION:-0.16.0}"
expected_llvm_major="${MC_LLVM_MAJOR:?MC_LLVM_MAJOR must name the qualified LLVM major}"

actual_zig="$(zig version)"
if [[ "$actual_zig" != "$expected_zig" ]]; then
  echo "expected Zig $expected_zig, got $actual_zig" >&2
  exit 1
fi

tools=("$@")
if (( ${#tools[@]} == 0 )); then
  tools=(clang llvm-as llc opt)
fi

for tool in "${tools[@]}"; do
  first_line="$("$tool" --version | head -n 1)"
  echo "$tool: $first_line"
  if [[ ! "$first_line" =~ (^|[[:space:]])version[[:space:]]+${expected_llvm_major}\. ]]; then
    echo "expected $tool to report LLVM major $expected_llvm_major, got: $first_line" >&2
    exit 1
  fi
done
