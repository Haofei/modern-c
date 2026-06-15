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

HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SERVER = os.path.join(HERE, "tools", "lsp", "mc-lsp.py")

BAD = (
    "#[no_lang_trap]\n"
    "fn reads_variable_index(a: [4]u32, i: usize) -> u32 {\n"
    "    return a[i];\n"          # indexing may trap -> E_NO_LANG_TRAP_EDGE
    "}\n"
)
EXPECTED_CODE = "E_NO_LANG_TRAP_EDGE"
GOOD = "fn add_nums(a: u32, b: u32) -> u32 {\n    return a + b;\n}\n"
MESSY = "fn   f( )->u32{\n        return 7;\n}\n"  # misindented -> formatting changes it
# A multi-byte string literal before an undefined-identifier error on the same line: the LSP
# `character` must be the UTF-16 offset of `missing_id`, not its byte offset.
UTF16 = 'fn g() -> u32 { let s: u32 = 1; return missing_id; }\n'
UTF16_EMOJI = 'fn g() -> u32 { let s = "\U0001F389\U0001F389"; return missing_id; }\n'


def utf16_len(s):
    return sum(2 if ord(c) > 0xFFFF else 1 for c in s)


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


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else "mcc"
    mcc = os.path.abspath(mcc)
    env = dict(os.environ, MCC=mcc)

    workdir = tempfile.mkdtemp(prefix="lsp_test_")
    bad_path = os.path.join(workdir, "bad.mc")
    good_path = os.path.join(workdir, "good.mc")
    with open(bad_path, "w") as f:
        f.write(BAD)
    with open(good_path, "w") as f:
        f.write(GOOD)
    bad_uri = "file://" + bad_path
    good_uri = "file://" + good_path

    proc = subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, env=env)
    try:
        proc.stdin.write(frame({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": {"capabilities": {}}}))
        proc.stdin.flush()
        init = read_message(proc.stdout)
        assert init.get("id") == 1 and "result" in init, f"bad initialize result: {init}"
        caps = init["result"]["capabilities"]
        assert caps.get("textDocumentSync") == 1, f"expected Full textDocumentSync, got {caps}"
        assert caps.get("documentFormattingProvider"), f"expected formatting capability, got {caps}"
        assert caps.get("documentSymbolProvider"), f"expected documentSymbol capability, got {caps}"

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

        # Open a clean document -> expect no diagnostics.
        proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                                "params": {"textDocument": {"uri": good_uri, "languageId": "mc",
                                                            "version": 1, "text": GOOD}}}))
        proc.stdin.flush()
        good_diags = diagnostics_for(proc, good_uri)
        if good_diags:
            raise SystemExit(f"FAIL: lsp-test — clean document produced diagnostics: {good_diags}")

        # didChange the good document to introduce the same error -> diagnostic reappears.
        proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didChange",
                                "params": {"textDocument": {"uri": good_uri, "version": 2},
                                            "contentChanges": [{"text": BAD}]}}))
        proc.stdin.flush()
        changed = diagnostics_for(proc, good_uri)
        if EXPECTED_CODE not in [d.get("code") for d in changed]:
            raise SystemExit(f"FAIL: lsp-test — didChange did not re-diagnose: {[d.get('code') for d in changed]}")

        # --- document symbols (via `mcc emit-map`) -------------------------------------------
        sym_path = os.path.join(workdir, "sym.mc")
        with open(sym_path, "w") as f:
            f.write(GOOD)
        sym_uri = "file://" + sym_path
        did_open(proc, sym_uri, GOOD)
        diagnostics_for(proc, sym_uri)
        symbols = request(proc, 10, "textDocument/documentSymbol", {"textDocument": {"uri": sym_uri}})
        names = [s.get("name") for s in (symbols or [])]
        if "add_nums" not in names:
            raise SystemExit(f"FAIL: lsp-test — documentSymbol did not list function add_nums: {names}")
        ok_sym = next(s for s in symbols if s["name"] == "add_nums")
        if ok_sym.get("kind") != 12:  # SymbolKind.Function
            raise SystemExit(f"FAIL: lsp-test — 'add_nums' symbol kind should be Function(12): {ok_sym}")

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

    print(f"PASS: lsp-test — diagnostics ({EXPECTED_CODE}, clean, didChange), documentSymbol outline, "
          "`mcc fmt` formatting, and UTF-16 position encoding all verified")


if __name__ == "__main__":
    main()
