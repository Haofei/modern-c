#!/usr/bin/env bash
# Installed-layout import fallback smoke test for --std-dir and MC_PATH.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
case "$MCC" in
    /*) MCC_ABS="$MCC" ;;
    *) MCC_ABS="$PWD/$MCC" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/app"
LIB_ROOT="$WORK/install/lib/mc"
STD_DIR="$LIB_ROOT/std"
mkdir -p "$APP" "$STD_DIR"

cat >"$STD_DIR/answer.mc" <<'MC'
export fn installed_answer() -> u32 {
    return 42;
}
MC

cat >"$APP/main.mc" <<'MC'
import "std/answer.mc";

export fn main() -> u32 {
    return installed_answer();
}
MC

run_from_app() {
    (cd "$APP" && "$MCC_ABS" "$@")
}

if ! run_from_app check main.mc --std-dir="$STD_DIR" >/dev/null 2>&1; then
    echo "FAIL: install-layout-test — --std-dir did not resolve import \"std/answer.mc\" from installed std dir"
    exit 1
fi

if ! (cd "$APP" && MC_PATH="$LIB_ROOT" "$MCC_ABS" check main.mc) >/dev/null 2>&1; then
    echo "FAIL: install-layout-test — MC_PATH lib root did not resolve import \"std/answer.mc\""
    exit 1
fi

if ! (cd "$APP" && MC_PATH="$WORK/missing:$STD_DIR" "$MCC_ABS" check main.mc) >/dev/null 2>&1; then
    echo "FAIL: install-layout-test — MC_PATH path list with std-dir entry did not resolve import \"std/answer.mc\""
    exit 1
fi

OUTSIDE="$WORK/outside.mc"
cat >"$OUTSIDE" <<'MC'
export fn outside_answer() -> u32 {
    return 7;
}
MC

cat >"$APP/bad_abs.mc" <<MC
import "$OUTSIDE";

export fn main() -> u32 {
    return outside_answer();
}
MC

sandbox_output=""
if sandbox_output=$(cd "$APP" && MC_PATH="$LIB_ROOT" "$MCC_ABS" check bad_abs.mc 2>&1); then
    echo "FAIL: install-layout-test — absolute import outside sandbox unexpectedly succeeded with MC_PATH set"
    exit 1
fi
if ! grep -Fq "bad_abs.mc:1:1: error: E_IMPORT_OUTSIDE_SANDBOX" <<<"$sandbox_output"; then
    echo "FAIL: install-layout-test — outside-sandbox diagnostic did not point at absolute import"
    printf '%s\n' "$sandbox_output"
    exit 1
fi
if ! grep -Fq "$OUTSIDE" <<<"$sandbox_output"; then
    echo "FAIL: install-layout-test — outside-sandbox diagnostic did not mention candidate path"
    printf '%s\n' "$sandbox_output"
    exit 1
fi

INSTALLED_OUTSIDE="$WORK/installed-outside.mc"
cat >"$INSTALLED_OUTSIDE" <<'MC'
export fn installed_escape() -> u32 {
    return 11;
}
MC
ln -s "$INSTALLED_OUTSIDE" "$STD_DIR/escape.mc"
cat >"$APP/bad_installed_symlink.mc" <<'MC'
import "std/escape.mc";

export fn main() -> u32 {
    return installed_escape();
}
MC

installed_symlink_output=""
if installed_symlink_output=$(run_from_app check bad_installed_symlink.mc --std-dir="$STD_DIR" 2>&1); then
    echo "FAIL: install-layout-test — installed std symlink outside its root unexpectedly succeeded"
    exit 1
fi
if ! grep -Fq "bad_installed_symlink.mc:1:1: error: E_IMPORT_OUTSIDE_SANDBOX" <<<"$installed_symlink_output"; then
    echo "FAIL: install-layout-test — installed-root symlink escape diagnostic was missing"
    printf '%s\n' "$installed_symlink_output"
    exit 1
fi
if ! grep -Fq "$INSTALLED_OUTSIDE" <<<"$installed_symlink_output"; then
    echo "FAIL: install-layout-test — installed-root symlink diagnostic did not mention resolved target"
    printf '%s\n' "$installed_symlink_output"
    exit 1
fi

echo "PASS: install-layout-test — --std-dir and MC_PATH fallbacks preserve explicit and symlink-resolved import containment"
