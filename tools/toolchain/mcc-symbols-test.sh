#!/usr/bin/env bash
# `mcc symbols` index gate: the symbol index is the enabler for the language server's
# navigation features (go-to-definition, references, rename, hover, semantic tokens), so this
# asserts the JSON is well-formed and that identifier references resolve to the right
# declarations: a param use -> its param def, a local use -> its local def, a cross-function
# global read -> the global def, a call -> the function def, a type used as a parameter ->
# the type def, and aggregate fields -> their owner/type metadata. Needs mcc + python3.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/symbols_demo.mc"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
"$MCC" symbols "$SRC" > "$W/idx.json"

python3 - "$W/idx.json" <<'PY'
import json, sys
idx = json.load(open(sys.argv[1]))
defs, refs, fields = idx["defs"], idx["refs"], idx.get("fields", [])

def fail(m):
    print(f"FAIL: mcc-symbols-test — {m}"); sys.exit(1)

def def_named(name, kind=None):
    cands = [d for d in defs if d["name"] == name and (kind is None or d["kind"] == kind)]
    return cands[0] if cands else None

def ref_named(name):
    return [r for r in refs if r["name"] == name]

def field_named(owner, name):
    cands = [f for f in fields if f["owner"] == owner and f["name"] == name]
    return cands[0] if cands else None

# Declarations are all present with the right kinds + stringified types.
add = def_named("add", "function") or fail("no function def 'add'")
if add["type"] != "fn(u32, u32) -> u32":
    fail(f"add type should be 'fn(u32, u32) -> u32', got {add['type']}")
if not def_named("origin", "global"): fail("no global def 'origin'")
if not def_named("Point", "struct"): fail("no struct def 'Point'")
for name in ("x", "y"):
    fld = field_named("Point", name)
    if not fld: fail(f"no field metadata for Point.{name}")
    if fld["owner_kind"] != "struct": fail(f"Point.{name} owner_kind should be struct, got {fld['owner_kind']}")
    if fld["type"] != "u32": fail(f"Point.{name} type should be u32, got {fld['type']}")
for p in ("a", "b", "by", "p"):
    if not def_named(p, "param"): fail(f"no param def '{p}'")
if not def_named("sum", "local"): fail("no local def 'sum'")
shift = def_named("shift", "function")
if shift["type"] != "fn(Point, u32) -> u32":
    fail(f"shift type should name the struct param, got {shift['type']}")

def same_span(a, b):
    return a["line"] == b["line"] and a["col"] == b["col"]

# Each reference resolves to the correct declaration span.
def check_resolves(refname, target_def, what):
    rs = ref_named(refname)
    if not rs: fail(f"no reference '{refname}'")
    if not all(same_span(r["def"], target_def["span"]) for r in rs):
        fail(f"{what}: '{refname}' refs do not all resolve to its def at {target_def['span']}")

check_resolves("add", add, "call -> function def")
check_resolves("origin", def_named("origin"), "cross-function global read")
check_resolves("sum", def_named("sum"), "local use -> local def")
check_resolves("a", def_named("a"), "param use -> param def")
check_resolves("Point", def_named("Point"), "type used as parameter -> type def")

# The param `a` is read inside `add` exactly once (`a + b`).
if len(ref_named("a")) != 1: fail(f"expected 1 reference to 'a', got {len(ref_named('a'))}")
print("PASS: mcc-symbols-test — defs, fields, and stringified types correct; refs resolve to their declarations")
PY
