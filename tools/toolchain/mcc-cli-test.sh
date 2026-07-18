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
assert_stdout_contains "mcc --help" "--help help command"
assert_stdout_contains "mcc --version" "--help version command"
assert_stdout_contains "mcc explain E_CODE" "--help explain command"
assert_stdout_contains "mcc lex <file.mc>" "--help lex command"
assert_stdout_contains "mcc check <file.mc> [--json]" "--help check command"
assert_stdout_contains "mcc run-trap <file.mc>" "--help run-trap command"
assert_stdout_contains "mcc facts <file.mc>" "--help facts command"
assert_stdout_contains "mcc lower-hir <file.mc>" "--help lower-hir command"
assert_stdout_contains "mcc verify-hir <file.mc>" "--help verify-hir command"
assert_stdout_contains "mcc lower-mir <file.mc> [--checks=all|elide-proven]" "--help lower-mir command"
assert_stdout_contains "mcc verify <file.mc> [--checks=all|elide-proven]" "--help verify command"
assert_stdout_contains "mcc lower-ir <file.mc>" "--help lower-ir command"
assert_stdout_contains "mcc lower-c <file.mc>" "--help lower-c command"
assert_stdout_contains "mcc list-tests <file.mc>" "--help list-tests command"
assert_stdout_contains "mcc emit-c <file.mc> [-o <out.c>]" "--help emit-c output path"
assert_stdout_contains "mcc emit-map <file.mc> [-o <out.mcmap>]" "--help emit-map output path"
assert_stdout_contains "mcc emit-llvm <file.mc> [-o <out.ll>]" "--help emit-llvm output path"
assert_stdout_contains "mcc emit-layout <file.mc> --structs=A,B,C" "--help emit-layout command"
assert_stdout_contains "mcc emit-c-struct <file.mc> --structs=A,B,C" "--help emit-c-struct command"
assert_stdout_contains "mcc fmt <file.mc> [--check]" "--help fmt command"
assert_stdout_contains "mcc symbols <file.mc>" "--help symbols command"
assert_stdout_contains "mcc build <file.mc> -o <exe>" "--help build command"
assert_stdout_contains "--remap-prefix=FROM=TO" "--help remap-prefix option"
assert_stdout_contains "--std-dir=<dir>" "--help installed std-dir option"
assert_stdout_contains "--visibility=legacy|explicit" "--help visibility mode option"
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

run_case version
assert_rc 0 "version"
if ! grep -Eq '^mcc 0\.7\.0-dev$' "$OUT"; then
    echo "FAIL: mcc-cli-test — unexpected version stdout"
    cat "$OUT"
    exit 1
fi
assert_stderr_empty "version"

run_case explain E_UNKNOWN_IDENTIFIER
assert_rc 0 "explain known diagnostic"
assert_stdout_contains "E_UNKNOWN_IDENTIFIER" "explain known diagnostic code"
assert_stdout_contains "messages:" "explain known diagnostic messages"
assert_stdout_contains "unknown identifier" "explain known diagnostic message"
assert_stdout_contains "sources:" "explain known diagnostic sources"
assert_stdout_contains "src/sema.zig" "explain known diagnostic source"
assert_stderr_empty "explain known diagnostic"

run_case explain E_NOT_A_REAL_CODE
assert_rc 1 "explain unknown diagnostic"
assert_stdout_empty "explain unknown diagnostic"
assert_stderr_starts_with "error: unknown diagnostic code: E_NOT_A_REAL_CODE" "explain unknown diagnostic"

run_case explain
assert_rc 1 "explain missing code"
assert_stdout_empty "explain missing code"
assert_stderr_contains "usage:" "explain missing code usage"

run_case explain E_UNKNOWN_IDENTIFIER extra
assert_rc 1 "explain extra arg"
assert_stdout_empty "explain extra arg"
assert_stderr_contains "usage:" "explain extra arg usage"

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

printf 'fn hidden() -> u32 { return 1; }\n' >"$WORK/visibility_lib.mc"
printf 'import "./visibility_lib.mc";\nfn use_hidden() -> u32 { return hidden(); }\n' >"$WORK/visibility_root.mc"
run_case check "$WORK/visibility_root.mc" --visibility=legacy
assert_rc 0 "legacy visibility compatibility"
assert_stderr_empty "legacy visibility compatibility"

run_case check "$WORK/visibility_root.mc" --visibility=explicit
assert_rc 1 "explicit visibility private default"
assert_stderr_contains "E_PRIVATE_IMPORT" "explicit visibility private default"

run_case check "$WORK/visibility_root.mc" --visibility=invalid
assert_rc 1 "invalid visibility mode"
assert_stderr_contains "usage:" "invalid visibility mode usage"

run_case emit-c "$WORK/ok.mc" -o "$WORK/ok.c"
assert_rc 0 "emit-c output path"
assert_stdout_empty "emit-c output path"
assert_stderr_empty "emit-c output path"
if [ ! -s "$WORK/ok.c" ]; then
    echo "FAIL: mcc-cli-test — emit-c -o did not create output"
    exit 1
fi
if ! grep -Fq "mc-profile: kernel" "$WORK/ok.c"; then
    echo "FAIL: mcc-cli-test — emit-c -o output does not look like emitted C"
    cat "$WORK/ok.c"
    exit 1
fi

run_case emit-map "$WORK/ok.mc" -o "$WORK/ok.mcmap"
assert_rc 0 "emit-map output path"
assert_stdout_empty "emit-map output path"
assert_stderr_empty "emit-map output path"
if ! grep -Fq "source_path=" "$WORK/ok.mcmap"; then
    echo "FAIL: mcc-cli-test — emit-map -o output does not look like an mcmap"
    cat "$WORK/ok.mcmap"
    exit 1
fi

run_case emit-llvm "$WORK/ok.mc" -o "$WORK/ok.ll"
assert_rc 0 "emit-llvm output path"
assert_stdout_empty "emit-llvm output path"
assert_stderr_empty "emit-llvm output path"
if ! grep -Fq "define" "$WORK/ok.ll"; then
    echo "FAIL: mcc-cli-test — emit-llvm -o output does not look like LLVM IR"
    cat "$WORK/ok.ll"
    exit 1
fi

run_case emit-c "$WORK/ok.mc" -o
assert_rc 1 "missing output path"
assert_stdout_empty "missing output path"
assert_stderr_contains "usage:" "missing output path usage"

run_case check "$WORK/ok.mc" -o "$WORK/check.c"
assert_rc 1 "invalid output flag for check"
assert_stdout_empty "invalid output flag for check"
assert_stderr_starts_with 'error: option -o is not valid for command `check`' "invalid output flag for check"
assert_stderr_contains "usage:" "invalid output flag for check usage"

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
