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
GOOD = "fn ok(a: u32, b: u32) -> u32 {\n    return a + b;\n}\n"


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

    print(f"PASS: lsp-test — server published {EXPECTED_CODE} for the broken doc (matching mcc check), "
          "none for the clean doc, and re-diagnosed on didChange")


if __name__ == "__main__":
    main()
