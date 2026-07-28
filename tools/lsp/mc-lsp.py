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
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
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
MCC = os.environ.get("MCC_UNDER_TEST") or os.environ.get("MCC") or "mcc"
if not os.path.isabs(MCC) and os.sep in MCC:
    MCC = os.path.abspath(MCC)
DIAGNOSTIC_DEBOUNCE_MS = int(os.environ.get("MC_LSP_DIAGNOSTIC_DEBOUNCE_MS", "150"))
DIAGNOSTIC_DEBOUNCE_SECONDS = max(DIAGNOSTIC_DEBOUNCE_MS, 0) / 1000.0
MCC_TIMEOUT_SECONDS = max(float(os.environ.get("MC_LSP_MCC_TIMEOUT_SECONDS", "15")), 0.1)
WRITE_LOCK = threading.RLock()
MAX_MESSAGE_SIZE = int(os.environ.get("MC_LSP_MAX_MESSAGE_SIZE", str(16 * 1024 * 1024)))
MAX_HEADER_COUNT = 64
MAX_HEADER_LINE = 8192
MAX_WORKSPACE_SOURCE_BYTES = int(os.environ.get("MC_LSP_MAX_WORKSPACE_SOURCE_BYTES", str(4 * 1024 * 1024)))
MAX_WORKSPACE_TOTAL_BYTES = int(os.environ.get("MC_LSP_MAX_WORKSPACE_TOTAL_BYTES", str(64 * 1024 * 1024)))
MAX_WORKSPACE_SOURCES = int(os.environ.get("MC_LSP_MAX_WORKSPACE_SOURCES", "10000"))
MAX_WORKSPACE_SCAN_SECONDS = max(float(os.environ.get("MC_LSP_MAX_WORKSPACE_SCAN_SECONDS", "5")), 0.1)
MAX_WORKSPACE_COMPILER_INVOCATIONS = int(os.environ.get("MC_LSP_MAX_WORKSPACE_COMPILER_INVOCATIONS", "64"))
MAX_WORKSPACE_SYMBOLS = int(os.environ.get("MC_LSP_MAX_WORKSPACE_SYMBOLS", "10000"))
MAX_WORKSPACE_RESULT_BYTES = int(os.environ.get("MC_LSP_MAX_WORKSPACE_RESULT_BYTES", str(4 * 1024 * 1024)))
MAX_COMPILER_OUTPUT_BYTES = int(os.environ.get("MC_LSP_MAX_COMPILER_OUTPUT_BYTES", str(8 * 1024 * 1024)))


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
    header_count = 0
    while True:
        line = stream.readline(MAX_HEADER_LINE + 1)
        if not line:
            return None  # EOF
        if len(line) > MAX_HEADER_LINE:
            raise ValueError("LSP header line exceeds configured limit")
        line = line.decode("ascii").rstrip("\r\n")
        if line == "":
            break
        header_count += 1
        if header_count > MAX_HEADER_COUNT:
            raise ValueError("LSP header count exceeds configured limit")
        if ":" not in line:
            raise ValueError("malformed LSP header")
        k, v = line.split(":", 1)
        key = k.strip().lower()
        if key in headers:
            raise ValueError(f"duplicate LSP header: {key}")
        headers[key] = v.strip()
    if "content-length" not in headers:
        raise ValueError("missing Content-Length")
    try:
        length = int(headers["content-length"], 10)
    except ValueError as error:
        raise ValueError("invalid Content-Length") from error
    if length < 0 or length > MAX_MESSAGE_SIZE:
        raise ValueError("Content-Length is outside the configured bounds")
    chunks = []
    remaining = length
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise ValueError("truncated LSP message body")
        chunks.append(chunk)
        remaining -= len(chunk)
    message = json.loads(b"".join(chunks).decode("utf-8"))
    if not isinstance(message, dict):
        raise ValueError("LSP message must be a JSON object")
    return message


def write_message(stream, payload):
    with WRITE_LOCK:
        data = json.dumps(payload).encode("utf-8")
        stream.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
        stream.write(data)
        stream.flush()


