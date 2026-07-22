#!/usr/bin/env bash
# Formatter gate for `mcc fmt`. The formatter is token-preserving by construction (it rewrites
# leading indentation / trailing whitespace, collapses blank lines, and normalizes conservative
# intra-line token spacing), so this gate proves exactly that across the real corpus, plus
# idempotence and the `--check` contract:
#
#   1. Token preservation — for every std/ and tests/spec/ and tests/c_emit/ module, the
#      formatted output lexes to the SAME token sequence as the input (positions aside). So
#      formatting can never drop, add, or reorder a token.
#   2. Idempotence — `fmt(fmt(x)) == fmt(x)` for every module.
#   3. --check — a freshly formatted file passes `fmt --check` (exit 0); a misindented file
#      fails it (nonzero) and reformats to the expected canonical text.
#
# Needs only mcc.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# Token sequence of a file (kinds + lexemes, source positions stripped). `mcc lex` writes to
# stderr, so capture 2>&1.
toks() { "$MCC" lex "$1" 2>&1 | sed -E 's/^[^ ]+:[0-9]+:[0-9]+: //'; }

# `mcc fmt` formats a single file (it does not flatten imports), but `mcc lex` DOES resolve
# `import "..."` relative to the file's directory. So the formatted copy used for the token
# check is written as a sibling of the original — same directory — so its imports resolve
# identically and only the top file's tokens are being compared.
TMPS=()
cleanup_tmps() { for t in ${TMPS[@]+"${TMPS[@]}"}; do rm -f "$t"; done; }
trap 'cleanup_tmps; rm -rf "$W"' EXIT

checked=0
while IFS= read -r f; do
    # `mcc lex` resolves imports. Intentional missing-import reject fixtures are diagnostic
    # tests, not formatter corpus members; diagnostics-test owns them.
    if grep -q 'EXPECT_ERROR: E_IMPORT_' "$f"; then
        continue
    fi
    checked=$((checked + 1))
    sib="$(dirname "$f")/.mcfmt_check_$$.mc"; TMPS+=("$sib")
    "$MCC" fmt "$f" > "$sib" 2>/dev/null || { echo "FAIL: fmt-test — fmt errored on $f"; exit 1; }
    "$MCC" fmt "$sib" > "$W/f2" 2>/dev/null || { echo "FAIL: fmt-test — fmt errored re-formatting $f"; exit 1; }
    # 2. idempotence
    if ! cmp -s "$sib" "$W/f2"; then
        echo "FAIL: fmt-test — not idempotent on $f"; diff "$sib" "$W/f2" | head; exit 1
    fi
    # 1. token preservation (both lexed in the same directory, so imports resolve identically)
    toks "$f"   > "$W/t_orig"
    toks "$sib" > "$W/t_fmt"
    if ! cmp -s "$W/t_orig" "$W/t_fmt"; then
        echo "FAIL: fmt-test — formatting changed the token stream of $f"; diff "$W/t_orig" "$W/t_fmt" | head; exit 1
    fi
    rm -f "$sib"
done < <(find "$HERE/std" "$HERE/tests/spec" "$HERE/tests/c_emit" -name '*.mc' | LC_ALL=C sort)

# 3. --check contract on a deliberately misindented input.
printf 'fn  f( a: u32 )->u32{\n  let x:u32=a+1;\n        return f( x,2 );\n}\n' > "$W/messy.mc"
if "$MCC" fmt "$W/messy.mc" --check >/dev/null 2>&1; then
    echo "FAIL: fmt-test — fmt --check accepted a misindented file"; exit 1
fi
"$MCC" fmt "$W/messy.mc" > "$W/messy.fmt" 2>/dev/null
# The canonical formatting: body at one level, closer at column 0, and conservative token
# spacing within ordinary code lines.
cat > "$W/messy.want" <<'EXPECTED'
fn f(a: u32) -> u32 {
    let x: u32 = a + 1;
    return f(x, 2);
}
EXPECTED
if ! cmp -s "$W/messy.fmt" "$W/messy.want"; then
    echo "FAIL: fmt-test — reindentation did not match expected canonical output"; diff "$W/messy.want" "$W/messy.fmt"; exit 1
fi
# A formatted file passes --check.
if ! "$MCC" fmt "$W/messy.fmt" --check >/dev/null 2>&1; then
    echo "FAIL: fmt-test — fmt --check rejected an already-formatted file"; exit 1
fi

echo "PASS: fmt-test — fmt is token-preserving and idempotent across $checked modules; --check passes formatted / fails misindented input"
