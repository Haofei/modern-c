"""Shared parsing primitives for the spec-corpus sweep scripts.

These functions protect NEGATIVE-fixture stripping: a spec fixture interleaves valid
("accept") declarations with EXPECT_ERROR ("reject") declarations, and every sweep must
drop the reject cases before emitting/compiling the remainder. The chunker that does this
is comment/string-aware (punctuation inside a comment or literal is not a delimiter), and
getting it subtly wrong silently un-strips a negative case — so the logic lives in ONE
place rather than being copy-pasted (and drifting) across the sweep scripts.

Consumers (invoked as `python3 tools/toolchain/<name>.py` from the repo root, which puts
tools/toolchain/ on sys.path[0]):
  - spec-emit-sweep.py      uses strip_expect_error
  - spec-llvm-sweep.py      uses valid_program
  - spec-llvm-obj-sweep.py  uses valid_program
  - llvm-opt-sweep.py       uses valid_program
"""
import re


def split_top_level(src):
    """Split source into top-level chunks by brace/semicolon at depth 0.

    Comment- and string-aware: a `{`, `}`, or `;` inside a `//` line comment, a
    `/* */` block comment, or a string/char literal is literal text, NOT a
    structural delimiter. (A comment-blind split mis-chunks any fixture that
    writes punctuation in prose, orphaning the EXPECT_ERROR marker from the
    declaration it annotates so the negative case is never stripped.)
    """
    chunks, buf, depth = [], "", 0
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            j = src.find("\n", i)
            j = n if j == -1 else j + 1
            buf += src[i:j]; i = j; continue
        if c == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            j = n if j == -1 else j + 2
            buf += src[i:j]; i = j; continue
        if c == '"' or c == "'":
            q = c; buf += c; i += 1
            while i < n:
                d = src[i]; buf += d; i += 1
                if d == "\\" and i < n:
                    buf += src[i]; i += 1; continue
                if d == q:
                    break
            continue
        buf += c
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                chunks.append(buf)
                buf = ""
        elif c == ";" and depth == 0:
            chunks.append(buf)
            buf = ""
        i += 1
    if buf.strip():
        chunks.append(buf)
    return chunks


def is_rejected_chunk(chunk):
    return "EXPECT_ERROR" in chunk or "SWEEP_SKIP_DEPENDS_ON_REJECTED_DECL" in chunk


def strip_expect_error(src):
    """Drop rejected declarations and declarations that depend on them."""
    return "".join(ch for ch in split_top_level(src) if not is_rejected_chunk(ch))


def normalize_valid_chunk(chunk):
    """Drop EXPECT_ERROR chunks; rewrite a top-level `fn foo(...);` prototype to an
    `extern fn` so the stripped LLVM program still type-checks (the LLVM sweeps)."""
    if is_rejected_chunk(chunk):
        return ""
    if chunk.strip().endswith(";") and re.search(r"(?m)^\s*fn\s+\w+\s*\(", chunk):
        return re.sub(r"(?m)^(\s*)fn\s+", r"\1extern fn ", chunk, count=1)
    return chunk


def valid_program(src):
    """The fixture's valid declarations only, with prototypes normalized (LLVM sweeps)."""
    return "".join(normalize_valid_chunk(ch) for ch in split_top_level(src))
