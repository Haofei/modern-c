#!/usr/bin/env bash
# tools/toolchain/unsafe-audit.sh — S0.2 unsafe-boundary audit.
#
# This is now a thin compatibility shim: the three near-identical audit lints
# (unsafe / double-fetch / taint) were consolidated into ONE parameterized tool,
# tools/toolchain/mc-audit.sh, so a single fix (cross-line line-joining, the `<>`
# argument-depth fix, the taint cleanse-the-right-binding fix) applies to all three.
# The audit logic, inventory, and self-test all live there. This wrapper preserves
# the historical entry point and command line (`unsafe-audit.sh [DIR ...]`,
# `--self-test`). See docs/unsafe-boundary.md.
exec bash "$(dirname "$0")/mc-audit.sh" --mode unsafe "$@"
