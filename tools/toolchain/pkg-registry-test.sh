#!/usr/bin/env bash
# Registry / version-resolution / lockfile gate for the MC package manager (mcc-registry.sh).
# Exercises the full offline flow against a temporary registry built from the fixtures under
# tests/toolchain/pkg/, with no network:
#
#   1. publish     — three mathlib versions (1.0.0, 1.1.0, 2.0.0) into a fresh registry, and
#                    `versions` lists them.
#   2. resolve     — the version policy: `^1.0.0` -> 1.1.0 (highest 1.x), `=1.0.0` -> 1.0.0,
#                    `^2.0.0` -> 2.0.0; an unsatisfiable constraint fails.
#   3. install     — the app's `^1.0.0` dep vendors mathlib 1.1.0 into mc_packages/ and writes
#                    mcpkg.lock pinning 1.1.0 + its checksum.
#   4. reproducible— after publishing a newer 1.2.0, a re-install still uses the LOCKED 1.1.0
#                    (not 1.2.0); deleting the lock then re-installing picks up 1.2.0.
#   5. frozen      — `--frozen` with no lock entry fails; with the lock it succeeds.
#   6. adversarial — traversal/symlink identities and lock drift fail closed.
#   7. build       — the installed tree builds: `mcc-cc app.mc` lowers + compiles the app
#                    against the vendored dependency (needs clang; that step self-skips without).
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
REGTOOL="$HERE/tools/toolchain/mcc-registry.sh"
FIX="$HERE/tests/toolchain/pkg"
CLANG="${CLANG:-clang}"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
REG="$W/registry"
APP="$W/app"
cp -R "$FIX/app" "$APP"          # work on a copy: install writes mc_packages/ + mcpkg.lock

fail() { echo "FAIL: pkg-registry-test — $1"; exit 1; }

# 1. publish + versions
bash "$REGTOOL" publish "$FIX/mathlib-1.0.0" --registry "$REG" >/dev/null
bash "$REGTOOL" publish "$FIX/mathlib-1.1.0" --registry "$REG" >/dev/null
bash "$REGTOOL" publish "$FIX/mathlib-2.0.0" --registry "$REG" >/dev/null
got="$(bash "$REGTOOL" versions mathlib --registry "$REG" | tr '\n' ' ')"
[ "$got" = "1.0.0 1.1.0 2.0.0 " ] || fail "versions listed '$got', expected '1.0.0 1.1.0 2.0.0 '"
# re-publishing an existing version is refused (immutable)
if bash "$REGTOOL" publish "$FIX/mathlib-1.0.0" --registry "$REG" >/dev/null 2>&1; then
    fail "re-publishing an existing version should be refused"
fi

# 2. resolve (version policy)
[ "$(bash "$REGTOOL" resolve mathlib '^1.0.0' --registry "$REG")" = "1.1.0" ] || fail "^1.0.0 should resolve to 1.1.0"
[ "$(bash "$REGTOOL" resolve mathlib '=1.0.0' --registry "$REG")" = "1.0.0" ] || fail "=1.0.0 should resolve to 1.0.0"
[ "$(bash "$REGTOOL" resolve mathlib '^2.0.0' --registry "$REG")" = "2.0.0" ] || fail "^2.0.0 should resolve to 2.0.0"
if bash "$REGTOOL" resolve mathlib '^3.0.0' --registry "$REG" >/dev/null 2>&1; then
    fail "^3.0.0 should be unsatisfiable"
fi

# 3. install -> vendors 1.1.0 + writes lock
bash "$REGTOOL" install "$APP" --registry "$REG" >/dev/null
grep -q '^name = mathlib' "$APP/mc_packages/mathlib/mcpkg.txt" || fail "mathlib not vendored"
grep -q '^version = 1.1.0' "$APP/mc_packages/mathlib/mcpkg.txt" || fail "wrong mathlib version vendored"
awk '$1=="mathlib"{print $2}' "$APP/mcpkg.lock" | grep -qx "1.1.0" || fail "lockfile did not pin mathlib 1.1.0"
grep -q 'return 110;' "$APP/mc_packages/mathlib/mathlib.mc" || fail "vendored source is not the 1.1.0 build"

# 4. reproducibility: publish a newer 1.2.0; a locked re-install must stay on 1.1.0.
bash "$REGTOOL" publish "$FIX/mathlib-1.2.0" --registry "$REG" >/dev/null
[ "$(bash "$REGTOOL" resolve mathlib '^1.0.0' --registry "$REG")" = "1.2.0" ] || fail "^1.0.0 should now resolve to 1.2.0"
bash "$REGTOOL" install "$APP" --registry "$REG" >/dev/null
awk '$1=="mathlib"{print $2}' "$APP/mcpkg.lock" | grep -qx "1.1.0" || fail "locked re-install drifted off 1.1.0"
grep -q '^version = 1.1.0' "$APP/mc_packages/mathlib/mcpkg.txt" || fail "locked re-install vendored the wrong version"
# 4b. dropping the lock lets resolution advance to 1.2.0.
rm -f "$APP/mcpkg.lock"
bash "$REGTOOL" install "$APP" --registry "$REG" >/dev/null
awk '$1=="mathlib"{print $2}' "$APP/mcpkg.lock" | grep -qx "1.2.0" || fail "fresh install did not advance to 1.2.0"

