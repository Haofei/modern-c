//! C backend runtime prelude emission.
//!
//! State-free helpers that write the generated C runtime support shared by the
//! C emitter: profile marker, common headers, trap helpers, and weak sanitizer
//! hook defaults.

const std = @import("std");

const ast = @import("ast.zig");

// The sanitizer shadow-hook symbols (mirrors `sanitizer_hooks` in lower_llvm.zig). Each gets a
// weak no-op `define` in the C preamble that a linked sanitizer runtime overrides — UNLESS the
// module itself defines the hook in MC, in which case the weak stub is suppressed to avoid a C
// `redefinition` error.
const sanitizer_hooks = [_][]const u8{
    "mc_ksan_poison",
    "mc_ksan_unpoison",
    "mc_ksan_check",
    "mc_ksan_store",
    "mc_csan_read",
    "mc_csan_write",
};

// True if the MODULE provides a `fn` definition (a body) named `hook` — a pure-MC sanitizer
// runtime. An `extern fn` declaration (no body) does not count as a definition.
fn moduleDefinesHook(module: ast.Module, hook: []const u8) bool {
    for (module.decls) |decl| {
        if (decl.kind == .fn_decl) {
            const fn_decl = decl.kind.fn_decl;
            if (fn_decl.body != null and std.mem.eql(u8, fn_decl.name.text, hook)) return true;
        }
    }
    return false;
}

