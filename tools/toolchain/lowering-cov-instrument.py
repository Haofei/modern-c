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

# A function-definition line: optional indentation, optional `pub `, `fn name(`,
# and ending in `{` (whole signature on one line — verified true for both backend
# files). `inline fn` / `export fn` are also handled via the optional qualifier.
FN_RE = re.compile(r'^(?P<indent>\s*)(?:pub\s+)?(?:inline\s+|export\s+)?fn\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(.*\{\s*$')

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
    # Prepend the import. Putting it on its own first line keeps line numbers of the
    # ORIGINAL body shifted by exactly 1, which we account for in the label.
    out.append('const lower_cov = @import("lower_cov.zig");\n')
    for idx, ln in enumerate(lines):
        out.append(ln)
        m = FN_RE.match(ln)
        if not m:
            continue
        # Skip degenerate one-liners like `fn f() void {}` (open+close same line):
        # a probe after `{` would land before `}` which is fine, but these are rare
        # and we still handle them — the insertion is valid Zig either way.
        name = m.group('name')
        indent = m.group('indent')
        lineno = idx + 1  # 1-based line number in the ORIGINAL file
        label = f"{base}:{name}:{lineno}"
        labels.append(label)
        out.append(f'{indent}    lower_cov.hit("{label}");\n')

    with open(path, 'w') as f:
        f.writelines(out)

    for label in labels:
        print(label)

if __name__ == '__main__':
    main()
