#!/usr/bin/env bash
set -euo pipefail

MCC=${1:-zig-out/bin/mcc}
ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$ROOT_DIR/tests/toolchain/inspection_modules_root.mc"

FACTS=$("$MCC" facts "$SRC")
INSPECT_IR=$("$MCC" inspect-ir "$SRC")

if ! grep -Fq "fact checked_arithmetic_trap fn=imported_checked op=add" <<<"$FACTS"; then
    echo "FAIL: mcc-inspection-modules-test — mcc facts did not include imported module facts"
    echo "$FACTS"
    exit 1
fi

if ! grep -Fq "ir function name=imported_checked" <<<"$INSPECT_IR"; then
    echo "FAIL: mcc-inspection-modules-test — mcc inspect-ir did not include imported module IR"
    echo "$INSPECT_IR"
    exit 1
fi

echo "PASS: mcc-inspection-modules-test — facts and inspect-ir consume per-file resolved modules including imports"
