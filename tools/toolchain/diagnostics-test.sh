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

assert_occurrences() {
    local haystack="$1"
    local needle="$2"
    local expected="$3"
    local label="$4"
    local actual
    actual=$(HAYSTACK="$haystack" NEEDLE="$needle" python3 - <<'PY'
import os

print(os.environ["HAYSTACK"].count(os.environ["NEEDLE"]))
PY
)
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: diagnostics-test — unexpected occurrence count for $label"
        echo "expected $expected occurrence(s) of: $needle"
        echo "actual count: $actual"
        echo "actual output:"
        printf '%s\n' "$haystack"
        exit 1
    fi
}

cat >"$WORK/parse_error.mc" <<'MC'
export fn main( -> u32 {
    return 0;
}
MC

parse_output=""
if parse_output=$("$MCC" check "$WORK/parse_error.mc" 2>&1); then
    echo "FAIL: diagnostics-test — parse error unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$parse_output" "expected parameter name" 1 "text parse diagnostic"
assert_not_contains "$parse_output" "src/main.zig" "parse error Zig stack trace"

parse_json=""
if parse_json=$("$MCC" check "$WORK/parse_error.mc" --json); then
    echo "FAIL: diagnostics-test — parse error JSON unexpectedly succeeded"
    exit 1
fi
JSON_OUT="$parse_json" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_OUT"])
diags = payload.get("diagnostics")
assert isinstance(diags, list) and len(diags) == 1, payload
assert diags[0]["code"] == "E_PARSE_EXPECTED_PARAMETER_NAME", diags[0]
assert "expected parameter name" in diags[0]["message"], diags[0]
assert payload["error_count"] == 1 and payload["warning_count"] == 0, payload
PY

cat >"$WORK/lex_error.mc" <<'MC'
export fn main() -> u32 {
    return $;
}
MC

lex_json=""
if lex_json=$("$MCC" check "$WORK/lex_error.mc" --json); then
    echo "FAIL: diagnostics-test — lexer error JSON unexpectedly succeeded"
    exit 1
fi
JSON_OUT="$lex_json" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_OUT"])
diags = payload.get("diagnostics")
assert isinstance(diags, list) and len(diags) >= 1, payload
assert any(d.get("code") == "E_LEX_UNEXPECTED_BYTE" for d in diags), diags
assert payload["error_count"] >= 1 and payload["warning_count"] == 0, payload
PY

cat >"$WORK/nesting_too_deep.mc" <<'MC'
fn nesting_too_deep(p: ??????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????????u32) -> void;
MC

nesting_output=""
if nesting_output=$("$MCC" check "$WORK/nesting_too_deep.mc" 2>&1); then
    echo "FAIL: diagnostics-test — nesting-too-deep unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$nesting_output" "E_NESTING_TOO_DEEP" 1 "text nesting-too-deep diagnostic"
assert_not_contains "$nesting_output" "src/main.zig" "nesting-too-deep Zig stack trace"

nesting_json=""
if nesting_json=$("$MCC" check "$WORK/nesting_too_deep.mc" --json); then
    echo "FAIL: diagnostics-test — nesting-too-deep JSON unexpectedly succeeded"
    exit 1
fi
JSON_OUT="$nesting_json" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_OUT"])
diags = payload.get("diagnostics")
assert isinstance(diags, list) and len(diags) == 1, payload
assert diags[0]["code"] == "E_NESTING_TOO_DEEP", diags[0]
assert payload["error_count"] == 1 and payload["warning_count"] == 0, payload
PY

perl -e 'my $n=700; print "fn main() -> u32 { return ", "(" x $n, "1", ")" x $n, "; }\n"' >"$WORK/nesting_expr_parens.mc"
paren_output=""
if paren_output=$("$MCC" check "$WORK/nesting_expr_parens.mc" 2>&1); then
    echo "FAIL: diagnostics-test — expression nesting unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$paren_output" "E_NESTING_TOO_DEEP" 1 "expression nesting-too-deep diagnostic"
assert_not_contains "$paren_output" "src/main.zig" "expression nesting-too-deep Zig stack trace"

perl -e 'my $n=700; print "fn main() -> bool { return ", "!" x $n, "false; }\n"' >"$WORK/nesting_expr_unary.mc"
unary_output=""
if unary_output=$("$MCC" check "$WORK/nesting_expr_unary.mc" 2>&1); then
    echo "FAIL: diagnostics-test — unary nesting unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$unary_output" "E_NESTING_TOO_DEEP" 1 "unary nesting-too-deep diagnostic"
assert_not_contains "$unary_output" "src/main.zig" "unary nesting-too-deep Zig stack trace"

perl -e 'my $n=700; print "fn nested_blocks() -> void ", "{" x $n, "}" x $n, "\n"' >"$WORK/nesting_blocks.mc"
blocks_output=""
if blocks_output=$("$MCC" check "$WORK/nesting_blocks.mc" 2>&1); then
    echo "FAIL: diagnostics-test — block nesting unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$blocks_output" "E_NESTING_TOO_DEEP" 1 "block nesting-too-deep diagnostic"
assert_not_contains "$blocks_output" "src/main.zig" "block nesting-too-deep Zig stack trace"

perl -e 'my $n=700; print "fn main(x: u32) -> u32 { return x", " + x" x $n, "; }\n"' >"$WORK/nesting_expr_binary.mc"
binary_output=""
if binary_output=$("$MCC" check "$WORK/nesting_expr_binary.mc" 2>&1); then
    echo "FAIL: diagnostics-test — binary expression nesting unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$binary_output" "E_NESTING_TOO_DEEP" 1 "binary expression nesting-too-deep diagnostic"
assert_not_contains "$binary_output" "src/main.zig" "binary expression nesting-too-deep Zig stack trace"

perl -e 'my $n=700; print "fn main(x: Node) -> u32 { return x", ".next" x $n, "; }\n"' >"$WORK/nesting_expr_member.mc"
member_output=""
if member_output=$("$MCC" check "$WORK/nesting_expr_member.mc" 2>&1); then
    echo "FAIL: diagnostics-test — member expression nesting unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$member_output" "E_NESTING_TOO_DEEP" 1 "member expression nesting-too-deep diagnostic"
assert_not_contains "$member_output" "src/main.zig" "member expression nesting-too-deep Zig stack trace"

perl -e 'my $n=700; print "type TooDeepMember = A", ".B" x $n, ";\n"' >"$WORK/nesting_type_member.mc"
type_member_output=""
if type_member_output=$("$MCC" check "$WORK/nesting_type_member.mc" 2>&1); then
    echo "FAIL: diagnostics-test — type member nesting unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$type_member_output" "E_NESTING_TOO_DEEP" 1 "type member nesting-too-deep diagnostic"
assert_not_contains "$type_member_output" "src/main.zig" "type member nesting-too-deep Zig stack trace"

mono_output=""
if mono_output=$("$MCC" check tests/spec/monomorphization_limits.mc 2>&1); then
    echo "FAIL: diagnostics-test — monomorphization limit unexpectedly succeeded"
    exit 1
fi
assert_occurrences "$mono_output" "E_MONOMORPHIZATION_LIMIT" 1 "monomorphization-limit diagnostic"
assert_contains "$mono_output" "required from here:" "monomorphization instantiation chain header"
assert_contains "$mono_output" 'function `runaway__129` required from here' "monomorphization current instantiation"
assert_contains "$mono_output" 'function `runaway__128` required from here' "monomorphization parent instantiation"
assert_contains "$mono_output" "note: ..." "monomorphization bounded chain elision"
assert_not_contains "$mono_output" "src/main.zig" "monomorphization-limit Zig stack trace"

mono_json=""
if mono_json=$("$MCC" check tests/spec/monomorphization_limits.mc --json); then
    echo "FAIL: diagnostics-test — monomorphization limit JSON unexpectedly succeeded"
    exit 1
fi
JSON_OUT="$mono_json" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["JSON_OUT"])
diags = payload.get("diagnostics")
assert isinstance(diags, list) and len(diags) == 1, payload
d = diags[0]
assert d["code"] == "E_MONOMORPHIZATION_LIMIT", d
assert "required from here:" not in d["message"], d
notes = d.get("notes")
assert isinstance(notes, list) and len(notes) >= 3, d
assert notes[0]["message"] == "required from here:", notes
assert notes[1]["message"] == "function `runaway__129` required from here", notes[1]
assert notes[1]["path"].endswith("monomorphization_limits.mc"), notes[1]
assert notes[1]["line"] == 13 and notes[1]["column"] == 16, notes[1]
assert any(n.get("message") == "..." for n in notes), notes
assert payload["error_count"] == 1 and payload["warning_count"] == 0, payload
PY

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

cat >"$OUTSIDE" <<'MC'
export fn symlink_escape_value() -> u32 {
    return 9;
}
MC
ln -s "$(dirname "$OUTSIDE")" "$WORK/symlink-outside"
cat >"$WORK/root_symlink_import.mc" <<MC
import "./symlink-outside/$(basename "$OUTSIDE")";

export fn main() -> u32 {
    return symlink_escape_value();
}
MC

symlink_output=""
if symlink_output=$("$MCC" check "$WORK/root_symlink_import.mc" 2>&1); then
    echo "FAIL: diagnostics-test — symlink import outside sandbox unexpectedly succeeded"
    exit 1
fi
assert_contains "$symlink_output" "root_symlink_import.mc:1:1: error: E_IMPORT_OUTSIDE_SANDBOX" "symlink outside-sandbox import diagnostic location"
assert_contains "$symlink_output" "$OUTSIDE" "symlink outside-sandbox resolved target"
assert_not_contains "$symlink_output" "parsed 2 top-level declarations" "symlink outside-sandbox import acceptance"

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
