// qjs_async_agent — the confined QuickJS agent with an EVENT LOOP. Real agents need async: a
// Promise/await does nothing until its reactions (microtasks) are drained. This agent evaluates
// a Promise chain, then runs the event loop (JS_ExecutePendingJob until the job queue empties) —
// the concurrency substrate Phase 7 requires — and reports the resolved result via SYS_WRITE.
//
// Phase 7 core: the microtask event loop. Non-blocking kernel I/O (SYS_SUBMIT/SYS_POLL resolving
// a host Promise) layers on top of this same loop.
#include "quickjs.h"
#include <stdint.h>
#include <stddef.h>

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
size_t strlen(const char *s);
int snprintf(char *, size_t, const char *, ...);

static void emit(const char *s, unsigned long n) { sys_write(1, s, n); }

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { emit("no-rt\n", 6); return 1; }
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { emit("no-ctx\n", 7); return 1; }

    // A Promise chain whose .then reactions run as MICROTASKS — they execute only when the
    // event loop drains the job queue, not during JS_Eval. `result` stays 0 until the loop runs.
    const char *script =
        "var result = 0;"
        "Promise.resolve(6)"
        "  .then(function (x) { return x * 7; })"
        "  .then(function (y) { result = y; });";
    JSValue v = JS_Eval(ctx, script, strlen(script), "<async>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(v)) {
        emit("EXC\n", 4);
        rc = 1;
    } else {
        // THE EVENT LOOP: drain all pending jobs (Promise reactions / microtasks). >0 = a job
        // ran, 0 = queue empty, <0 = a job threw.
        JSContext *jctx;
        int err = 0;
        for (;;) {
            err = JS_ExecutePendingJob(rt, &jctx);
            if (err <= 0) break;
        }
        if (err < 0) {
            emit("JOB-EXC\n", 8);
            rc = 1;
        } else {
            JSValue global = JS_GetGlobalObject(ctx);
            JSValue rv = JS_GetPropertyStr(ctx, global, "result");
            int32_t r = 0;
            JS_ToInt32(ctx, &r, rv);
            char buf[32];
            int n = snprintf(buf, sizeof buf, "ASYNC=%d\n", r); // expect ASYNC=42 after the loop
            emit(buf, (unsigned long)n);
            JS_FreeValue(ctx, rv);
            JS_FreeValue(ctx, global);
        }
    }

    JS_FreeValue(ctx, v);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