def uri_to_path(uri):
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme == "file":
        # url2pathname performs the percent decoding itself. Decoding beforehand turns a
        # literal `%20` filename (`%2520` in a URI) into a space and can change components.
        path = urllib.request.url2pathname(parsed.path)
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


def terminate_process_tree(proc):
    if proc.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(proc.pid, signal.SIGTERM)
        else:
            proc.terminate()
    except ProcessLookupError:
        return
    except OSError:
        pass
    try:
        proc.wait(timeout=1.0)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "posix":
                kill_signal = getattr(signal, "SIGKILL", signal.SIGTERM)
                os.killpg(proc.pid, kill_signal)
            else:
                proc.kill()
        except ProcessLookupError:
            pass
        except OSError:
            pass


def run_compiler_bounded(argv, cwd, input_text, timeout, cancel_handle=None, start_new_session=False):
    input_bytes = input_text.encode("utf-8")
    out_chunks = []
    err_chunks = []
    out_len = 0
    err_len = 0
    proc = None
    try:
        with tempfile.TemporaryFile() as stdin_file:
            stdin_file.write(input_bytes)
            stdin_file.seek(0)
            popen_kwargs = {
                "cwd": cwd,
                "stdin": stdin_file,
                "stdout": subprocess.PIPE,
                "stderr": subprocess.PIPE,
            }
            if os.name == "posix" and start_new_session:
                popen_kwargs["start_new_session"] = True
            proc = subprocess.Popen(argv, **popen_kwargs)
            if cancel_handle is not None:
                cancel_handle.attach(proc)

            sel = selectors.DefaultSelector()
            assert proc.stdout is not None
            assert proc.stderr is not None
            os.set_blocking(proc.stdout.fileno(), False)
            os.set_blocking(proc.stderr.fileno(), False)
            sel.register(proc.stdout, selectors.EVENT_READ, "stdout")
            sel.register(proc.stderr, selectors.EVENT_READ, "stderr")
            deadline = time.monotonic() + timeout
            timed_out = False
            output_limited = False

            while sel.get_map():
                if cancel_handle is not None and cancel_handle.is_canceled():
                    terminate_process_tree(proc)
                    return None
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    terminate_process_tree(proc)
                    break
                events = sel.select(min(0.1, remaining))
                if not events and proc.poll() is not None:
                    events = [(key, selectors.EVENT_READ) for key in list(sel.get_map().values())]
                for key, _mask in events:
                    try:
                        data = os.read(key.fileobj.fileno(), 65536)
                    except BlockingIOError:
                        continue
                    if not data:
                        try:
                            sel.unregister(key.fileobj)
                        except KeyError:
                            pass
                        continue
                    if key.data == "stdout":
                        out_len += len(data)
                        if out_len <= MAX_COMPILER_OUTPUT_BYTES:
                            out_chunks.append(data)
                    else:
                        err_len += len(data)
                        if err_len <= MAX_COMPILER_OUTPUT_BYTES:
                            err_chunks.append(data)
                    if out_len > MAX_COMPILER_OUTPUT_BYTES or err_len > MAX_COMPILER_OUTPUT_BYTES:
                        output_limited = True
                        terminate_process_tree(proc)
                        break
                if output_limited:
                    break

            try:
                rc = proc.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                terminate_process_tree(proc)
                rc = 124

            out = b"".join(out_chunks).decode("utf-8", "replace")
            err = b"".join(err_chunks).decode("utf-8", "replace")
            if output_limited:
                log(f"compiler '{MCC}' exceeded {MAX_COMPILER_OUTPUT_BYTES} byte output limit")
                return 125, out, "mcc subprocess output exceeded configured limit"
            if timed_out:
                log(f"compiler '{MCC}' exceeded {timeout:g}s timeout")
                return 124, out, err or "mcc subprocess timed out"
            return rc, out, err
    except FileNotFoundError:
        log(f"compiler '{MCC}' not found")
        return 127, "", ""
    except OSError as exc:
        log(f"compiler '{MCC}' failed: {exc}")
        return 126, "", str(exc)
    finally:
        if proc is not None and proc.poll() is None:
            terminate_process_tree(proc)