# 5. frozen: with a lock it succeeds; without a matching lock entry it fails.
bash "$REGTOOL" install "$APP" --registry "$REG" --frozen >/dev/null || fail "--frozen with a valid lock should succeed"
rm -f "$APP/mcpkg.lock"
if bash "$REGTOOL" install "$APP" --registry "$REG" --frozen >/dev/null 2>&1; then
    fail "--frozen without a lock entry should fail"
fi
bash "$REGTOOL" install "$APP" --registry "$REG" >/dev/null   # restore a lock (now 1.2.0)

# 6. Adversarial identities cannot write or delete outside managed roots.
EVIL="$W/evil"
mkdir -p "$EVIL" "$W/outside"
printf 'name = ../outside\nversion = 1.0.0\n' > "$EVIL/mcpkg.txt"
printf 'sentinel\n' > "$W/outside/sentinel"
if bash "$REGTOOL" publish "$EVIL" --registry "$REG" >/dev/null 2>&1; then
    fail "publish accepted a traversal package name"
fi
[ -f "$W/outside/sentinel" ] || fail "traversal publish changed an outside sentinel"

for bad in '/absolute' '..' 'bad/name' 'bad\name' 'bad name'; do
    if bash "$REGTOOL" versions "$bad" --registry "$REG" >/dev/null 2>&1; then
        fail "versions accepted invalid package name '$bad'"
    fi
done
for bad in '../1.0.0' '1.0' 'v1.0.0' '1.0.0/path'; do
    printf 'name = invalidversion\nversion = %s\n' "$bad" > "$EVIL/mcpkg.txt"
    if bash "$REGTOOL" publish "$EVIL" --registry "$REG" >/dev/null 2>&1; then
        fail "publish accepted invalid package version '$bad'"
    fi
done

SYMLINK_REG="$W/symlink-reg"
mkdir -p "$SYMLINK_REG" "$W/symlink-target"
ln -s "$W/symlink-target" "$SYMLINK_REG/pkgs"
if bash "$REGTOOL" publish "$FIX/mathlib-1.0.0" --registry "$SYMLINK_REG" >/dev/null 2>&1; then
    fail "publish followed a symlinked registry path"
fi
[ -z "$(find "$W/symlink-target" -mindepth 1 -print -quit)" ] || fail "symlink publish wrote outside the registry"

# A current lock must satisfy the current manifest, including under --frozen.
DRIFT="$W/drift"
cp -R "$FIX/app" "$DRIFT"
bash "$REGTOOL" install "$DRIFT" --registry "$REG" >/dev/null
sed 's/\^1\.0\.0/\^2.0.0/' "$DRIFT/mcpkg.txt" > "$DRIFT/mcpkg.txt.new"
mv "$DRIFT/mcpkg.txt.new" "$DRIFT/mcpkg.txt"
if bash "$REGTOOL" install "$DRIFT" --registry "$REG" >/dev/null 2>&1; then
    fail "install accepted a pinned version outside the manifest constraint"
fi
if bash "$REGTOOL" install "$DRIFT" --registry "$REG" --frozen >/dev/null 2>&1; then
    fail "--frozen accepted manifest/lock constraint drift"
fi
sed 's/\^2\.0\.0/not-a-constraint/' "$DRIFT/mcpkg.txt" > "$DRIFT/mcpkg.txt.new"
mv "$DRIFT/mcpkg.txt.new" "$DRIFT/mcpkg.txt"
if bash "$REGTOOL" install "$DRIFT" --registry "$REG" >/dev/null 2>&1; then
    fail "install accepted a malformed constraint"
fi

VENDOR_LINK="$W/vendor-link-app"
cp -R "$FIX/app" "$VENDOR_LINK"
ln -s "$W/outside" "$VENDOR_LINK/mc_packages"
if bash "$REGTOOL" install "$VENDOR_LINK" --registry "$REG" >/dev/null 2>&1; then
    fail "install accepted a symlinked vendor root"
fi
[ -f "$W/outside/sentinel" ] || fail "symlinked vendor install changed an outside sentinel"

# 7. build the installed tree (needs clang; self-skip without).
if command -v "$CLANG" >/dev/null 2>&1; then
    MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$APP/app.mc" -o "$W/app.o" >/dev/null \
        || fail "the installed package tree did not build"
    echo "PASS: pkg-registry-test — safe publish/resolve/install, constraint-consistent lock/frozen behavior, traversal/symlink rejection, and installed-tree build"
else
    echo "PASS: pkg-registry-test — safe publish/resolve/install, constraint-consistent lock/frozen behavior, traversal/symlink rejection (build step skipped: clang absent)"
fi
