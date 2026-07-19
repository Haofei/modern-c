#!/usr/bin/env python3
"""End-to-end test for mc-lsp: drives a real JSON-RPC session over stdio and asserts the
server publishes the compiler's diagnostics — with the same E_ codes as `mcc check` — for a
broken document, and an empty diagnostic list for a clean one.

Usage: lsp-test.py <path-to-mcc>
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import pathlib

HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SERVER = os.path.join(HERE, "tools", "lsp", "mc-lsp.py")
BUILD_ZIG_ZON = os.path.join(HERE, "build.zig.zon")

BAD = (
    "#[no_lang_trap]\n"
    "fn reads_variable_index(a: [4]u32, i: usize) -> u32 {\n"
    "    return a[i];\n"          # indexing may trap -> E_NO_LANG_TRAP_EDGE
    "}\n"
)
EXPECTED_CODE = "E_NO_LANG_TRAP_EDGE"
GOOD = "fn add_nums(a: u32, b: u32) -> u32 {\n    return a + b;\n}\n"
MONO_BAD = (
    "fn runaway(comptime N: usize) -> [N]u8 {\n"
    "    var scratch: [N]u8 = uninit;\n"
    "    let next: [N + 1]u8 = runaway(N + 1);\n"
    "    return scratch;\n"
    "}\n"
    "\n"
    "fn trigger() -> u8 {\n"
    "    let out: [1]u8 = runaway(1);\n"
    "    return out[0];\n"
    "}\n"
)
CANCEL_BAD = "# cancel_probe\n" + BAD
TIMEOUT_BAD = "# timeout_probe\n" + GOOD
MESSY = "fn   f( )->u32{\n        return 7;\n}\n"  # misindented -> formatting changes it
# A multi-byte string literal before an undefined-identifier error on the same line: the LSP
# `character` must be the UTF-16 offset of `missing_id`, not its byte offset.
UTF16 = 'fn g() -> u32 { let s: u32 = 1; return missing_id; }\n'
UTF16_EMOJI = 'fn g() -> u32 { let s = "\U0001F389\U0001F389"; return missing_id; }\n'
NAV = (
    "fn target(x: u32) -> u32 {\n"   # target def (0,3); param x def (0,10)
    "    return x + x;\n"            # x refs (1,11),(1,15)
    "}\n"
    "\n"
    "fn caller() -> u32 {\n"
    "    return target(5);\n"        # target ref (5,11)
    "}\n"
)
MEMBER = (
    "struct Point {\n"
    "    x: u32,\n"
    "    y: u32,\n"
    "}\n"
    "\n"
    "fn shift(p: Point) -> u32 {\n"
    "    let unrelated: u32 = 0;\n"
    "    return p.x;\n"
    "}\n"
)
TYPE_FILTER = (
    "fn takes(n: u32, ok: bool) -> u32 {\n"
    "    return n;\n"
    "}\n"
    "\n"
    "fn make_u32() -> u32 {\n"
    "    return 7;\n"
    "}\n"
    "\n"
    "fn choose(good: u32, flag: bool) -> u32 {\n"
    "    let wrong: bool = false;\n"
    "    var slot: u32 = 0;\n"
    "    let init: u32 = good;\n"
    "    slot = good;\n"
    "    takes(good, flag);\n"
    "    return good;\n"
    "}\n"
)


def utf16_len(s):
    return sum(2 if ord(c) > 0xFFFF else 1 for c in s)


def pos_of(text, line_idx, substr, occurrence=0):
    """LSP position of the `occurrence`-th `substr` on a (0-based) line (NAV is ASCII)."""
    line = text.split("\n")[line_idx]
    col = -1
    for _ in range(occurrence + 1):
        col = line.index(substr, col + 1)
    return {"line": line_idx, "character": col}


def pos_after(text, line_idx, substr, occurrence=0):
    pos = pos_of(text, line_idx, substr, occurrence)
    pos["character"] += len(substr)
    return pos


def frame(payload):
    data = json.dumps(payload).encode("utf-8")
    return f"Content-Length: {len(data)}\r\n\r\n".encode("ascii") + data


def read_message(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if line == "":
            break
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    length = int(headers.get("content-length", 0))
    return json.loads(stream.read(length).decode("utf-8"))


def diagnostics_for(proc, uri):
    """Read messages until a publishDiagnostics for `uri` arrives; return its diagnostics."""
    while True:
        msg = read_message(proc.stdout)
        if msg is None:
            raise SystemExit("FAIL: lsp-test — server closed before publishing diagnostics")
        if msg.get("method") == "textDocument/publishDiagnostics" and msg["params"]["uri"] == uri:
            return msg["params"]["diagnostics"]


def request(proc, rid, method, params):
    """Send a request and return its result, skipping any interleaved notifications."""
    proc.stdin.write(frame({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
    proc.stdin.flush()
    while True:
        msg = read_message(proc.stdout)
        if msg is None:
            raise SystemExit(f"FAIL: lsp-test — server closed before answering {method}")
        if msg.get("id") == rid:
            return msg.get("result")


def did_open(proc, uri, text):
    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                            "params": {"textDocument": {"uri": uri, "languageId": "mc",
                                                        "version": 1, "text": text}}}))
    proc.stdin.flush()


def did_change(proc, uri, version, text, flush=True):
    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didChange",
                            "params": {"textDocument": {"uri": uri, "version": version},
                                       "contentChanges": [{"text": text}]}}))
    if flush:
        proc.stdin.flush()


def check_count(path):
    try:
        with open(path) as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def wait_for_file(path, label, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return
        time.sleep(0.02)
    raise SystemExit(f"FAIL: lsp-test — timed out waiting for {label}")


def build_zig_zon_version():
    with open(BUILD_ZIG_ZON, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith(".version"):
                return line.split('"', 2)[1]
    raise SystemExit("FAIL: lsp-test — build.zig.zon missing .version")


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else "mcc"
    mcc = os.path.abspath(mcc)
    expected_server_version = build_zig_zon_version()

    workdir = tempfile.mkdtemp(prefix="lsp_test_")
    counter_path = os.path.join(workdir, "check.count")
    emit_map_counter_path = os.path.join(workdir, "emit-map.count")
    slow_started_path = os.path.join(workdir, "slow-check.started")
    slow_killed_path = os.path.join(workdir, "slow-check.killed")
    wrapper_path = os.path.join(workdir, "mcc-wrapper.py")
    with open(wrapper_path, "w") as f:
        f.write(
            "#!/usr/bin/env python3\n"
            "import os\n"
            "import signal\n"
            "import subprocess\n"
            "import sys\n"
            "import time\n"
            "\n"
            "def path_from_env(name):\n"
            "    return os.environ.get(name, '')\n"
            "\n"
            "def write_marker(path, text='1'):\n"
            "    if path:\n"
            "        with open(path, 'w') as marker:\n"
            "            marker.write(text)\n"
            "\n"
            "if len(sys.argv) > 1 and sys.argv[1] == 'check':\n"
            "    with open(os.environ['MC_LSP_TEST_CHECK_COUNTER'], 'a') as count_file:\n"
            "        count_file.write('1\\n')\n"
            "    check_path = next((arg for arg in sys.argv[2:] if not arg.startswith('--')), sys.argv[-1])\n"
            "    if check_path == '-':\n"
            "        source = sys.stdin.read()\n"
            "    else:\n"
            "        with open(check_path) as source_file:\n"
            "            source = source_file.read()\n"
            "    if 'cancel_probe' in source:\n"
            "        killed_path = path_from_env('MC_LSP_TEST_SLOW_KILLED')\n"
            "        def on_term(signum, frame):\n"
            "            write_marker(killed_path, str(os.getpid()))\n"
            "            sys.exit(128 + signum)\n"
            "        signal.signal(signal.SIGTERM, on_term)\n"
            "        write_marker(path_from_env('MC_LSP_TEST_SLOW_STARTED'), str(os.getpid()))\n"
            "        while True:\n"
            "            time.sleep(0.05)\n"
            "    if 'timeout_probe' in source:\n"
            "        while True:\n"
            "            time.sleep(0.05)\n"
            "elif len(sys.argv) > 1 and sys.argv[1] == 'emit-map':\n"
            "    with open(os.environ['MC_LSP_TEST_EMIT_MAP_COUNTER'], 'a') as count_file:\n"
            "        count_file.write('1\\n')\n"
            "forward_input = source if 'source' in globals() and '-' in sys.argv[1:] else None\n"
            "proc = subprocess.run([os.environ['MC_LSP_TEST_REAL_MCC']] + sys.argv[1:], input=forward_input, text=True)\n"
            "sys.exit(proc.returncode)\n"
        )
    os.chmod(wrapper_path, 0o755)
    env = dict(os.environ, MCC=wrapper_path, MC_LSP_DIAGNOSTIC_DEBOUNCE_MS="50",
               MC_LSP_MCC_TIMEOUT_SECONDS="1.5",
               MC_LSP_TEST_REAL_MCC=mcc, MC_LSP_TEST_CHECK_COUNTER=counter_path,
               MC_LSP_TEST_EMIT_MAP_COUNTER=emit_map_counter_path,
               MC_LSP_TEST_SLOW_STARTED=slow_started_path,
               MC_LSP_TEST_SLOW_KILLED=slow_killed_path)

    bad_path = os.path.join(workdir, "bad.mc")
    good_path = os.path.join(workdir, "good.mc")
    with open(bad_path, "w") as f:
        f.write(BAD)
    with open(good_path, "w") as f:
        f.write(GOOD)
    bad_uri = pathlib.Path(bad_path).as_uri()
    good_uri = pathlib.Path(good_path).as_uri()

    proc = subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, env=env)
    try:
        proc.stdin.write(frame({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": {"capabilities": {}, "rootUri": pathlib.Path(workdir).as_uri()}}))
        proc.stdin.flush()
        init = read_message(proc.stdout)
        assert init.get("id") == 1 and "result" in init, f"bad initialize result: {init}"
        caps = init["result"]["capabilities"]
        server_info = init["result"].get("serverInfo", {})
        assert server_info.get("name") == "mc-lsp", f"expected mc-lsp serverInfo name, got {server_info}"
        assert server_info.get("version") == expected_server_version, (
            f"expected serverInfo version {expected_server_version}, got {server_info}"
        )
        assert caps.get("textDocumentSync") == 1, f"expected Full textDocumentSync, got {caps}"
        assert caps.get("documentFormattingProvider"), f"expected formatting capability, got {caps}"
        assert caps.get("documentSymbolProvider"), f"expected documentSymbol capability, got {caps}"
        triggers = caps.get("completionProvider", {}).get("triggerCharacters", [])
        assert "." in triggers, f"expected dot completion trigger, got {triggers}"

        proc.stdin.write(frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}))

        # Open the broken document -> expect a diagnostic carrying the exact compiler code.
        proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                                "params": {"textDocument": {"uri": bad_uri, "languageId": "mc",
                                                            "version": 1, "text": BAD}}}))
        proc.stdin.flush()
        diags = diagnostics_for(proc, bad_uri)
        codes = [d.get("code") for d in diags]
        if EXPECTED_CODE not in codes:
            raise SystemExit(f"FAIL: lsp-test — expected {EXPECTED_CODE} in diagnostics, got {codes}")
        d = next(d for d in diags if d.get("code") == EXPECTED_CODE)
        assert d.get("source") == "mcc", f"diagnostic source should be 'mcc': {d}"
        assert d["range"]["start"]["line"] == 2, f"E_NO_LANG_TRAP_EDGE should be on line 3 (0-based 2): {d}"
        checks_after_push = check_count(counter_path)
        for rid in (101, 102):
            rep = request(proc, rid, "textDocument/diagnostic", {"textDocument": {"uri": bad_uri}})
            if EXPECTED_CODE not in [d.get("code") for d in rep.get("items", [])]:
                raise SystemExit(f"FAIL: lsp-test — cached pull diagnostics missed {EXPECTED_CODE}: {rep}")
        cached_pull_checks = check_count(counter_path) - checks_after_push
        if cached_pull_checks != 0:
            raise SystemExit(f"FAIL: lsp-test — unchanged pull diagnostics should reuse cache, ran {cached_pull_checks} check(s)")

        # Structured compiler notes should survive JSON -> LSP as related information.
        mono_path = os.path.join(workdir, "mono.mc")
        with open(mono_path, "w") as f:
            f.write(MONO_BAD)
        mono_uri = "file://" + mono_path
        did_open(proc, mono_uri, MONO_BAD)
        mono_diags = diagnostics_for(proc, mono_uri)
        mono = next((d for d in mono_diags if d.get("code") == "E_MONOMORPHIZATION_LIMIT"), None)
        if mono is None:
            raise SystemExit(f"FAIL: lsp-test — missing monomorphization diagnostic: {mono_diags}")
        related = mono.get("relatedInformation", [])
        if not any("runaway__129" in item.get("message", "") for item in related):
            raise SystemExit(f"FAIL: lsp-test — monomorphization notes missing related information: {mono}")

        # Open a clean document -> expect no diagnostics.
        proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                                "params": {"textDocument": {"uri": good_uri, "languageId": "mc",
                                                            "version": 1, "text": GOOD}}}))
        proc.stdin.flush()
        good_diags = diagnostics_for(proc, good_uri)
        if good_diags:
            raise SystemExit(f"FAIL: lsp-test — clean document produced diagnostics: {good_diags}")

        # didChange the good document to introduce the same error -> diagnostic reappears.
        checks_before_change = check_count(counter_path)
        did_change(proc, good_uri, 2, BAD)
        changed = diagnostics_for(proc, good_uri)
        if EXPECTED_CODE not in [d.get("code") for d in changed]:
            raise SystemExit(f"FAIL: lsp-test — didChange did not re-diagnose: {[d.get('code') for d in changed]}")
        changed_checks = check_count(counter_path) - checks_before_change
        if changed_checks != 1:
            raise SystemExit(f"FAIL: lsp-test — didChange should invalidate diagnostic cache and run one check, ran {changed_checks}")

        # Rapid didChange bursts should publish diagnostics for the final text, not a stale edit.
        rapid_path = os.path.join(workdir, "rapid.mc")
        with open(rapid_path, "w") as f:
            f.write(GOOD)
        rapid_uri = "file://" + rapid_path
        did_open(proc, rapid_uri, GOOD)
        diagnostics_for(proc, rapid_uri)
        checks_before_burst = check_count(counter_path)
        did_change(proc, rapid_uri, 2, BAD, flush=False)
        did_change(proc, rapid_uri, 3, GOOD)
        rapid_diags = diagnostics_for(proc, rapid_uri)
        if rapid_diags:
            raise SystemExit(f"FAIL: lsp-test — debounced didChange published stale diagnostics: {rapid_diags}")
        burst_checks = check_count(counter_path) - checks_before_burst
        if burst_checks != 1:
            raise SystemExit(f"FAIL: lsp-test — didChange burst should run one check, ran {burst_checks}")

        # A newer document generation must cancel an obsolete in-flight `mcc check`, not merely
        # discard its eventual output.
        cancel_path = os.path.join(workdir, "cancel.mc")
        with open(cancel_path, "w") as f:
            f.write(GOOD)
        cancel_uri = "file://" + cancel_path
        did_open(proc, cancel_uri, GOOD)
        diagnostics_for(proc, cancel_uri)
        did_change(proc, cancel_uri, 2, CANCEL_BAD)
        wait_for_file(slow_started_path, "slow diagnostic check to start")
        did_change(proc, cancel_uri, 3, GOOD)
        wait_for_file(slow_killed_path, "stale diagnostic check to be killed")
        cancel_diags = diagnostics_for(proc, cancel_uri)
        if cancel_diags:
            raise SystemExit(f"FAIL: lsp-test — cancelled stale check published diagnostics: {cancel_diags}")

        # A wedged compiler request hits a hard timeout and the single-process server remains
        # responsive for the next request.
        timeout_path = os.path.join(workdir, "timeout.mc")
        with open(timeout_path, "w") as f:
            f.write(TIMEOUT_BAD)
        timeout_uri = pathlib.Path(timeout_path).as_uri()
        started = time.monotonic()
        did_open(proc, timeout_uri, TIMEOUT_BAD)
        timeout_diags = diagnostics_for(proc, timeout_uri)
        if timeout_diags:
            raise SystemExit(f"FAIL: lsp-test — timeout should fail closed without stale diagnostics: {timeout_diags}")
        if time.monotonic() - started > 4.0:
            raise SystemExit("FAIL: lsp-test — compiler hard timeout did not bound request latency")

        # URI decoding and stdin overlays work in an encoded, read-only source directory.
        encoded_dir = os.path.join(workdir, "space \u00fc")
        os.mkdir(encoded_dir)
        encoded_path = os.path.join(encoded_dir, "broken file.mc")
        with open(encoded_path, "w") as f:
            f.write(BAD)
        os.chmod(encoded_dir, 0o555)
        encoded_uri = pathlib.Path(encoded_path).as_uri()
        try:
            did_open(proc, encoded_uri, BAD)
            encoded_diags = diagnostics_for(proc, encoded_uri)
        finally:
            os.chmod(encoded_dir, 0o755)
        if EXPECTED_CODE not in [d.get("code") for d in encoded_diags]:
            raise SystemExit(f"FAIL: lsp-test — encoded/read-only URI lost diagnostics: {encoded_diags}")

        # Imported diagnostics retain the imported file URI rather than being dropped.
        imported_path = os.path.join(workdir, "imported_bad.mc")
        imported_root_path = os.path.join(workdir, "import_root.mc")
        with open(imported_path, "w") as f:
            f.write(BAD)
        imported_root = 'import "./imported_bad.mc";\nfn import_root() -> u32 { return 0; }\n'
        with open(imported_root_path, "w") as f:
            f.write(imported_root)
        imported_uri = pathlib.Path(imported_path).as_uri()
        imported_root_uri = pathlib.Path(imported_root_path).as_uri()
        did_open(proc, imported_root_uri, imported_root)
        diagnostics_for(proc, imported_root_uri)
        imported_diags = diagnostics_for(proc, imported_uri)
        if EXPECTED_CODE not in [d.get("code") for d in imported_diags]:
            raise SystemExit(f"FAIL: lsp-test — imported file diagnostic was not published: {imported_diags}")
        with open(imported_path, "w") as f:
            f.write(GOOD)
        proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didSave",
                                "params": {"textDocument": {"uri": imported_root_uri}}}))
        proc.stdin.flush()
        diagnostics_for(proc, imported_root_uri)
        cleared_imported = diagnostics_for(proc, imported_uri)
        if cleared_imported:
            raise SystemExit(f"FAIL: lsp-test — stale imported diagnostics were not cleared: {cleared_imported}")

        # --- document symbols (via `mcc emit-map`) -------------------------------------------
        sym_path = os.path.join(workdir, "sym.mc")
        with open(sym_path, "w") as f:
            f.write(GOOD)
        sym_uri = "file://" + sym_path
        did_open(proc, sym_uri, GOOD)
        diagnostics_for(proc, sym_uri)
        maps_before_symbols = check_count(emit_map_counter_path)
        symbols = request(proc, 10, "textDocument/documentSymbol", {"textDocument": {"uri": sym_uri}})
        names = [s.get("name") for s in (symbols or [])]
        if "add_nums" not in names:
            raise SystemExit(f"FAIL: lsp-test — documentSymbol did not list function add_nums: {names}")
        ok_sym = next(s for s in symbols if s["name"] == "add_nums")
        if ok_sym.get("kind") != 12:  # SymbolKind.Function
            raise SystemExit(f"FAIL: lsp-test — 'add_nums' symbol kind should be Function(12): {ok_sym}")
        symbols_again = request(proc, 42, "textDocument/documentSymbol", {"textDocument": {"uri": sym_uri}})
        if symbols_again != symbols:
            raise SystemExit(f"FAIL: lsp-test — cached documentSymbol response changed: {symbols_again}")
        symbol_maps = check_count(emit_map_counter_path) - maps_before_symbols
        if symbol_maps != 1:
            raise SystemExit(f"FAIL: lsp-test — unchanged documentSymbol should run emit-map once, ran {symbol_maps}")

        # --- formatting (via `mcc fmt`) ------------------------------------------------------
        fmt_path = os.path.join(workdir, "fmt.mc")
        with open(fmt_path, "w") as f:
            f.write(MESSY)
        fmt_uri = "file://" + fmt_path
        did_open(proc, fmt_uri, MESSY)
        diagnostics_for(proc, fmt_uri)
        edits = request(proc, 11, "textDocument/formatting", {"textDocument": {"uri": fmt_uri},
                                                              "options": {"tabSize": 4, "insertSpaces": True}})
        if not edits or "    return 7;" not in edits[0]["newText"]:
            raise SystemExit(f"FAIL: lsp-test — formatting did not reindent the body: {edits}")

        # --- UTF-16 position encoding --------------------------------------------------------
        # The error column must be the UTF-16 offset of `missing_id` — which differs from its
        # byte offset because of the leading multi-byte emoji string.
        u_path = os.path.join(workdir, "utf16.mc")
        with open(u_path, "w") as f:
            f.write(UTF16_EMOJI)
        u_uri = "file://" + u_path
        did_open(proc, u_uri, UTF16_EMOJI)
        udiags = diagnostics_for(proc, u_uri)
        line0 = UTF16_EMOJI.split("\n")[0]
        want_char = utf16_len(line0[:line0.index("missing_id")])
        want_byte = len(line0[:line0.index("missing_id")].encode("utf-8"))
        chars = [d["range"]["start"]["character"] for d in udiags]
        if want_char not in chars:
            raise SystemExit(f"FAIL: lsp-test — expected UTF-16 column {want_char} for missing_id, got {chars}")
        if want_byte in chars and want_byte != want_char:
            raise SystemExit(f"FAIL: lsp-test — reported a byte column {want_byte} instead of UTF-16 {want_char}")

        # --- navigation features (via `mcc symbols`) -----------------------------------------
        nav_path = os.path.join(workdir, "nav.mc")
        with open(nav_path, "w") as f:
            f.write(NAV)
        nav_uri = "file://" + nav_path
        did_open(proc, nav_uri, NAV)
        diagnostics_for(proc, nav_uri)
        td = {"textDocument": {"uri": nav_uri}}

        # hover on the `target` definition -> its function signature + kind.
        hov = request(proc, 20, "textDocument/hover", {**td, "position": pos_of(NAV, 0, "target")})
        val = (hov or {}).get("contents", {}).get("value", "")
        if "fn(u32) -> u32" not in val or "function" not in val:
            raise SystemExit(f"FAIL: lsp-test — hover missing signature/kind: {hov}")

        # go-to-definition from the `target` call (line 5) -> the def on line 0.
        defn = request(proc, 21, "textDocument/definition", {**td, "position": pos_of(NAV, 5, "target")})
        if not defn or defn["range"]["start"]["line"] != 0:
            raise SystemExit(f"FAIL: lsp-test — definition did not jump to line 0: {defn}")

        # references to `target` (declaration + the one call).
        refs = request(proc, 22, "textDocument/references",
                       {**td, "position": pos_of(NAV, 0, "target"), "context": {"includeDeclaration": True}})
        ref_lines = sorted(r["range"]["start"]["line"] for r in (refs or []))
        if ref_lines != [0, 5]:
            raise SystemExit(f"FAIL: lsp-test — references to target should be lines [0,5], got {ref_lines}")

        # document highlight for `x` -> the two uses + the param declaration (3, all line 0/1).
        hl = request(proc, 23, "textDocument/documentHighlight", {**td, "position": pos_of(NAV, 1, "x")})
        if len(hl or []) != 3:
            raise SystemExit(f"FAIL: lsp-test — expected 3 highlights for x, got {hl}")

        # rename `x` -> `y`: edits for the param decl + both uses (3 edits, all in this file).
        ren = request(proc, 24, "textDocument/rename",
                      {**td, "position": pos_of(NAV, 0, "x"), "newName": "y"})
        edits = (ren or {}).get("changes", {}).get(nav_uri, [])
        if len(edits) != 3 or any(e["newText"] != "y" for e in edits):
            raise SystemExit(f"FAIL: lsp-test — rename should produce 3 edits to 'y', got {ren}")

        # semantic tokens: first token is the `target` function def at (line 0, char 3, len 6).
        sem = request(proc, 25, "textDocument/semanticTokens/full", td)
        data = (sem or {}).get("data", [])
        if data[:5] != [0, 3, 6, 0, 0]:  # deltaLine, deltaChar, length, tokenType(function=0), mods
            raise SystemExit(f"FAIL: lsp-test — first semantic token should be the function def: {data[:5]}")

        # signature help inside the `target(5)` call -> the function signature, active param 0.
        sig = request(proc, 26, "textDocument/signatureHelp", {**td, "position": pos_of(NAV, 5, "5")})
        sigs = (sig or {}).get("signatures", [])
        if not sigs or "target(u32) -> u32" not in sigs[0]["label"]:
            raise SystemExit(f"FAIL: lsp-test — signature help wrong: {sig}")
        if sig.get("activeParameter") != 0:
            raise SystemExit(f"FAIL: lsp-test — signature help active param should be 0: {sig}")

        # pull diagnostics (LSP 3.17) on the broken doc -> full report carrying the same code.
        rep = request(proc, 27, "textDocument/diagnostic", {"textDocument": {"uri": bad_uri}})
        if (rep or {}).get("kind") != "full" or EXPECTED_CODE not in [d.get("code") for d in rep.get("items", [])]:
            raise SystemExit(f"FAIL: lsp-test — pull diagnostics did not report {EXPECTED_CODE}: {rep}")

        # workspace symbols across open documents -> the `caller` function from nav.mc.
        ws = request(proc, 28, "workspace/symbol", {"query": "caller"})
        if not any(s["name"] == "caller" and s["kind"] == 12 for s in (ws or [])):
            raise SystemExit(f"FAIL: lsp-test — workspace/symbol did not find function 'caller': {ws}")

        # Workspace discovery includes unopened .mc files under initialize.rootUri.
        unopened_path = os.path.join(workdir, "unopened.mc")
        with open(unopened_path, "w") as f:
            f.write("fn unopened_workspace_symbol() -> u32 { return 9; }\n")
        ws_unopened = request(proc, 43, "workspace/symbol", {"query": "unopened_workspace_symbol"})
        if not any(s["name"] == "unopened_workspace_symbol" and
                   s["location"]["uri"] == pathlib.Path(unopened_path).as_uri()
                   for s in (ws_unopened or [])):
            raise SystemExit(f"FAIL: lsp-test — workspace/symbol ignored unopened file: {ws_unopened}")

        # Imported symbol spans carry source paths, enabling cross-file navigation and edits.
        cross_lib_path = os.path.join(workdir, "cross_lib.mc")
        cross_root_path = os.path.join(workdir, "cross_root.mc")
        cross_lib = "fn cross_target(x: u32) -> u32 { return x + 1; }\n"
        cross_root = 'import "./cross_lib.mc";\nfn cross_caller() -> u32 { return cross_target(4); }\n'
        with open(cross_lib_path, "w") as f:
            f.write(cross_lib)
        with open(cross_root_path, "w") as f:
            f.write(cross_root)
        cross_root_uri = pathlib.Path(cross_root_path).as_uri()
        cross_lib_uri = pathlib.Path(cross_lib_path).as_uri()
        did_open(proc, cross_root_uri, cross_root)
        diagnostics_for(proc, cross_root_uri)
        cross_td = {"textDocument": {"uri": cross_root_uri}}
        cross_pos = pos_of(cross_root, 1, "cross_target")
        cross_def = request(proc, 44, "textDocument/definition", {**cross_td, "position": cross_pos})
        if not cross_def or cross_def["uri"] != cross_lib_uri or cross_def["range"]["start"]["line"] != 0:
            raise SystemExit(f"FAIL: lsp-test — cross-file definition has wrong location: {cross_def}")
        cross_refs = request(proc, 45, "textDocument/references",
                             {**cross_td, "position": cross_pos, "context": {"includeDeclaration": True}})
        if {entry["uri"] for entry in (cross_refs or [])} != {cross_root_uri, cross_lib_uri}:
            raise SystemExit(f"FAIL: lsp-test — cross-file references incomplete: {cross_refs}")
        cross_rename = request(proc, 46, "textDocument/rename",
                               {**cross_td, "position": cross_pos, "newName": "renamed_target"})
        if set((cross_rename or {}).get("changes", {})) != {cross_root_uri, cross_lib_uri}:
            raise SystemExit(f"FAIL: lsp-test — cross-file rename incomplete: {cross_rename}")

        # call hierarchy: caller() -> target(). Incoming to target = caller; outgoing from caller = target.
        prep_t = request(proc, 29, "textDocument/prepareCallHierarchy", {**td, "position": pos_of(NAV, 0, "target")})
        if not prep_t or prep_t[0]["name"] != "target":
            raise SystemExit(f"FAIL: lsp-test — prepareCallHierarchy on target wrong: {prep_t}")
        inc = request(proc, 30, "callHierarchy/incomingCalls", {"item": prep_t[0]})
        if not any(c["from"]["name"] == "caller" for c in (inc or [])):
            raise SystemExit(f"FAIL: lsp-test — incomingCalls to target should include caller: {inc}")
        prep_c = request(proc, 31, "textDocument/prepareCallHierarchy", {**td, "position": pos_of(NAV, 4, "caller")})
        out_calls = request(proc, 32, "callHierarchy/outgoingCalls", {"item": prep_c[0]})
        if not any(c["to"]["name"] == "target" for c in (out_calls or [])):
            raise SystemExit(f"FAIL: lsp-test — outgoingCalls from caller should include target: {out_calls}")

        # completion inside target()'s body: offers the param `x`, the functions, a primitive,
        # and a keyword.
        comp = request(proc, 33, "textDocument/completion", {**td, "position": pos_of(NAV, 1, "return")})
        labels = {i["label"] for i in (comp or {}).get("items", [])}
        for want in ("x", "target", "caller", "u32", "return"):
            if want not in labels:
                raise SystemExit(f"FAIL: lsp-test — completion missing '{want}': {sorted(labels)[:20]}")
        # in caller()'s body, target's param `x` is out of scope.
        comp2 = request(proc, 34, "textDocument/completion", {**td, "position": pos_of(NAV, 5, "return")})
        labels2 = {i["label"] for i in (comp2 or {}).get("items", [])}
        if "x" in labels2:
            raise SystemExit("FAIL: lsp-test — completion leaked another function's param 'x' into caller()")
        if "caller" not in labels2:
            raise SystemExit(f"FAIL: lsp-test — completion in caller() missing 'caller': {sorted(labels2)[:20]}")

        # member completion after `p.` should return fields from Point, not unrelated locals.
        member_path = os.path.join(workdir, "member.mc")
        with open(member_path, "w") as f:
            f.write(MEMBER)
        member_uri = "file://" + member_path
        did_open(proc, member_uri, MEMBER)
        diagnostics_for(proc, member_uri)
        member_td = {"textDocument": {"uri": member_uri}}
        dot_comp = request(proc, 35, "textDocument/completion",
                           {**member_td, "position": pos_after(MEMBER, 7, "p.")})
        dot_labels = {i["label"] for i in (dot_comp or {}).get("items", [])}
        for want in ("x", "y"):
            if want not in dot_labels:
                raise SystemExit(f"FAIL: lsp-test — member completion missing Point.{want}: {sorted(dot_labels)}")
        for leak in ("p", "shift", "unrelated", "return", "u32"):
            if leak in dot_labels:
                raise SystemExit(f"FAIL: lsp-test — member completion leaked non-field '{leak}': {sorted(dot_labels)}")
        prefix_comp = request(proc, 36, "textDocument/completion",
                              {**member_td, "position": pos_after(MEMBER, 7, "p.x")})
        prefix_labels = {i["label"] for i in (prefix_comp or {}).get("items", [])}
        if prefix_labels != {"x"}:
            raise SystemExit(f"FAIL: lsp-test — member prefix completion should only return x, got {sorted(prefix_labels)}")

        # Type-filtered completion in typed value contexts should keep compatible values and
        # compatible-return functions, while filtering incompatible visible locals.
        tf_path = os.path.join(workdir, "type_filter.mc")
        with open(tf_path, "w") as f:
            f.write(TYPE_FILTER)
        tf_uri = "file://" + tf_path
        did_open(proc, tf_uri, TYPE_FILTER)
        diagnostics_for(proc, tf_uri)
        tf_td = {"textDocument": {"uri": tf_uri}}

        return_comp = request(proc, 37, "textDocument/completion",
                              {**tf_td, "position": pos_after(TYPE_FILTER, 14, "return ")})
        return_labels = {i["label"] for i in (return_comp or {}).get("items", [])}
        for want in ("good", "slot", "init", "make_u32"):
            if want not in return_labels:
                raise SystemExit(f"FAIL: lsp-test — return type-filter missing '{want}': {sorted(return_labels)}")
        for leak in ("flag", "wrong", "return", "u32"):
            if leak in return_labels:
                raise SystemExit(f"FAIL: lsp-test — return type-filter leaked '{leak}': {sorted(return_labels)}")

        init_comp = request(proc, 38, "textDocument/completion",
                            {**tf_td, "position": pos_after(TYPE_FILTER, 11, "let init: u32 = ")})
        init_labels = {i["label"] for i in (init_comp or {}).get("items", [])}
        if "good" not in init_labels or "wrong" in init_labels:
            raise SystemExit(f"FAIL: lsp-test — typed initializer filter wrong: {sorted(init_labels)}")

        assign_comp = request(proc, 39, "textDocument/completion",
                              {**tf_td, "position": pos_after(TYPE_FILTER, 12, "slot = ")})
        assign_labels = {i["label"] for i in (assign_comp or {}).get("items", [])}
        if "good" not in assign_labels or "wrong" in assign_labels:
            raise SystemExit(f"FAIL: lsp-test — assignment type-filter wrong: {sorted(assign_labels)}")

        arg0_comp = request(proc, 40, "textDocument/completion",
                            {**tf_td, "position": pos_after(TYPE_FILTER, 13, "takes(")})
        arg0_labels = {i["label"] for i in (arg0_comp or {}).get("items", [])}
        if "good" not in arg0_labels or "flag" in arg0_labels:
            raise SystemExit(f"FAIL: lsp-test — first call-arg type-filter wrong: {sorted(arg0_labels)}")

        arg1_comp = request(proc, 41, "textDocument/completion",
                            {**tf_td, "position": pos_after(TYPE_FILTER, 13, "takes(good, ")})
        arg1_labels = {i["label"] for i in (arg1_comp or {}).get("items", [])}
        for want in ("flag", "wrong", "true", "false"):
            if want not in arg1_labels:
                raise SystemExit(f"FAIL: lsp-test — bool call-arg type-filter missing '{want}': {sorted(arg1_labels)}")
        for leak in ("good", "slot", "init", "u32"):
            if leak in arg1_labels:
                raise SystemExit(f"FAIL: lsp-test — bool call-arg type-filter leaked '{leak}': {sorted(arg1_labels)}")

        proc.stdin.write(frame({"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": {}}))
        proc.stdin.flush()
        shut = read_message(proc.stdout)
        assert shut.get("id") == 2, f"bad shutdown response: {shut}"
        proc.stdin.write(frame({"jsonrpc": "2.0", "method": "exit", "params": {}}))
        proc.stdin.flush()
        proc.wait(timeout=10)
    finally:
        if proc.poll() is None:
            proc.kill()

    print(f"PASS: lsp-test — diagnostics ({EXPECTED_CODE}, clean, debounced didChange, "
          "in-flight cancellation, hard timeout, imported-file, pull), encoded/read-only URI overlay, "
          "documentSymbol outline, `mcc fmt` formatting, UTF-16 positions, hover/definition/"
          "references/highlight/rename/semantic-tokens (including cross-file), identifier/member/type-filtered completion, signature help, workspace "
          "symbols, and call hierarchy all verified")


if __name__ == "__main__":
    main()
