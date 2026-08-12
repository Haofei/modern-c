#!/usr/bin/env bash
set -euo pipefail

MCC=${1:-zig-out/bin/mcc}
ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT_DIR/tests/toolchain/list_tests_root.mc"

OUT=$("$MCC" list-tests "$SRC")

if ! grep -Fxq "root_test" <<<"$OUT"; then
    echo "FAIL: mcc-list-tests-modules-test — root test was not listed"
    echo "$OUT"
    exit 1
fi

if ! grep -Fxq "imported_test" <<<"$OUT"; then
    echo "FAIL: mcc-list-tests-modules-test — imported test was not listed from per-file resolved modules"
    echo "$OUT"
    exit 1
fi

COUNT=$(grep -Ec '^(root_test|imported_test)$' <<<"$OUT")
if [ "$COUNT" -ne 2 ]; then
    echo "FAIL: mcc-list-tests-modules-test — expected exactly root_test and imported_test once"
    echo "$OUT"
    exit 1
fi

echo "PASS: mcc-list-tests-modules-test — list-tests consumes per-file resolved modules including imports"
