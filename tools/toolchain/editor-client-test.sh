#!/usr/bin/env bash
# Validates the VS Code editor client (editors/vscode) is well-formed and internally
# consistent — the manifest, language configuration, and TextMate grammar are valid JSON and
# agree on the language id (`mc`) and grammar scope (`source.mc`), and extension.js is valid
# JavaScript that wires the language client. Needs python3 (JSON); the JS syntax check runs
# only when `node` is available. Does not require VS Code.
set -euo pipefail

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
DIR="$HERE/editors/vscode"

python3 - "$DIR" <<'PY'
import json, os, sys
d = sys.argv[1]

def fail(m):
    print(f"FAIL: editor-client-test — {m}"); sys.exit(1)

def load(name):
    p = os.path.join(d, name)
    if not os.path.exists(p):
        fail(f"missing {name}")
    try:
        return json.load(open(p))
    except json.JSONDecodeError as e:
        fail(f"{name} is not valid JSON: {e}")

pkg = load("package.json")
langs = pkg.get("contributes", {}).get("languages", [])
if not any(l.get("id") == "mc" and ".mc" in l.get("extensions", []) for l in langs):
    fail("package.json does not register language 'mc' for '.mc'")
grammars = pkg.get("contributes", {}).get("grammars", [])
if not any(g.get("language") == "mc" and g.get("scopeName") == "source.mc" for g in grammars):
    fail("package.json grammar must map language 'mc' to scope 'source.mc'")
if pkg.get("main") != "./extension.js":
    fail("package.json main must be ./extension.js")
if "vscode-languageclient" not in pkg.get("dependencies", {}):
    fail("package.json must depend on vscode-languageclient")
for key in ("mc.server.enable", "mc.server.path", "mc.mcc.path", "mc.python.path"):
    if key not in pkg["contributes"]["configuration"]["properties"]:
        fail(f"package.json missing setting {key}")

load("language-configuration.json")
gram = load(os.path.join("syntaxes", "mc.tmLanguage.json"))
if gram.get("scopeName") != "source.mc":
    fail("grammar scopeName must be source.mc")
if not gram.get("patterns") or "repository" not in gram:
    fail("grammar must have patterns + repository")

ext = open(os.path.join(d, "extension.js")).read()
for needle in ("LanguageClient", "language: \"mc\"", "MCC", "mc-lsp.py" if False else "server.path"):
    if needle not in ext:
        fail(f"extension.js missing '{needle}'")
print("PASS: editor-client-test — manifest/config/grammar valid JSON; language id 'mc' + scope 'source.mc' consistent")
PY

if command -v node >/dev/null 2>&1; then
    node --check "$DIR/extension.js" || { echo "FAIL: editor-client-test — extension.js is not valid JavaScript"; exit 1; }
    echo "PASS: editor-client-test — extension.js passes node --check"
else
    echo "SKIP: editor-client-test — node not found, skipped extension.js syntax check"
fi
