#!/usr/bin/env python3
"""mc-lsp — a Language Server for MC built on the `mcc` CLI.

Speaks the Language Server Protocol over stdio (Content-Length-framed JSON-RPC). The compiler
is the single source of truth; the server only drives `mcc` subcommands and translates output:

  - Diagnostics  — on didOpen/didSave runs `mcc check --json` immediately, and on didChange
                   coalesces rapid edits before publishing diagnostics with the SAME codes the
                   CLI reports (`E_...`), so an editor squiggle and a CI `mcc check` failure name
                   the identical rule.
  - Formatting   — `textDocument/formatting` runs `mcc fmt` (token-preserving, so it works even
                   while the buffer has type errors).
  - Document symbols — `textDocument/documentSymbol` reuses `mcc emit-map`'s per-declaration
                   rows as a file outline.
  - Navigation    — hover (type + kind), go-to-definition, find-references, document-highlight,
                   rename, semantic tokens, completion (identifiers in scope + keywords/types,
                   field members after `.`, and type-filtered values in typed contexts),
                   signature help, workspace symbols, and call hierarchy, all driven by
                   `mcc symbols` (a JSON index of definitions, references, and fields with
                   spans).
  - Pull diagnostics — answers the LSP 3.17 `textDocument/diagnostic` request in addition to
                   pushing `publishDiagnostics`.

Positions are converted from `mcc`'s 1-based byte columns to LSP UTF-16 code-unit offsets, so
ranges are correct on non-ASCII source.

Usage (configured as the language server for `.mc` files in an editor):
    MCC=/path/to/mcc python3 tools/lsp/mc-lsp.py
The `MCC` environment variable (or --mcc) selects the compiler binary; default `mcc` on PATH.
"""
import copy
import json
import os
import re
import signal
import subprocess
import sys
import threading
import pathlib
import urllib.parse
import urllib.request

# `path:line:col: error: rest` — the CLI diagnostic format, where `rest` is either
# `E_CODE: message` (a checked diagnostic) or a bare message (e.g. a parse error like
# `expected function name`). We capture the path so we can keep only the document's own
# diagnostics and drop the compiler's internal Zig stack-trace frames (which use src/*.zig
# paths). A bare `error: ParseFailed`/`CheckFailed` summary line has no path:line:col and so
# never matches.
DIAG_RE = re.compile(r"^(?P<path>.+?):(?P<line>\d+):(?P<col>\d+):\s*error:\s*(?P<rest>.*)$")
CODE_RE = re.compile(r"^(E_[A-Z0-9_]+):\s*(.*)$")
VERSION_RE = re.compile(r'^\s*\.version\s*=\s*"([^"]+)"\s*,?\s*$')

HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILD_ZIG_ZON = os.path.join(HERE, "build.zig.zon")
MCC = os.environ.get("MCC", "mcc")
if not os.path.isabs(MCC) and os.sep in MCC:
    MCC = os.path.abspath(MCC)
DIAGNOSTIC_DEBOUNCE_MS = int(os.environ.get("MC_LSP_DIAGNOSTIC_DEBOUNCE_MS", "150"))
DIAGNOSTIC_DEBOUNCE_SECONDS = max(DIAGNOSTIC_DEBOUNCE_MS, 0) / 1000.0
MCC_TIMEOUT_SECONDS = max(float(os.environ.get("MC_LSP_MCC_TIMEOUT_SECONDS", "15")), 0.1)
WRITE_LOCK = threading.RLock()


def log(*a):
    print("[mc-lsp]", *a, file=sys.stderr, flush=True)


def server_version():
    try:
        with open(BUILD_ZIG_ZON, encoding="utf-8") as f:
            for line in f:
                match = VERSION_RE.match(line)
                if match:
                    return match.group(1)
    except OSError:
        pass
    return "0.0.0-dev"


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
    with WRITE_LOCK:
        data = json.dumps(payload).encode("utf-8")
        stream.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
        stream.write(data)
        stream.flush()


def uri_to_path(uri):
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme == "file":
        path = urllib.request.url2pathname(urllib.parse.unquote(parsed.path))
        if parsed.netloc and parsed.netloc not in ("", "localhost"):
            path = f"//{parsed.netloc}{path}"
        if os.name == "nt" and re.match(r"^/[A-Za-z]:", path):
            path = path[1:]
        return path
    return uri


def path_to_uri(path):
    return pathlib.Path(path).absolute().as_uri()


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
# mcc accepts `-` as source input and resolves its imports relative to cwd. This is a real
# in-memory overlay: it preserves relative-import behavior without requiring the source tree
# to be writable.
def run_on_temp(path, text, args):
    directory = os.path.dirname(path) or "."
    argv = [MCC, args[0], "-", *args[1:]]
    try:
        proc = subprocess.run(argv, cwd=directory, input=text,
                              capture_output=True, text=True, timeout=MCC_TIMEOUT_SECONDS)
        return proc.returncode, proc.stdout, proc.stderr, "-"
    except FileNotFoundError:
        log(f"compiler '{MCC}' not found")
        return 127, "", "", "-"
    except subprocess.TimeoutExpired:
        log(f"compiler '{MCC}' exceeded {MCC_TIMEOUT_SECONDS:g}s timeout")
        return 124, "", "mcc subprocess timed out", "-"
    except OSError as exc:
        log(f"compiler '{MCC}' failed: {exc}")
        return 126, "", str(exc), "-"


