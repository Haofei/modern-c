#!/usr/bin/env bash
# tools/toolchain/double-fetch-audit.sh — U2 double-fetch / TOCTOU audit.
#
# Thin compatibility shim: consolidated into tools/toolchain/mc-audit.sh (see the note
# in unsafe-audit.sh). Preserves the historical entry point and command line
# (`double-fetch-audit.sh [DIR ...]`, `--self-test`). See docs/uaccess.md.
exec bash "$(dirname "$0")/mc-audit.sh" --mode double-fetch "$@"
