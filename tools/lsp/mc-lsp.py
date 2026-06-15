#!/usr/bin/env python3
"""mc-lsp — a minimal Language Server for MC.

Speaks the Language Server Protocol over stdio (Content-Length-framed JSON-RPC) and surfaces
the compiler's own diagnostics to any LSP-capable editor. On `didOpen` / `didChange` /
`didSave` it runs `mcc check` on the document's current text and publishes the results as LSP
diagnostics — using the SAME diagnostic codes the CLI reports (`E_...`), so a squiggle in the
editor and a `mcc check` failure in CI name the identical rule.

It deliberately implements only the diagnostics slice (textDocumentSync = Full); hovers,
completion, and go-to-definition can layer on later without changing this transport. The
compiler is the single source of truth for diagnostics — the server only translates.

Usage (configured as the language server for `.mc` files in an editor):
    mcc=/path/to/mcc python3 tools/lsp/mc-lsp.py
The `MCC` environment variable (or --mcc) selects the compiler binary; default `mcc` on PATH.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

# `path:line:col: error: E_CODE: message` — the CLI diagnostic format. The code is optional
# (a few wrapper errors like `CheckFailed` carry none); those are skipped.
DIAG_RE = re.compile(r"^.*?:(\d+):(\d+):\s*error:\s*(E_[A-Z0-9_]+):\s*(.*)$")

MCC = os.environ.get("MCC", "mcc")


def log(*a):
    print("[mc-lsp]", *a, file=sys.stderr, flush=True)


# ---- JSON-RPC framing over stdio -----------------------------------------------------------
def read_message(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None  # EOF
        line = line.decode("utf-8", "replace").rstrip("\r\n")
        if line == "":
            break
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    length = int(headers.get("content-length", 0))
    body = stream.read(length)
    return json.loads(body.decode("utf-8"))


def write_message(stream, payload):
    data = json.dumps(payload).encode("utf-8")
    stream.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
    stream.write(data)
    stream.flush()


def uri_to_path(uri):
    if uri.startswith("file://"):
        return uri[len("file://"):]
    return uri


# ---- diagnostics ---------------------------------------------------------------------------
def run_diagnostics(uri, text):
    """Run `mcc check` on `text` and return a list of LSP Diagnostic objects.

    The text is written to a sibling temp file of the real document so that `import "..."`
    statements (resolved relative to the file's directory) still find their targets, then the
    compiler is run on that temp file."""
    path = uri_to_path(uri)
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".mclsp_", suffix=".mc", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        proc = subprocess.run([MCC, "check", tmp], capture_output=True, text=True)
        output = proc.stdout + "\n" + proc.stderr
    except FileNotFoundError:
        log(f"compiler '{MCC}' not found")
        return []
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass

    diags = []
    seen = set()
    for line in output.splitlines():
        m = DIAG_RE.match(line)
        if not m:
            continue
        ln, col, code, msg = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
        key = (ln, col, code)
        if key in seen:
            continue
        seen.add(key)
        # LSP positions are 0-based; the compiler reports 1-based line/column.
        start = {"line": max(ln - 1, 0), "character": max(col - 1, 0)}
        diags.append({
            "range": {"start": start, "end": {"line": start["line"], "character": start["character"] + 1}},
            "severity": 1,  # Error
            "code": code,
            "source": "mcc",
            "message": f"{code}: {msg}",
        })
    return diags


def publish(out, uri, text):
    write_message(out, {
        "jsonrpc": "2.0",
        "method": "textDocument/publishDiagnostics",
        "params": {"uri": uri, "diagnostics": run_diagnostics(uri, text)},
    })


# ---- server loop ---------------------------------------------------------------------------
def main():
    global MCC
    args = sys.argv[1:]
    if "--mcc" in args:
        MCC = args[args.index("--mcc") + 1]

    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    docs = {}  # uri -> text

    while True:
        msg = read_message(stdin)
        if msg is None:
            break
        method = msg.get("method")
        mid = msg.get("id")

        if method == "initialize":
            write_message(stdout, {
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "capabilities": {
                        "textDocumentSync": 1,  # Full
                    },
                    "serverInfo": {"name": "mc-lsp", "version": "0.1.0"},
                },
            })
        elif method == "initialized":
            pass
        elif method == "textDocument/didOpen":
            doc = msg["params"]["textDocument"]
            docs[doc["uri"]] = doc["text"]
            publish(stdout, doc["uri"], doc["text"])
        elif method == "textDocument/didChange":
            uri = msg["params"]["textDocument"]["uri"]
            changes = msg["params"]["contentChanges"]
            if changes:  # Full sync: the last change carries the whole document
                docs[uri] = changes[-1]["text"]
            publish(stdout, uri, docs.get(uri, ""))
        elif method == "textDocument/didSave":
            uri = msg["params"]["textDocument"]["uri"]
            publish(stdout, uri, docs.get(uri, ""))
        elif method == "textDocument/didClose":
            docs.pop(msg["params"]["textDocument"]["uri"], None)
        elif method == "shutdown":
            write_message(stdout, {"jsonrpc": "2.0", "id": mid, "result": None})
        elif method == "exit":
            break
        elif mid is not None:
            # Unknown request: reply MethodNotFound rather than hang the client.
            write_message(stdout, {
                "jsonrpc": "2.0", "id": mid,
                "error": {"code": -32601, "message": f"method not found: {method}"},
            })
        # notifications we don't handle are ignored


if __name__ == "__main__":
    main()
