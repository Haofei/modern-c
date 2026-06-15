#!/usr/bin/env python3
"""mc-lsp — a Language Server for MC built on the `mcc` CLI.

Speaks the Language Server Protocol over stdio (Content-Length-framed JSON-RPC). The compiler
is the single source of truth; the server only drives `mcc` subcommands and translates output:

  - Diagnostics  — on didOpen/didChange/didSave runs `mcc check` and publishes diagnostics with
                   the SAME codes the CLI reports (`E_...`), so an editor squiggle and a CI
                   `mcc check` failure name the identical rule.
  - Formatting   — `textDocument/formatting` runs `mcc fmt` (token-preserving, so it works even
                   while the buffer has type errors).
  - Document symbols — `textDocument/documentSymbol` reuses `mcc emit-map`'s per-declaration
                   rows as a file outline.

Positions are converted from `mcc`'s 1-based byte columns to LSP UTF-16 code-unit offsets, so
ranges are correct on non-ASCII source. Features that need a symbol/type index the CLI does not
yet expose (hover types, go-to-definition, references, rename, semantic tokens) would require a
new `mcc` subcommand and can layer on without changing this transport.

Usage (configured as the language server for `.mc` files in an editor):
    MCC=/path/to/mcc python3 tools/lsp/mc-lsp.py
The `MCC` environment variable (or --mcc) selects the compiler binary; default `mcc` on PATH.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

# `path:line:col: error: rest` — the CLI diagnostic format, where `rest` is either
# `E_CODE: message` (a checked diagnostic) or a bare message (e.g. a parse error like
# `expected function name`). We capture the path so we can keep only the document's own
# diagnostics and drop the compiler's internal Zig stack-trace frames (which use src/*.zig
# paths). A bare `error: ParseFailed`/`CheckFailed` summary line has no path:line:col and so
# never matches.
DIAG_RE = re.compile(r"^(?P<path>.+?):(?P<line>\d+):(?P<col>\d+):\s*error:\s*(?P<rest>.*)$")
CODE_RE = re.compile(r"^(E_[A-Z0-9_]+):\s*(.*)$")

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


# ---- positions -----------------------------------------------------------------------------
# LSP `character` is a UTF-16 code-unit offset, but `mcc` reports a 1-based *byte* column (its
# lexer advances one column per UTF-8 byte). Converting byte→UTF-16 against the document text is
# required for correct ranges on any non-ASCII source (accents, CJK, emoji) — without it the
# squiggle/cursor drifts on every multi-byte character.
def utf16_len(s):
    return sum(2 if ord(c) > 0xFFFF else 1 for c in s)


def byte_col_to_utf16(line_text, byte_col):
    nbytes = max(byte_col - 1, 0)  # 1-based byte column -> 0-based byte offset
    prefix = line_text.encode("utf-8")[:nbytes].decode("utf-8", "ignore")
    return utf16_len(prefix)


def line_of(text_lines, one_based_line):
    idx = one_based_line - 1
    return text_lines[idx] if 0 <= idx < len(text_lines) else ""


# ---- run the compiler on the in-memory document --------------------------------------------
# The text is written to a sibling temp file of the real document so that `import "..."`
# (resolved relative to the file's directory) still finds its targets, then `mcc <args> <tmp>`
# runs on that temp. Returns (returncode, stdout, stderr, tmp_path); tmp_path is the (now
# deleted) name the compiler used, so callers can match it against `source_path` in the output.
def run_on_temp(path, text, args):
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".mclsp_", suffix=".mc", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        proc = subprocess.run([MCC] + args + [tmp], capture_output=True, text=True)
        return proc.returncode, proc.stdout, proc.stderr, tmp
    except FileNotFoundError:
        log(f"compiler '{MCC}' not found")
        return 127, "", "", tmp
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# ---- diagnostics ---------------------------------------------------------------------------
def run_diagnostics(uri, text):
    """Run `mcc check` on `text` and return a list of LSP Diagnostic objects."""
    rc, out, err, tmp = run_on_temp(uri_to_path(uri), text, ["check"])
    if rc == 127:
        return []
    text_lines = text.split("\n")
    diags = []
    seen = set()
    for line in (out + "\n" + err).splitlines():
        m = DIAG_RE.match(line)
        if not m or m.group("path") != tmp:  # skip the compiler's internal stack-trace frames
            continue
        ln, col, rest = int(m.group("line")), int(m.group("col")), m.group("rest")
        cm = CODE_RE.match(rest)
        code, msg = (cm.group(1), cm.group(2)) if cm else (None, rest)
        # Dedup on the full identity so two distinct diagnostics sharing a position are both kept.
        key = (ln, col, code, msg)
        if key in seen:
            continue
        seen.add(key)
        char = byte_col_to_utf16(line_of(text_lines, ln), col)
        start = {"line": max(ln - 1, 0), "character": char}
        diag = {
            "range": {"start": start, "end": {"line": start["line"], "character": char + 1}},
            "severity": 1,  # Error
            "source": "mcc",
            "message": f"{code}: {msg}" if code else msg,
        }
        if code:
            diag["code"] = code
        diags.append(diag)
    return diags


# ---- formatting (textDocument/formatting via `mcc fmt`) ------------------------------------
def format_document(uri, text):
    """Format the document with `mcc fmt` and return a single whole-document TextEdit.

    `mcc fmt` only lexes (it is token-preserving), so it works even while the document has type
    errors. On any failure we return no edits rather than risk mangling the buffer."""
    rc, out, err, _ = run_on_temp(uri_to_path(uri), text, ["fmt"])
    if rc != 0 or out == "":
        return []
    if out == text:
        return []  # already formatted
    lines = text.split("\n")
    end = {"line": len(lines) - 1, "character": utf16_len(lines[-1])}
    return [{"range": {"start": {"line": 0, "character": 0}, "end": end}, "newText": out}]


# ---- document symbols (textDocument/documentSymbol via `mcc emit-map`) ----------------------
# The .mcmap already records one row per declaration with kind/symbol/source_line/source_column;
# we reuse it as a file outline. emit-map requires a successful compile (it runs the full
# pipeline), so a file with errors yields no outline — acceptable LSP behaviour.
SYMBOL_KIND = {
    "function": 12,      # Function
    "struct": 23, "union": 23, "packed_bits": 23, "overlay_union": 23, "opaque": 23,  # Struct
    "enum": 10,          # Enum
    "type_alias": 5,     # Class (closest for an alias)
}
ROW_KIND_RE = re.compile(r'kind="([^"]*)"')
ROW_SYM_RE = re.compile(r'symbol="([^"]*)"')
ROW_PATH_RE = re.compile(r'source_path="([^"]*)"')
ROW_LINE_RE = re.compile(r"source_line=(\d+)")
ROW_COL_RE = re.compile(r"source_column=(\d+)")


def document_symbols(uri, text):
    rc, out, err, tmp = run_on_temp(uri_to_path(uri), text, ["emit-map"])
    if rc != 0:
        return []
    text_lines = text.split("\n")
    syms = []
    seen = set()
    for row in out.splitlines():
        if not row.startswith("entry "):
            continue
        km = ROW_KIND_RE.search(row)
        if not km or km.group(1) not in SYMBOL_KIND:
            continue
        pm = ROW_PATH_RE.search(row)
        if not pm or pm.group(1) != tmp:  # skip declarations pulled in from imports
            continue
        sm, lm, cm = ROW_SYM_RE.search(row), ROW_LINE_RE.search(row), ROW_COL_RE.search(row)
        if not (sm and lm and cm):
            continue
        name, ln, col = sm.group(1), int(lm.group(1)), int(cm.group(1))
        dedup = (name, ln)
        if dedup in seen:
            continue
        seen.add(dedup)
        char = byte_col_to_utf16(line_of(text_lines, ln), col)
        pos = {"line": max(ln - 1, 0), "character": char}
        rng = {"start": pos, "end": {"line": pos["line"], "character": char + utf16_len(name)}}
        syms.append({
            "name": name,
            "kind": SYMBOL_KIND[km.group(1)],
            "range": rng,
            "selectionRange": rng,
        })
    return syms


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
                        "documentFormattingProvider": True,  # via `mcc fmt`
                        "documentSymbolProvider": True,       # via `mcc emit-map`
                    },
                    "serverInfo": {"name": "mc-lsp", "version": "0.2.0"},
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
        elif method == "textDocument/formatting":
            uri = msg["params"]["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": format_document(uri, docs.get(uri, ""))})
        elif method == "textDocument/documentSymbol":
            uri = msg["params"]["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": document_symbols(uri, docs.get(uri, ""))})
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
