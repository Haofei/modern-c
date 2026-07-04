#!/usr/bin/env bash
# Transcript gate for top-level mcc help/version/usage behavior.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
case "$MCC" in
    /*) ;;
    *) MCC="$PWD/$MCC" ;;
esac

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
    if ! grep -Fq -- "$needle" "$OUT"; then
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
    if ! grep -Fq -- "$needle" "$ERR"; then
        echo "FAIL: mcc-cli-test — missing stderr $label"
        echo "expected substring: $needle"
        echo "stderr:"
        cat "$ERR"
        exit 1
    fi
}

assert_stderr_not_contains() {
    local needle="$1"
    local label="$2"
    if grep -Fq -- "$needle" "$ERR"; then
        echo "FAIL: mcc-cli-test — unexpected stderr $label"
        echo "unexpected substring: $needle"
        echo "stderr:"
        cat "$ERR"
        exit 1
    fi
}

assert_stderr_starts_with() {
    local needle="$1"
    local label="$2"
    local first_line
    first_line="$(head -n 1 "$ERR")"
    if [ "$first_line" != "$needle" ]; then
        echo "FAIL: mcc-cli-test — unexpected stderr start for $label"
        echo "expected first line: $needle"
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
assert_stdout_contains "mcc build <file.mc> -o <exe>" "--help build command"
assert_stdout_contains "--remap-prefix=FROM=TO" "--help remap-prefix option"
assert_stdout_contains "--std-dir=<dir>" "--help installed std-dir option"
assert_stdout_contains "MC_PATH=dir[:dir...]" "--help MC_PATH fallback"
assert_stdout_contains "or - to read MC source from stdin" "--help stdin input"
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
assert_stderr_starts_with 'error: option --check is not valid for command `check`' "invalid check flag"
assert_stderr_contains "usage:" "invalid check flag usage"

run_case check "$WORK/ok.mc" --definitely-bad
assert_rc 1 "unknown check flag"
assert_stdout_empty "unknown check flag"
assert_stderr_starts_with "error: unknown option: --definitely-bad" "unknown check flag"
assert_stderr_contains "usage:" "unknown check flag usage"

mkdir -p "$WORK/std"
run_case fmt "$WORK/ok.mc" --std-dir="$WORK/std"
assert_rc 1 "invalid std-dir for fmt"
assert_stdout_empty "invalid std-dir for fmt"
assert_stderr_contains "usage:" "invalid std-dir for fmt usage"

run_case check "$WORK/ok.mc" --remap-prefix="$WORK=/src"
assert_rc 1 "invalid remap-prefix for check"
assert_stdout_empty "invalid remap-prefix for check"
assert_stderr_contains "usage:" "invalid remap-prefix usage"

MISSING="$WORK/missing-root.mc"
run_case check "$MISSING"
assert_rc 1 "missing root input"
assert_stdout_empty "missing root input"
assert_stderr_starts_with "error: unable to read input \"$MISSING\": FileNotFound" "missing root input"
assert_stderr_not_contains "error: FileNotFound" "raw missing root error"
assert_stderr_not_contains "src/main.zig" "missing root Zig stack trace"

set +e
printf 'export fn main() -> u32 { return 0; }\n' | "$MCC" check - >"$OUT" 2>"$ERR"
RC=$?
set -e
assert_rc 0 "stdin input"
assert_stdout_empty "stdin input"
assert_stderr_contains "parsed 1 top-level declarations" "stdin input parse summary"

cat >"$WORK/stdin_lib.mc" <<'MC'
fn helper() -> u32 {
    return 7;
}
MC
set +e
(cd "$WORK" && printf 'import "stdin_lib.mc";\nexport fn main() -> u32 { return helper(); }\n' | "$MCC" check - >"$OUT" 2>"$ERR")
RC=$?
set -e
assert_rc 0 "stdin input with relative import"
assert_stdout_empty "stdin input with relative import"
assert_stderr_contains "parsed 2 top-level declarations" "stdin import parse summary"

set +e
printf 'export fn main() -> u32 { return nope; }\n' | "$MCC" check - >"$OUT" 2>"$ERR"
RC=$?
set -e
assert_rc 1 "stdin diagnostic"
assert_stdout_empty "stdin diagnostic"
assert_stderr_contains "-:1:" "stdin diagnostic location"
assert_stderr_contains "E_UNKNOWN_IDENTIFIER" "stdin diagnostic code"
assert_stderr_not_contains "src/main.zig" "stdin diagnostic Zig stack trace"

set +e
"$MCC" check - </dev/null >"$OUT" 2>"$ERR"
RC=$?
set -e
assert_rc 0 "empty stdin input"
assert_stdout_empty "empty stdin input"
assert_stderr_contains "parsed 0 top-level declarations" "empty stdin parse summary"

echo "PASS: mcc-cli-test — help/version/usage transcripts are stable"
