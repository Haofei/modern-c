// qjs_io_agent — the confined QuickJS agent with NON-BLOCKING I/O resolving JS Promises. This is
// the full Phase-7 model: a host function `host_async(arg)` submits a non-blocking kernel op
// (SYS_SUBMIT) and returns a PENDING Promise; the agent keeps running; the event loop polls for
// the completion (SYS_POLL) and resolves the matching Promise, whose .then reaction then runs as
// a microtask. The agent never blocks on the op — it submits, drains jobs, and resolves on poll.
#include "quickjs.h"
#include <stdint.h>
#include <stddef.h>

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern long sys_submit(unsigned long req_ptr); // pointer to a ToolReq
// Vector poll: (events_ptr, max, timeout) -> count delivered (0..max) | -E_FAULT. This agent uses
// the single-event form (max=1, timeout=0): fill ONE ToolEvent, returns 1 (delivered) / 0 (none).
extern long sys_poll(unsigned long events_ptr, unsigned long max, unsigned long timeout);
size_t strlen(const char *s);
int snprintf(char *, size_t, const char *, ...);

// The tool ABI, mirrored byte-for-byte from user/abi.mc (ToolReq=40B, ToolEvent=24B).
#define TOOL_OP_SUM 1u
typedef struct {
    uint32_t op; uint32_t flags; uint64_t arg;
    uint64_t in_ptr; uint32_t in_len; uint32_t out_cap; uint64_t out_ptr;
} ToolReq; // 40 bytes
typedef struct {
    uint64_t id; int32_t status; int32_t result; uint32_t out_len; uint32_t reserved;
} ToolEvent; // 24 bytes

static void emit(const char *s, unsigned long n) { sys_write(1, s, n); }

// In-flight request table: request id -> the Promise's resolve function.
#define MAXREQ 16
static JSValue g_resolvers[MAXREQ];
static int64_t g_ids[MAXREQ];
static int g_inflight = 0;

// Reject `promise` with `code` and free the capability — the request was never registered, so
// JS observes a rejection instead of a forever-pending Promise (which would hang any .then).
static void reject_async(JSContext *ctx, JSValue *resolving, JSValue promise, int32_t code) {
    JSValue reason = JS_NewInt32(ctx, code);
    JSValue rr = JS_Call(ctx, resolving[1], JS_UNDEFINED, 1, &reason);
    JS_FreeValue(ctx, rr);
    JS_FreeValue(ctx, reason);
    JS_FreeValue(ctx, resolving[0]);
    JS_FreeValue(ctx, resolving[1]);
    (void)promise;
}

// host_async(arg): submit a non-blocking op and return a pending Promise (resolved by the loop).
static JSValue js_host_async(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int32_t arg = 0;
    if (argc > 0) JS_ToInt32(ctx, &arg, argv[0]);

    // Create the Promise FIRST so a failure here submits nothing to the kernel.
    JSValue resolving[2]; // [0] = resolve, [1] = reject
    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise)) return promise;

    // Local resolver table saturated: reject without submitting (we could not record a completion).
    if (g_inflight >= MAXREQ) {
        reject_async(ctx, resolving, promise, -1);
        return promise;
    }

    // Submit a ToolReq (SUM op). The kernel returns -errno under back-pressure/policy — reject.
    ToolReq req;
    req.op = TOOL_OP_SUM;
    req.flags = 0;
    req.arg = (uint64_t)arg;
    req.in_ptr = 0;
    req.in_len = 0;
    req.out_cap = 0;
    req.out_ptr = 0;
    int64_t id = sys_submit((unsigned long)&req);
    if (id < 0) {
        reject_async(ctx, resolving, promise, (int32_t)id);
        return promise;
    }

    g_ids[g_inflight] = id;
    g_resolvers[g_inflight] = resolving[0]; // retain resolve until the completion arrives
    g_inflight++;
    JS_FreeValue(ctx, resolving[1]); // reject unused for an accepted request
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
            int jerr = 0;
            while ((jerr = JS_ExecutePendingJob(rt, &jctx)) > 0) {
            }
            if (jerr < 0) { // a microtask threw — don't keep resolving with a live exception
                emit("JOB-EXC\n", 8);
                rc = 1;
                break;
            }
            ToolEvent ev;
            long got = sys_poll((unsigned long)&ev, 1, 0);
            if (got > 0) {
                int64_t id = (int64_t)ev.id;
                int32_t val = ev.result;
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
        // Free any resolve functions for requests that never completed (none in this toy op, but
        // the table must not leak refs into JS_FreeRuntime).
        for (int i = 0; i < g_inflight; i++) {
            JS_FreeValue(ctx, g_resolvers[i]);
        }
        g_inflight = 0;
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
