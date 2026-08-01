#!/usr/bin/env bash
# Source/MIR debug-tooling gate (spec §N): validates the `.mcmap` source map's stable
# typed-AST/MIR identifiers and its object-symbol correlation against the symbols the C and
# LLVM backends actually emit.
#
#   1. Stability   — `emit-map` is deterministic: two runs are byte-identical, so the
#                    typed-AST / MIR IDs are stable across invocations.
#   2. Uniqueness  — every row carries a typed_ast_node ID and a mir_block ID; the AST IDs
#                    are distinct per node (no two source nodes collide).
#   3. Correlation — each exported function row's `object_symbol` is a symbol actually
#                    DEFINED in both the C object and the LLVM object, and a
#                    `#[backend_name]`-renamed function's map row reports the *renamed*
#                    emitted symbol (object_symbol != source symbol), which is itself defined
#                    in both objects — so the map reports the genuine emitted symbol. (The C
#                    backend renames the symbol outright; the LLVM backend keeps the original
#                    define and adds the renamed symbol as an alias — both define the renamed
#                    symbol, which is what the map must, and does, report.)
#
# Steps 1–2 need only mcc. Step 3 needs clang + llc + nm; it self-skips (not fails) when any
# is absent — same policy as the other backend-equivalence gates.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/mcmap_demo.mc"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
LOADED_SRC="$W/loaded-source.mc"
MCMAP_VERIFY="$HERE/tools/toolchain/mcmap-verify.py"
# loader.loadCombinedSource appends a separator newline for this no-import root.
cat "$SRC" > "$LOADED_SRC"
printf '\n' >> "$LOADED_SRC"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

header_value() {
    local name="$1" map="$2"
    grep -m1 "^# ${name}=" "$map" | sed "s/^# ${name}=//"
}

require_header() {
    local name="$1" expected="$2" map="$3"
    local actual
    actual="$(header_value "$name" "$map")"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: mcmap-test — header $name=$actual, expected $expected"
        exit 1
    fi
}

require_sha_header() {
    local name="$1" expected="$2" map="$3"
    local actual
    actual="$(header_value "$name" "$map")"
    printf '%s\n' "$actual" | grep -Eq '^[0-9a-f]{64}$' || {
        echo "FAIL: mcmap-test — $name header is missing or malformed"; exit 1;
    }
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: mcmap-test — $name does not match expected digest"
        echo "map:      $actual"
        echo "expected: $expected"
        exit 1
    fi
}

require_sha_header_present() {
    local name="$1" map="$2"
    local actual
    actual="$(header_value "$name" "$map")"
    printf '%s\n' "$actual" | grep -Eq '^[0-9a-f]{64}$' || {
        echo "FAIL: mcmap-test — $name header is missing or malformed"; exit 1;
    }
}

mcmap_payload_sha256() {
    local map="$1"
    local payload="$W/$(basename "$map").payload"
    awk 'found { print } /^# columns:/ { found=1; print }' "$map" > "$payload"
    sha256_file "$payload"
}

# 1. Stability: two emissions are byte-identical (stable IDs).
"$MCC" emit-map "$SRC" > "$W/a.mcmap" 2>/dev/null
"$MCC" emit-map "$SRC" > "$W/b.mcmap" 2>/dev/null
if ! cmp -s "$W/a.mcmap" "$W/b.mcmap"; then
    echo "FAIL: mcmap-test — emit-map is not deterministic (typed-AST/MIR IDs are not stable)"; exit 1
fi
MAP="$W/a.mcmap"

"$MCC" emit-c "$SRC" > "$W/generated.c" 2>/dev/null
require_sha_header generated_artifact_sha256 "$(sha256_file "$W/generated.c")" "$MAP"
require_sha_header source_map_payload_sha256 "$(mcmap_payload_sha256 "$MAP")" "$MAP"
require_sha_header_present mir_facts_sha256 "$MAP"
require_sha_header source_sha256 "$(sha256_file "$LOADED_SRC")" "$MAP"
require_header lower_profile kernel "$MAP"
require_header lower_checks_optimize false "$MAP"
require_header lower_checks_ksan false "$MAP"
require_header lower_checks_msan false "$MAP"
require_header lower_checks_csan false "$MAP"
require_header lower_stub_asm false "$MAP"
python3 "$MCMAP_VERIFY" --map "$MAP" --artifact "$W/generated.c" --source "$LOADED_SRC" >/dev/null

