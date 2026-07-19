#!/usr/bin/env bash
# Materialize the package selected by build.zig.zon's .paths and prove it retains
# the complete source qualification inputs without relying on .git metadata.
set -euo pipefail

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
W="$(mktemp -d)"
CACHE="$W/cache"
OUT="$W/source"

[ ! -e "$HERE/zig-pkg" ] || { echo "FAIL: source-package-test - stale $HERE/zig-pkg blocks safe packaging"; exit 1; }
cleanup() {
    [ ! -e "$HERE/zig-pkg" ] || find "$HERE/zig-pkg" -depth -delete
    [ ! -e "$W" ] || find "$W" -depth -delete
}
trap cleanup EXIT

hash="$(cd "$HERE" && zig fetch --global-cache-dir "$CACHE" .)"
archive="$CACHE/p/$hash.tar.gz"
[ -f "$archive" ] || { echo "FAIL: source-package-test - zig fetch did not create $archive"; exit 1; }
mkdir -p "$OUT"
tar -xzf "$archive" -C "$OUT" --strip-components=1

for path in build.zig build.zig.zon src tests selfhost third_party editors .github/workflows/ci.yml \
    Dockerfile docker-compose.yml SECURITY.md STABILITY.md CHANGELOG.md THIRD-PARTY-LICENSES.md; do
    [ -e "$OUT/$path" ] || { echo "FAIL: source-package-test - package omitted $path"; exit 1; }
done
[ ! -e "$OUT/.git" ] || { echo "FAIL: source-package-test - package unexpectedly contains .git"; exit 1; }

( cd "$OUT" && zig build test && zig build release-metadata-test )
echo "PASS: source-package-test - fetched source package is Git-independent and passes unit/release metadata gates"
