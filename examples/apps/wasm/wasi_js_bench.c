// examples/apps/wasm/wasi_js_bench.c — Phase-7 JS benchmark guest (QuickJS-on-WASM side). Evaluates
// the SAME deterministic JS workload as examples/agents/agent_bench.js (native QuickJS side):
// recursion (fib), an integer reduction loop, and object-array + JSON churn. The eval RETURNS a
// single integer; we print "BENCH-RESULT=<n>". The Phase-7 harness (wasm-js-bench-test.sh) runs this
// guest and the native agent and asserts the SAME result (functional parity) while recording each
// path's QEMU wall time + U-mode image size into zig-out/wasm-js-bench.json. Keep the SCRIPT byte-for-
// byte equivalent to agent_bench.js's computation so the results match.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "quickjs.h"

static const char *SCRIPT =
    "function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2); }\n"
    "var s = 0;\n"
    "for (var i = 0; i < 30000; i++) { s = (s + i * 3) % 1000000007; }\n"
    "var arr = [];\n"
    "for (var i = 0; i < 20; i++) arr.push({ k: i, v: i * i });\n"
    "var j = 0;\n"
    "for (var i = 0; i < arr.length; i++) j += arr[i].v % 97;\n"
    "var doc = JSON.parse(JSON.stringify({ s: s, j: j, f: fib(22) }));\n"
    "doc.s + doc.j + doc.f;\n";

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { printf("bench: no-rt\n"); return 1; }
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { printf("bench: no-ctx\n"); return 1; }

    JSValue val = JS_Eval(ctx, SCRIPT, strlen(SCRIPT), "<bench>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(val)) {
        JSValue exc = JS_GetException(ctx);
        const char *msg = JS_ToCString(ctx, exc);
        printf("bench: EXC %s\n", msg ? msg : "?");
        if (msg) JS_FreeCString(ctx, msg);
        JS_FreeValue(ctx, exc);
        rc = 1;
    } else {
        int32_t r = 0;
        JS_ToInt32(ctx, &r, val);
        printf("BENCH-RESULT=%d\n", r);
    }
    JS_FreeValue(ctx, val);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