# ---- run the compiler on the in-memory document --------------------------------------------
# mcc accepts `-` as source input and resolves its imports relative to cwd. This is a real
# in-memory overlay: it preserves relative-import behavior without requiring the source tree
# to be writable.
def run_on_temp(path, text, args, timeout=None):
    directory = os.path.dirname(path) or "."
    argv = [MCC, args[0], "-", *args[1:]]
    effective_timeout = MCC_TIMEOUT_SECONDS if timeout is None else max(min(timeout, MCC_TIMEOUT_SECONDS), 0.001)
    rc, out, err = run_compiler_bounded(argv, directory, text, effective_timeout)
    return rc, out, err, "-"


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
        def run_check(args):
            argv = [MCC, args[0], "-", *args[1:]]
            if cancel_handle is not None and cancel_handle.is_canceled():
                return None
            return run_compiler_bounded(
                argv,
                directory,
                text,
                MCC_TIMEOUT_SECONDS,
                cancel_handle=cancel_handle,
                start_new_session=True,
            )

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


def get_index(uri, text, timeout=None):
    cached = _index_cache.get(uri)
    if cached and cached[0] == text:
        return cached[1]
    rc, out, err, _ = run_on_temp(uri_to_path(uri), text, ["symbols"], timeout=timeout)
    try:
        index = json.loads(out) if out else {"complete": False, "defs": [], "refs": [], "fields": []}
    except (json.JSONDecodeError, ValueError):
        index = {"complete": False, "defs": [], "refs": [], "fields": []}
    if rc == 0 and index.get("complete") is True:
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


def _lt(a, b):
    return (a["line"], a["character"]) < (b["line"], b["character"])


def in_range(pos, rng):
    return _le(rng["start"], pos) and _lt(pos, rng["end"])


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


def is_valid_identifier(name):
    return (isinstance(name, str)
            and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) is not None
            and name not in MC_KEYWORDS)


def do_rename(uri, text, position, new_name):
    if not is_valid_identifier(new_name):
        return None
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
def open_workspace_source(root, path):
    """Open PATH beneath ROOT without following any path component symlink."""
    relative = os.path.relpath(path, root)
    components = relative.split(os.sep)
    if (relative == os.pardir or relative.startswith(os.pardir + os.sep)
            or any(component in ("", ".", os.pardir) for component in components)):
        raise OSError("workspace source escapes root")
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    cloexec = getattr(os, "O_CLOEXEC", 0)
    if os.open in getattr(os, "supports_dir_fd", set()):
        directory_flags = os.O_RDONLY | cloexec | nofollow | getattr(os, "O_DIRECTORY", 0)
        directory_fd = os.open(root, directory_flags)
        try:
            for component in components[:-1]:
                next_fd = os.open(component, directory_flags, dir_fd=directory_fd)
                os.close(directory_fd)
                directory_fd = next_fd
            return os.open(components[-1], os.O_RDONLY | cloexec | nofollow, dir_fd=directory_fd)
        finally:
            os.close(directory_fd)
    return os.open(path, os.O_RDONLY | cloexec | nofollow)


