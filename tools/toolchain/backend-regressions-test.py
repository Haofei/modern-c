#!/usr/bin/env python3
"""Compile and execute regressions for static data and executable MIR lowering."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
MCC = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / 'zig-out/bin/mcc').resolve()
CLANG = os.environ.get('CLANG', 'clang')


def run(args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True,
                            timeout=120, cwd=ROOT, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}\n{result.stdout}{result.stderr}")
    return result.stdout


CASES = {
    'static_aggregates': '''
global matrix: [2][2]u32 = .{ .{1, 2}, .{3, 4} };
global pairs: [2]Pair = .{ .{ .x = 5 }, .{ .x = 6 } };
struct Pair { x: u32 }
const fn values() -> [2]u32 { return .{7, 8}; }
const fn pair() -> Pair { return .{ .x = 9 }; }
global folded: [2]u32 = values();
global folded_pair: Pair = pair();
global index: usize = 1;
global p: *const u32 = &matrix[index][0];
global q: *const u32 = &pairs[1].x;
export fn entry() -> u32 {
    if matrix[1][0] != 3 { return 1; }
    if pairs[1].x != 6 { return 2; }
    if folded[1] != 8 { return 3; }
    if folded_pair.x != 9 { return 4; }
    if p.* != 3 { return 5; }
    if q.* != 6 { return 6; }
    return 0;
}
''',
    'alias_and_struct_slices': '''
type Word = u32;
struct Inner { x: u32 }
struct Outer { objects: []const Inner, words: []const Word, numbers: []const u32 }
struct Arrays { words: [2]Word, numbers: [2]u32 }
struct Options { word: ?Word, number: ?u32 }
struct Callbacks { word: fn(Word) -> Word, number: fn(u32) -> u32 }
export fn entry() -> u32 { return 0; }
''',
    'discarded_result': '''
global calls: u32 = 0;
fn effect() -> u32 { calls = calls + 1; return 9; }
export fn entry() -> u32 { effect(); return calls - 1; }
''',
    'void_result': '''
enum E { failed }
global calls: u32 = 0;
fn effect() -> void { calls = calls + 1; }
fn marker() -> Result<void, E> { return ok(effect()); }
fn unit() -> Result<void, E> { return ok(()); }
export fn entry() -> u32 {
    switch marker() { ok(v) => {}, err(e) => { return 2; }, }
    switch unit() { ok(v) => {}, err(e) => { return 3; }, }
    return calls - 1;
}
''',
    'nullable_callable': '''
type Callback = fn(u32) -> u32;
global cb: ?fn(u32) -> u32;
global alias_cb: ?Callback;
export fn entry() -> u32 { return 0; }
''',
    'wide_signed': '''
fn minimum() -> i128 { return -170141183460469231731687303715884105728; }
fn maximum() -> i128 { return 170141183460469231731687303715884105727; }
export fn entry() -> u32 {
    if minimum() + maximum() != -1 { return 1; }
    if minimum() >= 0 { return 2; }
    return 0;
}
''',
}

with tempfile.TemporaryDirectory(prefix='mcc-backend-regressions-') as work:
    work = Path(work)
    harness = work / 'harness.c'
    harness.write_text('#include <stdint.h>\nextern uint32_t entry(void);\nint main(void) { return (int)entry(); }\n')
    for name, source in CASES.items():
        path = work / f'{name}.mc'
        path.write_text(source)
        for backend, ext in [('c', 'c'), ('llvm', 'll')]:
            artifact = work / f'{name}.{ext}'
            artifact.write_text(run([MCC, f'emit-{backend}', path]))
            exe = work / f'{name}-{backend}'
            flags = ['-std=c11', '-Wall', '-Wextra', '-Werror'] if backend == 'c' else ['-Wno-override-module']
            run([CLANG, *flags, artifact, harness, '-o', exe])
            run([exe])
        # Exercise the hosted driver's own strict compiler flags as well.
        if name == 'discarded_result':
            path.write_text(source.replace('fn entry()', 'fn main()'))
            exe = work / 'hosted-discard'
            run([MCC, 'build', path, '-o', exe])
            run([exe])
        print(f'PASS: {name} (C and LLVM runtime)')

    # Cover direct fields, whole-struct stores, global array elements and loads.
    closure = work / 'closure.mc'
    closure.write_text((ROOT / 'tests/c_emit/global_closure.mc').read_text() +
                       '\nfn copy_slot() -> void { g_slot = g_table[2]; }\n')
    artifact = work / 'closure.c'
    artifact.write_text(run([MCC, 'emit-c', closure]) + '''
int main(void) {
    install();
    if (invoke(7) != 7 || invoke_direct(8) != 8 || !check(0)) return 1;
    install_at(2);
    set_active_at(2, true); set_run_at(2); set_probe_at(2);
    if (!active_at(2) || invoke_field_at(2, 9) != 9) return 2;
    if (invoke_field_direct_at(2, 10) != 10 || !check_field_at(2, 0)) return 3;
    copy_slot();
    if (invoke(12) != 12) return 4;
    return invoke_at(2, 11) != 11;
}
''')
    exe = work / 'closure'
    run([CLANG, '-std=c11', '-Wall', '-Wextra', '-Werror', artifact, '-o', exe])
    run([exe])
    llvm_closure = work / 'closure.ll'
    llvm_closure.write_text(run([MCC, 'emit-llvm', closure]))
    run([CLANG, '-Wno-override-module', '-c', llvm_closure, '-o', work / 'closure.o'])
    print('PASS: closure field and aggregate race accesses (C runtime, LLVM compilation)')

    # Existing imported async fixture exercises generated declarations across files.
    run([MCC, 'check', ROOT / 'tests/c_emit/fuzz_async_syntax.mc'])
    print('PASS: imported async source identity')

print("PASS: backend-regressions-test")
