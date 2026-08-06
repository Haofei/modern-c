#!/usr/bin/env bash
# Smoke test for the installed `mcc build <file.mc> -o <exe>` launcher path.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
CLANG="${CLANG:-clang}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
MCMAP_VERIFY="$HERE/tools/toolchain/mcmap-verify.py"

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: mcc-build-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/ok.mc" <<'MC'
export fn main() -> u32 {
    return 7;
}
MC

cat >"$WORK/void_main.mc" <<'MC'
export fn main() -> void {
}
MC

cat >"$WORK/no_main.mc" <<'MC'
export fn not_main() -> u32 {
    return 9;
}
MC

cat >"$WORK/nine.mc" <<'MC'
export fn main() -> u32 {
    return 9;
}
MC

"$MCC" build "$WORK/ok.mc" -o "$WORK/ok" >"$WORK/build.out" 2>"$WORK/build.err"

set +e
"$WORK/ok" >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -ne 7 ]; then
    echo "FAIL: mcc-build-test - built executable exited $RC, want 7"
    cat "$WORK/build.out"
    cat "$WORK/build.err"
    exit 1
fi
if [ ! -s "$WORK/ok.mcmeta" ]; then
    echo "FAIL: mcc-build-test - build did not create executable metadata sidecar"
    exit 1
fi
"$MCC" emit-c "$WORK/ok.mc" --profile=hosted -o "$WORK/ok.raw.c" >/dev/null 2>"$WORK/emit-c.err"
python3 "$MCMAP_VERIFY" --metadata "$WORK/ok.mcmeta" --artifact "$WORK/ok" --source-map-artifact "$WORK/ok.raw.c" --artifact-kind host-executable --backend c >/dev/null
cp "$WORK/ok" "$WORK/ok-mutated"
printf '\n# stale metadata probe\n' >>"$WORK/ok-mutated"
if python3 "$MCMAP_VERIFY" --metadata "$WORK/ok.mcmeta" --artifact "$WORK/ok-mutated" --artifact-kind host-executable --backend c >/dev/null 2>&1; then
    echo "FAIL: mcc-build-test - metadata verifier accepted a stale executable sidecar for different artifact bytes"
    cat "$WORK/ok.mcmeta"
    exit 1
fi
if python3 "$MCMAP_VERIFY" --metadata "$WORK/ok.mcmeta" --artifact "$WORK/ok" --artifact-kind c --backend c >/dev/null 2>&1; then
    echo "FAIL: mcc-build-test - metadata verifier accepted executable sidecar as C source"
    cat "$WORK/ok.mcmeta"
    exit 1
fi
grep -Fq "# artifact_kind=host-executable" "$WORK/ok.mcmeta" || {
    echo "FAIL: mcc-build-test - build metadata missing artifact kind"; cat "$WORK/ok.mcmeta"; exit 1;
}
grep -Fq "# toolchain_identity=" "$WORK/ok.mcmeta" || {
    echo "FAIL: mcc-build-test - build metadata missing toolchain identity"; cat "$WORK/ok.mcmeta"; exit 1;
}
grep -Eq "# toolchain_identity=.*sha256=[0-9a-f]{64}" "$WORK/ok.mcmeta" || {
    echo "FAIL: mcc-build-test - build metadata missing clang executable digest"; cat "$WORK/ok.mcmeta"; exit 1;
}
grep -Eq "# source_map_generated_artifact_sha256=[0-9a-f]{64}" "$WORK/ok.mcmeta" || {
    echo "FAIL: mcc-build-test - build metadata missing source-map generated artifact digest"; cat "$WORK/ok.mcmeta"; exit 1;
}
grep -Eq "# source_map_payload_sha256=[0-9a-f]{64}" "$WORK/ok.mcmeta" || {
    echo "FAIL: mcc-build-test - build metadata missing source-map payload digest"; cat "$WORK/ok.mcmeta"; exit 1;
}
grep -Eq "# mir_facts_sha256=[0-9a-f]{64}" "$WORK/ok.mcmeta" || {
    echo "FAIL: mcc-build-test - build metadata missing MIR facts digest"; cat "$WORK/ok.mcmeta"; exit 1;
}

"$MCC" build "$WORK/void_main.mc" -o "$WORK/void-main" >"$WORK/void-build.out" 2>"$WORK/void-build.err"
set +e
"$WORK/void-main" >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    echo "FAIL: mcc-build-test - built void main executable exited $RC, want 0"
    cat "$WORK/void-build.out"
    cat "$WORK/void-build.err"
    exit 1
fi

cat >"$WORK/fail-clang.sh" <<'SH'
#!/usr/bin/env bash
set -eu
out="${@: -1}"
if [ -n "$out" ]; then
    printf 'not an executable\n' >"$out"
fi
exit 42
SH
chmod +x "$WORK/fail-clang.sh"