def workspace_sources(docs, roots, deadline=None):
    sources = dict(docs)
    skipped = {".git", ".zig-cache", "zig-out", "zig-pkg", "mc_packages"}
    total_bytes = 0
    if deadline is None:
        deadline = time.monotonic() + MAX_WORKSPACE_SCAN_SECONDS
    for root in roots:
        root_real = os.path.realpath(root)
        if not os.path.isdir(root_real):
            continue
        for directory, dirnames, filenames in os.walk(root_real, followlinks=False):
            if time.monotonic() >= deadline:
                return sources
            dirnames[:] = [name for name in dirnames if name not in skipped]
            for filename in filenames:
                if time.monotonic() >= deadline or len(sources) >= MAX_WORKSPACE_SOURCES:
                    return sources
                if not filename.endswith(".mc"):
                    continue
                path = os.path.join(directory, filename)
                try:
                    lst = os.lstat(path)
                    if not stat.S_ISREG(lst.st_mode) or stat.S_ISLNK(lst.st_mode):
                        continue
                    real_path = os.path.realpath(path)
                    if os.path.commonpath((root_real, real_path)) != root_real:
                        continue
                    fd = open_workspace_source(root_real, path)
                    try:
                        opened = os.fstat(fd)
                        if not stat.S_ISREG(opened.st_mode) or opened.st_size > MAX_WORKSPACE_SOURCE_BYTES:
                            continue
                        if total_bytes + opened.st_size > MAX_WORKSPACE_TOTAL_BYTES:
                            return sources
                        with os.fdopen(fd, "rb", closefd=False) as source:
                            raw = source.read(MAX_WORKSPACE_SOURCE_BYTES + 1)
                        if len(raw) > MAX_WORKSPACE_SOURCE_BYTES:
                            continue
                        text = raw.decode("utf-8")
                    finally:
                        os.close(fd)
                except (OSError, UnicodeDecodeError, ValueError):
                    continue
                uri = path_to_uri(real_path)
                if uri in sources:
                    continue
                sources[uri] = text
                total_bytes += len(raw)
    return sources


def workspace_symbols(docs, query, roots=()):
    deadline = time.monotonic() + MAX_WORKSPACE_SCAN_SECONDS
    q = query.lower()
    results = []
    seen = set()
    result_bytes = 0
    compiler_invocations = 0
    for uri, text in workspace_sources(docs, roots, deadline=deadline).items():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        cached = _index_cache.get(uri)
        if not cached or cached[0] != text:
            if compiler_invocations >= MAX_WORKSPACE_COMPILER_INVOCATIONS:
                break
            compiler_invocations += 1
        index = get_index(uri, text, timeout=remaining)
        for d in index.get("defs", []):
            if time.monotonic() >= deadline or len(results) >= MAX_WORKSPACE_SYMBOLS:
                return results
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
            item = {
                "name": d["name"],
                "kind": KIND_TO_SYMBOLKIND.get(d["kind"], 13),
                "location": location,
            }
            item_bytes = len(json.dumps(item, ensure_ascii=False).encode("utf-8"))
            if result_bytes + item_bytes > MAX_WORKSPACE_RESULT_BYTES:
                return results
            result_bytes += item_bytes
            results.append(item)
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


def _masked_source_prefix(text, position):
    lines = text.splitlines(keepends=True)
    line_no = position["line"]
    if line_no < 0 or line_no >= len(lines):
        return None
    line = lines[line_no].rstrip("\r\n")
    cursor = sum(len(item) for item in lines[:line_no])
    cursor += utf16_to_strindex(line, position["character"])
    prefix = text[:cursor]
    chars = list(prefix)
    state = "normal"
    index = 0
    while index < len(chars):
        c = chars[index]
        nxt = chars[index + 1] if index + 1 < len(chars) else ""
        if state == "line_comment":
            if c == "\n":
                state = "normal"
            else:
                chars[index] = " "
            index += 1
            continue
        if state == "block_comment":
            chars[index] = " "
            if c == "*" and nxt == "/":
                chars[index + 1] = " "
                state = "normal"
                index += 2
            else:
                index += 1
            continue
        if state in ("string", "char"):
            quote = '"' if state == "string" else "'"
            chars[index] = " "
            if c == "\\" and index + 1 < len(chars):
                chars[index + 1] = " "
                index += 2
            elif c == quote:
                state = "normal"
                index += 1
            else:
                index += 1
            continue
        if c == "/" and nxt == "/":
            chars[index] = chars[index + 1] = " "
            state = "line_comment"
            index += 2
        elif c == "/" and nxt == "*":
            chars[index] = chars[index + 1] = " "
            state = "block_comment"
            index += 2
        elif c == '"':
            chars[index] = " "
            state = "string"
            index += 1
        elif c == "'":
            chars[index] = " "
            state = "char"
            index += 1
        else:
            index += 1
    return "".join(chars)


