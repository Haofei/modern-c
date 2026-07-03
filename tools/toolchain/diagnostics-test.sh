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

missing_json=""
if missing_json=$("$MCC" check "$WORK/root_missing.mc" --json); then
    echo "FAIL: diagnostics-test — missing import JSON unexpectedly succeeded"
    exit 1
fi
JSON_OUT="$missing_json" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_OUT"])
diags = payload.get("diagnostics")
assert isinstance(diags, list) and len(diags) == 1, payload
d = diags[0]
assert d["severity"] == "error", d
assert d["code"] == "E_IMPORT_NOT_FOUND", d
assert "cannot find import" in d["message"], d
assert d["path"].endswith("root_missing.mc"), d
assert d["file"] == d["path"], d
assert d["line"] == 3 and d["column"] == 1, d
assert d["span"]["line"] == 3 and d["span"]["column"] == 1, d
assert payload["error_count"] == 1 and payload["warning_count"] == 0, payload
PY

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

boundary_json=""
if boundary_json=$("$MCC" check "$WORK/root_import.mc" --json); then
    echo "FAIL: diagnostics-test — imported-file semantic error JSON unexpectedly succeeded"
    exit 1
fi
JSON_OUT="$boundary_json" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_OUT"])
d = payload["diagnostics"][0]
assert d["severity"] == "error", d
assert d["code"] == "E_UNKNOWN_IDENTIFIER", d
assert "unknown identifier" in d["message"], d
assert d["path"].endswith("lib.mc"), d
assert d["file"] == d["path"], d
assert d["line"] == 2 and d["column"] == 12, d
expected_offset = len("fn helper() -> u32 {\n    return ")
assert d["span"]["offset"] == expected_offset, d
assert d["span"]["line"] == 2 and d["span"]["column"] == 12, d
assert d["span"]["length"] == 4, d
assert d["source"]["text"] == "    return nope;", d
assert d["source"]["highlight_length"] == 4, d
assert d["source"]["caret"] == "^~~~", d
PY

cat >"$WORK/root_import_bom.mc" <<'MC'
import "lib_bom.mc";

export fn main() -> u32 {
    return helper_bom();
}
MC

printf '\xEF\xBB\xBFfn helper_bom() -> u32 {\n    return nope;\n}\n' >"$WORK/lib_bom.mc"

imported_bom_output=""
if imported_bom_output=$("$MCC" check "$WORK/root_import_bom.mc" 2>&1); then
    echo "FAIL: diagnostics-test — imported-file BOM semantic error unexpectedly succeeded"
    exit 1
fi
assert_contains "$imported_bom_output" "lib_bom.mc:2:12: error: E_UNKNOWN_IDENTIFIER" "imported-file BOM diagnostic location"
assert_contains "$imported_bom_output" "  |     return nope;" "imported-file BOM source-line snippet"

cat >"$WORK/backend_unsupported.mc" <<'MC'
export fn main() -> u32 {
    .{ 1, 2 };
    return 0;
}
MC

c_backend_output=""
if c_backend_output=$("$MCC" emit-c "$WORK/backend_unsupported.mc" 2>&1); then
    echo "FAIL: diagnostics-test — unsupported C backend construct unexpectedly succeeded"
    exit 1
fi
assert_contains "$c_backend_output" "backend_unsupported.mc:2:5: error: E_BACKEND_UNSUPPORTED" "C backend unsupported diagnostic location"
assert_contains "$c_backend_output" "  |     .{ 1, 2 };" "C backend unsupported source-line snippet"
assert_contains "$c_backend_output" "  |     ^~~~~~~~~" "C backend unsupported caret underline"
assert_not_contains "$c_backend_output" "UnsupportedCEmission" "raw C backend unsupported error"
assert_not_contains "$c_backend_output" "src/main.zig" "C backend Zig stack trace"

llvm_backend_output=""
if llvm_backend_output=$("$MCC" emit-llvm "$WORK/backend_unsupported.mc" 2>&1); then
    echo "FAIL: diagnostics-test — unsupported LLVM backend construct unexpectedly succeeded"
    exit 1
fi
assert_contains "$llvm_backend_output" "backend_unsupported.mc:2:5: error: E_BACKEND_UNSUPPORTED" "LLVM backend unsupported diagnostic location"
assert_contains "$llvm_backend_output" "  |     .{ 1, 2 };" "LLVM backend unsupported source-line snippet"
assert_contains "$llvm_backend_output" "  |     ^~~~~~~~~" "LLVM backend unsupported caret underline"
assert_not_contains "$llvm_backend_output" "UnsupportedLlvmEmission" "raw LLVM backend unsupported error"
assert_not_contains "$llvm_backend_output" "src/main.zig" "LLVM backend Zig stack trace"

printf '\xEF\xBB\xBFexport fn main() -> u32 {\n    return 0;\n}\n' >"$WORK/bom.mc"
if ! "$MCC" check "$WORK/bom.mc" >/dev/null 2>&1; then
    echo "FAIL: diagnostics-test — UTF-8 BOM input did not parse"
    exit 1
fi

clean_json="$("$MCC" check "$WORK/bom.mc" --json)"
JSON_OUT="$clean_json" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_OUT"])
assert payload == {"diagnostics": [], "error_count": 0, "warning_count": 0}, payload
PY

echo "PASS: diagnostics-test — text and JSON diagnostics, imported-source locations, and UTF-8 BOM handling are stable"
