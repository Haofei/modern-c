// qjs_host.mc — the generic QuickJS host, in MC (not C). Proves MC can drive the QuickJS C API:
// the engine's `JSValue` (the non-NaN-boxed 16-byte struct {union u; int64 tag} our 64-bit build
// uses) is mirrored as an MC struct, constructed and inspected on the MC side. The FFI seam
// passes JSValues by POINTER only (extern fns must not pass or return structs by value —
// E_EXTERN_STRUCT_BY_VALUE, no C ABI classification yet): qjs_host_shim.c wraps the engine's
// by-value API in out-pointer forms. The accessor macros (JS_IsException/JS_UNDEFINED) are tiny
// struct ops reimplemented here.
//
// This minimal host evaluates a script and reads back an integer result — enough to verify the
// MC-drives-QuickJS FFI end to end. The full host (host-API callbacks + the async event loop)
// uses the same patterns.

// The engine's JSValue (must mirror third_party/quickjs/quickjs.h's non-NaN-boxed layout exactly).
struct JSValue {
    u: u64,   // JSValueUnion (int32 / double / ptr), as a raw 64-bit slot
    tag: i64,
}

const JS_TAG_INT: i64 = 0;
const JS_TAG_UNDEFINED: i64 = 3;
const JS_TAG_EXCEPTION: i64 = 6;
const JS_EVAL_TYPE_GLOBAL: i32 = 0;

// Accessor "macros", reimplemented (pure struct construction / field read).
fn js_undefined() -> JSValue {
    return .{ .u = 0, .tag = JS_TAG_UNDEFINED };
}
fn js_is_exception(v: JSValue) -> bool {
    return v.tag == JS_TAG_EXCEPTION;
}

// The QuickJS C API. JSContext*/JSRuntime* are opaque FFI handles; JSValue crosses by pointer
// through the qjs_host_shim.c wrappers (mc_js_* forwards to the engine's by-value API).
extern fn JS_NewRuntime() -> *mut c_void;
extern fn JS_NewContext(rt: *mut c_void) -> *mut c_void;
extern fn mc_js_eval(ctx: *mut c_void, input: *const u8, len: usize, name: *const u8, flags: i32, out: *mut JSValue) -> void;
extern fn mc_js_get_global_object(ctx: *mut c_void, out: *mut JSValue) -> void;
extern fn mc_js_get_property_str(ctx: *mut c_void, this_obj: *JSValue, name: *const u8, out: *mut JSValue) -> void;
extern fn mc_js_to_int32(ctx: *mut c_void, pres: *mut i32, val: *JSValue) -> i32;

// Platform: console + the string length helper (from the all-MC libc).
extern fn sys_write(fd: u64, buf: usize, len: usize) -> i64;
extern fn strlen(s: *const u8) -> usize;

fn emit(s: *const u8) -> void {
    let n: usize = strlen(s);
    let ignored: i64 = sys_write(1, s as usize, n);
}

export fn main() -> i32 {
    let rt: *mut c_void = JS_NewRuntime();
    let ctx: *mut c_void = JS_NewContext(rt);

    let script: *const u8 = "var r = 6 * 7;";
    let name: *const u8 = "<mc-host>";
    var v: JSValue = js_undefined();
    mc_js_eval(ctx, script, strlen(script), name, JS_EVAL_TYPE_GLOBAL, &v);
    if js_is_exception(v) {
        emit("MC-host: agent threw\n");
        return 1; // exit; the kernel reclaims the agent's whole address space
    }

    var global: JSValue = js_undefined();
    mc_js_get_global_object(ctx, &global);
    let rname: *const u8 = "r";
    var rv: JSValue = js_undefined();
    mc_js_get_property_str(ctx, &global, rname, &rv);
    var out: i32 = 0;
    let ignored: i32 = mc_js_to_int32(ctx, &out, &rv);

    if out == 42 {
        emit("MC-host: JS evaluated 6*7 -> 42 (MC drove QuickJS)\n");
    } else {
        emit("MC-host: WRONG RESULT\n");
    }

    // A confined run-once agent exits here; the kernel reclaims its ENTIRE address space (the
    // 8 MiB JS arena, the engine, everything) on SYS_EXIT, so JS_FreeContext/JS_FreeRuntime are
    // unnecessary — and skipping them also avoids the engine's leak-report path for the values
    // we intentionally did not free. (A long-lived host would reimplement JS_FreeValue in MC.)
    return 0;
}
