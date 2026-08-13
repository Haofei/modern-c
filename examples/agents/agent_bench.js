// JS benchmark agent for optional native QuickJS timing checks.
// Prints "BENCH-RESULT=<n>" for harnesses that want a stable workload.
function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2); }
var s = 0;
for (var i = 0; i < 8000; i++) { s = (s + i * 3) % 1000000007; }
var arr = [];
for (var i = 0; i < 20; i++) arr.push({ k: i, v: i * i });
var j = 0;
for (var i = 0; i < arr.length; i++) j += arr[i].v % 97;
var doc = JSON.parse(JSON.stringify({ s: s, j: j, f: fib(18) }));
print("BENCH-RESULT=" + (doc.s + doc.j + doc.f));