pub fn appendHeaderAndSanitizerHooks(
    allocator: std.mem.Allocator,
    module: ast.Module,
    out: *std.ArrayList(u8),
    profile_marker: []const u8,
) !void {
    try out.appendSlice(allocator, profile_marker);
    try out.appendSlice(allocator,
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\#include <stdalign.h>
        \\#include <limits.h>
        \\
        \\#if defined(__GNUC__) || defined(__clang__)
        \\#define MC_NORETURN __attribute__((noreturn))
        \\#define MC_UNUSED __attribute__((unused))
        \\#else
        \\#define MC_NORETURN
        \\#define MC_UNUSED
        \\#endif
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_IntegerOverflow(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_DivideByZero(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_InvalidShift(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_Bounds(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_Assert(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_NullUnwrap(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_InvalidRepresentation(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_Unreachable(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_UNUSED static inline uintptr_t mc_check_index_usize(uintptr_t index, uintptr_t len) {
        \\    if (index >= len) mc_trap_Bounds();
        \\    return index;
        \\}
        \\
        \\/* KASAN shadow hooks (D2.1). Weak no-op defaults so EVERY build links and behaves
        \\   identically when no KASAN runtime is present (the hooks do nothing). A linked
        \\   KASAN shadow runtime (the ksan profile) provides STRONG definitions that
        \\   override these, poisoning/unpoisoning the shadow on heap free/alloc and trapping
        \\   on a poisoned access. The heap calls poison/unpoison only on a `heap_new_ksan`
        \\   heap (guarded `if h.ksan != 0`), so default heaps never reach even these stubs. */
        \\#if defined(__GNUC__) || defined(__clang__)
        \\#define MC_WEAK __attribute__((weak))
        \\#else
        \\#define MC_WEAK
        \\#endif
        \\
    );

    // Weak no-op `define`s for every sanitizer shadow hook. A pure-MC sanitizer runtime instead
    // DEFINES one of these (`export fn mc_ksan_check(...)`); for any hook the module itself
    // defines we must SKIP the weak stub here, or the C compiler errors with `redefinition`.
    // KMSAN init-tracking is `mc_ksan_store` (D2.2); KCSAN watchpoints are `mc_csan_read`/
    // `mc_csan_write` (D2.3). Only module-defined hooks are suppressed; all others keep the
    // weak no-op the linked sanitizer runtime overrides with a strong definition.
    for (sanitizer_hooks) |hook| {
        if (moduleDefinesHook(module, hook)) continue;
        try out.print(allocator, "MC_WEAK void {s}(uintptr_t addr, uintptr_t size) {{ (void)addr; (void)size; }}\n", .{hook});
    }
}

pub fn appendCheckedArithmeticHelpers(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
) !void {
    try out.appendSlice(allocator,
        \\
        \\#define MC_DEFINE_CHECKED_UNSIGNED(NAME, TYPE, MAXV) \
        \\MC_UNUSED static inline TYPE mc_checked_add_##NAME(TYPE a, TYPE b) { \
        \\    TYPE out; \
        \\    if (__builtin_add_overflow(a, b, &out)) mc_trap_IntegerOverflow(); \
        \\    return out; \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_sub_##NAME(TYPE a, TYPE b) { \
        \\    TYPE out; \
        \\    if (__builtin_sub_overflow(a, b, &out)) mc_trap_IntegerOverflow(); \
        \\    return out; \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_mul_##NAME(TYPE a, TYPE b) { \
        \\    TYPE out; \
        \\    if (__builtin_mul_overflow(a, b, &out)) mc_trap_IntegerOverflow(); \
        \\    return out; \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_div_##NAME(TYPE a, TYPE b) { \
        \\    if (b == (TYPE)0) mc_trap_DivideByZero(); \
        \\    return (TYPE)(a / b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_mod_##NAME(TYPE a, TYPE b) { \
        \\    if (b == (TYPE)0) mc_trap_DivideByZero(); \
        \\    return (TYPE)(a % b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_shl_##NAME(TYPE a, TYPE b) { \
        \\    if (b >= (TYPE)(sizeof(TYPE) * CHAR_BIT)) mc_trap_InvalidShift(); \
        \\    if (a > (TYPE)(MAXV >> b)) mc_trap_IntegerOverflow(); \
        \\    return (TYPE)(a << b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_shr_##NAME(TYPE a, TYPE b) { \
        \\    if (b >= (TYPE)(sizeof(TYPE) * CHAR_BIT)) mc_trap_InvalidShift(); \
        \\    return (TYPE)(a >> b); \
        \\}
        \\
        \\#define MC_DEFINE_CHECKED_SIGNED(NAME, TYPE, MINV, MAXV) \
        \\MC_UNUSED static inline TYPE mc_checked_add_##NAME(TYPE a, TYPE b) { \
        \\    TYPE out; \
        \\    if (__builtin_add_overflow(a, b, &out)) mc_trap_IntegerOverflow(); \
        \\    return out; \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_sub_##NAME(TYPE a, TYPE b) { \
        \\    TYPE out; \
        \\    if (__builtin_sub_overflow(a, b, &out)) mc_trap_IntegerOverflow(); \
        \\    return out; \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_mul_##NAME(TYPE a, TYPE b) { \
        \\    TYPE out; \
        \\    if (__builtin_mul_overflow(a, b, &out)) mc_trap_IntegerOverflow(); \
        \\    return out; \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_div_##NAME(TYPE a, TYPE b) { \
        \\    if (b == (TYPE)0) mc_trap_DivideByZero(); \
        \\    if (a == (TYPE)(MINV) && b == (TYPE)-1) mc_trap_IntegerOverflow(); \
        \\    return (TYPE)(a / b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_mod_##NAME(TYPE a, TYPE b) { \
        \\    if (b == (TYPE)0) mc_trap_DivideByZero(); \
        \\    if (a == (TYPE)(MINV) && b == (TYPE)-1) mc_trap_IntegerOverflow(); \
        \\    return (TYPE)(a % b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_shl_##NAME(TYPE a, TYPE b) { \
        \\    if (b < (TYPE)0 || b >= (TYPE)(sizeof(TYPE) * CHAR_BIT)) mc_trap_InvalidShift(); \
        \\    if (a < (TYPE)0) mc_trap_IntegerOverflow(); \
        \\    if (a > (TYPE)(MAXV >> b)) mc_trap_IntegerOverflow(); \
        \\    return (TYPE)(a << b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_checked_shr_##NAME(TYPE a, TYPE b) { \
        \\    if (b < (TYPE)0 || b >= (TYPE)(sizeof(TYPE) * CHAR_BIT)) mc_trap_InvalidShift(); \
        \\    return (TYPE)(a >> b); \
        \\}
        \\
        \\MC_DEFINE_CHECKED_UNSIGNED(u8, uint8_t, UINT8_MAX)
        \\MC_DEFINE_CHECKED_UNSIGNED(u16, uint16_t, UINT16_MAX)
        \\MC_DEFINE_CHECKED_UNSIGNED(u32, uint32_t, UINT32_MAX)
        \\MC_DEFINE_CHECKED_UNSIGNED(u64, uint64_t, UINT64_MAX)
        \\MC_DEFINE_CHECKED_UNSIGNED(u128, unsigned __int128, (~(unsigned __int128)0))
        \\MC_DEFINE_CHECKED_UNSIGNED(usize, uintptr_t, UINTPTR_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i8, int8_t, INT8_MIN, INT8_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i16, int16_t, INT16_MIN, INT16_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i32, int32_t, INT32_MIN, INT32_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i64, int64_t, INT64_MIN, INT64_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(isize, intptr_t, INTPTR_MIN, INTPTR_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i128, __int128, (-(__int128)((unsigned __int128)(~(unsigned __int128)0) >> 1) - 1), (__int128)((unsigned __int128)(~(unsigned __int128)0) >> 1))
        \\
        \\#define MC_DEFINE_CHECKED_NEG_SIGNED(NAME, TYPE, MINV) \
        \\MC_UNUSED static inline TYPE mc_checked_neg_##NAME(TYPE a) { \
        \\    if (a == (TYPE)(MINV)) mc_trap_IntegerOverflow(); \
        \\    return (TYPE)(-a); \
        \\}
        \\
        \\MC_DEFINE_CHECKED_NEG_SIGNED(i8, int8_t, INT8_MIN)
        \\MC_DEFINE_CHECKED_NEG_SIGNED(i16, int16_t, INT16_MIN)
        \\MC_DEFINE_CHECKED_NEG_SIGNED(i32, int32_t, INT32_MIN)
        \\MC_DEFINE_CHECKED_NEG_SIGNED(i64, int64_t, INT64_MIN)
        \\MC_DEFINE_CHECKED_NEG_SIGNED(isize, intptr_t, INTPTR_MIN)
        \\MC_DEFINE_CHECKED_NEG_SIGNED(i128, __int128, (-(__int128)((unsigned __int128)(~(unsigned __int128)0) >> 1) - 1))
        \\
        \\#define MC_DEFINE_WRAP_SHIFT_UNSIGNED(NAME, TYPE) \
        \\MC_UNUSED static inline TYPE mc_wrap_shl_##NAME(TYPE a, TYPE b) { \
        \\    if (b >= (TYPE)(sizeof(TYPE) * CHAR_BIT)) mc_trap_InvalidShift(); \
        \\    return (TYPE)(a << b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_wrap_shr_##NAME(TYPE a, TYPE b) { \
        \\    if (b >= (TYPE)(sizeof(TYPE) * CHAR_BIT)) mc_trap_InvalidShift(); \
        \\    return (TYPE)(a >> b); \
        \\}
        \\
        \\#define MC_DEFINE_SAT_UNSIGNED(NAME, TYPE, MAXV) \
        \\MC_UNUSED static inline TYPE mc_sat_add_##NAME(TYPE a, TYPE b) { \
        \\    if (a > (TYPE)(MAXV - b)) return (TYPE)MAXV; \
        \\    return (TYPE)(a + b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_sat_sub_##NAME(TYPE a, TYPE b) { \
        \\    if (a < b) return (TYPE)0; \
        \\    return (TYPE)(a - b); \
        \\} \
        \\MC_UNUSED static inline TYPE mc_sat_mul_##NAME(TYPE a, TYPE b) { \
        \\    if (b != (TYPE)0 && a > (TYPE)(MAXV / b)) return (TYPE)MAXV; \
        \\    return (TYPE)(a * b); \
        \\}
        \\
        \\MC_DEFINE_WRAP_SHIFT_UNSIGNED(u8, uint8_t)
        \\MC_DEFINE_WRAP_SHIFT_UNSIGNED(u16, uint16_t)
        \\MC_DEFINE_WRAP_SHIFT_UNSIGNED(u32, uint32_t)
        \\MC_DEFINE_WRAP_SHIFT_UNSIGNED(u64, uint64_t)
        \\MC_DEFINE_WRAP_SHIFT_UNSIGNED(usize, uintptr_t)
        \\MC_DEFINE_WRAP_SHIFT_UNSIGNED(u128, unsigned __int128)
        \\MC_DEFINE_SAT_UNSIGNED(u8, uint8_t, UINT8_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(u16, uint16_t, UINT16_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(u32, uint32_t, UINT32_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(u64, uint64_t, UINT64_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(usize, uintptr_t, UINTPTR_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(u128, unsigned __int128, (~(unsigned __int128)0))
        \\
    );
}

pub fn appendMemoryAccessHelpers(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ksan: bool,
    msan: bool,
    csan: bool,
) !void {
    // The synchronized scalar load/store helpers (`mc_race_load_<T>`/`mc_race_store_<T>`).
    // EVERY non-raw memory access funnels through these: a scalar `global` read/write, a
    // struct-field load/store, and an array-index load/store all lower to `mc_race_*`. The raw
    // macros below only cover `raw.load`/`raw.store`; this is where the bulk of real kernel data
    // access lives. So sanitizer profiles splice the SAME shadow hooks in here as on the raw
    // path, giving KASAN/KMSAN/KCSAN real coverage of UAF/OOB/uninit/race through fields,
    // elements, and globals — not just the raw-pointer demo path. Default builds emit no hook.
    const race_load_pre: []const u8 = if (csan)
        ""
    else if (ksan)
        "    mc_ksan_check((uintptr_t)p, (uintptr_t)sizeof(TYPE)); \\\n"
    else
        "";
    const race_store_pre: []const u8 = if (csan)
        ""
    else if (ksan and !msan)
        "    mc_ksan_check((uintptr_t)p, (uintptr_t)sizeof(TYPE)); \\\n"
    else
        "";
    const race_store_post: []const u8 = if (msan)
        "    mc_ksan_store((uintptr_t)p, (uintptr_t)sizeof(TYPE)); \\\n"
    else
        "";
    try out.print(
        allocator,
        "#define MC_DEFINE_RACE_SCALAR(NAME, TYPE) \\\n" ++
            "MC_UNUSED static inline TYPE mc_race_load_##NAME(TYPE const *p) {{ \\\n" ++
            "{s}" ++
            "    TYPE value; \\\n" ++
            "    __atomic_load(p, &value, __ATOMIC_RELAXED); \\\n" ++
            "    return value; \\\n" ++
            "}} \\\n" ++
            "MC_UNUSED static inline void mc_race_store_##NAME(TYPE *p, TYPE value) {{ \\\n" ++
            "{s}" ++
            "    __atomic_store(p, &value, __ATOMIC_RELAXED); \\\n" ++
            "{s}" ++
            "}}\n\n",
        .{ race_load_pre, race_store_pre, race_store_post },
    );

    try out.appendSlice(allocator,
        \\MC_DEFINE_RACE_SCALAR(bool, bool)
        \\MC_DEFINE_RACE_SCALAR(u8, uint8_t)
        \\MC_DEFINE_RACE_SCALAR(u16, uint16_t)
        \\MC_DEFINE_RACE_SCALAR(u32, uint32_t)
        \\MC_DEFINE_RACE_SCALAR(u64, uint64_t)
        \\MC_DEFINE_RACE_SCALAR(usize, uintptr_t)
        \\MC_DEFINE_RACE_SCALAR(i8, int8_t)
        \\MC_DEFINE_RACE_SCALAR(i16, int16_t)
        \\MC_DEFINE_RACE_SCALAR(i32, int32_t)
        \\MC_DEFINE_RACE_SCALAR(i64, int64_t)
        \\MC_DEFINE_RACE_SCALAR(isize, intptr_t)
        \\MC_DEFINE_RACE_SCALAR(f32, float)
        \\MC_DEFINE_RACE_SCALAR(f64, double)
        \\
    );

    // The raw scalar load/store macros (the pointer-deref / raw memory-access path).
    // The four profiles differ only in which shadow hook brackets the volatile access.
    const store_pre: []const u8 = if (csan)
        "    mc_csan_write((uintptr_t)addr, (uintptr_t)sizeof(TYPE)); \\\n"
    else if (ksan and !msan)
        "    mc_ksan_check((uintptr_t)addr, (uintptr_t)sizeof(TYPE)); \\\n"
    else
        "";
    const store_post: []const u8 = if (msan)
        "    mc_ksan_store((uintptr_t)addr, (uintptr_t)sizeof(TYPE)); \\\n"
    else
        "";
    const load_pre: []const u8 = if (csan)
        "    mc_csan_read((uintptr_t)addr, (uintptr_t)sizeof(TYPE)); \\\n"
    else if (ksan)
        "    mc_ksan_check((uintptr_t)addr, (uintptr_t)sizeof(TYPE)); \\\n"
    else
        "";
    const profile_comment: []const u8 = if (msan)
        \\/* mc-checks: msan (KMSAN uninit-heap-use detection on the ksan shadow, D2.2).
        \\   raw.store marks bytes initialized via mc_ksan_store; raw.load traps in
        \\   mc_ksan_check if the bytes are still uninit (or freed/redzone-poisoned). */
        \\
    else if (ksan)
        \\/* mc-checks: ksan (KASAN shadow-memory access instrumentation, D2.1).
        \\   mc_ksan_check is declared+weak-defined above; the linked ksan runtime
        \\   provides the strong, shadow-consulting definition that overrides it. */
        \\
    else if (csan)
        \\/* mc-checks: csan (KCSAN data-race watchpoint instrumentation, D2.3).
        \\   mc_csan_write/mc_csan_read are declared+weak-defined above; the linked csan
        \\   watchpoint runtime provides the strong, shadow-consulting definitions. The
        \\   write hook brackets the store so a concurrent access lands inside the watch
        \\   window; the read hook brackets the load. */
        \\
    else
        "";
    try out.appendSlice(allocator, profile_comment);
    try out.print(
        allocator,
        "#define MC_DEFINE_RAW_STORE(NAME, TYPE) \\\n" ++
            "MC_UNUSED static inline void mc_raw_store_##NAME(uintptr_t addr, TYPE value) {{ \\\n" ++
            "{s}" ++
            "    *((volatile TYPE *)(uintptr_t)addr) = value; \\\n" ++
            "{s}" ++
            "}}\n" ++
            "#define MC_DEFINE_RAW_LOAD(NAME, TYPE) \\\n" ++
            "MC_UNUSED static inline TYPE mc_raw_load_##NAME(uintptr_t addr) {{ \\\n" ++
            "{s}" ++
            "    return *((volatile TYPE *)(uintptr_t)addr); \\\n" ++
            "}}\n\n",
        .{ store_pre, store_post, load_pre },
    );

    try out.appendSlice(allocator,
        \\MC_DEFINE_RAW_STORE(bool, bool)
        \\MC_DEFINE_RAW_STORE(u8, uint8_t)
        \\MC_DEFINE_RAW_STORE(u16, uint16_t)
        \\MC_DEFINE_RAW_STORE(u32, uint32_t)
        \\MC_DEFINE_RAW_STORE(u64, uint64_t)
        \\MC_DEFINE_RAW_STORE(usize, uintptr_t)
        \\MC_DEFINE_RAW_STORE(i8, int8_t)
        \\MC_DEFINE_RAW_STORE(i16, int16_t)
        \\MC_DEFINE_RAW_STORE(i32, int32_t)
        \\MC_DEFINE_RAW_STORE(i64, int64_t)
        \\MC_DEFINE_RAW_STORE(isize, intptr_t)
        \\MC_DEFINE_RAW_STORE(f32, float)
        \\MC_DEFINE_RAW_STORE(f64, double)
        \\
        \\MC_DEFINE_RAW_LOAD(bool, bool)
        \\MC_DEFINE_RAW_LOAD(u8, uint8_t)
        \\MC_DEFINE_RAW_LOAD(u16, uint16_t)
        \\MC_DEFINE_RAW_LOAD(u32, uint32_t)
        \\MC_DEFINE_RAW_LOAD(u64, uint64_t)
        \\MC_DEFINE_RAW_LOAD(usize, uintptr_t)
        \\MC_DEFINE_RAW_LOAD(i8, int8_t)
        \\MC_DEFINE_RAW_LOAD(i16, int16_t)
        \\MC_DEFINE_RAW_LOAD(i32, int32_t)
        \\MC_DEFINE_RAW_LOAD(i64, int64_t)
        \\MC_DEFINE_RAW_LOAD(isize, intptr_t)
        \\MC_DEFINE_RAW_LOAD(f32, float)
        \\MC_DEFINE_RAW_LOAD(f64, double)
        \\
        \\MC_UNUSED static inline void mc_cpu_pause(void) {
        \\#if defined(__i386__) || defined(__x86_64__)
        \\    __asm__ __volatile__("pause" ::: "memory");
        \\#else
        \\    __atomic_thread_fence(__ATOMIC_SEQ_CST);
        \\#endif
        \\}
        \\
        \\MC_UNUSED static inline uint8_t mc_mmio_read_u8(uint8_t volatile const *p) {
        \\    return *p;
        \\}
        \\
        \\MC_UNUSED static inline uint16_t mc_mmio_read_u16(uint16_t volatile const *p) {
        \\    return *p;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_mmio_read_u32(uint32_t volatile const *p) {
        \\    return *p;
        \\}
        \\
        \\MC_UNUSED static inline uint64_t mc_mmio_read_u64(uint64_t volatile const *p) {
        \\    return *p;
        \\}
        \\
        \\MC_UNUSED static inline void mc_mmio_write_u8(uint8_t volatile *p, uint8_t value) {
        \\    *p = value;
        \\}
        \\
        \\MC_UNUSED static inline void mc_mmio_write_u16(uint16_t volatile *p, uint16_t value) {
        \\    *p = value;
        \\}
        \\
        \\MC_UNUSED static inline void mc_mmio_write_u32(uint32_t volatile *p, uint32_t value) {
        \\    *p = value;
        \\}
        \\
        \\MC_UNUSED static inline void mc_mmio_write_u64(uint64_t volatile *p, uint64_t value) {
        \\    *p = value;
        \\}
        \\
        \\// Each fence pairs the CPU thread-fence with an explicit compiler barrier (empty asm with a
        \\// "memory" clobber). A thread-fence alone orders *atomic* accesses, but LLVM/clang LICM can
        \\// still hoist a plain (non-atomic) load across it — which silently breaks a device poll like
        \\// `while (!vq_has_used()) {}` reading a DMA-updated `used->idx` (the load gets hoisted out of
        \\// the loop and never re-read). The "memory" clobber makes the compiler treat memory as
        \\// clobbered at the fence, so such loads are re-read: an MC fence orders accesses against the
        \\// compiler too, not just the hardware.
        \\MC_UNUSED static inline void mc_barrier_release_before(void) {
        \\    __atomic_thread_fence(__ATOMIC_RELEASE);
        \\    __asm__ __volatile__("" ::: "memory");
        \\}
        \\
        \\MC_UNUSED static inline void mc_barrier_acquire_after(void) {
        \\    __atomic_thread_fence(__ATOMIC_ACQUIRE);
        \\    __asm__ __volatile__("" ::: "memory");
        \\}
        \\
        \\MC_UNUSED static inline void mc_barrier_full(void) {
        \\    __atomic_thread_fence(__ATOMIC_SEQ_CST);
        \\    __asm__ __volatile__("" ::: "memory");
        \\}
        \\
    );
}