def _callee_before(source, open_index):
    end = open_index
    while end > 0 and source[end - 1].isspace():
        end -= 1
    if end > 0 and source[end - 1] == ">":
        depth = 1
        end -= 1
        while end > 0 and depth:
            end -= 1
            if source[end] == ">":
                depth += 1
            elif source[end] == "<":
                depth -= 1
        while end > 0 and source[end - 1].isspace():
            end -= 1
    start = end
    while start > 0 and (source[start - 1].isalnum() or source[start - 1] == "_"):
        start -= 1
    return source[start:end]


def _generic_call_close(source, open_index):
    if open_index == 0 or source[open_index] != "<":
        return None
    previous = open_index - 1
    while previous >= 0 and source[previous].isspace():
        previous -= 1
    if previous < 0 or not (source[previous].isalnum() or source[previous] in "_>"):
        return None
    depth = 1
    index = open_index + 1
    while index < len(source):
        char = source[index]
        if char == "<":
            depth += 1
        elif char == ">":
            depth -= 1
            if depth == 0:
                after = index + 1
                while after < len(source) and source[after].isspace():
                    after += 1
                return index if after < len(source) and source[after] == "(" else None
        elif char in ";{}" or (char == "\n" and depth == 1):
            return None
        index += 1
    return None


def _active_call(text, position):
    prefix = _masked_source_prefix(text, position)
    if prefix is None:
        return None
    matching = {")": "(", "]": "[", "}": "{"}
    stack = []
    for index, char in enumerate(prefix):
        if stack and stack[-1]["kind"] == "<" and index == stack[-1]["close"]:
            stack.pop()
            continue
        if char == "<":
            generic_close = _generic_call_close(prefix, index)
            if generic_close is not None:
                stack.append({"kind": "<", "close": generic_close, "callee": "", "commas": 0})
                continue
        if char in "([{":
            stack.append({"kind": char,
                          "callee": _callee_before(prefix, index) if char == "(" else "",
                          "commas": 0})
        elif char in ")]}":
            expected = matching[char]
            while stack and stack[-1]["kind"] != expected:
                stack.pop()
            if stack:
                stack.pop()
        elif char == "," and stack:
            stack[-1]["commas"] += 1
    for frame in reversed(stack):
        if frame["kind"] == "(" and frame["callee"]:
            return frame["callee"], frame["commas"]
    return None