class DiagnosticRun:
    """Cancellation handle for one in-flight `mcc check` process."""

    def __init__(self):
        self.lock = threading.RLock()
        self.proc = None
        self.canceled = False

    def is_canceled(self):
        with self.lock:
            return self.canceled

    def attach(self, proc):
        with self.lock:
            self.proc = proc
            canceled = self.canceled
        if canceled:
            self._terminate(proc)
        return not canceled

    def cancel(self):
        with self.lock:
            self.canceled = True
            proc = self.proc
        if proc is not None:
            self._terminate(proc)

    def _send_signal(self, proc, sig):
        if proc.poll() is not None:
            return
        try:
            if os.name == "posix":
                os.killpg(proc.pid, sig)
            elif sig == signal.SIGTERM:
                proc.terminate()
            else:
                proc.kill()
        except ProcessLookupError:
            pass
        except OSError:
            pass

    def _terminate(self, proc):
        self._send_signal(proc, signal.SIGTERM)

        def force_kill():
            kill_signal = getattr(signal, "SIGKILL", None)
            if kill_signal is None:
                try:
                    proc.kill()
                except OSError:
                    pass
            else:
                self._send_signal(proc, kill_signal)

        killer = threading.Timer(1.0, force_kill)
        killer.daemon = True
        killer.start()


