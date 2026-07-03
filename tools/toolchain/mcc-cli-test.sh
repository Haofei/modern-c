#!/usr/bin/env bash
# Transcript gate for top-level mcc help/version/usage behavior.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT="$WORK/stdout.txt"
ERR="$WORK/stderr.txt"
RC=0

run_case() {
    set +e
    "$MCC" "$@" >"$OUT" 2>"$ERR"
    RC=$?
    set -e
}

assert_rc() {
    local want="$1"
    local label="$2"
    if [ "$RC" -ne "$want" ]; then
        echo "FAIL: mcc-cli-test — $label exited $RC, want $want"
        echo "stdout:"
        cat "$OUT"
        echo "stderr:"
        cat "$ERR"
        exit 1
    fi
}

assert_stdout_contains() {
    local needle="$1"
    local label="$2"
    if ! grep -Fq "$needle" "$OUT"; then
        echo "FAIL: mcc-cli-test — missing stdout $label"
        echo "expected substring: $needle"
        echo "stdout:"
        cat "$OUT"
        exit 1
    fi
}

assert_stderr_contains() {
    local needle="$1"
    local label="$2"
    if ! grep -Fq "$needle" "$ERR"; then
        echo "FAIL: mcc-cli-test — missing stderr $label"
        echo "expected substring: $needle"
        echo "stderr:"
        cat "$ERR"
        exit 1
    fi
}

assert_stdout_empty() {
    local label="$1"
    if [ -s "$OUT" ]; then
        echo "FAIL: mcc-cli-test — $label wrote stdout"
        cat "$OUT"
        exit 1
    fi
}

assert_stderr_empty() {
    local label="$1"
    if [ -s "$ERR" ]; then
        echo "FAIL: mcc-cli-test — $label wrote stderr"
        cat "$ERR"
        exit 1
    fi
}

run_case --help
assert_rc 0 "--help"
assert_stdout_contains "usage:" "--help usage header"
assert_stdout_contains "mcc list-tests <file.mc>" "--help list-tests command"
assert_stdout_contains "exit codes:" "--help exit-code section"
assert_stderr_empty "--help"

run_case help
assert_rc 0 "help"
assert_stdout_contains "usage:" "help usage header"
assert_stdout_contains "mcc --version" "help version command"
assert_stderr_empty "help"

run_case --version
assert_rc 0 "--version"
if ! grep -Eq '^mcc 0\.7\.0-dev$' "$OUT"; then
    echo "FAIL: mcc-cli-test — unexpected --version stdout"
    cat "$OUT"
    exit 1
fi
assert_stderr_empty "--version"

run_case
assert_rc 1 "missing command"
assert_stdout_empty "missing command"
assert_stderr_contains "usage:" "missing-command usage"

run_case check
assert_rc 1 "missing file"
assert_stdout_empty "missing file"
assert_stderr_contains "usage:" "missing-file usage"

run_case --help extra
assert_rc 1 "--help with extra arg"
assert_stdout_empty "--help with extra arg"
assert_stderr_contains "usage:" "--help extra-arg usage"

printf 'export fn main() -> u32 { return 0; }\n' >"$WORK/ok.mc"
run_case check "$WORK/ok.mc" --check
assert_rc 1 "invalid check flag"
assert_stdout_empty "invalid check flag"
assert_stderr_contains "usage:" "invalid check flag usage"

echo "PASS: mcc-cli-test — help/version/usage transcripts are stable"