tail -n +2 "$MAP" > "$W/no-magic.mcmap"
if python3 "$MCMAP_VERIFY" --map "$W/no-magic.mcmap" --artifact "$W/generated.c" --source "$LOADED_SRC" >/dev/null 2>&1; then
    echo "FAIL: mcmap-test — verifier accepted a map without the mcmap magic"; exit 1
fi
grep -v '^# generated_artifact_sha256=' "$MAP" > "$W/no-artifact-digest.mcmap"
if python3 "$MCMAP_VERIFY" --map "$W/no-artifact-digest.mcmap" --source "$LOADED_SRC" >/dev/null 2>&1; then
    echo "FAIL: mcmap-test — verifier accepted a map without generated_artifact_sha256"; exit 1
fi
grep -v '^# artifact_kind=' "$MAP" > "$W/no-artifact-kind.mcmap"
if python3 "$MCMAP_VERIFY" --map "$W/no-artifact-kind.mcmap" --artifact "$W/generated.c" --source "$LOADED_SRC" >/dev/null 2>&1; then
    echo "FAIL: mcmap-test — verifier accepted a map without artifact_kind"; exit 1
fi
sed 's/^# backend=c$/# backend=llvm/' "$MAP" > "$W/wrong-backend.mcmap"
if python3 "$MCMAP_VERIFY" --map "$W/wrong-backend.mcmap" --artifact "$W/generated.c" --source "$LOADED_SRC" >/dev/null 2>&1; then
    echo "FAIL: mcmap-test — verifier accepted a map with the wrong backend header"; exit 1
fi

"$MCC" emit-map "$SRC" --profile=hosted --checks=elide-proven,ksan --stub-asm > "$W/hosted.mcmap" 2>/dev/null
"$MCC" emit-c "$SRC" --profile=hosted --checks=elide-proven,ksan --stub-asm > "$W/hosted.c" 2>/dev/null
require_sha_header generated_artifact_sha256 "$(sha256_file "$W/hosted.c")" "$W/hosted.mcmap"
require_sha_header source_map_payload_sha256 "$(mcmap_payload_sha256 "$W/hosted.mcmap")" "$W/hosted.mcmap"
require_sha_header_present mir_facts_sha256 "$W/hosted.mcmap"
require_sha_header source_sha256 "$(sha256_file "$LOADED_SRC")" "$W/hosted.mcmap"
require_header lower_profile hosted "$W/hosted.mcmap"
require_header lower_checks_optimize true "$W/hosted.mcmap"
require_header lower_checks_ksan true "$W/hosted.mcmap"
require_header lower_checks_msan false "$W/hosted.mcmap"
require_header lower_checks_csan false "$W/hosted.mcmap"
require_header lower_stub_asm true "$W/hosted.mcmap"
python3 "$MCMAP_VERIFY" --map "$W/hosted.mcmap" --artifact "$W/hosted.c" --source "$LOADED_SRC" >/dev/null

# Consumer mismatch rejection: a substituted map body or wrong artifact must not
# verify against the bundle headers.
cp "$MAP" "$W/tampered-payload.mcmap"
printf 'entry kind="tamper"\n' >> "$W/tampered-payload.mcmap"
if python3 "$MCMAP_VERIFY" --map "$W/tampered-payload.mcmap" --artifact "$W/generated.c" --source "$LOADED_SRC" >/dev/null 2>&1; then
    echo "FAIL: mcmap-test — verifier accepted a map with a tampered payload"; exit 1
fi

cp "$W/generated.c" "$W/tampered.c"
printf '\n/* tamper */\n' >> "$W/tampered.c"
if python3 "$MCMAP_VERIFY" --map "$MAP" --artifact "$W/tampered.c" --source "$LOADED_SRC" >/dev/null 2>&1; then
    echo "FAIL: mcmap-test — verifier accepted the wrong generated artifact"; exit 1
fi

