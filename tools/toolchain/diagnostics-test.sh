#!/usr/bin/env bash
# Diagnostics gate for import-aware source locations and CLI failure rendering.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if ! grep -Fq "$needle" <<<"$haystack"; then
        echo "FAIL: diagnostics-test — missing $label"
        echo "expected substring: $needle"
        echo "actual output:"
        printf '%s\n' "$haystack"
        exit 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if grep -Fq "$needle" <<<"$haystack"; then
        echo "FAIL: diagnostics-test — unexpected $label"
        echo "unexpected substring: $needle"
        echo "actual output:"
        printf '%s\n' "$haystack"
        exit 1
    fi
}

cat >"$WORK/root_missing.mc" <<'MC'

// line marker
import "missing/nope.mc";

export fn main() -> u32 {
    return 0;
}
MC

missing_output=""
if missing_output=$("$MCC" check "$WORK/root_missing.mc" 2>&1); then
    echo "FAIL: diagnostics-test — missing import unexpectedly succeeded"
    exit 1
fi
assert_contains "$missing_output" "root_missing.mc:3:1: error: E_IMPORT_NOT_FOUND" "missing-import diagnostic location"
assert_contains "$missing_output" 'cannot find import "missing/nope.mc"' "missing-import diagnostic text"
assert_not_contains "$missing_output" "error: ImportNotFound" "raw Zig ImportNotFound error"
assert_not_contains "$missing_output" "src/main.zig" "Zig stack trace"

OUTSIDE="$(mktemp -t mcc-outside-import.XXXXXX.mc)"
trap 'rm -rf "$WORK"; rm -f "$OUTSIDE"' EXIT
cat >"$OUTSIDE" <<'MC'
export fn outside_value() -> u32 {
    return 7;
}
MC

cat >"$WORK/root_abs_import.mc" <<MC
import "$OUTSIDE";

export fn main() -> u32 {
    return outside_value();
}
MC

sandbox_output=""
if sandbox_output=$("$MCC" check "$WORK/root_abs_import.mc" 2>&1); then
    echo "FAIL: diagnostics-test — absolute import outside sandbox unexpectedly succeeded"
    exit 1
fi
assert_contains "$sandbox_output" "root_abs_import.mc:1:1: error: E_IMPORT_OUTSIDE_SANDBOX" "outside-sandbox import diagnostic location"
assert_contains "$sandbox_output" "outside the import sandbox rooted at" "outside-sandbox import diagnostic text"
assert_not_contains "$sandbox_output" "parsed 2 top-level declarations" "outside-sandbox import acceptance"

cat >"$WORK/root_import.mc" <<'MC'
import "lib.mc";

export fn main() -> u32 {
    return helper();
}
MC

cat >"$WORK/lib.mc" <<'MC'
fn helper() -> u32 {
    return nope;
}
MC

boundary_output=""
if boundary_output=$("$MCC" check "$WORK/root_import.mc" 2>&1); then
    echo "FAIL: diagnostics-test — imported-file semantic error unexpectedly succeeded"
    exit 1
fi
assert_contains "$boundary_output" "lib.mc:2:12: error: E_UNKNOWN_IDENTIFIER" "imported-file diagnostic location"
assert_contains "$boundary_output" "  |     return nope;" "source-line snippet"
assert_contains "$boundary_output" "  |            ^~~~" "caret underline"

printf '\xEF\xBB\xBFexport fn main() -> u32 {\n    return 0;\n}\n' >"$WORK/bom.mc"
if ! "$MCC" check "$WORK/bom.mc" >/dev/null 2>&1; then
    echo "FAIL: diagnostics-test — UTF-8 BOM input did not parse"
    exit 1
fi

echo "PASS: diagnostics-test — import diagnostics, imported-source locations, and UTF-8 BOM handling are stable"
