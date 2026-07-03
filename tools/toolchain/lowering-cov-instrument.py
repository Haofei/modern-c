#!/usr/bin/env python3
"""Inject function-entry coverage probes into a backend lowering file (V3.2).

For every Zig function definition in the file (a line of the form
`<indent>[pub ]fn <name>(...) ... {` whose signature ends on that line), insert a
`lower_cov.hit("<basename>:<name>:<lineno>");` call as the first statement of the
body. Also prepend `const lower_cov = @import("lower_cov.zig");` so the probe
resolves. The transform is line-oriented and idempotent-safe (it refuses to run if
the file already imports lower_cov).

Usage: lowering-cov-instrument.py <src.zig>   # rewrites the file in place

Emitted to stdout: the universe of probe labels, one per line, so the report script
knows the full set of functions (covered + uncovered) without re-parsing.
"""
import re
import sys
import os

# A function-definition start: optional indentation, optional `pub `, `fn name(`.
# The opening `{` may be on the same line or a later signature line.
FN_START_RE = re.compile(r'^(?P<indent>\s*)(?:pub\s+)?(?:inline\s+|export\s+)?fn\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(')

def main():
    path = sys.argv[1]
    base = os.path.basename(path)
    with open(path, 'r') as f:
        lines = f.readlines()

    if any('@import("lower_cov.zig")' in ln for ln in lines):
        sys.stderr.write(f"refusing: {path} already instrumented\n")
        sys.exit(2)

    out = []
    labels = []
    start = 0
    while start < len(lines) and lines[start].startswith('//!'):
        out.append(lines[start])
        start += 1
    if start > 0 and start < len(lines) and lines[start].strip() == '':
        out.append(lines[start])
        start += 1
    # Insert after any leading container-doc block; `//!` comments must remain at
    # the top of the file in Zig.
    out.append('const lower_cov = @import("lower_cov.zig");\n')
    pending = None
    for idx, ln in enumerate(lines[start:], start):
        out.append(ln)
        if pending is None:
            m = FN_START_RE.match(ln)
            if not m:
                continue
            pending = (m.group('name'), m.group('indent'), idx + 1)
        name, indent, lineno = pending
        if not re.search(r'\{\s*$', ln):
            continue
        label = f"{base}:{name}:{lineno}"
        labels.append(label)
        out.append(f'{indent}    lower_cov.hit("{label}");\n')
        pending = None

    with open(path, 'w') as f:
        f.writelines(out)

    for label in labels:
        print(label)

if __name__ == '__main__':
    main()
