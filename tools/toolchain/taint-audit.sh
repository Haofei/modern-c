#!/usr/bin/env bash
# tools/toolchain/taint-audit.sh — U3 tainted length/index audit.
#
# Thin compatibility shim: consolidated into tools/toolchain/mc-audit.sh (see the note
# in unsafe-audit.sh). Preserves the historical entry point and command line
# (`taint-audit.sh [DIR ...]`, `--self-test`). See docs/uaccess.md.
exec bash "$(dirname "$0")/mc-audit.sh" --mode taint "$@"