def signature_help(uri, text, position):
    active_call = _active_call(text, position)
    if active_call is None:
        return None
    callee, active = active_call

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
def invalid_request_params(msg):
    if not isinstance(msg, dict):
        return -32600, "JSON-RPC message must be an object"
    method = msg.get("method")
    if msg.get("jsonrpc") != "2.0":
        return -32600, "jsonrpc must be exactly '2.0'"
    if not isinstance(method, str):
        return -32600, "method must be a string"
    request_id = msg.get("id")
    if (request_id is not None
            and (isinstance(request_id, bool) or not isinstance(request_id, (int, str)))):
        return -32600, "id must be a string, integer, or null"
    params = msg.get("params", {})
    if params is None:
        params = {}
    if not isinstance(params, dict):
        return -32602, "params must be an object"
    # Dispatch consumes this normalized object rather than rereading `null`.
    msg["params"] = params

    text_document_methods = {
        "textDocument/didOpen", "textDocument/didChange", "textDocument/didSave",
        "textDocument/didClose", "textDocument/formatting", "textDocument/documentSymbol",
        "textDocument/hover", "textDocument/definition", "textDocument/references",
        "textDocument/documentHighlight", "textDocument/rename",
        "textDocument/semanticTokens/full", "textDocument/completion",
        "textDocument/signatureHelp", "textDocument/diagnostic",
        "textDocument/prepareCallHierarchy",
    }
    if method in text_document_methods:
        document = params.get("textDocument")
        if not isinstance(document, dict) or not isinstance(document.get("uri"), str):
            return -32602, "params.textDocument.uri must be a string"

    position_methods = {
        "textDocument/hover", "textDocument/definition", "textDocument/references",
        "textDocument/documentHighlight", "textDocument/rename",
        "textDocument/completion", "textDocument/signatureHelp",
        "textDocument/prepareCallHierarchy",
    }
    if method in position_methods:
        position = params.get("position")
        if (not isinstance(position, dict)
                or not isinstance(position.get("line"), int)
                or not isinstance(position.get("character"), int)
                or position["line"] < 0 or position["character"] < 0):
            return -32602, "params.position must contain nonnegative integer line and character"

    if method == "textDocument/didOpen":
        if not isinstance(params["textDocument"].get("text"), str):
            return -32602, "params.textDocument.text must be a string"
    elif method == "textDocument/didChange":
        changes = params.get("contentChanges")
        if (not isinstance(changes, list)
                or any(not isinstance(change, dict) or not isinstance(change.get("text"), str)
                       for change in changes)):
            return -32602, "params.contentChanges must be an array of full-text changes"
    elif method == "textDocument/rename":
        if not is_valid_identifier(params.get("newName")):
            return -32602, "params.newName must be a non-keyword MC identifier"
    elif method == "textDocument/references":
        context = params.get("context", {})
        if not isinstance(context, dict):
            return -32602, "params.context must be an object"
    elif method == "workspace/symbol":
        if not isinstance(params.get("query", ""), str):
            return -32602, "params.query must be a string"
    elif method == "initialize":
        folders = params.get("workspaceFolders") or []
        if (not isinstance(folders, list)
                or any(not isinstance(folder, dict)
                       or not isinstance(folder.get("uri"), str)
                       for folder in folders)):
            return -32602, "params.workspaceFolders must contain URI objects"
        for key in ("rootUri", "rootPath"):
            if params.get(key) is not None and not isinstance(params[key], str):
                return -32602, f"params.{key} must be a string or null"
    elif method in {"callHierarchy/incomingCalls", "callHierarchy/outgoingCalls"}:
        item = params.get("item")
        if not isinstance(item, dict) or not isinstance(item.get("uri"), str):
            return -32602, "params.item.uri must be a string"
        selection = item.get("selectionRange")
        start = selection.get("start") if isinstance(selection, dict) else None
        if (not isinstance(start, dict)
                or not isinstance(start.get("line"), int)
                or not isinstance(start.get("character"), int)
                or start["line"] < 0 or start["character"] < 0):
            return -32602, "params.item.selectionRange.start must be a valid position"
    return None


def main():
    global MCC
    args = sys.argv[1:]
    if "--mcc" in args:
        index = args.index("--mcc")
        if index + 1 >= len(args) or args[index + 1].startswith("--"):
            print("mc-lsp: --mcc requires a compiler path", file=sys.stderr)
            return 2
        MCC = args[index + 1]
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
        try:
            msg = read_message(stdin)
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
            log("closing malformed JSON-RPC stream:", error)
            break
        if msg is None:
            break
        invalid_params = invalid_request_params(msg)
        if not isinstance(msg, dict):
            log("invalid JSON-RPC message:", invalid_params)
            write_message(stdout, {
                "jsonrpc": "2.0", "id": None,
                "error": {"code": -32600, "message": invalid_params[1]},
            })
            continue
        method = msg.get("method")
        mid = msg.get("id")
        if invalid_params is not None:
            error_code, error_message = invalid_params
            log("invalid request parameters for", method, ":", error_message)
            if mid is not None:
                write_message(stdout, {
                    "jsonrpc": "2.0", "id": mid,
                    "error": {"code": error_code, "message": error_message},
                })
            continue

        try:
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
        except Exception as error:
            # A single malformed or unexpectedly shaped request must never take
            # down the long-lived server.  Validation remains the primary
            # defence; this is the final containment boundary.
            log("request failed for", method, ":", repr(error))
            if mid is not None:
                write_message(stdout, {
                    "jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32603, "message": "internal error"},
                })


if __name__ == "__main__":
    raise SystemExit(main() or 0)