def run_diagnostic_on_temp(path, text, cancel_handle):
    directory = os.path.dirname(path) or "."
    tmp = "-"
    try:
        if cancel_handle is not None and cancel_handle.is_canceled():
            return None
        popen_kwargs = {"cwd": directory, "stdin": subprocess.PIPE, "stdout": subprocess.PIPE,
                        "stderr": subprocess.PIPE, "text": True}
        if os.name == "posix":
            popen_kwargs["start_new_session"] = True
        def run_check(args):
            argv = [MCC, args[0], "-", *args[1:]]
            try:
                proc = subprocess.Popen(argv, **popen_kwargs)
            except FileNotFoundError:
                log(f"compiler '{MCC}' not found")
                return 127, "", ""
            if cancel_handle is not None:
                cancel_handle.attach(proc)
            try:
                out, err = proc.communicate(text, timeout=MCC_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                DiagnosticRun()._terminate(proc)
                out, err = proc.communicate()
                log(f"compiler '{MCC}' exceeded {MCC_TIMEOUT_SECONDS:g}s diagnostic timeout")
                return 124, out, err
            if cancel_handle is not None and cancel_handle.is_canceled():
                return None
            return proc.returncode, out, err

        result = run_check(["check", "--json"])
        if result is None:
            return None
        rc, out, err = result
        if rc not in (124, 126, 127) and _json_diagnostics_payload(out) is None:
            legacy = run_check(["check"])
            if legacy is None:
                return None
            rc, out, err = legacy
        return rc, out, err, tmp
    except OSError as exc:
        log(f"compiler '{MCC}' failed: {exc}")
        return 126, "", str(exc), tmp


# ---- diagnostics ---------------------------------------------------------------------------
def _json_diagnostics_payload(out):
    try:
        payload = json.loads(out)
    except (TypeError, json.JSONDecodeError):
        return None
    if isinstance(payload, dict) and isinstance(payload.get("diagnostics"), list):
        return payload
    return None


def diagnostic_uri(root_uri, tmp, path):
    if not path or path == tmp or path == "-":
        return root_uri
    if not os.path.isabs(path):
        path = os.path.join(os.path.dirname(uri_to_path(root_uri)), path)
    return path_to_uri(path)


def diagnostic_lines(uri, root_uri, root_lines):
    if uri == root_uri:
        return root_lines
    try:
        with open(uri_to_path(uri), encoding="utf-8") as source:
            return source.read().split("\n")
    except OSError:
        return []


def _lsp_diagnostic_from_json(item, root_uri, tmp, text_lines):
    path = item.get("path") or item.get("file")
    item_uri = diagnostic_uri(root_uri, tmp, path)
    item_lines = diagnostic_lines(item_uri, root_uri, text_lines)
    try:
        ln = int(item.get("line", 1))
        col = int(item.get("column", 1))
    except (TypeError, ValueError):
        return None
    source = item.get("source") if isinstance(item.get("source"), dict) else {}
    span = item.get("span") if isinstance(item.get("span"), dict) else {}
    length = source.get("highlight_length", span.get("length", 1))
    try:
        length = max(int(length), 1)
    except (TypeError, ValueError):
        length = 1
    line_text = line_of(item_lines, ln)
    start_char = byte_col_to_utf16(line_text, col)
    end_char = byte_col_to_utf16(line_text, col + length)
    if end_char <= start_char:
        end_char = start_char + 1
    severity = 2 if item.get("severity") == "warning" else 1
    code = item.get("code")
    msg = item.get("message") or ""
    diag = {
        "range": {
            "start": {"line": max(ln - 1, 0), "character": start_char},
            "end": {"line": max(ln - 1, 0), "character": end_char},
        },
        "severity": severity,
        "source": "mcc",
        "message": f"{code}: {msg}" if code else msg,
    }
    if code:
        diag["code"] = code
    related = []
    for note in item.get("notes", []):
        if not isinstance(note, dict):
            continue
        note_path = note.get("path") or note.get("file")
        note_uri = diagnostic_uri(root_uri, tmp, note_path)
        try:
            note_ln = int(note.get("line", 1))
            note_col = int(note.get("column", 1))
        except (TypeError, ValueError):
            continue
        note_source = note.get("source") if isinstance(note.get("source"), dict) else {}
        note_span = note.get("span") if isinstance(note.get("span"), dict) else {}
        note_length = note_source.get("highlight_length", note_span.get("length", 1))
        try:
            note_length = max(int(note_length), 1)
        except (TypeError, ValueError):
            note_length = 1
        note_line_text = line_of(diagnostic_lines(note_uri, root_uri, text_lines), note_ln)
        note_start = byte_col_to_utf16(note_line_text, note_col)
        note_end = byte_col_to_utf16(note_line_text, note_col + note_length)
        if note_end <= note_start:
            note_end = note_start + 1
        related.append({
            "location": {
                "uri": note_uri,
                "range": {
                    "start": {"line": max(note_ln - 1, 0), "character": note_start},
                    "end": {"line": max(note_ln - 1, 0), "character": note_end},
                },
            },
            "message": note.get("message") or "",
        })
    if related:
        diag["relatedInformation"] = related
    return item_uri, diag


def _diagnostics_from_json(out, root_uri, tmp, text_lines):
    payload = _json_diagnostics_payload(out)
    if payload is None:
        return None
    by_uri = {}
    seen = set()
    for item in payload["diagnostics"]:
        if not isinstance(item, dict):
            continue
        converted = _lsp_diagnostic_from_json(item, root_uri, tmp, text_lines)
        if converted is None:
            continue
        item_uri, diag = converted
        start = diag["range"]["start"]
        key = (item_uri, start["line"], start["character"], diag.get("code"), diag.get("message"))
        if key in seen:
            continue
        seen.add(key)
        by_uri.setdefault(item_uri, []).append(diag)
    return by_uri


def run_diagnostics(uri, text, cancel_handle=None):
    """Run `mcc check` on `text` and return diagnostics, or None when cancelled."""
    if cancel_handle is not None and cancel_handle.is_canceled():
        return None
    cached = _diagnostics_cache.get(uri)
    if cached and cached[0] == text:
        return copy.deepcopy(cached[1])
    result = run_diagnostic_on_temp(uri_to_path(uri), text, cancel_handle)
    if result is None:
        return None
    rc, out, err, tmp = result
    if rc == 127:
        if cancel_handle is not None and cancel_handle.is_canceled():
            return None
        diags = []
        _diagnostics_cache[uri] = (text, copy.deepcopy(diags))
        return diags
    text_lines = text.split("\n")
    json_diags = _diagnostics_from_json(out, uri, tmp, text_lines)
    if json_diags is not None:
        if cancel_handle is not None and cancel_handle.is_canceled():
            return None
        root_diags = json_diags.get(uri, [])
        _related_diagnostics_cache[uri] = {key: value for key, value in json_diags.items() if key != uri}
        _diagnostics_cache[uri] = (text, copy.deepcopy(root_diags))
        return root_diags
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
    if cancel_handle is not None and cancel_handle.is_canceled():
        return None
    _diagnostics_cache[uri] = (text, copy.deepcopy(diags))
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
    cached = _document_symbol_cache.get(uri)
    if cached and cached[0] == text:
        return copy.deepcopy(cached[1])
    rc, out, err, tmp = run_on_temp(uri_to_path(uri), text, ["emit-map"])
    if rc != 0:
        _document_symbol_cache[uri] = (text, [])
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
    _document_symbol_cache[uri] = (text, copy.deepcopy(syms))
    return syms


# ---- symbol index (the `mcc symbols` JSON) -------------------------------------------------
# Cached per-document so a hover/definition/reference burst reuses one compiler call.
_index_cache = {}  # uri -> (text, index)
_diagnostics_cache = {}  # uri -> (text, diagnostics)
_related_diagnostics_cache = {}  # root uri -> {imported uri: diagnostics}
_published_related_diagnostics = {}  # root uri -> imported URIs last published
_document_symbol_cache = {}  # uri -> (text, document symbols)


def invalidate_document_caches(uri):
    _index_cache.pop(uri, None)
    _diagnostics_cache.pop(uri, None)
    _related_diagnostics_cache.pop(uri, None)
    _document_symbol_cache.pop(uri, None)


def get_index(uri, text):
    cached = _index_cache.get(uri)
    if cached and cached[0] == text:
        return cached[1]
    rc, out, err, _ = run_on_temp(uri_to_path(uri), text, ["symbols"])
    try:
        index = json.loads(out) if rc != 127 and out else {"defs": [], "refs": [], "fields": []}
    except (json.JSONDecodeError, ValueError):
        index = {"defs": [], "refs": [], "fields": []}
    _index_cache[uri] = (text, index)
    return index


# An index span is {line (1-based), col (1-based byte), len (bytes)}; convert to an LSP range
# (0-based line, UTF-16 character offsets).
def span_to_range(lines, span):
    ln = span["line"] - 1
    line_text = lines[ln] if 0 <= ln < len(lines) else ""
    start = byte_col_to_utf16(line_text, span["col"])
    end = byte_col_to_utf16(line_text, span["col"] + span["len"])
    ln = max(ln, 0)
    return {"start": {"line": ln, "character": start}, "end": {"line": ln, "character": end}}


def span_uri(root_uri, span):
    path = span.get("path")
    if not path or path == "-":
        return root_uri
    if not os.path.isabs(path):
        path = os.path.join(os.path.dirname(uri_to_path(root_uri)), path)
    return path_to_uri(path)


def span_lines(root_uri, root_lines, span):
    target_uri = span_uri(root_uri, span)
    if target_uri == root_uri:
        return root_lines
    try:
        with open(uri_to_path(target_uri), encoding="utf-8") as source:
            return source.read().split("\n")
    except OSError:
        return []


def span_location(root_uri, root_lines, span):
    return {"uri": span_uri(root_uri, span),
            "range": span_to_range(span_lines(root_uri, root_lines, span), span)}


def span_identity(root_uri, span):
    return (span_uri(root_uri, span), span["line"], span["col"])


def _le(a, b):
    return (a["line"], a["character"]) <= (b["line"], b["character"])


def in_range(pos, rng):
    return _le(rng["start"], pos) and _le(pos, rng["end"])


# Find the def or ref whose span covers `position`: returns ("ref"|"def", entry) or (None, None).
def covering(index, lines, position, uri=None):
    for r in index.get("refs", []):
        if uri is not None and span_uri(uri, r["span"]) != uri:
            continue
        if in_range(position, span_to_range(lines, r["span"])):
            return "ref", r
    for d in index.get("defs", []):
        if uri is not None and span_uri(uri, d["span"]) != uri:
            continue
        if in_range(position, span_to_range(lines, d["span"])):
            return "def", d
    return None, None


# The declaration span (with len) the symbol under `position` belongs to, or None.
def target_def(index, lines, position, uri=None):
    kind, sym = covering(index, lines, position, uri)
    if kind == "ref":
        return sym["def"]      # {line, col, len}
    if kind == "def":
        return sym["span"]
    return None


def hover(uri, text, position):
    index = get_index(uri, text)
    lines = text.split("\n")
    kind, sym = covering(index, lines, position, uri)
    if not sym:
        return None
    md = f"```mc\n{sym['name']}: {sym['type']}\n```\n*{sym['kind']}*"
    return {"contents": {"kind": "markdown", "value": md}, "range": span_to_range(lines, sym["span"])}


def goto_definition(uri, text, position):
    index = get_index(uri, text)
    lines = text.split("\n")
    d = target_def(index, lines, position, uri)
    if not d:
        return None
    return span_location(uri, lines, d)


def _occurrences(index, lines, uri, position, include_decl):
    d = target_def(index, lines, position, uri)
    if not d:
        return []
    identity = span_identity(uri, d)
    locations = [span_location(uri, lines, r["span"]) for r in index.get("refs", [])
                 if span_identity(uri, r["def"]) == identity]
    if include_decl:
        locations.append(span_location(uri, lines, d))
    return locations


def find_references(uri, text, position, include_decl):
    return _occurrences(get_index(uri, text), text.split("\n"), uri, position, include_decl)


def document_highlight(uri, text, position):
    return [{"range": location["range"], "kind": 2}  # DocumentHighlightKind.Read
            for location in _occurrences(get_index(uri, text), text.split("\n"), uri, position, True)
            if location["uri"] == uri]


def do_rename(uri, text, position, new_name):
    locations = _occurrences(get_index(uri, text), text.split("\n"), uri, position, True)
    if not locations:
        return None
    changes = {}
    for location in locations:
        changes.setdefault(location["uri"], []).append({"range": location["range"], "newText": new_name})
    return {"changes": changes}


# Semantic tokens: classify every identifier occurrence (defs + refs) by its symbol kind, then
# delta-encode per the LSP spec (relative line/char, length, tokenType, modifiers).
TOKEN_TYPES = ["function", "variable", "parameter", "type"]
KIND_TO_TOKEN = {
    "function": 0,
    "global": 1, "constant": 1, "local": 1, "local_mut": 1,
    "param": 2,
    "struct": 3, "enum": 3, "union": 3, "packed_bits": 3, "overlay_union": 3,
    "opaque": 3, "type_alias": 3,
}


def semantic_tokens(uri, text):
    index = get_index(uri, text)
    lines = text.split("\n")
    toks = []
    for entry in index.get("defs", []) + index.get("refs", []):
        if span_uri(uri, entry["span"]) != uri:
            continue
        ttype = KIND_TO_TOKEN.get(entry["kind"])
        if ttype is None:
            continue
        rng = span_to_range(lines, entry["span"])
        if rng["start"]["line"] != rng["end"]["line"]:
            continue
        length = rng["end"]["character"] - rng["start"]["character"]
        if length <= 0:
            continue
        toks.append((rng["start"]["line"], rng["start"]["character"], length, ttype))
    toks.sort()
    data = []
    prev_line, prev_char = 0, 0
    for line, char, length, ttype in toks:
        d_line = line - prev_line
        d_char = char - prev_char if d_line == 0 else char
        data += [d_line, d_char, length, ttype, 0]
        prev_line, prev_char = line, char
    return {"data": data}


# ---- workspace symbols (workspace/symbol) --------------------------------------------------
def workspace_sources(docs, roots):
    sources = dict(docs)
    skipped = {".git", ".zig-cache", "zig-out", "zig-pkg", "mc_packages"}
    for root in roots:
        if not os.path.isdir(root):
            continue
        for directory, dirnames, filenames in os.walk(root):
            dirnames[:] = [name for name in dirnames if name not in skipped]
            for filename in filenames:
                if not filename.endswith(".mc"):
                    continue
                path = os.path.join(directory, filename)
                uri = path_to_uri(path)
                if uri in sources:
                    continue
                try:
                    with open(path, encoding="utf-8") as source:
                        sources[uri] = source.read()
                except OSError:
                    continue
                if len(sources) >= 10_000:
                    return sources
    return sources


def workspace_symbols(docs, query, roots=()):
    q = query.lower()
    results = []
    seen = set()
    for uri, text in workspace_sources(docs, roots).items():
        index = get_index(uri, text)
        for d in index.get("defs", []):
            if d["kind"] in ("param", "local", "local_mut"):
                continue  # workspace symbols are top-level only
            if q and q not in d["name"].lower():
                continue
            location = span_location(uri, text.split("\n"), d["span"])
            key = (location["uri"], location["range"]["start"]["line"],
                   location["range"]["start"]["character"], d["name"], d["kind"])
            if key in seen:
                continue
            seen.add(key)
            results.append({
                "name": d["name"],
                "kind": KIND_TO_SYMBOLKIND.get(d["kind"], 13),
                "location": location,
            })
    return results


KIND_TO_SYMBOLKIND = {
    "function": 12, "global": 13, "constant": 14,
    "struct": 23, "union": 23, "packed_bits": 23, "overlay_union": 23, "opaque": 23,
    "enum": 10, "type_alias": 5,
}


# ---- signature help (textDocument/signatureHelp) -------------------------------------------
def utf16_to_strindex(line, u16col):
    u = 0
    for i, c in enumerate(line):
        if u >= u16col:
            return i
        u += 2 if ord(c) > 0xFFFF else 1
    return len(line)


def _split_top_level(s):
    parts, depth, cur = [], 0, ""
    for c in s:
        if c in "(<[":
            depth += 1
        elif c in ")>]":
            depth -= 1
        if c == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += c
    if cur.strip():
        parts.append(cur.strip())
    return parts


def parse_fn_type(t):
    """`fn(P0, P1) -> R` -> (["P0", "P1"], "R"). Returns None if not a function type."""
    if not t.startswith("fn(") and not t.startswith("closure("):
        return None
    open_paren = t.index("(")
    depth, close = 0, -1
    for i in range(open_paren, len(t)):
        if t[i] == "(":
            depth += 1
        elif t[i] == ")":
            depth -= 1
            if depth == 0:
                close = i
                break
    if close < 0:
        return None
    params = _split_top_level(t[open_paren + 1:close])
    rest = t[close + 1:].strip()
    ret = rest[len("->"):].strip() if rest.startswith("->") else ""
    return params, ret


def signature_help(uri, text, position):
    lines = text.split("\n")
    ln = position["line"]
    if ln >= len(lines):
        return None
    line = lines[ln]
    prefix = line[:utf16_to_strindex(line, position["character"])]

    # Find the innermost unmatched '(' to the left of the cursor.
    depth, open_idx = 0, -1
    for i in range(len(prefix) - 1, -1, -1):
        c = prefix[i]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth == 0:
                open_idx = i
                break
            depth -= 1
    if open_idx < 0:
        return None

    # The callee is the identifier immediately before that '('.
    k = open_idx
    while k > 0 and (prefix[k - 1].isalnum() or prefix[k - 1] == "_"):
        k -= 1
    callee = prefix[k:open_idx]
    if not callee:
        return None

    # Active parameter = number of top-level commas between the '(' and the cursor.
    depth, active = 0, 0
    for c in prefix[open_idx + 1:]:
        if c in "(<[":
            depth += 1
        elif c in ")>]":
            depth -= 1
        elif c == "," and depth == 0:
            active += 1

    fn = next((d for d in get_index(uri, text).get("defs", [])
               if d["name"] == callee and d["kind"] == "function"), None)
    if not fn:
        return None
    parsed = parse_fn_type(fn["type"])
    if parsed is None:
        return None
    params, ret = parsed

    # Build "name(P0, P1) -> R" and the [start,end] label offsets for each parameter.
    label = callee + "("
    param_info = []
    for i, p in enumerate(params):
        if i > 0:
            label += ", "
        start = len(label)
        label += p
        param_info.append({"label": [start, len(label)]})
    label += ")"
    if ret:
        label += " -> " + ret
    return {
        "signatures": [{"label": label, "parameters": param_info}],
        "activeSignature": 0,
        "activeParameter": min(active, max(len(params) - 1, 0)),
    }


# ---- call hierarchy (textDocument/prepareCallHierarchy + callHierarchy/*) -------------------
# MC functions do not nest, so the function enclosing a call is simply the last function
# declared at or before that line — no body-range tracking needed.
def _function_defs(index):
    return [d for d in index.get("defs", []) if d["kind"] == "function"]


def enclosing_function(index, line):
    best = None
    for d in _function_defs(index):
        if d["span"]["line"] <= line and (best is None or d["span"]["line"] > best["span"]["line"]):
            best = d
    return best


def function_def_by_pos(index, line, col):
    for d in _function_defs(index):
        if d["span"]["line"] == line and d["span"]["col"] == col:
            return d
    return None


def function_item(uri, lines, d):
    rng = span_to_range(lines, d["span"])
    return {"name": d["name"], "kind": 12, "uri": uri, "detail": d["type"],
            "range": rng, "selectionRange": rng}


def prepare_call_hierarchy(uri, text, position):
    index = get_index(uri, text)
    lines = text.split("\n")
    kind, sym = covering(index, lines, position)
    f = None
    if kind == "def" and sym["kind"] == "function":
        f = sym
    elif kind == "ref" and sym["kind"] == "function":
        f = function_def_by_pos(index, sym["def"]["line"], sym["def"]["col"])
    if f is None:
        f = enclosing_function(index, position["line"] + 1)
    return [function_item(uri, lines, f)] if f else None


def _function_from_item(index, lines, item):
    start = item["selectionRange"]["start"]
    for d in _function_defs(index):
        if span_to_range(lines, d["span"])["start"] == start:
            return d
    return None


def incoming_calls(uri, text, item):
    index = get_index(uri, text)
    lines = text.split("\n")
    target = _function_from_item(index, lines, item)
    if not target:
        return []
    tl, tc = target["span"]["line"], target["span"]["col"]
    callers = {}  # caller (line,col) -> (def, [ranges])
    for r in index.get("refs", []):
        if r["kind"] != "function" or r["def"]["line"] != tl or r["def"]["col"] != tc:
            continue
        caller = enclosing_function(index, r["span"]["line"])
        if not caller:
            continue
        key = (caller["span"]["line"], caller["span"]["col"])
        callers.setdefault(key, (caller, []))[1].append(span_to_range(lines, r["span"]))
    return [{"from": function_item(uri, lines, c), "fromRanges": rngs} for c, rngs in callers.values()]


def outgoing_calls(uri, text, item):
    index = get_index(uri, text)
    lines = text.split("\n")
    src = _function_from_item(index, lines, item)
    if not src:
        return []
    sl, sc = src["span"]["line"], src["span"]["col"]
    callees = {}
    for r in index.get("refs", []):
        if r["kind"] != "function":
            continue
        enc = enclosing_function(index, r["span"]["line"])
        if not enc or enc["span"]["line"] != sl or enc["span"]["col"] != sc:
            continue
        callee = function_def_by_pos(index, r["def"]["line"], r["def"]["col"])
        if not callee:
            continue
        key = (callee["span"]["line"], callee["span"]["col"])
        callees.setdefault(key, (callee, []))[1].append(span_to_range(lines, r["span"]))
    return [{"to": function_item(uri, lines, c), "fromRanges": rngs} for c, rngs in callees.values()]


# ---- completion (textDocument/completion) --------------------------------------------------
# Offers the identifiers visible at the cursor — every top-level declaration, plus the params
# and locals of the enclosing function declared at or before the cursor — together with the MC
# keywords and primitive types. In typed value contexts (`let x: T =`, `return`, simple
# assignment, and simple call arguments), candidates are narrowed to values compatible with the
# expected type. Scope is approximated from the symbol index's declaration lines (functions do
# not nest); over-inclusion is harmless for untyped completion.
MC_KEYWORDS = [
    "fn", "let", "var", "const", "struct", "enum", "union", "type", "closure", "return", "if",
    "else", "switch", "match", "for", "while", "break", "continue", "defer", "unsafe", "comptime",
    "import", "export", "extern", "move", "opaque", "packed", "overlay", "asm", "assert",
    "sizeof", "alignof", "true", "false", "null", "ok", "err", "mut", "unreachable",
]
MC_PRIMITIVES = [
    "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "bool", "void",
    "f32", "f64",
]
COMPLETION_KIND = {  # LSP CompletionItemKind
    "function": 3, "global": 6, "constant": 21, "local": 6, "local_mut": 6, "param": 6,
    "struct": 22, "enum": 13, "type_alias": 7, "field": 5,
}


def utf16_to_py_index(s, character):
    used = 0
    for i, ch in enumerate(s):
        width = 2 if ord(ch) > 0xFFFF else 1
        if used + width > character:
            return i
        used += width
        if used == character:
            return i + 1
    return len(s)


MEMBER_COMPLETION_RE = re.compile(
    r"([A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)?$"
)
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def member_context(text, position):
    lines = text.split("\n")
    if position["line"] < 0 or position["line"] >= len(lines):
        return None
    line = lines[position["line"]]
    prefix = line[:utf16_to_py_index(line, position["character"])]
    match = MEMBER_COMPLETION_RE.search(prefix)
    if not match:
        return None
    chain = [part.strip() for part in match.group(1).split(".")]
    if not chain or not all(IDENT_RE.match(part) for part in chain):
        return None
    return chain, match.group(2) or ""


def visible_value_defs(index, position):
    cursor_line = position["line"] + 1
    out = {}
    for d in index.get("defs", []):
        if d["kind"] in ("global", "constant"):
            out.setdefault(d["name"], d)

    enc = enclosing_function(index, cursor_line)
    if enc:
        func_line = enc["span"]["line"]
        next_line = min([d["span"]["line"] for d in _function_defs(index)
                         if d["span"]["line"] > func_line], default=10 ** 9)
        for d in index.get("defs", []):
            if (d["kind"] in ("param", "local", "local_mut")
                    and func_line <= d["span"]["line"] <= cursor_line
                    and d["span"]["line"] < next_line):
                out[d["name"]] = d
    return out


def type_aliases(index):
    return {d["name"]: d["type"] for d in index.get("defs", []) if d["kind"] == "type_alias"}


def normalize_type_name(ty, aliases):
    seen = set()
    current = ty.strip()
    while current and current not in seen:
        seen.add(current)
        changed = False
        for prefix in ("mut ", "const "):
            if current.startswith(prefix):
                current = current[len(prefix):].strip()
                changed = True
        while current.startswith("?"):
            current = current[1:].strip()
            changed = True
        while current.startswith("*"):
            current = current[1:].strip()
            changed = True
            for prefix in ("mut ", "const "):
                if current.startswith(prefix):
                    current = current[len(prefix):].strip()
        base = current.split("<", 1)[0].strip()
        if base in aliases:
            current = aliases[base].strip()
            changed = True
            continue
        if not changed:
            return base
    return current.split("<", 1)[0].strip()


def fields_for_owner(index, owner):
    return [f for f in index.get("fields", []) if f.get("owner") == owner]


def resolve_member_chain_type(index, position, chain):
    visible = visible_value_defs(index, position)
    current = visible.get(chain[0])
    if not current:
        return None
    aliases = type_aliases(index)
    ty = normalize_type_name(current.get("type", "?"), aliases)
    for field_name in chain[1:]:
        field = next((f for f in fields_for_owner(index, ty) if f.get("name") == field_name), None)
        if not field:
            return None
        ty = normalize_type_name(field.get("type", "?"), aliases)
    return ty


def function_return_type(ty):
    parsed = parse_fn_type(ty)
    if parsed is None:
        return None
    return parsed[1] or None


def type_matches(candidate, expected, aliases):
    cand = normalize_type_name(candidate, aliases)
    exp = normalize_type_name(expected, aliases)
    if not cand or not exp or cand == "?" or exp == "?":
        return False
    return cand == exp


def simple_call_expected_type(index, prefix):
    depth, open_idx = 0, -1
    for i in range(len(prefix) - 1, -1, -1):
        c = prefix[i]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth == 0:
                open_idx = i
                break
            depth -= 1
    if open_idx < 0:
        return None

    k = open_idx
    while k > 0 and (prefix[k - 1].isalnum() or prefix[k - 1] == "_"):
        k -= 1
    callee = prefix[k:open_idx]
    if not callee:
        return None

    depth, active = 0, 0
    for c in prefix[open_idx + 1:]:
        if c in "(<[":
            depth += 1
        elif c in ")>]":
            depth -= 1
        elif c == "," and depth == 0:
            active += 1

    fn = next((d for d in index.get("defs", [])
               if d["name"] == callee and d["kind"] == "function"), None)
    if not fn:
        return None
    parsed = parse_fn_type(fn["type"])
    if parsed is None:
        return None
    params, _ = parsed
    return params[active] if active < len(params) else None


LET_INIT_RE = re.compile(r"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*([^=;]+)=\s*$")
ASSIGN_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*$")


def expected_type_context(index, text, position):
    lines = text.split("\n")
    if position["line"] < 0 or position["line"] >= len(lines):
        return None
    line = lines[position["line"]]
    prefix = line[:utf16_to_py_index(line, position["character"])]

    call_expected = simple_call_expected_type(index, prefix)
    if call_expected:
        return call_expected

    let_match = LET_INIT_RE.search(prefix)
    if let_match:
        return let_match.group(1).strip()

    stripped = prefix.strip()
    if stripped == "return" or stripped.startswith("return "):
        enc = enclosing_function(index, position["line"] + 1)
        if enc:
            return function_return_type(enc.get("type", ""))

    assign_match = ASSIGN_RE.search(prefix)
    if assign_match and not re.search(r"[=!<>]=\s*$", prefix):
        target = visible_value_defs(index, position).get(assign_match.group(1))
        if target:
            return target.get("type")
    return None


def add_type_filtered_completion(index, position, expected, add):
    aliases = type_aliases(index)

    for d in visible_value_defs(index, position).values():
        if type_matches(d.get("type", "?"), expected, aliases):
            add(d["name"], COMPLETION_KIND[d["kind"]], d["type"])

    for d in index.get("defs", []):
        if d["kind"] != "function":
            continue
        ret = function_return_type(d.get("type", ""))
        if ret and type_matches(ret, expected, aliases):
            add(d["name"], COMPLETION_KIND["function"], d["type"])

    normalized_expected = normalize_type_name(expected, aliases)
    if normalized_expected == "bool":
        add("true", 12, "bool")
        add("false", 12, "bool")
    if expected.strip().startswith("?"):
        add("null", 12, expected.strip())


def completion(uri, text, position):
    index = get_index(uri, text)
    items = []
    seen = set()

    def add(label, kind, detail=None):
        if label in seen:
            return
        seen.add(label)
        it = {"label": label, "kind": kind}
        if detail:
            it["detail"] = detail
        items.append(it)

    member = member_context(text, position)
    if member:
        chain, prefix = member
        owner = resolve_member_chain_type(index, position, chain)
        if owner:
            for field in fields_for_owner(index, owner):
                label = field.get("name", "")
                if label.startswith(prefix):
                    add(label, COMPLETION_KIND["field"], field.get("type"))
            return {"isIncomplete": False, "items": items}
        return {"isIncomplete": False, "items": []}

    expected = expected_type_context(index, text, position)
    if expected:
        add_type_filtered_completion(index, position, expected, add)
        return {"isIncomplete": False, "items": items}

    # Top-level declarations are always in scope.
    for d in index.get("defs", []):
        if d["kind"] in ("function", "global", "constant", "struct", "enum", "type_alias"):
            add(d["name"], COMPLETION_KIND[d["kind"]], d["type"])

    # Params/locals of the enclosing function, declared at or before the cursor line.
    enc = enclosing_function(index, position["line"] + 1)
    if enc:
        func_line = enc["span"]["line"]
        next_line = min([d["span"]["line"] for d in _function_defs(index)
                         if d["span"]["line"] > func_line], default=10 ** 9)
        cursor_line = position["line"] + 1
        for d in index.get("defs", []):
            if (d["kind"] in ("param", "local", "local_mut")
                    and func_line <= d["span"]["line"] <= cursor_line
                    and d["span"]["line"] < next_line):
                add(d["name"], 6, d["type"])

    for kw in MC_KEYWORDS:
        add(kw, 14)  # Keyword
    for ty in MC_PRIMITIVES:
        add(ty, 7)   # Class (closest for a type)
    return {"isIncomplete": False, "items": items}


def publish_diagnostics(out, uri, diagnostics):
    write_message(out, {
        "jsonrpc": "2.0",
        "method": "textDocument/publishDiagnostics",
        "params": {"uri": uri, "diagnostics": diagnostics},
    })


def publish_related_diagnostics(out, root_uri):
    related = _related_diagnostics_cache.get(root_uri, {})
    previous = _published_related_diagnostics.get(root_uri, set())
    for stale_uri in previous - set(related):
        publish_diagnostics(out, stale_uri, [])
    for related_uri, diagnostics in related.items():
        publish_diagnostics(out, related_uri, diagnostics)
    _published_related_diagnostics[root_uri] = set(related)


def publish(out, uri, text):
    diagnostics = run_diagnostics(uri, text)
    publish_diagnostics(out, uri, diagnostics)
    publish_related_diagnostics(out, uri)


# ---- server loop ---------------------------------------------------------------------------
def main():
    global MCC
    args = sys.argv[1:]
    if "--mcc" in args:
        MCC = args[args.index("--mcc") + 1]
        if not os.path.isabs(MCC) and os.sep in MCC:
            MCC = os.path.abspath(MCC)

    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    docs = {}  # uri -> text
    doc_versions = {}  # uri -> internal monotonically increasing document generation
    diag_timers = {}  # uri -> threading.Timer
    active_diag_runs = {}  # uri -> DiagnosticRun
    state_lock = threading.RLock()
    shutting_down = False
    workspace_roots = []

    def next_doc_version(uri):
        return doc_versions.get(uri, 0) + 1

    def update_doc(uri, text):
        with state_lock:
            docs[uri] = text
            doc_versions[uri] = next_doc_version(uri)
            invalidate_document_caches(uri)

    def get_doc_text(uri):
        with state_lock:
            return docs.get(uri, "")

    def cancel_pending_diagnostics_locked(uri):
        timer = diag_timers.pop(uri, None)
        if timer is not None:
            timer.cancel()
        run = active_diag_runs.pop(uri, None)
        if run is not None:
            run.cancel()

    def cancel_pending_diagnostics(uri):
        with state_lock:
            cancel_pending_diagnostics_locked(uri)

    def cancel_all_diagnostics():
        with state_lock:
            for timer in diag_timers.values():
                timer.cancel()
            diag_timers.clear()
            runs = list(active_diag_runs.values())
            active_diag_runs.clear()
        for run in runs:
            run.cancel()

    def schedule_diagnostics(uri):
        with state_lock:
            if shutting_down or uri not in docs:
                return
            cancel_pending_diagnostics_locked(uri)
            expected_version = doc_versions.get(uri, 0)

        timer_ref = {"timer": None}

        def worker():
            with state_lock:
                text = docs.get(uri)
                if shutting_down or text is None or doc_versions.get(uri, 0) != expected_version:
                    return
                diag_run = DiagnosticRun()
                active_diag_runs[uri] = diag_run

            diagnostics = run_diagnostics(uri, text, diag_run)

            with state_lock:
                if active_diag_runs.get(uri) is diag_run:
                    active_diag_runs.pop(uri, None)
                if diag_timers.get(uri) is timer_ref["timer"]:
                    diag_timers.pop(uri, None)
                if (diagnostics is None or shutting_down or docs.get(uri) is None
                        or doc_versions.get(uri, 0) != expected_version):
                    return

            publish_diagnostics(stdout, uri, diagnostics)
            publish_related_diagnostics(stdout, uri)

        timer = threading.Timer(DIAGNOSTIC_DEBOUNCE_SECONDS, worker)
        timer.daemon = True
        timer_ref["timer"] = timer
        with state_lock:
            if shutting_down or uri not in docs or doc_versions.get(uri, 0) != expected_version:
                return
            diag_timers[uri] = timer
        timer.start()

    while True:
        msg = read_message(stdin)
        if msg is None:
            break
        method = msg.get("method")
        mid = msg.get("id")

        if method == "initialize":
            params = msg.get("params", {})
            folders = params.get("workspaceFolders") or []
            for folder in folders:
                folder_uri = folder.get("uri") if isinstance(folder, dict) else None
                if folder_uri:
                    workspace_roots.append(uri_to_path(folder_uri))
            root_uri = params.get("rootUri")
            root_path = params.get("rootPath")
            if root_uri:
                workspace_roots.append(uri_to_path(root_uri))
            elif root_path:
                workspace_roots.append(root_path)
            workspace_roots[:] = list(dict.fromkeys(os.path.abspath(root) for root in workspace_roots))
            write_message(stdout, {
                "jsonrpc": "2.0",
                "id": mid,
                "result": {
                    "capabilities": {
                        "textDocumentSync": 1,  # Full
                        "documentFormattingProvider": True,  # via `mcc fmt`
                        "documentSymbolProvider": True,       # via `mcc emit-map`
                        # the following are powered by `mcc symbols`
                        "hoverProvider": True,
                        "definitionProvider": True,
                        "referencesProvider": True,
                        "documentHighlightProvider": True,
                        "renameProvider": True,
                        "semanticTokensProvider": {
                            "legend": {"tokenTypes": TOKEN_TYPES, "tokenModifiers": []},
                            "full": True,
                        },
                        "workspaceSymbolProvider": True,
                        "callHierarchyProvider": True,
                        "completionProvider": {"triggerCharacters": ["."]},
                        "signatureHelpProvider": {"triggerCharacters": ["(", ","]},
                        "diagnosticProvider": {  # LSP 3.17 pull model (in addition to push)
                            "interFileDependencies": True,
                            "workspaceDiagnostics": False,
                        },
                    },
                    "serverInfo": {"name": "mc-lsp", "version": server_version()},
                },
            })
        elif method == "initialized":
            pass
        elif method == "textDocument/didOpen":
            doc = msg["params"]["textDocument"]
            cancel_pending_diagnostics(doc["uri"])
            update_doc(doc["uri"], doc["text"])
            publish(stdout, doc["uri"], doc["text"])
        elif method == "textDocument/didChange":
            uri = msg["params"]["textDocument"]["uri"]
            changes = msg["params"]["contentChanges"]
            if changes:  # Full sync: the last change carries the whole document
                update_doc(uri, changes[-1]["text"])
                schedule_diagnostics(uri)
        elif method == "textDocument/didSave":
            uri = msg["params"]["textDocument"]["uri"]
            cancel_pending_diagnostics(uri)
            _diagnostics_cache.pop(uri, None)
            _related_diagnostics_cache.pop(uri, None)
            publish(stdout, uri, get_doc_text(uri))
        elif method == "textDocument/didClose":
            uri = msg["params"]["textDocument"]["uri"]
            with state_lock:
                cancel_pending_diagnostics_locked(uri)
                docs.pop(uri, None)
                doc_versions.pop(uri, None)
                invalidate_document_caches(uri)
                for related_uri in _published_related_diagnostics.pop(uri, set()):
                    publish_diagnostics(stdout, related_uri, [])
        elif method == "textDocument/formatting":
            uri = msg["params"]["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": format_document(uri, get_doc_text(uri))})
        elif method == "textDocument/documentSymbol":
            uri = msg["params"]["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": document_symbols(uri, get_doc_text(uri))})
        elif method == "textDocument/hover":
            p = msg["params"]
            uri = p["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": hover(uri, get_doc_text(uri), p["position"])})
        elif method == "textDocument/definition":
            p = msg["params"]
            uri = p["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": goto_definition(uri, get_doc_text(uri), p["position"])})
        elif method == "textDocument/references":
            p = msg["params"]
            uri = p["textDocument"]["uri"]
            include = p.get("context", {}).get("includeDeclaration", True)
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": find_references(uri, get_doc_text(uri), p["position"], include)})
        elif method == "textDocument/documentHighlight":
            p = msg["params"]
            uri = p["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": document_highlight(uri, get_doc_text(uri), p["position"])})
        elif method == "textDocument/rename":
            p = msg["params"]
            uri = p["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": do_rename(uri, get_doc_text(uri), p["position"], p["newName"])})
        elif method == "textDocument/semanticTokens/full":
            uri = msg["params"]["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": semantic_tokens(uri, get_doc_text(uri))})
        elif method == "textDocument/completion":
            p = msg["params"]
            uri = p["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": completion(uri, get_doc_text(uri), p["position"])})
        elif method == "textDocument/signatureHelp":
            p = msg["params"]
            uri = p["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": signature_help(uri, get_doc_text(uri), p["position"])})
        elif method == "textDocument/diagnostic":
            uri = msg["params"]["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": {"kind": "full",
                                              "items": run_diagnostics(uri, get_doc_text(uri))}})
        elif method == "workspace/symbol":
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": workspace_symbols(docs, msg["params"].get("query", ""), workspace_roots)})
        elif method == "textDocument/prepareCallHierarchy":
            p = msg["params"]
            uri = p["textDocument"]["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": prepare_call_hierarchy(uri, get_doc_text(uri), p["position"])})
        elif method == "callHierarchy/incomingCalls":
            item = msg["params"]["item"]
            uri = item["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": incoming_calls(uri, get_doc_text(uri), item)})
        elif method == "callHierarchy/outgoingCalls":
            item = msg["params"]["item"]
            uri = item["uri"]
            write_message(stdout, {"jsonrpc": "2.0", "id": mid,
                                   "result": outgoing_calls(uri, get_doc_text(uri), item)})
        elif method == "shutdown":
            shutting_down = True
            cancel_all_diagnostics()
            write_message(stdout, {"jsonrpc": "2.0", "id": mid, "result": None})
        elif method == "exit":
            shutting_down = True
            cancel_all_diagnostics()
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
