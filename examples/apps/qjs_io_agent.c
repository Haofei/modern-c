// qjs_io_agent — the confined QuickJS agent with NON-BLOCKING I/O resolving JS Promises. This is
// the full Phase-7 model: a host function `host_async(arg)` submits a non-blocking kernel op
// (SYS_SUBMIT) and returns a PENDING Promise; the agent keeps running; the event loop polls for
// the completion (SYS_POLL) and resolves the matching Promise, whose .then reaction then runs as
// a microtask. The agent never blocks on the op — it submits, drains jobs, and resolves on poll.
#include "quickjs.h"
#include <stdint.h>
#include <stddef.h>

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern long sys_submit(uint64_t arg);
extern long sys_poll(void *buf);
size_t strlen(const char *s);
int snprintf(char *, size_t, const char *, ...);

static void emit(const char *s, unsigned long n) { sys_write(1, s, n); }

// In-flight request table: request id -> the Promise's resolve function.
#define MAXREQ 16
static JSValue g_resolvers[MAXREQ];
static int64_t g_ids[MAXREQ];
static int g_inflight = 0;

// host_async(arg): submit a non-blocking op and return a pending Promise (resolved by the loop).
static JSValue js_host_async(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int32_t arg = 0;
    if (argc > 0) JS_ToInt32(ctx, &arg, argv[0]);
    int64_t id = sys_submit((uint64_t)arg);

    JSValue resolving[2]; // [0] = resolve, [1] = reject
    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise)) return promise;

    if (g_inflight < MAXREQ) {
        g_ids[g_inflight] = id;
        g_resolvers[g_inflight] = resolving[0]; // retain resolve until the completion arrives
        g_inflight++;
    } else {
        JS_FreeValue(ctx, resolving[0]);
    }
    JS_FreeValue(ctx, resolving[1]); // reject unused in this toy op (it never fails)
    return promise;
}

int main(void) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) { emit("no-rt\n", 6); return 1; }
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { emit("no-ctx\n", 7); return 1; }

    // Expose host_async on the global object.
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "host_async",
                      JS_NewCFunction(ctx, js_host_async, "host_async", 1));
    JS_FreeValue(ctx, global);

    // host_async(40) submits arg=40; the kernel op completes as arg+2 == 42. The .then runs only
    // after the loop polls the completion and resolves the Promise.
    const char *script =
        "var result = 0;"
        "host_async(40).then(function (r) { result = r; });";
    JSValue v = JS_Eval(ctx, script, strlen(script), "<io>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(v)) { emit("EXC\n", 4); rc = 1; }
    JS_FreeValue(ctx, v);

    // THE EVENT LOOP: drain microtasks, poll the kernel for a completion, resolve its Promise
    // (which queues the .then reaction), repeat — until nothing is queued and nothing is in flight.
    if (rc == 0) {
        int guard = 0;
        for (;;) {
            JSContext *jctx;
            while (JS_ExecutePendingJob(rt, &jctx) > 0) {
            }
            uint64_t comp[2]; // [id, result]
            long got = sys_poll(comp);
            if (got > 0) {
                int64_t id = (int64_t)comp[0];
                int32_t val = (int32_t)comp[1];
                for (int i = 0; i < g_inflight; i++) {
                    if (g_ids[i] == id) {
                        JSValue a = JS_NewInt32(ctx, val);
                        JSValue ret = JS_Call(ctx, g_resolvers[i], JS_UNDEFINED, 1, &a);
                        JS_FreeValue(ctx, ret);
                        JS_FreeValue(ctx, a);
                        JS_FreeValue(ctx, g_resolvers[i]);
                        g_resolvers[i] = g_resolvers[g_inflight - 1];
                        g_ids[i] = g_ids[g_inflight - 1];
                        g_inflight--;
                        break;
                    }
                }
            } else if (g_inflight == 0) {
                break; // nothing in flight and the queue is empty: the loop is drained
            }
            if (++guard > 1000000) break; // safety against a stuck loop
        }
    }

    JSValue global2 = JS_GetGlobalObject(ctx);
    JSValue rv = JS_GetPropertyStr(ctx, global2, "result");
    int32_t r = 0;
    JS_ToInt32(ctx, &r, rv);
    char buf[32];
    int n = snprintf(buf, sizeof buf, "IO=%d\n", r); // expect IO=42
    emit(buf, (unsigned long)n);
    JS_FreeValue(ctx, rv);
    JS_FreeValue(ctx, global2);

    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
