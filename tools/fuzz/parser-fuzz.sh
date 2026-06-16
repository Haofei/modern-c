#!/usr/bin/env bash
# P1 parser fuzz oracle — drive the kernel's parsers over ATTACKER-CONTROLLED bytes.
#
# The kernel parses untrusted wire data (DNS/TCP/IP records, ELF). Every read in those
# parsers now routes through the TOTAL checked reader (std/bytes `br_try_*`), so a read
# that would run off the end returns a typed error instead of trapping. This oracle
# proves the property empirically: it feeds RANDOM and TRUNCATED/MALFORMED byte buffers
# of every length to `dns_parse_response` and `tcp_parse_frame` (the two parsers handling
# the most attacker-controlled data) and asserts each ALWAYS terminates and NEVER
# over-reads — a malformed/truncated packet is rejected cleanly with an error, not a
# trap-crash.
#
# It runs over a million parses via the host-driver harness (tools/lib/host-harness.sh,
# manifest row `parser-fuzz-test`, fixture tests/qemu/net/parser_fuzz_demo.mc, driver
# tools/lib/host-drivers/parser-fuzz-test.c). If any parse over-read, the bounds-checked
# reader would fire `unreachable` and the driver process would abort (SIGABRT) before
# printing success — so a clean PASS line is the proof of totality.
#
# Crucially this oracle has TEETH: removing a bounds guard / reverting a `br_try_*` to a
# trapping `br_*` in either parser makes a truncated-answer case over-read, and the run
# FAILS (verified during development).
#
# Usage: tools/fuzz/parser-fuzz.sh [path-to-mcc]
# Skips (exit 0) when clang is unavailable, like the host harness it drives.
set -euo pipefail

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
MCC="${1:-$HERE/zig-out/bin/mcc}"

# Build the compiler if the caller did not hand us a fresh one.
if [ ! -x "$MCC" ]; then
    echo "parser-fuzz: building mcc (no $MCC) ..."
    ( cd "$HERE" && zig build >/dev/null )
    MCC="$HERE/zig-out/bin/mcc"
fi

echo "=== parser-fuzz: DNS + TCP parsers over random/truncated/malformed bytes ==="
bash "$HERE/tools/lib/host-harness.sh" "$MCC" parser-fuzz-test

echo "parser-fuzz: OK — parsers are total over a finite buffer (no over-read, clean reject on garbage)"