set +e
CLANG="$WORK/fail-clang.sh" "$MCC" build "$WORK/ok.mc" -o "$WORK/ok" >"$WORK/fail-clang.out" 2>"$WORK/fail-clang.err"
RC=$?
"$WORK/ok" >/dev/null 2>&1
OLD_RC=$?
set -e
if [ "$RC" -ne 1 ] || [ "$OLD_RC" -ne 7 ]; then
    echo "FAIL: mcc-build-test - failing clang corrupted an existing executable or returned wrong status (build rc=$RC old rc=$OLD_RC)"
    cat "$WORK/fail-clang.out"
    cat "$WORK/fail-clang.err"
    exit 1
fi
if find "$WORK" -maxdepth 1 -name '*.mc-build-*' | grep -q .; then
    echo "FAIL: mcc-build-test - failing clang leaked temporary build artifacts"
    find "$WORK" -maxdepth 1 -name '*.mc-build-*' -print
    exit 1
fi

rm -f "$WORK/ok.mcmeta"
mkdir "$WORK/ok.mcmeta"
set +e
"$MCC" build "$WORK/nine.mc" -o "$WORK/ok" >"$WORK/metadata-dir.out" 2>"$WORK/metadata-dir.err"
RC=$?
"$WORK/ok" >/dev/null 2>&1
OLD_RC=$?
set -e
if [ "$RC" -ne 1 ] || [ "$OLD_RC" -ne 7 ]; then
    echo "FAIL: mcc-build-test - metadata sidecar failure corrupted an existing executable or returned wrong status (build rc=$RC old rc=$OLD_RC)"
    cat "$WORK/metadata-dir.out"
    cat "$WORK/metadata-dir.err"
    exit 1
fi
if ! grep -Fq "metadata sidecar" "$WORK/metadata-dir.err"; then
    echo "FAIL: mcc-build-test - metadata sidecar preflight did not report the sidecar path"
    cat "$WORK/metadata-dir.out"
    cat "$WORK/metadata-dir.err"
    exit 1
fi
rmdir "$WORK/ok.mcmeta"

mkdir "$WORK/output-dir"
set +e
"$MCC" build "$WORK/nine.mc" -o "$WORK/output-dir" >"$WORK/output-dir.out" 2>"$WORK/output-dir.err"
RC=$?
set -e
if [ "$RC" -ne 1 ]; then
    echo "FAIL: mcc-build-test - directory output target did not fail closed"
    cat "$WORK/output-dir.out"
    cat "$WORK/output-dir.err"
    exit 1
fi
if ! grep -Fq "destination is a directory" "$WORK/output-dir.err"; then
    echo "FAIL: mcc-build-test - directory output preflight did not report directory destination"
    cat "$WORK/output-dir.out"
    cat "$WORK/output-dir.err"
    exit 1
fi
if find "$WORK" -maxdepth 1 -name 'output-dir.mc-build-*' | grep -q .; then
    echo "FAIL: mcc-build-test - directory output failure leaked temporary build artifacts"
    find "$WORK" -maxdepth 1 -name 'output-dir.mc-build-*' -print
    exit 1
fi
if [ -e "$WORK/output-dir.mcmeta" ]; then
    echo "FAIL: mcc-build-test - directory output failure created metadata sidecar"
    ls -la "$WORK/output-dir.mcmeta"
    exit 1
fi

if ! grep -Fq "mcc build: wrote $WORK/ok" "$WORK/build.out"; then
    echo "FAIL: mcc-build-test - build output did not report the executable path"
    cat "$WORK/build.out"
    exit 1
fi

set +e
"$MCC" build "$WORK/ok.mc" >"$WORK/missing-out.out" 2>"$WORK/missing-out.err"
RC=$?
set -e
if [ "$RC" -ne 1 ] || ! grep -Fq "missing -o <exe>" "$WORK/missing-out.err"; then
    echo "FAIL: mcc-build-test - missing -o did not fail with a usage diagnostic"
    cat "$WORK/missing-out.out"
    cat "$WORK/missing-out.err"
    exit 1
fi

set +e
"$MCC" build "$WORK/no_main.mc" -o "$WORK/no-main" >"$WORK/no-main.out" 2>"$WORK/no-main.err"
RC=$?
set -e
if [ "$RC" -ne 1 ] || ! grep -Fq "expected exported no-argument main() entry point" "$WORK/no-main.err"; then
    echo "FAIL: mcc-build-test - missing main did not fail closed with an entry diagnostic"
    cat "$WORK/no-main.out"
    cat "$WORK/no-main.err"
    exit 1
fi

set +e
"$MCC" build "$WORK/ok.mc" "$WORK/void_main.mc" -o "$WORK/two" >"$WORK/two.out" 2>"$WORK/two.err"
RC=$?
set -e
if [ "$RC" -ne 1 ] || ! grep -Fq "multiple input files are not supported" "$WORK/two.err"; then
    echo "FAIL: mcc-build-test - multiple inputs did not fail with a usage diagnostic"
    cat "$WORK/two.out"
    cat "$WORK/two.err"
    exit 1
fi

echo "PASS: mcc-build-test - installed mcc build compiled, ran, and failed closed at its hosted boundary"
