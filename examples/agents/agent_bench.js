// Phase-7 JS benchmark agent (native QuickJS side). The SAME deterministic workload as
// examples/apps/wasm/wasi_js_bench.c's SCRIPT (recursion + an integer reduction loop + object-array
// + JSON churn), printing "BENCH-RESULT=<n>". The Phase-7 harness asserts this matches the WASM
// path's result (functional parity) and records each path's QEMU wall time + image size. Keep the
// computation byte-for-byte equivalent to wasi_js_bench.c so the results match.
function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2); }
var s = 0;
for (var i = 0; i < 8000; i++) { s = (s + i * 3) % 1000000007; }
var arr = [];
for (var i = 0; i < 20; i++) arr.push({ k: i, v: i * i });
var j = 0;
for (var i = 0; i < arr.length; i++) j += arr[i].v % 97;
var doc = JSON.parse(JSON.stringify({ s: s, j: j, f: fib(18) }));
print("BENCH-RESULT=" + (doc.s + doc.j + doc.f));
