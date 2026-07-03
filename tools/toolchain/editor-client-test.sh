#!/usr/bin/env bash
# Validates the VS Code editor client (editors/vscode) is well-formed, packageable,
# and internally consistent: manifest metadata, npm/vsce packaging contract,
# language configuration, TextMate grammar, .vscodeignore, docs, and release
# workflow hooks are checked statically. The JS syntax check runs only when
# `node` is available. Does not require VS Code.
set -euo pipefail

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
DIR="$HERE/editors/vscode"

python3 - "$HERE" "$DIR" <<'PY'
import fnmatch
import json
import os
import re
import sys

root = sys.argv[1]
d = sys.argv[2]


def fail(m):
    print(f"FAIL: editor-client-test - {m}")
    sys.exit(1)


def load(name):
    p = os.path.join(d, name)
    if not os.path.exists(p):
        fail(f"missing {name}")
    try:
        with open(p, encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as e:
        fail(f"{name} is not valid JSON: {e}")


pkg = load("package.json")
for key in ("name", "displayName", "description", "version", "publisher", "license", "repository", "engines"):
    if not pkg.get(key):
        fail(f"package.json missing required manifest field {key}")
if pkg["name"] != "mc":
    fail("package.json name must be mc")
if pkg["publisher"] != "modern-c":
    fail("package.json publisher must be modern-c")
if pkg["license"] != "MIT":
    fail("package.json license must be MIT")
if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", pkg["version"]):
    fail("package.json version must be a concrete semver")
repo = pkg["repository"]
if (
    not isinstance(repo, dict)
    or repo.get("type") != "git"
    or not repo.get("url")
    or repo.get("directory") != "editors/vscode"
):
    fail("package.json repository must point at the editors/vscode subdirectory")

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

scripts = pkg.get("scripts", {})
if scripts.get("package") != "vsce package":
    fail("package.json must define scripts.package as 'vsce package'")
if "vsce ls" not in scripts.get("package:check", ""):
    fail("package.json must define a package:check script using vsce ls")
if scripts.get("check") != "node --check extension.js":
    fail("package.json must define scripts.check as 'node --check extension.js'")
vsce = pkg.get("devDependencies", {}).get("@vscode/vsce")
if not vsce:
    fail("package.json must pin @vscode/vsce in devDependencies")
if vsce.startswith(("^", "~", ">", "<", "*")):
    fail("@vscode/vsce must be pinned to an exact version")
if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", vsce):
    fail("@vscode/vsce must be a concrete semver")
if pkg.get("overrides", {}).get("cheerio") != "1.0.0-rc.12":
    fail("package.json must pin cheerio override to keep vsce package checks Node 18-compatible")

for key in ("mc.server.enable", "mc.server.path", "mc.mcc.path", "mc.python.path"):
    if key not in pkg["contributes"]["configuration"]["properties"]:
        fail(f"package.json missing setting {key}")

load("language-configuration.json")
gram = load(os.path.join("syntaxes", "mc.tmLanguage.json"))
if gram.get("scopeName") != "source.mc":
    fail("grammar scopeName must be source.mc")
if not gram.get("patterns") or "repository" not in gram:
    fail("grammar must have patterns + repository")
for language in langs:
    if language.get("id") == "mc":
        config_path = language.get("configuration", "").removeprefix("./")
        if config_path != "language-configuration.json" or not os.path.exists(os.path.join(d, config_path)):
            fail("package.json language configuration must point at language-configuration.json")
for grammar in grammars:
    if grammar.get("language") == "mc":
        grammar_path = grammar.get("path", "").removeprefix("./")
        if grammar_path != "syntaxes/mc.tmLanguage.json" or not os.path.exists(os.path.join(d, grammar_path)):
            fail("package.json grammar path must point at syntaxes/mc.tmLanguage.json")

lock = load("package-lock.json")
root_package = lock.get("packages", {}).get("", {})
if root_package.get("devDependencies", {}).get("@vscode/vsce") != vsce:
    fail("package-lock.json must lock the same @vscode/vsce version as package.json")

ignore_path = os.path.join(d, ".vscodeignore")
if not os.path.exists(ignore_path):
    fail("missing .vscodeignore")
ignore_patterns = [
    line.strip()
    for line in open(ignore_path, encoding="utf-8")
    if line.strip() and not line.lstrip().startswith("#")
]
for pattern in (
    ".vscode/**",
    "**/.vscode/**",
    "**/.github/**",
    "*.vsix",
    "node_modules/.cache/**",
    "**/test/**",
    "**/tests/**",
    "package-lock.json",
    ".gitignore",
    ".vscodeignore",
):
    if pattern not in ignore_patterns:
        fail(f".vscodeignore must exclude {pattern}")
runtime_paths = (
    "package.json",
    "README.md",
    "LICENSE",
    "extension.js",
    "language-configuration.json",
    "syntaxes/mc.tmLanguage.json",
)
for path in runtime_paths:
    if not os.path.exists(os.path.join(d, path)):
        fail(f"missing VSIX runtime file {path}")
    if any(fnmatch.fnmatch(path, pattern) for pattern in ignore_patterns):
        fail(f".vscodeignore excludes required VSIX runtime file {path}")

with open(os.path.join(d, "extension.js"), encoding="utf-8") as handle:
    ext = handle.read()
for needle in ("LanguageClient", 'language: "mc"', "MCC", "server.path"):
    if needle not in ext:
        fail(f"extension.js missing {needle!r}")

with open(os.path.join(d, "README.md"), encoding="utf-8") as handle:
    readme = handle.read()
for needle in ("npm run package", "code --install-extension", "../../docs/lsp.md"):
    if needle not in readme:
        fail(f"editors/vscode/README.md missing {needle!r}")

with open(os.path.join(root, "docs", "lsp.md"), encoding="utf-8") as handle:
    docs_lsp = handle.read()
for needle in ("python3 tools/lsp/mc-lsp.py", "MCC=", "Language id", ".mc"):
    if needle not in docs_lsp:
        fail(f"docs/lsp.md missing {needle!r}")

with open(os.path.join(root, ".github", "workflows", "release.yml"), encoding="utf-8") as handle:
    release = handle.read()
for needle in ("actions/setup-node@v4", "npm ci", "npm run package", "editors/vscode/*.vsix"):
    if needle not in release:
        fail(f"release workflow missing VSIX packaging hook {needle!r}")

print("PASS: editor-client-test - VS Code manifest, package metadata, grammar, ignore rules, and docs are VSIX-ready")
PY

if command -v node >/dev/null 2>&1; then
    node --check "$DIR/extension.js" || { echo "FAIL: editor-client-test - extension.js is not valid JavaScript"; exit 1; }
    echo "PASS: editor-client-test - extension.js passes node --check"
else
    echo "SKIP: editor-client-test - node not found, skipped extension.js syntax check"
fi