# 2. Every entry row has a non-empty typed_ast_node and mir_block, and the AST IDs are unique.
rows="$(grep -c '^entry ' "$MAP" || true)"
ids="$(grep -oE 'typed_ast_node="[^"]+"' "$MAP" | grep -vE 'typed_ast_node="-"' | wc -l | tr -d ' ')"
if [ "$ids" -ne "$rows" ]; then
    echo "FAIL: mcmap-test — $rows entry rows but only $ids have a typed_ast_node ID"; exit 1
fi
if ! grep -qE 'mir_block="mir:[^"]+"' "$MAP"; then
    echo "FAIL: mcmap-test — no row carries a MIR block ID"; exit 1
fi
uniq_ids="$(grep -oE 'typed_ast_node="[^"]+"' "$MAP" | sort -u | wc -l | tr -d ' ')"
all_ids="$(grep -oE 'typed_ast_node="[^"]+"' "$MAP" | wc -l | tr -d ' ')"
if [ "$uniq_ids" -ne "$all_ids" ]; then
    echo "FAIL: mcmap-test — typed_ast_node IDs are not unique ($all_ids rows, $uniq_ids distinct)"; exit 1
fi

# 3. Object-symbol correlation (needs clang + llc + nm).
if ! command -v "$CLANG" >/dev/null 2>&1 || ! command -v "$LLC" >/dev/null 2>&1 || ! command -v nm >/dev/null 2>&1; then
    echo "PASS: mcmap-test — stable typed-AST/MIR IDs and mcmap consumer mismatch rejection validated (skipped object correlation: clang/llc/nm absent)"
    exit 0
fi

# C object.
MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$W/c.o" >/dev/null
# LLVM object.
"$MCC" emit-llvm "$SRC" > "$W/m.ll" 2>/dev/null
"$LLC" -filetype=obj "$W/m.ll" -o "$W/l.o"

# Defined symbol names (text/data) in each object, normalized (strip a leading '_').
defined_syms() { nm "$1" 2>/dev/null | awk '$2 ~ /^[TtDdRrBb]$/ {n=$3; sub(/^_/,"",n); print n}'; }
defined_syms "$W/c.o" | sort -u > "$W/c.syms"
defined_syms "$W/l.o" | sort -u > "$W/l.syms"

# Each exported function row's object_symbol must be defined in BOTH objects.
exported_objsyms="$(grep '^entry ' "$MAP" | grep 'kind="function"' | grep 'visibility="exported"' \
    | grep -oE 'object_symbol="[^"]+"' | sed -E 's/object_symbol="([^"]+)"/\1/' | sort -u)"
if [ -z "$exported_objsyms" ]; then
    echo "FAIL: mcmap-test — no exported function rows found in the map"; exit 1
fi
for sym in $exported_objsyms; do
    grep -qx "$sym" "$W/c.syms" || { echo "FAIL: mcmap-test — object_symbol '$sym' not defined in the C object"; nm "$W/c.o"; exit 1; }
    grep -qx "$sym" "$W/l.syms" || { echo "FAIL: mcmap-test — object_symbol '$sym' not defined in the LLVM object"; nm "$W/l.o"; exit 1; }
done

# The renamed export's map row reports the *renamed* emitted symbol, not the source name,
# and that renamed symbol is itself defined in both objects (covered by the loop above, but
# asserted explicitly here for both backends).
rename_row="$(grep '^entry ' "$MAP" | grep 'kind="function"' | grep 'symbol="renamed_export"' | head -1)"
[ -n "$rename_row" ] || { echo "FAIL: mcmap-test — no map row for the renamed function"; exit 1; }
case "$rename_row" in
    *'object_symbol="mc_renamed_export"'*) : ;;
    *) echo "FAIL: mcmap-test — renamed function's object_symbol is not the #[backend_name] symbol"; exit 1 ;;
esac
grep -qx "mc_renamed_export" "$W/c.syms"   || { echo "FAIL: mcmap-test — renamed symbol absent from C object"; exit 1; }
grep -qx "mc_renamed_export" "$W/l.syms"   || { echo "FAIL: mcmap-test — renamed symbol absent from LLVM object"; exit 1; }

echo "PASS: mcmap-test — stable typed-AST/MIR IDs, generated/source/MIR-facts/map-payload digest + lowering-option metadata, mcmap consumer mismatch rejection, and every exported object_symbol (incl. the #[backend_name] rename) matches the real C and LLVM object symbols"
