// qjs_worker_agent — the confined QuickJS agent with WORKERS (Phase 8, single-core v0). A worker
// is a SEPARATE JS context — its own global scope, isolated from the main agent — that the agent
// spawns, posts a message to, runs (the worker participates in the same cooperative event loop),
// and receives a result back from. This is the spawn/mailbox substrate; SMP parallelism (v1)
// would run the worker on another hart, but the isolation + message-passing model is the same.
//
// Demonstrates: main posts 21 -> the worker (its own globalThis) computes via its OWN Promise
// (input*2) -> posts 42 back. The worker's `output`/`input` never touch the main global scope.
#include "quickjs.h"
#include <stdint.h>
#include <stddef.h>

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
size_t strlen(const char *s);
int snprintf(char *, size_t, const char *, ...);

static void emit(const char *s, unsigned long n) { sys_write(1, s, n); }

// spawn_worker(input): create a worker context, post `input`, run its event loop, return its
// `output`. The worker is isolated — a distinct global object in the same runtime.
static JSValue js_spawn_worker(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int32_t input = 0;
    if (argc > 0) JS_ToInt32(ctx, &input, argv[0]);

    JSRuntime *rt = JS_GetRuntime(ctx);
    JSContext *wctx = JS_NewContext(rt); // the worker: its OWN global scope
    if (!wctx) return JS_NewInt32(ctx, -1);

    // postMessage(input): seed the worker's global with the message.
    JSValue wg = JS_GetGlobalObject(wctx);
    JS_SetPropertyStr(wctx, wg, "input", JS_NewInt32(wctx, input));

    // The worker body — runs in its own scope, using its own Promise (its event-loop participation).
    const char *wsrc =
        "var output = 0;"
        "Promise.resolve(input).then(function (x) { output = x * 2; });";
    JSValue wv = JS_Eval(wctx, wsrc, strlen(wsrc), "<worker>", JS_EVAL_TYPE_GLOBAL);
    int rc = JS_IsException(wv);

    // Cooperative event loop: drain the runtime's job queue (the worker's microtasks run here).
    JSContext *jctx;
    while (JS_ExecutePendingJob(rt, &jctx) > 0) {
    }

    int32_t out = -1;
    if (!rc) {
        JSValue ov = JS_GetPropertyStr(wctx, wg, "output"); // receive the worker's result
        JS_ToInt32(wctx, &out, ov);
        JS_FreeValue(wctx, ov);
    }
    JS_FreeValue(wctx, wv);
    JS_FreeValue(wctx, wg);
    JS_FreeContext(wctx); // the worker is torn down; its scope never leaked to main

    return JS_NewInt32(ctx, out);
}

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { emit("no-rt\n", 6); return 1; }
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { emit("no-ctx\n", 7); return 1; }

    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "spawn_worker",
                      JS_NewCFunction(ctx, js_spawn_worker, "spawn_worker", 1));
    JS_FreeValue(ctx, global);

    // Main posts 21 to a worker and keeps the returned result. `output` is the WORKER's global,
    // not visible here — proving isolation; only the posted-back value crosses.
    const char *script =
        "var result = spawn_worker(21);"
        "var leaked = (typeof output === 'undefined') ? 1 : 0;"; // worker scope did not leak
    JSValue v = JS_Eval(ctx, script, strlen(script), "<main>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(v)) { emit("EXC\n", 4); rc = 1; }
    JS_FreeValue(ctx, v);

    JSContext *jctx;
    while (JS_ExecutePendingJob(rt, &jctx) > 0) {
    }

    JSValue g2 = JS_GetGlobalObject(ctx);
    JSValue rv = JS_GetPropertyStr(ctx, g2, "result");
    JSValue lv = JS_GetPropertyStr(ctx, g2, "leaked");
    int32_t r = 0, leaked = 0;
    JS_ToInt32(ctx, &r, rv);
    JS_ToInt32(ctx, &leaked, lv);
    char buf[48];
    // expect WORKER=42 (result) and isolated=1 (the worker's `output` global did not leak to main)
    int n = snprintf(buf, sizeof buf, "WORKER=%d isolated=%d\n", r, leaked);
    emit(buf, (unsigned long)n);
    JS_FreeValue(ctx, rv);
    JS_FreeValue(ctx, lv);
    JS_FreeValue(ctx, g2);

    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
