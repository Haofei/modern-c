const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");

pub fn appendInspection(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) anyerror!void {
    var inspector = Inspector.init(allocator, out);
    try inspector.inspectModule(module);
}

// The target conformance profile (spec §0). `kernel` is freestanding-by-default
// and has no ambient I/O. `hosted` opts in to a host C runtime (libc/libm); it
// changes only the toolchain link step (link libc + `-lm`) — the generated C is
// the same shape, so emitting hosted code with no hosted features is harmless.
// The profile is stamped into the C as a marker so the toolchain driver and a
// reader can see which target was selected.
pub const Profile = enum { kernel, hosted };

pub fn appendC(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) anyerror!void {
    return appendCProfile(allocator, module, out, .kernel);
}

pub fn appendCProfile(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), profile: Profile) anyerror!void {
    switch (profile) {
        .kernel => try out.appendSlice(allocator, "/* mc-profile: kernel (freestanding) */\n"),
        .hosted => try out.appendSlice(allocator, "/* mc-profile: hosted (links libc + -lm) */\n"),
    }
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
        \\MC_DEFINE_CHECKED_UNSIGNED(usize, uintptr_t, UINTPTR_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i8, int8_t, INT8_MIN, INT8_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i16, int16_t, INT16_MIN, INT16_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i32, int32_t, INT32_MIN, INT32_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(i64, int64_t, INT64_MIN, INT64_MAX)
        \\MC_DEFINE_CHECKED_SIGNED(isize, intptr_t, INTPTR_MIN, INTPTR_MAX)
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
        \\MC_DEFINE_SAT_UNSIGNED(u8, uint8_t, UINT8_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(u16, uint16_t, UINT16_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(u32, uint32_t, UINT32_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(u64, uint64_t, UINT64_MAX)
        \\MC_DEFINE_SAT_UNSIGNED(usize, uintptr_t, UINTPTR_MAX)
        \\
        \\#define MC_DEFINE_RACE_SCALAR(NAME, TYPE) \
        \\MC_UNUSED static inline TYPE mc_race_load_##NAME(TYPE const *p) { \
        \\    TYPE value; \
        \\    __atomic_load(p, &value, __ATOMIC_RELAXED); \
        \\    return value; \
        \\} \
        \\MC_UNUSED static inline void mc_race_store_##NAME(TYPE *p, TYPE value) { \
        \\    __atomic_store(p, &value, __ATOMIC_RELAXED); \
        \\}
        \\
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
        \\
        \\#define MC_DEFINE_RAW_STORE(NAME, TYPE) \
        \\MC_UNUSED static inline void mc_raw_store_##NAME(uintptr_t addr, TYPE value) { \
        \\    *((volatile TYPE *)(uintptr_t)addr) = value; \
        \\}
        \\#define MC_DEFINE_RAW_LOAD(NAME, TYPE) \
        \\MC_UNUSED static inline TYPE mc_raw_load_##NAME(uintptr_t addr) { \
        \\    return *((volatile TYPE *)(uintptr_t)addr); \
        \\}
        \\
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
        \\MC_UNUSED static inline void mc_barrier_release_before(void) {
        \\    __atomic_thread_fence(__ATOMIC_RELEASE);
        \\}
        \\
        \\MC_UNUSED static inline void mc_barrier_acquire_after(void) {
        \\    __atomic_thread_fence(__ATOMIC_ACQUIRE);
        \\}
        \\
        \\MC_UNUSED static inline void mc_barrier_full(void) {
        \\    __atomic_thread_fence(__ATOMIC_SEQ_CST);
        \\}
        \\
    );

    var typed_mir = try mir.build(allocator, module);
    defer typed_mir.deinit();

    var emitter = CEmitter.init(allocator, out, &typed_mir);
    try emitter.emitModule(module);
}

fn hasTestDiagnosticCode(reporter: diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.startsWith(u8, diag.message, code) and diag.message.len > code.len and diag.message[code.len] == ':') return true;
    }
    return false;
}

const CEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scratch: std.heap.ArenaAllocator,
    globals: std.StringHashMap(GlobalInfo),
    static_initializers: std.StringHashMap(ast.Expr),
    type_aliases: std.StringHashMap(ast.TypeExpr),
    functions: std.StringHashMap(FnInfo),
    // `const fn` bodies and folded `const` global values, for folding comptime
    // const-fn calls / named constants in fixed-array lengths (section 22
    // comptime↔type feedback).
    const_fns: std.StringHashMap(ast.FnDecl),
    const_globals: std.StringHashMap(eval.ComptimeValue),
    structs: std.StringHashMap(ast.StructDecl),
    mmio_structs: std.StringHashMap(MmioStruct),
    packed_bits: std.StringHashMap(PackedBitsInfo),
    overlay_unions: std.StringHashMap(OverlayUnionInfo),
    tagged_unions: std.StringHashMap(ast.UnionDecl),
    enums: std.StringHashMap(ast.EnumDecl),
    array_types: std.StringHashMap(ArrayInfo),
    slice_types: std.StringHashMap(SliceInfo),
    result_types: std.StringHashMap(ResultInfo),
    // Function-pointer signatures encountered, each emitted as a `typedef RET
    // (*name)(params);` so the name-in-the-middle C declarator works anywhere a
    // plain type name does.
    fn_ptr_types: std.StringHashMap(ast.TypeExpr),
    closure_types: std.StringHashMap(ast.TypeExpr),
    mir_module: *const mir.Module,
    current_function: ?[]const u8 = null,
    temp_index: usize,
    indent: usize,
    // Stack of enclosing loop ids and a counter, for lowering `break`/`continue`
    // as labeled `goto`s so they target the loop even through an intervening
    // `switch` (a C `break` inside a `switch` would otherwise break the switch).
    loop_ids: std.ArrayList(u32) = .empty,
    next_loop_id: u32 = 0,

    fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8), mir_module: *const mir.Module) CEmitter {
        return .{
            .allocator = allocator,
            .out = out,
            .scratch = std.heap.ArenaAllocator.init(allocator),
            .globals = std.StringHashMap(GlobalInfo).init(allocator),
            .static_initializers = std.StringHashMap(ast.Expr).init(allocator),
            .type_aliases = std.StringHashMap(ast.TypeExpr).init(allocator),
            .functions = std.StringHashMap(FnInfo).init(allocator),
            .const_fns = std.StringHashMap(ast.FnDecl).init(allocator),
            .const_globals = std.StringHashMap(eval.ComptimeValue).init(allocator),
            .structs = std.StringHashMap(ast.StructDecl).init(allocator),
            .mmio_structs = std.StringHashMap(MmioStruct).init(allocator),
            .packed_bits = std.StringHashMap(PackedBitsInfo).init(allocator),
            .overlay_unions = std.StringHashMap(OverlayUnionInfo).init(allocator),
            .tagged_unions = std.StringHashMap(ast.UnionDecl).init(allocator),
            .enums = std.StringHashMap(ast.EnumDecl).init(allocator),
            .array_types = std.StringHashMap(ArrayInfo).init(allocator),
            .slice_types = std.StringHashMap(SliceInfo).init(allocator),
            .result_types = std.StringHashMap(ResultInfo).init(allocator),
            .fn_ptr_types = std.StringHashMap(ast.TypeExpr).init(allocator),
            .closure_types = std.StringHashMap(ast.TypeExpr).init(allocator),
            .mir_module = mir_module,
            .temp_index = 0,
            .indent = 0,
        };
    }

    fn deinit(self: *CEmitter) void {
        self.fn_ptr_types.deinit();
        self.closure_types.deinit();
        self.result_types.deinit();
        self.slice_types.deinit();
        self.array_types.deinit();
        self.enums.deinit();
        var packed_bits = self.packed_bits.valueIterator();
        while (packed_bits.next()) |bits| bits.fields.deinit();
        self.packed_bits.deinit();
        var overlay_unions = self.overlay_unions.valueIterator();
        while (overlay_unions.next()) |overlay_union| overlay_union.fields.deinit();
        self.overlay_unions.deinit();
        self.tagged_unions.deinit();
        var mmio_structs = self.mmio_structs.valueIterator();
        while (mmio_structs.next()) |mmio_struct| mmio_struct.fields.deinit();
        self.mmio_structs.deinit();
        self.structs.deinit();
        self.const_fns.deinit();
        self.const_globals.deinit();
        self.functions.deinit();
        self.type_aliases.deinit();
        self.static_initializers.deinit();
        self.globals.deinit();
        self.loop_ids.deinit(self.allocator);
        self.scratch.deinit();
    }

    fn emitModule(self: *CEmitter, module: ast.Module) anyerror!void {
        defer self.deinit();
        // Pre-pass: collect `const fn` bodies and fold `const` global values up
        // front, so fixed-array lengths that reference them (section 22
        // comptime↔type) resolve during the artifact-collection pass below.
        for (module.decls) |decl| {
            if (decl.kind == .fn_decl) {
                const fn_decl = decl.kind.fn_decl;
                if (fn_decl.is_const and !self.const_fns.contains(fn_decl.name.text)) try self.const_fns.put(fn_decl.name.text, fn_decl);
            }
        }
        try eval.collectConstGlobals(self.allocator, module, &self.const_fns, &self.const_globals);
        // Pre-register every (non-MMIO) struct and type alias name so type-name
        // mangling (`typeSuffix`'s `struct_` prefix) is consistent regardless of
        // declaration/import order — e.g. an array-of-struct field (`[N]S`) whose
        // element struct `S` is declared after the containing struct, or in a
        // later-merged import. Without this the generated-typedef name and the
        // field's type reference can disagree.
        for (module.decls) |decl| {
            switch (decl.kind) {
                .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
                .struct_decl => |struct_decl| {
                    if (!isMmioStructAbi(struct_decl)) try self.structs.put(struct_decl.name.text, struct_decl);
                },
                else => {},
            }
        }
        for (module.decls) |decl| {
            switch (decl.kind) {
                .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
                .global_decl => |global| {
                    if (global.ty) |ty| try self.globals.put(global.name.text, try self.globalInfoFromType(ty));
                    if (global.ty) |ty| try self.collectTypeArtifacts(ty);
                },
                .struct_decl => |struct_decl| {
                    if (isMmioStructAbi(struct_decl)) {
                        try self.collectMmioStruct(struct_decl);
                    } else {
                        try self.structs.put(struct_decl.name.text, struct_decl);
                        for (struct_decl.fields) |field| try self.collectTypeArtifacts(field.ty);
                    }
                },
                .enum_decl => |enum_decl| try self.enums.put(enum_decl.name.text, enum_decl),
                .union_decl => |union_decl| try self.collectTaggedUnion(union_decl),
                .packed_bits_decl => |packed_bits| try self.collectPackedBits(packed_bits),
                .overlay_union_decl => |overlay_union| try self.collectOverlayUnion(overlay_union),
                .fn_decl => |fn_decl| {
                    try self.functions.put(fn_decl.name.text, .{ .params = fn_decl.params, .return_type = fn_decl.return_type, .is_extern = false });
                    if (fn_decl.is_const and !self.const_fns.contains(fn_decl.name.text)) try self.const_fns.put(fn_decl.name.text, fn_decl);
                    try self.collectFunctionSliceTypes(fn_decl);
                },
                .extern_fn => |fn_decl| {
                    try self.functions.put(fn_decl.name.text, .{ .params = fn_decl.params, .return_type = fn_decl.return_type, .is_extern = true });
                    try self.collectFunctionSliceTypes(fn_decl);
                },
                else => {},
            }
        }
        try self.emitEnums();
        try self.emitPackedBitsTypes();
        try self.emitOverlayUnionTypes();
        try self.emitAggregateForwardDeclarations(module);
        // Slices lower to a struct with a pointer field, so the forward
        // declarations above suffice; emit them before the by-value aggregates
        // (a struct may embed a slice by value).
        try self.emitSliceTypes();
        // Function-pointer typedefs depend only on already-declared scalar/struct
        // types, and structs/params may reference them by name.
        try self.emitFnPtrTypes();
        try self.emitClosureTypes();
        for (module.decls) |decl| {
            if (decl.kind == .struct_decl and self.mmio_structs.contains(decl.kind.struct_decl.name.text)) {
                try self.emitMmioStruct(decl.kind.struct_decl);
            }
        }
        // Arrays, structs, Result types, and tagged unions can embed one another
        // by value (`[N]S`, `struct { [N]S }`, `Result<S, E>`), so emit them in
        // dependency order rather than a fixed category order.
        try self.emitOrderedAggregates(module);
        // Forward-declare every defined function up front so a call to a function
        // declared later in the (possibly import-merged) source resolves — MC
        // resolves calls module-wide, independent of declaration order.
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fn_decl| if (fn_decl.body != null) try self.emitFunctionForwardDecl(fn_decl),
                // Extern prototypes must precede any function body that calls them;
                // an imported `extern fn` can be merged after its caller.
                .extern_fn => |fn_decl| try self.emitExternFunction(fn_decl),
                else => {},
            }
        }
        // Emit every global before any function body. MC resolves names
        // module-wide regardless of declaration order, and import-merged sources
        // can place a function ahead of a global it reads (e.g. a `const` defined
        // in an imported module). Globals are simple `static` definitions, so
        // emitting them first satisfies C's declare-before-use without needing
        // forward declarations.
        for (module.decls) |decl| {
            switch (decl.kind) {
                .global_decl => |global| try self.emitGlobal(global),
                else => {},
            }
        }
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl => |fn_decl| if (fn_decl.body) |body| try self.emitFunction(fn_decl, body) else try self.emitFunctionPrototype(fn_decl),
                // extern prototypes were already emitted in the forward-declaration pass.
                .extern_fn => {},
                .global_decl, .type_alias, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl => {},
            }
        }
    }

    fn emitGlobal(self: *CEmitter, global: ast.GlobalDecl) !void {
        try self.out.appendSlice(self.allocator, "static MC_UNUSED ");
        if (global.ty) |global_ty| {
            try self.emitDeclarator(global_ty, global.name.text);
        } else {
            try self.out.print(self.allocator, "uint32_t {s}", .{global.name.text});
        }
        if (global.init) |initializer| {
            // A `const` global (section 22) emits its folded compile-time value,
            // so initializers like `MAX * 2` that reference earlier const
            // globals lower to a plain C constant.
            if (global.is_const) {
                if (try self.constGlobalCValue(initializer)) |text| {
                    try self.out.print(self.allocator, " = {s};\n\n", .{text});
                    return;
                }
            }
            if (self.staticCInitializer(initializer)) |static_initializer| {
                try self.out.appendSlice(self.allocator, " = ");
                if (try self.emitStaticCInitializer(static_initializer)) {
                    // Emitted directly.
                } else if (global.ty) |global_ty| {
                    try self.emitExprWithTarget(static_initializer, null, global_ty);
                } else {
                    try self.emitExpr(static_initializer, null);
                }
                try self.static_initializers.put(global.name.text, static_initializer);
            } else if (global.ty != null and isArrayLiteralExpr(initializer)) {
                try self.out.appendSlice(self.allocator, " = ");
                try self.emitExprWithTarget(initializer, null, global.ty.?);
            } else if (global.ty != null and isStructLiteralExpr(initializer)) {
                try self.out.appendSlice(self.allocator, " = ");
                try self.emitExprWithTarget(initializer, null, global.ty.?);
            } else if (global.ty != null and global.ty.?.kind == .array) {
                try self.out.appendSlice(self.allocator, "/* unsupported non-static global array initializer */");
                return error.UnsupportedCEmission;
            } else {
                try self.out.appendSlice(self.allocator, "/* unsupported non-static global initializer */");
                return error.UnsupportedCEmission;
            }
        } else if (global.ty != null and self.zeroInitializerRequiresBraces(global.ty.?)) {
            try self.out.appendSlice(self.allocator, " = {0}");
        } else {
            try self.out.appendSlice(self.allocator, " = 0");
        }
        try self.out.appendSlice(self.allocator, ";\n\n");
    }

    // Fold a `const` global initializer to its C constant text (section 22).
    fn constGlobalCValue(self: *CEmitter, expr: ast.Expr) !?[]const u8 {
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var scope = eval.ComptimeScope.init(fba.allocator());
        scope.funcs = &self.const_fns;
        scope.globals = &self.const_globals;
        return switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => |v| switch (v) {
                // Values above the signed-64 range need an unsigned suffix, or C
                // reads the decimal literal as implicitly unsigned (a warning).
                .int => |n| if (n > std.math.maxInt(i64))
                    try std.fmt.allocPrint(self.scratch.allocator(), "{d}ULL", .{n})
                else
                    try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{n}),
                .boolean => |b| if (b) "1" else "0",
                // Aggregate const globals are not lowered to a C scalar here.
                .array, .@"struct" => null,
            },
            else => null,
        };
    }

    fn zeroInitializerRequiresBraces(self: *CEmitter, ty: ast.TypeExpr) bool {
        return switch (ty.kind) {
            .array => true,
            .name => |name| self.structs.contains(name.text),
            .qualified => |node| self.zeroInitializerRequiresBraces(node.child.*),
            else => false,
        };
    }

    fn emitEnums(self: *CEmitter) !void {
        var it = self.enums.valueIterator();
        while (it.next()) |enum_decl| {
            try self.out.print(self.allocator, "typedef {s} {s};\n", .{ try self.enumReprCType(enum_decl.*), enum_decl.name.text });
            try self.out.appendSlice(self.allocator, "enum {\n");
            self.indent += 1;
            for (enum_decl.cases, 0..) |case, i| {
                try self.writeIndent();
                try self.out.print(self.allocator, "{s}_{s}", .{ enum_decl.name.text, case.name.text });
                if (case.value) |value| {
                    try self.out.appendSlice(self.allocator, " = ");
                    try self.emitEnumCaseValue(value);
                } else {
                    try self.out.print(self.allocator, " = {d}", .{i});
                }
                try self.out.appendSlice(self.allocator, ",\n");
            }
            self.indent -= 1;
            try self.out.appendSlice(self.allocator, "};\n\n");
        }
    }

    fn enumReprCType(self: *CEmitter, enum_decl: ast.EnumDecl) ![]const u8 {
        return if (enum_decl.repr) |repr| try self.cTypeFor(repr, .typedef_name) else "intptr_t";
    }

    fn emitPackedBitsTypes(self: *CEmitter) !void {
        var it = self.packed_bits.iterator();
        while (it.next()) |entry| {
            try self.out.print(self.allocator, "typedef {s} {s};\n\n", .{ entry.value_ptr.repr_c_type, entry.key_ptr.* });
        }
    }

    fn emitOverlayUnionTypes(self: *CEmitter) !void {
        var it = self.overlay_unions.iterator();
        while (it.next()) |entry| {
            try self.out.print(self.allocator, "typedef struct {s} {{\n", .{entry.key_ptr.*});
            self.indent += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "alignas({d}) unsigned char storage[{d}];\n", .{ entry.value_ptr.alignment, entry.value_ptr.size });
            self.indent -= 1;
            try self.out.print(self.allocator, "}} {s};\n\n", .{entry.key_ptr.*});
        }
    }

    fn emitTaggedUnionTypes(self: *CEmitter, module: ast.Module) !void {
        for (module.decls) |decl| {
            if (decl.kind != .union_decl) continue;
            const union_decl = decl.kind.union_decl;
            if (!self.tagged_unions.contains(union_decl.name.text)) continue;
            try self.emitTaggedUnionType(union_decl);
        }
    }

    fn emitTaggedUnionType(self: *CEmitter, union_decl: ast.UnionDecl) !void {
        try self.out.print(self.allocator, "typedef enum {s}Tag {{\n", .{union_decl.name.text});
        self.indent += 1;
        for (union_decl.cases, 0..) |case, i| {
            try self.writeIndent();
            try self.out.print(self.allocator, "{s}Tag_{s} = {d},\n", .{ union_decl.name.text, case.name.text, i });
        }
        self.indent -= 1;
        try self.out.print(self.allocator, "}} {s}Tag;\n\n", .{union_decl.name.text});

        try self.out.print(self.allocator, "typedef struct {s} {{\n", .{union_decl.name.text});
        self.indent += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}Tag tag;\n", .{union_decl.name.text});

        var has_payload = false;
        for (union_decl.cases) |case| {
            if (case.ty != null) {
                has_payload = true;
                break;
            }
        }

        if (has_payload) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "union {\n");
            self.indent += 1;
            for (union_decl.cases) |case| {
                const payload_ty = case.ty orelse continue;
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s};\n", .{
                    try self.cTypeFor(payload_ty, .typedef_name),
                    try self.cPayloadFieldName(case.name.text),
                });
            }
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "} payload;\n");
        }

        self.indent -= 1;
        try self.out.print(self.allocator, "}} {s};\n\n", .{union_decl.name.text});
    }

    fn emitEnumCaseValue(self: *CEmitter, value: ast.Expr) !void {
        switch (value.kind) {
            .int_literal => |literal| try appendCIntLiteral(self.allocator, self.out, literal),
            .grouped => |inner| try self.emitEnumCaseValue(inner.*),
            // Negative discriminants for signed-repr enums (`negative = -1`).
            .unary => |node| {
                if (node.op != .neg) return self.unsupportedEnumValue(value);
                try self.out.appendSlice(self.allocator, "-");
                try self.emitEnumCaseValue(node.expr.*);
            },
            else => return self.unsupportedEnumValue(value),
        }
    }

    fn unsupportedEnumValue(self: *CEmitter, value: ast.Expr) !void {
        try self.out.print(self.allocator, "/* unsupported enum value: {s} */0", .{@tagName(value.kind)});
        return error.UnsupportedCEmission;
    }

    // Forward-declare every user struct and tagged-union as an incomplete
    // typedef so that container types emitted earlier (e.g. a slice
    // `[]const T` lowering to a struct with a `T *` field) can name `T` before
    // its full definition appears. C11 permits the later redundant
    // `typedef struct T { ... } T;`. Pointer references only need this forward
    // declaration; by-value embedding still relies on definition ordering.
    fn emitAggregateForwardDeclarations(self: *CEmitter, module: ast.Module) !void {
        var emitted = false;
        for (module.decls) |decl| {
            const name = switch (decl.kind) {
                .struct_decl => |struct_decl| if (self.structs.contains(struct_decl.name.text)) struct_decl.name.text else continue,
                .union_decl => |union_decl| if (self.tagged_unions.contains(union_decl.name.text)) union_decl.name.text else continue,
                else => continue,
            };
            try self.out.print(self.allocator, "typedef struct {s} {s};\n", .{ name, name });
            emitted = true;
        }
        // Generated array/Result typedefs are also `struct`s and may be referenced
        // through a pointer before their definition (e.g. a slice of an array,
        // `[][N]T`, whose element pointer is `mc_array_..._N *`).
        {
            var it = self.array_types.valueIterator();
            while (it.next()) |array| {
                try self.out.print(self.allocator, "typedef struct {s} {s};\n", .{ array.name, array.name });
                emitted = true;
            }
        }
        {
            var it = self.result_types.valueIterator();
            while (it.next()) |result| {
                try self.out.print(self.allocator, "typedef struct {s} {s};\n", .{ result.name, result.name });
                emitted = true;
            }
        }
        if (emitted) try self.out.appendSlice(self.allocator, "\n");
    }

    // Emit arrays, structs, Result types, and tagged unions in dependency
    // order: a unit is emitted once every aggregate it embeds *by value* has
    // been emitted. Pointer/slice references are covered by the forward
    // declarations and need no ordering. For valid (acyclic) programs this
    // terminates; a defensive fallback emits any stragglers to stay complete.
    fn emitOrderedAggregates(self: *CEmitter, module: ast.Module) !void {
        const arena = self.scratch.allocator();
        var units: std.ArrayList(AggregateEmitUnit) = .empty;
        defer units.deinit(arena);

        for (module.decls) |decl| switch (decl.kind) {
            .struct_decl => |s| if (self.structs.contains(s.name.text)) try units.append(arena, .{ .struct_decl = s }),
            .union_decl => |u| if (self.tagged_unions.contains(u.name.text)) try units.append(arena, .{ .tagged_union = u }),
            else => {},
        };
        {
            var it = self.array_types.valueIterator();
            while (it.next()) |a| try units.append(arena, .{ .array = a.* });
        }
        {
            var it = self.result_types.valueIterator();
            while (it.next()) |r| try units.append(arena, .{ .result = r.* });
        }

        var emitted = std.StringHashMap(void).init(arena);
        defer emitted.deinit();
        const done = try arena.alloc(bool, units.items.len);
        @memset(done, false);

        var remaining = units.items.len;
        while (remaining > 0) {
            var progressed = false;
            for (units.items, 0..) |unit, i| {
                if (done[i]) continue;
                if (!try self.aggregateDepsSatisfied(unit, &emitted)) continue;
                try self.emitAggregateUnit(unit);
                try emitted.put(self.aggregateUnitName(unit), {});
                done[i] = true;
                remaining -= 1;
                progressed = true;
            }
            if (progressed) continue;
            // No progress: an unexpected dependency cycle. Emit the rest as-is
            // so output stays complete (clang will flag any genuine bad order).
            for (units.items, 0..) |unit, i| {
                if (done[i]) continue;
                try self.emitAggregateUnit(unit);
                done[i] = true;
            }
            break;
        }
    }

    fn aggregateUnitName(self: *CEmitter, unit: AggregateEmitUnit) []const u8 {
        _ = self;
        return switch (unit) {
            .struct_decl => |s| s.name.text,
            .array => |a| a.name,
            .result => |r| r.name,
            .tagged_union => |u| u.name.text,
        };
    }

    fn emitAggregateUnit(self: *CEmitter, unit: AggregateEmitUnit) !void {
        switch (unit) {
            .struct_decl => |s| try self.emitStruct(s),
            .array => |a| try self.emitArrayType(a),
            .result => |r| try self.emitResultType(r),
            .tagged_union => |u| try self.emitTaggedUnionType(u),
        }
    }

    fn aggregateDepsSatisfied(self: *CEmitter, unit: AggregateEmitUnit, emitted: *std.StringHashMap(void)) !bool {
        switch (unit) {
            .struct_decl => |s| for (s.fields) |field| {
                if (try self.aggregateDepName(field.ty)) |dep| if (!emitted.contains(dep)) return false;
            },
            .array => |a| {
                if (try self.aggregateDepName(a.element_ty)) |dep| if (!emitted.contains(dep)) return false;
            },
            .result => |r| {
                if (try self.aggregateDepName(r.ok_ty)) |dep| if (!emitted.contains(dep)) return false;
                if (try self.aggregateDepName(r.err_ty)) |dep| if (!emitted.contains(dep)) return false;
            },
            .tagged_union => |u| for (u.cases) |case| {
                if (case.ty) |ty| if (try self.aggregateDepName(ty)) |dep| if (!emitted.contains(dep)) return false;
            },
        }
        return true;
    }

    // The typedef name of the by-value aggregate `ty` refers to, if it is one
    // this pass emits (struct, array, Result, tagged union). Slices, pointers,
    // and nullable pointers reference their pointee only through a pointer, so
    // they impose no ordering and return null; scalars and enums likewise.
    fn aggregateDepName(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .array => try self.cTypeFor(resolved, .typedef_name),
            .qualified => |node| try self.aggregateDepName(node.child.*),
            .generic => |node| if (std.mem.eql(u8, node.base.text, "Result"))
                try self.cTypeFor(resolved, .typedef_name)
            else
                null,
            .name => |ident| if (self.structs.contains(ident.text) or self.tagged_unions.contains(ident.text)) ident.text else null,
            else => null,
        };
    }

    fn emitStruct(self: *CEmitter, struct_decl: ast.StructDecl) !void {
        try self.out.print(self.allocator, "typedef struct {s} {{\n", .{struct_decl.name.text});
        self.indent += 1;
        for (struct_decl.fields) |field| {
            try self.writeIndent();
            try self.emitStructFieldDeclarator(field.ty, field.name.text);
            try self.out.appendSlice(self.allocator, ";\n");
        }
        self.indent -= 1;
        try self.out.print(self.allocator, "}} {s};\n\n", .{struct_decl.name.text});
    }

    fn emitSliceTypes(self: *CEmitter) !void {
        var it = self.slice_types.valueIterator();
        while (it.next()) |slice| {
            try self.out.print(self.allocator, "typedef struct {s} {{\n", .{slice.name});
            self.indent += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} ptr;\n", .{slice.ptr_type});
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "uintptr_t len;\n");
            self.indent -= 1;
            try self.out.print(self.allocator, "}} {s};\n\n", .{slice.name});
        }
    }

    fn emitResultTypes(self: *CEmitter) !void {
        var it = self.result_types.valueIterator();
        while (it.next()) |result| try self.emitResultType(result.*);
    }

    // C has no `void` struct member, so a `Result<void, E>` (or `Result<T, void>`)
    // payload uses a 1-byte placeholder. The unit value `()` lowers to `0`, so
    // `.payload.ok = 0` stays well-formed.
    fn resultPayloadCType(self: *CEmitter, ty: ast.TypeExpr) ![]const u8 {
        if (isVoidType(self.resolveAliasType(ty))) return "unsigned char";
        return try self.cTypeFor(ty, .typedef_name);
    }

    fn emitResultType(self: *CEmitter, result: ResultInfo) !void {
        try self.out.print(self.allocator, "typedef struct {s} {{\n", .{result.name});
        self.indent += 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "bool is_ok;\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "union {\n");
        self.indent += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} ok;\n", .{try self.resultPayloadCType(result.ok_ty)});
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} err;\n", .{try self.resultPayloadCType(result.err_ty)});
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "} payload;\n");
        self.indent -= 1;
        try self.out.print(self.allocator, "}} {s};\n\n", .{result.name});
    }

    fn emitArrayTypes(self: *CEmitter) !void {
        var it = self.array_types.valueIterator();
        while (it.next()) |array| try self.emitArrayType(array.*);
    }

    fn emitArrayType(self: *CEmitter, array: ArrayInfo) !void {
        try self.out.print(self.allocator, "typedef struct {s} {{\n", .{array.name});
        self.indent += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} elems[{s}];\n", .{ array.element_c_type, array.len });
        self.indent -= 1;
        try self.out.print(self.allocator, "}} {s};\n\n", .{array.name});
    }

    fn emitFunctionPrototype(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        try self.emitFunctionSignature(fn_decl, false);
        try self.out.appendSlice(self.allocator, ";\n\n");
    }

    // Forward declaration for a *defined* function, matching the definition's
    // storage class (non-exported functions are `static`) so the prototype and
    // body agree.
    fn emitFunctionForwardDecl(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        try self.emitFunctionSignature(fn_decl, !fn_decl.exported);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitExternFunction(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        try self.emitFunctionPrototype(fn_decl);
    }

    fn emitFunction(self: *CEmitter, fn_decl: ast.FnDecl, body: ast.Block) anyerror!void {
        try self.emitFunctionSignature(fn_decl, !fn_decl.exported);
        try self.out.appendSlice(self.allocator, " {\n");

        const previous_function = self.current_function;
        self.current_function = fn_decl.name.text;
        defer self.current_function = previous_function;

        var locals = std.StringHashMap(LocalInfo).init(self.allocator);
        defer locals.deinit();
        for (fn_decl.params) |param| try locals.put(param.name.text, try self.localInfoFromType(param.ty));

        self.indent += 1;
        try self.emitBlockItems(body, &locals, fn_decl.return_type);
        self.indent -= 1;
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn emitFunctionSignature(self: *CEmitter, fn_decl: ast.FnDecl, is_static: bool) !void {
        const ret = if (fn_decl.return_type) |ret_ty| try self.cTypeFor(ret_ty, .typedef_name) else "void";
        const cname = try self.cIdent(fn_decl.name.text);
        if (is_static) {
            try self.out.print(self.allocator, "MC_UNUSED static {s} {s}(", .{ ret, cname });
        } else {
            try self.out.print(self.allocator, "{s} {s}(", .{ ret, cname });
        }
        if (fn_decl.params.len == 0) {
            try self.out.appendSlice(self.allocator, "void");
        } else {
            for (fn_decl.params, 0..) |param, i| {
                if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                try self.emitParamDecl(param.ty, param.name.text);
            }
        }
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitParamDecl(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try self.emitDeclarator(ty, name);
    }

    fn emitDeclarator(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try self.emitDeclaratorWithStyle(ty, name, .typedef_name);
    }

    fn emitStructFieldDeclarator(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try self.emitDeclaratorWithStyle(ty, name, .struct_tag);
    }

    fn emitDeclaratorWithStyle(self: *CEmitter, ty: ast.TypeExpr, name: []const u8, style: StructTypeStyle) !void {
        try self.out.print(self.allocator, "{s} {s}", .{ try self.cTypeFor(ty, style), try self.cIdent(name) });
    }

    // Maps an MC value identifier to a safe C identifier. Identity for ordinary
    // names (so generated C is stable) and for the emitter's own `mc_`-prefixed
    // temporaries; only C reserved words are rewritten (e.g. `int` -> `int_`).
    // The mapping is deterministic, so declarations and uses stay consistent.
    fn cIdent(self: *CEmitter, name: []const u8) ![]const u8 {
        if (isCReservedWord(name)) return std.fmt.allocPrint(self.scratch.allocator(), "{s}_", .{name});
        return name;
    }

    fn cTypeFor(self: *CEmitter, ty: ast.TypeExpr, style: StructTypeStyle) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendType(&out, ty, style);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn appendType(self: *CEmitter, out: *std.ArrayList(u8), ty: ast.TypeExpr, style: StructTypeStyle) anyerror!void {
        if (self.aliasTargetType(ty)) |target| return self.appendType(out, target, style);
        switch (ty.kind) {
            .pointer => |node| return self.appendPointerType(out, node.child.*, node.mutability, style),
            .raw_many_pointer => |node| return self.appendPointerType(out, node.child.*, node.mutability, style),
            .slice => |node| return out.appendSlice(self.scratch.allocator(), try self.sliceTypeName(node.child.*, node.mutability)),
            .array => |node| return out.appendSlice(self.scratch.allocator(), try self.arrayTypeName(node.child.*, node.len)),
            .nullable => |child| return self.appendType(out, child.*, style),
            .qualified => |node| return self.appendType(out, node.child.*, style),
            .generic => |node| {
                if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
                    return out.appendSlice(self.scratch.allocator(), try self.resultTypeName(node.args[0], node.args[1]));
                }
                if ((std.mem.eql(u8, node.base.text, "wrap") or
                    std.mem.eql(u8, node.base.text, "sat") or
                    std.mem.eql(u8, node.base.text, "serial") or
                    std.mem.eql(u8, node.base.text, "counter") or
                    std.mem.eql(u8, node.base.text, "Duration")) and node.args.len == 1)
                {
                    return self.appendType(out, node.args[0], style);
                }
                if (std.mem.eql(u8, node.base.text, "atomic") and node.args.len == 1) {
                    return self.appendType(out, node.args[0], style);
                }
                if (std.mem.eql(u8, node.base.text, "UserPtr") or std.mem.eql(u8, node.base.text, "PhysPtr")) {
                    return out.appendSlice(self.scratch.allocator(), "uintptr_t");
                }
                if (std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1) {
                    const pointee = typeName(node.args[0]) orelse return out.appendSlice(self.scratch.allocator(), "void *");
                    if (self.mmio_structs.contains(pointee)) {
                        try out.appendSlice(self.scratch.allocator(), pointee);
                        return out.appendSlice(self.scratch.allocator(), " volatile *");
                    }
                }
            },
            .fn_pointer => |node| {
                const name = try self.fnPtrTypeName(node);
                if (!self.fn_ptr_types.contains(name)) try self.fn_ptr_types.put(name, ty);
                return out.appendSlice(self.scratch.allocator(), name);
            },
            .closure_type => |node| {
                const name = try self.closureTypeName(node);
                if (!self.closure_types.contains(name)) try self.closure_types.put(name, ty);
                return out.appendSlice(self.scratch.allocator(), name);
            },
            else => {},
        }
        if (typeName(ty)) |name| {
            if (std.mem.eql(u8, name, "c_void")) return out.appendSlice(self.scratch.allocator(), "void");
            if (self.enums.contains(name)) return out.appendSlice(self.scratch.allocator(), name);
            if (self.packed_bits.contains(name)) return out.appendSlice(self.scratch.allocator(), name);
            if (self.overlay_unions.contains(name)) return out.appendSlice(self.scratch.allocator(), name);
            if (self.tagged_unions.contains(name)) return out.appendSlice(self.scratch.allocator(), name);
            if (self.structs.contains(name)) {
                if (style == .struct_tag) try out.appendSlice(self.scratch.allocator(), "struct ");
                return out.appendSlice(self.scratch.allocator(), name);
            }
        }
        try out.appendSlice(self.scratch.allocator(), cType(ty));
    }

    fn resolveAliasType(self: *CEmitter, ty: ast.TypeExpr) ast.TypeExpr {
        return self.resolveAliasTypeDepth(ty, 0);
    }

    fn aliasTargetType(self: *CEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        return switch (ty.kind) {
            .name => |name| {
                const target = self.type_aliases.get(name.text) orelse return null;
                if (typeName(target)) |target_name| {
                    if (std.mem.eql(u8, target_name, name.text)) return null;
                }
                return target;
            },
            .qualified => |node| self.aliasTargetType(node.child.*),
            else => null,
        };
    }

    fn resolveAliasTypeDepth(self: *CEmitter, ty: ast.TypeExpr, depth: usize) ast.TypeExpr {
        if (depth > 64) return ty;
        return switch (ty.kind) {
            .name => |name| {
                const target = self.type_aliases.get(name.text) orelse return ty;
                if (typeName(target)) |target_name| {
                    if (std.mem.eql(u8, target_name, name.text)) return ty;
                }
                return self.resolveAliasTypeDepth(target, depth + 1);
            },
            .qualified => |node| self.resolveAliasTypeDepth(node.child.*, depth),
            else => ty,
        };
    }

    fn collectPackedBits(self: *CEmitter, packed_bits: ast.PackedBitsDecl) !void {
        var fields = std.StringHashMap(PackedBitsField).init(self.allocator);
        errdefer fields.deinit();
        for (packed_bits.fields, 0..) |field, bit_index| {
            try fields.put(field.name.text, .{ .bit_index = bit_index });
        }
        try self.packed_bits.put(packed_bits.name.text, .{
            .repr_name = typeName(packed_bits.repr) orelse "unknown",
            .repr_c_type = try self.cTypeFor(packed_bits.repr, .typedef_name),
            .fields = fields,
        });
    }

    fn collectOverlayUnion(self: *CEmitter, overlay_union: ast.OverlayUnionDecl) !void {
        var size: usize = 1;
        var alignment: usize = 1;
        var fields = std.StringHashMap(OverlayFieldInfo).init(self.allocator);
        errdefer fields.deinit();
        for (overlay_union.fields) |field| {
            const layout = self.overlayFieldLayout(field.ty) orelse return error.UnsupportedCEmission;
            size = @max(size, layout.size);
            alignment = @max(alignment, layout.alignment);
            try self.collectTypeArtifacts(field.ty);
            try fields.put(field.name.text, .{
                .ty = field.ty,
                .layout = layout,
                .byte_array_len = try self.overlayByteArrayLen(field.ty),
            });
        }
        try self.overlay_unions.put(overlay_union.name.text, .{ .size = size, .alignment = alignment, .fields = fields });
    }

    fn collectTaggedUnion(self: *CEmitter, union_decl: ast.UnionDecl) !void {
        for (union_decl.cases) |case| {
            if (case.ty) |ty| try self.collectTypeArtifacts(ty);
        }
        try self.tagged_unions.put(union_decl.name.text, union_decl);
    }

    fn overlayFieldLayout(self: *CEmitter, ty: ast.TypeExpr) ?OverlayLayout {
        switch (ty.kind) {
            .array => |node| {
                const child = self.overlayFieldLayout(node.child.*) orelse return null;
                const len = constArrayLenValue(node.len, &self.const_fns, &self.const_globals) orelse return null;
                return .{ .size = child.size * len, .alignment = child.alignment };
            },
            .qualified => |node| return self.overlayFieldLayout(node.child.*),
            else => {},
        }
        const name = typeName(ty) orelse return null;
        if (std.mem.eql(u8, name, "bool")) return .{ .size = 1, .alignment = 1 };
        if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return .{ .size = 1, .alignment = 1 };
        if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return .{ .size = 2, .alignment = 2 };
        if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return .{ .size = 4, .alignment = 4 };
        if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return .{ .size = 8, .alignment = 8 };
        return null;
    }

    fn overlayByteArrayLen(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
        return switch (ty.kind) {
            .array => |node| {
                const child_name = typeName(node.child.*) orelse return null;
                if (!std.mem.eql(u8, child_name, "u8")) return null;
                return try self.arrayLenTextForExpr(node.len);
            },
            .qualified => |node| try self.overlayByteArrayLen(node.child.*),
            else => null,
        };
    }

    fn collectMmioStruct(self: *CEmitter, struct_decl: ast.StructDecl) !void {
        var fields = std.StringHashMap(MmioField).init(self.allocator);
        errdefer fields.deinit();
        for (struct_decl.fields) |field| {
            if (mmioFieldFromType(field.ty)) |info| try fields.put(field.name.text, info);
        }
        try self.mmio_structs.put(struct_decl.name.text, .{ .fields = fields });
    }

    fn emitMmioStruct(self: *CEmitter, struct_decl: ast.StructDecl) !void {
        try self.out.print(self.allocator, "typedef struct {s} {{\n", .{struct_decl.name.text});
        self.indent += 1;
        var running: u64 = 0; // byte offset of the next field
        var pad_n: usize = 0;
        for (struct_decl.fields) |field| {
            const info = mmioFieldFromType(field.ty) orelse {
                try self.writeIndent();
                try self.out.print(self.allocator, "/* unsupported MMIO field: {s} */\n", .{field.name.text});
                return error.UnsupportedCEmission;
            };
            // `@offset(N)` registers are placed at exact byte offsets (a device
            // register map); insert reserved padding to reach each one.
            if (field.offset) |off| {
                if (off < running) return error.UnsupportedCEmission; // offsets must increase
                if (off > running) {
                    try self.writeIndent();
                    try self.out.print(self.allocator, "uint8_t _pad{d}[{d}];\n", .{ pad_n, off - running });
                    pad_n += 1;
                    running = off;
                }
            }
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} volatile {s};\n", .{ primitiveCTypeName(info.width) orelse "void *", try self.cIdent(field.name.text) });
            running += mmioFieldWidthBytes(info.width);
        }
        self.indent -= 1;
        try self.out.print(self.allocator, "}} {s};\n\n", .{struct_decl.name.text});
    }

    fn appendPointerType(self: *CEmitter, out: *std.ArrayList(u8), child: ast.TypeExpr, mutability: ast.Mutability, style: StructTypeStyle) anyerror!void {
        try self.appendType(out, child, style);
        if (mutability == .@"const") {
            try out.appendSlice(self.scratch.allocator(), " const *");
        } else {
            try out.appendSlice(self.scratch.allocator(), " *");
        }
    }

    fn collectFunctionSliceTypes(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        for (fn_decl.params) |param| try self.collectTypeArtifacts(param.ty);
        if (fn_decl.return_type) |ret| try self.collectTypeArtifacts(ret);
        if (fn_decl.body) |body| try self.collectBlockSliceTypes(body);
    }

    fn collectBlockSliceTypes(self: *CEmitter, block: ast.Block) anyerror!void {
        for (block.items) |stmt| switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                if (local.ty) |ty| try self.collectTypeArtifacts(ty);
                if (local.init) |initializer| try self.collectExprTypeArtifacts(initializer);
            },
            .loop => |node| {
                if (node.iterable) |expr| try self.collectExprTypeArtifacts(expr);
                try self.collectBlockSliceTypes(node.body);
            },
            .if_let => |node| {
                try self.collectExprTypeArtifacts(node.value);
                try self.collectBlockSliceTypes(node.then_block);
                if (node.else_block) |else_block| try self.collectBlockSliceTypes(else_block);
            },
            .@"switch" => |node| for (node.arms) |arm| switch (arm.body) {
                .block => |arm_block| try self.collectBlockSliceTypes(arm_block),
                .expr => |expr| try self.collectExprTypeArtifacts(expr),
            },
            .unsafe_block, .comptime_block, .block => |nested| try self.collectBlockSliceTypes(nested),
            .contract_block => |contract| try self.collectBlockSliceTypes(contract.block),
            .@"return" => |maybe| if (maybe) |expr| try self.collectExprTypeArtifacts(expr),
            .@"defer", .expr, .assert => |expr| try self.collectExprTypeArtifacts(expr),
            .assignment => |node| {
                try self.collectExprTypeArtifacts(node.target);
                try self.collectExprTypeArtifacts(node.value);
            },
            else => {},
        };
    }

    fn collectExprTypeArtifacts(self: *CEmitter, expr: ast.Expr) anyerror!void {
        switch (expr.kind) {
            .call => |node| {
                for (node.type_args) |ty| try self.collectTypeArtifacts(ty);
                try self.collectExprTypeArtifacts(node.callee.*);
                for (node.args) |arg| try self.collectExprTypeArtifacts(arg);
            },
            .grouped, .address_of, .deref => |inner| try self.collectExprTypeArtifacts(inner.*),
            .try_expr => |inner| try self.collectExprTypeArtifacts(inner.operand.*),
            .unary => |node| try self.collectExprTypeArtifacts(node.expr.*),
            .binary => |node| {
                try self.collectExprTypeArtifacts(node.left.*);
                try self.collectExprTypeArtifacts(node.right.*);
            },
            .index => |node| {
                try self.collectExprTypeArtifacts(node.base.*);
                try self.collectExprTypeArtifacts(node.index.*);
            },
            .member => |node| try self.collectExprTypeArtifacts(node.base.*),
            .cast => |node| {
                try self.collectTypeArtifacts(node.ty.*);
                try self.collectExprTypeArtifacts(node.value.*);
            },
            .array_literal => |items| for (items) |item| try self.collectExprTypeArtifacts(item),
            .struct_literal => |fields| for (fields) |field| try self.collectExprTypeArtifacts(field.value),
            else => {},
        }
    }

    fn collectTypeArtifacts(self: *CEmitter, ty: ast.TypeExpr) anyerror!void {
        const resolved_ty = self.resolveAliasType(ty);
        try self.collectArrayType(resolved_ty);
        try self.collectSliceType(resolved_ty);
        try self.collectResultType(resolved_ty);
        try self.collectFnPtrType(resolved_ty);
    }

    // A stable typedef name for a function-pointer signature: `mc_fnptr_<ret>` then
    // each parameter suffix, so identical signatures share one typedef.
    fn fnPtrTypeName(self: *CEmitter, node: anytype) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.scratch.allocator(), "mc_fnptr_");
        try buf.appendSlice(self.scratch.allocator(), try self.typeSuffix(node.ret.*));
        for (node.params) |param| {
            try buf.append(self.scratch.allocator(), '_');
            try buf.appendSlice(self.scratch.allocator(), try self.typeSuffix(param));
        }
        return buf.toOwnedSlice(self.scratch.allocator());
    }

    fn closureTypeName(self: *CEmitter, node: anytype) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.scratch.allocator(), "mc_closure_");
        try buf.appendSlice(self.scratch.allocator(), try self.typeSuffix(node.ret.*));
        for (node.params) |param| {
            try buf.append(self.scratch.allocator(), '_');
            try buf.appendSlice(self.scratch.allocator(), try self.typeSuffix(param));
        }
        return buf.toOwnedSlice(self.scratch.allocator());
    }

    fn collectFnPtrType(self: *CEmitter, ty: ast.TypeExpr) anyerror!void {
        switch (ty.kind) {
            .fn_pointer => |node| {
                try self.collectFnPtrType(node.ret.*);
                for (node.params) |param| try self.collectFnPtrType(param);
                const name = try self.fnPtrTypeName(node);
                if (!self.fn_ptr_types.contains(name)) try self.fn_ptr_types.put(name, ty);
            },
            .closure_type => |node| {
                try self.collectFnPtrType(node.ret.*);
                for (node.params) |param| try self.collectFnPtrType(param);
                const name = try self.closureTypeName(node);
                if (!self.closure_types.contains(name)) try self.closure_types.put(name, ty);
            },
            .pointer => |node| try self.collectFnPtrType(node.child.*),
            .raw_many_pointer => |node| try self.collectFnPtrType(node.child.*),
            .nullable => |child| try self.collectFnPtrType(child.*),
            .qualified => |node| try self.collectFnPtrType(node.child.*),
            .array => |node| try self.collectFnPtrType(node.child.*),
            .slice => |node| try self.collectFnPtrType(node.child.*),
            .generic => |node| for (node.args) |arg| try self.collectFnPtrType(arg),
            .member => |node| try self.collectFnPtrType(node.base.*),
            else => {},
        }
    }

    fn emitFnPtrTypes(self: *CEmitter) !void {
        var it = self.fn_ptr_types.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.kind.fn_pointer;
            try self.out.appendSlice(self.allocator, "typedef ");
            try self.out.appendSlice(self.allocator, try self.cTypeFor(node.ret.*, .typedef_name));
            try self.out.print(self.allocator, " (*{s})(", .{entry.key_ptr.*});
            if (node.params.len == 0) {
                try self.out.appendSlice(self.allocator, "void");
            } else {
                for (node.params, 0..) |param, i| {
                    if (i > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.appendSlice(self.allocator, try self.cTypeFor(param, .typedef_name));
                }
            }
            try self.out.appendSlice(self.allocator, ");\n\n");
        }
    }

    // A closure is a fat value: a code pointer taking the type-erased env first,
    // plus the env pointer. `bind`/calls cast at the boundary (compiler-generated),
    // so user code stays typed and cast-free.
    fn emitClosureTypes(self: *CEmitter) !void {
        var it = self.closure_types.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.kind.closure_type;
            try self.out.appendSlice(self.allocator, "typedef struct { ");
            try self.out.appendSlice(self.allocator, try self.cTypeFor(node.ret.*, .typedef_name));
            try self.out.appendSlice(self.allocator, " (*code)(void *");
            for (node.params) |param| {
                try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, try self.cTypeFor(param, .typedef_name));
            }
            try self.out.print(self.allocator, "); void *env; }} {s};\n\n", .{entry.key_ptr.*});
        }
    }

    // The closure type of a callee expression, if it is closure-typed (so its call
    // dispatches through the {code, env} pair). Resolves through aliases.
    fn closureCalleeType(self: *CEmitter, callee: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const ty = self.operandEmitType(callee, locals) orelse return null;
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .closure_type => resolved,
            else => null,
        };
    }

    // Emit `bind(&env, f)` as a closure compound literal. `f` names a function whose
    // first parameter is the (typed) env; the closure drops it to void*.
    fn emitBind(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) !void {
        const fname = calleeIdentName(node.args[1]) orelse return error.UnsupportedCEmission;
        const info = self.functions.get(fname) orelse return error.UnsupportedCEmission;
        if (info.params.len == 0) return error.UnsupportedCEmission; // need the env param
        // Closure type name = return type + the parameters after the env.
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.scratch.allocator(), "mc_closure_");
        const ret_ty: ast.TypeExpr = info.return_type orelse ast.TypeExpr{ .span = node.callee.*.span, .kind = .{ .name = .{ .text = "void", .span = node.callee.*.span } } };
        try buf.appendSlice(self.scratch.allocator(), try self.typeSuffix(ret_ty));
        for (info.params[1..]) |param| {
            try buf.append(self.scratch.allocator(), '_');
            try buf.appendSlice(self.scratch.allocator(), try self.typeSuffix(param.ty));
        }
        const cname = try buf.toOwnedSlice(self.scratch.allocator());
        // (cname){ .code = (RET (*)(void *, P...)) fname, .env = (void *)(env) }
        try self.out.print(self.allocator, "({s}){{ .code = (", .{cname});
        try self.out.appendSlice(self.allocator, try self.cTypeFor(ret_ty, .typedef_name));
        try self.out.appendSlice(self.allocator, " (*)(void *");
        for (info.params[1..]) |param| {
            try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, try self.cTypeFor(param.ty, .typedef_name));
        }
        try self.out.print(self.allocator, ")){s}, .env = (void *)(", .{fname});
        try self.emitExpr(node.args[0], locals);
        try self.out.appendSlice(self.allocator, ") }");
    }

    fn emitClosureCall(self: *CEmitter, node: anytype, clos: ast.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !void {
        _ = clos;
        // (c).code((c).env, args...)
        try self.out.appendSlice(self.allocator, "(");
        try self.emitExpr(node.callee.*, locals);
        try self.out.appendSlice(self.allocator, ").code((");
        try self.emitExpr(node.callee.*, locals);
        try self.out.appendSlice(self.allocator, ").env");
        for (node.args) |arg| {
            try self.out.appendSlice(self.allocator, ", ");
            try self.emitExpr(arg, locals);
        }
        try self.out.appendSlice(self.allocator, ")");
    }

    fn collectArrayType(self: *CEmitter, ty: ast.TypeExpr) anyerror!void {
        switch (ty.kind) {
            .array => |node| {
                try self.collectArrayType(node.child.*);
                try self.collectTypeArtifacts(node.child.*);
                const name = try self.arrayTypeName(node.child.*, node.len);
                if (!self.array_types.contains(name)) {
                    const len = try self.arrayLenTextForExpr(node.len);
                    try self.array_types.put(name, .{
                        .name = name,
                        .element_ty = node.child.*,
                        .element_c_type = try self.cTypeFor(node.child.*, .typedef_name),
                        .len = len,
                    });
                }
            },
            .pointer => |node| try self.collectArrayType(node.child.*),
            .raw_many_pointer => |node| try self.collectArrayType(node.child.*),
            .slice => |node| try self.collectArrayType(node.child.*),
            .nullable => |child| try self.collectArrayType(child.*),
            .qualified => |node| try self.collectArrayType(node.child.*),
            .generic => |node| for (node.args) |arg| try self.collectArrayType(arg),
            .member => |node| try self.collectArrayType(node.base.*),
            else => {},
        }
    }

    fn collectSliceType(self: *CEmitter, ty: ast.TypeExpr) anyerror!void {
        switch (ty.kind) {
            .slice => |node| {
                try self.collectSliceType(node.child.*);
                const name = try self.sliceTypeName(node.child.*, node.mutability);
                if (!self.slice_types.contains(name)) {
                    const ptr_type = try self.pointerTypeForSliceElement(node.child.*, node.mutability);
                    try self.slice_types.put(name, .{ .name = name, .ptr_type = ptr_type });
                }
            },
            .pointer => |node| try self.collectSliceType(node.child.*),
            .raw_many_pointer => |node| try self.collectSliceType(node.child.*),
            .nullable => |child| try self.collectSliceType(child.*),
            .qualified => |node| try self.collectSliceType(node.child.*),
            .array => |node| try self.collectSliceType(node.child.*),
            .generic => |node| for (node.args) |arg| try self.collectSliceType(arg),
            .member => |node| try self.collectSliceType(node.base.*),
            else => {},
        }
    }

    fn collectResultType(self: *CEmitter, ty: ast.TypeExpr) anyerror!void {
        switch (ty.kind) {
            .pointer => |node| try self.collectResultType(node.child.*),
            .raw_many_pointer => |node| try self.collectResultType(node.child.*),
            .slice => |node| try self.collectResultType(node.child.*),
            .array => |node| try self.collectResultType(node.child.*),
            .nullable => |child| try self.collectResultType(child.*),
            .qualified => |node| try self.collectResultType(node.child.*),
            .member => |node| try self.collectResultType(node.base.*),
            .generic => |node| {
                for (node.args) |arg| try self.collectTypeArtifacts(arg);
                if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
                    const name = try self.resultTypeName(node.args[0], node.args[1]);
                    if (!self.result_types.contains(name)) {
                        try self.result_types.put(name, .{ .name = name, .ok_ty = node.args[0], .err_ty = node.args[1] });
                    }
                }
            },
            else => {},
        }
    }

    fn sliceTypeName(self: *CEmitter, child: ast.TypeExpr, mutability: ast.Mutability) ![]const u8 {
        const prefix = if (mutability == .mut) "mc_slice_mut_" else "mc_slice_const_";
        return std.fmt.allocPrint(self.scratch.allocator(), "{s}{s}", .{ prefix, try self.typeSuffix(child) });
    }

    fn pointerTypeForSliceElement(self: *CEmitter, child: ast.TypeExpr, mutability: ast.Mutability) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendPointerType(&out, child, if (mutability == .mut) .mut else .@"const", .typedef_name);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn arrayTypeName(self: *CEmitter, child: ast.TypeExpr, len_expr: ast.Expr) ![]const u8 {
        const len = try self.arrayLenTextForExpr(len_expr);
        return std.fmt.allocPrint(self.scratch.allocator(), "mc_array_{s}_{s}", .{ try self.typeSuffix(child), len });
    }

    fn typeSuffix(self: *CEmitter, ty: ast.TypeExpr) ![]const u8 {
        const resolved_ty = self.resolveAliasType(ty);
        if (typeName(resolved_ty)) |name| {
            if (self.structs.contains(name)) return std.fmt.allocPrint(self.scratch.allocator(), "struct_{s}", .{name});
            return name;
        }
        return switch (resolved_ty.kind) {
            .pointer => |node| std.fmt.allocPrint(self.scratch.allocator(), "ptr_{s}", .{try self.typeSuffix(node.child.*)}),
            .raw_many_pointer => |node| std.fmt.allocPrint(self.scratch.allocator(), "manyptr_{s}", .{try self.typeSuffix(node.child.*)}),
            .slice => |node| std.fmt.allocPrint(self.scratch.allocator(), "slice_{s}", .{try self.typeSuffix(node.child.*)}),
            .array => |node| std.fmt.allocPrint(self.scratch.allocator(), "array_{s}_{s}", .{ try self.typeSuffix(node.child.*), try self.arrayLenTextForExpr(node.len) }),
            .nullable => |child| std.fmt.allocPrint(self.scratch.allocator(), "nullable_{s}", .{try self.typeSuffix(child.*)}),
            .qualified => |node| self.typeSuffix(node.child.*),
            .generic => |node| {
                if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) {
                    return std.fmt.allocPrint(self.scratch.allocator(), "result_{s}_{s}", .{ try self.typeSuffix(node.args[0]), try self.typeSuffix(node.args[1]) });
                }
                return node.base.text;
            },
            .fn_pointer => |node| blk: {
                var buf: std.ArrayList(u8) = .empty;
                try buf.appendSlice(self.scratch.allocator(), "fnptr_");
                try buf.appendSlice(self.scratch.allocator(), try self.typeSuffix(node.ret.*));
                for (node.params) |param| {
                    try buf.append(self.scratch.allocator(), '_');
                    try buf.appendSlice(self.scratch.allocator(), try self.typeSuffix(param));
                }
                break :blk try buf.toOwnedSlice(self.scratch.allocator());
            },
            else => "unknown",
        };
    }

    fn resultTypeName(self: *CEmitter, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) ![]const u8 {
        return std.fmt.allocPrint(self.scratch.allocator(), "mc_result_{s}_{s}", .{ try self.typeSuffix(ok_ty), try self.typeSuffix(err_ty) });
    }

    fn emitArrayLen(self: *CEmitter, expr: ast.Expr) !void {
        try self.out.appendSlice(self.allocator, try self.arrayLenTextForExpr(expr));
    }

    fn emitStmt(self: *CEmitter, stmt: ast.Stmt, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                const is_let = std.meta.activeTag(stmt.kind) == .let_decl;
                for (local.names) |name| {
                    var info = if (local.ty) |decl_ty| try self.localInfoFromType(decl_ty) else LocalInfo{};
                    // Value-range propagation: record the constant value of an
                    // immutable single `let` integer local for later proofs.
                    if (is_let and local.names.len == 1) {
                        if (local.ty) |decl_ty| {
                            if (local.init) |initializer| {
                                info.const_int = self.constLocalValue(decl_ty, initializer, locals);
                            }
                        }
                    }
                    try locals.put(name.text, info);
                    if (local.names.len == 1) {
                        if (local.ty) |decl_ty| {
                            if (local.init) |initializer| {
                                if (try self.emitResultTryExprLocalInit(name.text, decl_ty, initializer, locals, return_ty)) continue;
                                if (try self.emitNullableTryExprLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitResultTryLocalInit(name.text, decl_ty, initializer, locals, return_ty)) continue;
                                if (try self.emitMmioReadLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitMmioReadExprLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitDirectCallSliceIndexLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitDirectCallArrayIndexLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitRawManyOffsetDerefAddressLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitLocalIndexAddressLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitLocalIndexLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitRawManyOffsetDerefLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitRawManyOffsetLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitBitcastLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitExternNonNullCallLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitUncheckedAddLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitUncheckedAddAggregateLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitSequencedComparisonLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitSequencedCheckedBinaryLocalInit(name.text, decl_ty, initializer, locals)) continue;
                                if (try self.emitSequencedCallLocalInit(name.text, decl_ty, initializer, locals)) continue;
                            }
                        } else if (local.init) |initializer| {
                            if (try self.emitArrayCallInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitSliceCallInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitEnumCallInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitTaggedUnionCallInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitResultCallInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitNullableCallInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitRawManyOffsetDerefInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitRawManyOffsetInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitBitcastInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitExternNonNullCallInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitUncheckedAddInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitLocalCopyInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitBoolInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitCallInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitNumericInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitMmioReadInferredLocalInit(name.text, initializer, locals)) continue;
                            if (try self.emitMmioReadExprInferredLocalInit(name.text, initializer, locals)) continue;
                        }
                    }
                    try self.writeIndent();
                    if (local.ty) |decl_ty| {
                        try self.emitDeclarator(decl_ty, name.text);
                    } else {
                        try self.out.print(self.allocator, "uint32_t {s}", .{name.text});
                    }
                    if (local.init) |initializer| {
                        if (!isUninitLiteral(initializer)) {
                            try self.out.appendSlice(self.allocator, " = ");
                            if (local.ty) |decl_ty| {
                                try self.emitExprWithTarget(initializer, locals, decl_ty);
                            } else {
                                try self.emitExpr(initializer, locals);
                            }
                        }
                    } else if (local.ty != null and local.ty.?.kind == .array) {
                        try self.out.appendSlice(self.allocator, " = {0}");
                    } else {
                        try self.out.appendSlice(self.allocator, " = 0");
                    }
                    try self.out.appendSlice(self.allocator, ";\n");
                }
            },
            .assignment => |node| {
                if (try self.emitPackedBitsFieldWriteStmt(node, locals)) return;
                if (try self.emitOverlayFieldWriteStmt(node, locals)) return;
                if (try self.emitGlobalArrayIndexAssignmentStmt(node, locals)) return;
                if (try self.emitResultTryAssignmentStmt(node, locals, return_ty)) return;
                if (try self.emitNullableTryAssignmentStmt(node, locals)) return;
                if (try self.emitMmioReadAssignmentStmt(node, locals)) return;
                if (try self.emitMmioReadExprAssignmentStmt(node, locals)) return;
                if (try self.emitDirectCallSliceIndexAssignmentStmt(node, locals)) return;
                if (try self.emitDirectCallArrayIndexAssignmentStmt(node, locals)) return;
                if (try self.emitLocalIndexTargetAssignmentStmt(node, locals)) return;
                if (try self.emitRawManyOffsetDerefAddressAssignmentStmt(node, locals)) return;
                if (try self.emitLocalIndexAddressAssignmentStmt(node, locals)) return;
                if (try self.emitLocalIndexAssignmentStmt(node, locals)) return;
                if (try self.emitRawManyOffsetDerefTargetAssignmentStmt(node, locals)) return;
                if (try self.emitRawManyOffsetDerefAssignmentStmt(node, locals)) return;
                if (try self.emitRawManyOffsetAssignmentStmt(node, locals)) return;
                if (try self.emitBitcastAssignmentStmt(node, locals)) return;
                if (try self.emitExternNonNullCallAssignmentStmt(node, locals)) return;
                if (try self.emitUncheckedAddAggregateAssignmentStmt(node, locals)) return;
                if (try self.emitUncheckedAddAssignmentStmt(node, locals)) return;
                if (try self.emitSequencedComparisonAssignmentStmt(node, locals)) return;
                if (try self.emitSequencedCheckedBinaryAssignmentStmt(node, locals)) return;
                if (try self.emitSequencedCallAssignmentStmt(node, locals)) return;
                try self.writeIndent();
                if (self.globalAssignmentTarget(node.target, locals)) |target| {
                    try self.emitGlobalStorePrefix(target);
                    // Pass the global's type as the value target, so a struct-literal value
                    // (`g = .{ … }`) lowers to a typed compound literal like the non-global
                    // path; scalars/pointers are unaffected by the extra type hint.
                    try self.emitExprWithTarget(node.value, locals, simpleNameType(target.info.type_name, node.value.span));
                    try self.emitGlobalStoreSuffix(target);
                } else {
                    try self.emitExpr(node.target, locals);
                    try self.out.appendSlice(self.allocator, " = ");
                    try self.emitExprWithTarget(node.value, locals, self.assignmentTargetType(node.target, locals));
                    try self.out.appendSlice(self.allocator, ";\n");
                }
            },
            .@"return" => |maybe| {
                if (maybe) |expr| {
                    if (try self.emitNeverExprStmt(expr, locals)) return;
                    if (return_ty) |target_ty| {
                        if (isVoidType(target_ty) and isVoidLiteralExpr(expr)) {
                            try self.writeIndent();
                            try self.out.appendSlice(self.allocator, "return;\n");
                            return;
                        }
                    }
                    if (try self.emitDirectCallSliceIndexReturn(expr, locals)) return;
                    if (try self.emitDirectCallArrayIndexReturn(expr, locals)) return;
                    if (try self.emitRawManyOffsetDerefAddressReturn(expr, locals, return_ty)) return;
                    if (try self.emitLocalIndexAddressReturn(expr, locals, return_ty)) return;
                    if (try self.emitLocalIndexReturn(expr, locals, return_ty)) return;
                    if (try self.emitMmioReadReturn(expr, locals)) return;
                    if (try self.emitOverlayFieldReadReturn(expr, locals, return_ty)) return;
                    if (try self.emitResultTryCallReturn(expr, locals)) return;
                    if (try self.emitResultTryConstructorReturn(expr, locals, return_ty)) return;
                    if (try self.emitNullableTryCallReturn(expr, locals)) return;
                    if (try self.emitResultTryReturn(expr, locals, return_ty)) return;
                    if (try self.emitNullableTryReturn(expr, locals)) return;
                    if (try self.emitResultTryExprReturn(expr, locals, return_ty)) return;
                    if (try self.emitNullableTryExprReturn(expr, locals, return_ty)) return;
                    if (try self.emitMmioReadCallReturn(expr, locals)) return;
                    if (try self.emitMmioReadExprReturn(expr, locals, return_ty)) return;
                    if (try self.emitRawManyOffsetDerefReturn(expr, locals, return_ty)) return;
                    if (try self.emitRawManyOffsetReturn(expr, locals, return_ty)) return;
                    if (try self.emitBitcastReturn(expr, locals, return_ty)) return;
                    if (try self.emitExternNonNullCallReturn(expr, locals)) return;
                    if (try self.emitUncheckedAddReturn(expr, locals, return_ty)) return;
                    if (try self.emitUncheckedAddAggregateReturn(expr, locals, return_ty)) return;
                    if (try self.emitSequencedComparisonReturn(expr, locals, return_ty)) return;
                    if (try self.emitSequencedCheckedBinaryReturn(expr, locals, return_ty)) return;
                    if (try self.emitSequencedCallReturn(expr, locals)) return;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "return ");
                    if (return_ty) |target_ty| {
                        try self.emitExprWithTarget(expr, locals, target_ty);
                    } else {
                        try self.emitExpr(expr, locals);
                    }
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "return;\n");
                }
            },
            .@"break" => {
                try self.writeIndent();
                if (self.loop_ids.items.len > 0) {
                    try self.out.print(self.allocator, "goto mc_break_{d};\n", .{self.loop_ids.items[self.loop_ids.items.len - 1]});
                } else {
                    try self.out.appendSlice(self.allocator, "break;\n");
                }
            },
            .@"continue" => {
                try self.writeIndent();
                if (self.loop_ids.items.len > 0) {
                    try self.out.print(self.allocator, "goto mc_continue_{d};\n", .{self.loop_ids.items[self.loop_ids.items.len - 1]});
                } else {
                    try self.out.appendSlice(self.allocator, "continue;\n");
                }
            },
            .expr => |expr| {
                if (try self.emitNeverExprStmt(expr, locals)) return;
                if (try self.emitMmioWriteStmt(expr, locals)) return;
                if (try self.emitRawStoreStmt(expr, locals)) return;
                if (try self.emitCpuPauseStmt(expr)) return;
                if (try self.emitFenceStmt(expr)) return;
                if (try self.emitResultTryExprStmt(expr, locals, return_ty)) return;
                if (try self.emitNullableTryExprStmt(expr, locals)) return;
                if (try self.emitMmioReadExprStmt(expr, locals)) return;
                if (try self.emitSequencedCallExprStmt(expr, locals)) return;
                try self.writeIndent();
                try self.emitExpr(expr, locals);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .assert => |expr| {
                if (try self.emitMmioReadAssert(expr, locals)) return;
                if (try self.emitSequencedConditionAssert(expr, locals)) return;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "if (!(");
                try self.emitExpr(expr, locals);
                try self.out.appendSlice(self.allocator, ")) mc_trap_Assert();\n");
            },
            .block, .unsafe_block => |block| {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "{\n");
                var nested = try cloneLocals(self.allocator, locals.*);
                defer nested.deinit();
                self.indent += 1;
                try self.emitBlockItems(block, &nested, return_ty);
                self.indent -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "}\n");
            },
            .contract_block => |contract| {
                try self.writeIndent();
                try self.out.print(self.allocator, "/* MC_CONTRACT_BEGIN {s} */\n", .{contractName(contract.attr)});
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "{\n");
                var nested = try cloneLocals(self.allocator, locals.*);
                defer nested.deinit();
                self.indent += 1;
                try self.emitBlockItems(contract.block, &nested, return_ty);
                self.indent -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "}\n");
                try self.writeIndent();
                try self.out.print(self.allocator, "/* MC_CONTRACT_END {s} */\n", .{contractName(contract.attr)});
            },
            .comptime_block => {},
            .asm_stmt => |asm_stmt| try self.emitAsmStmt(asm_stmt, locals),
            .loop => |loop| {
                if (loop.kind == .@"while") {
                    if (try self.emitMmioReadWhileLoop(loop, locals, return_ty)) return;
                    if (try self.emitSequencedConditionWhileLoop(loop, locals, return_ty)) return;
                    const id = self.next_loop_id;
                    self.next_loop_id += 1;
                    const jumps = loopBodyHasOwnBreakContinue(loop.body);
                    try self.loop_ids.append(self.allocator, id);
                    defer _ = self.loop_ids.pop();
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "while (");
                    if (loop.iterable) |condition| {
                        try self.emitExpr(condition, locals);
                    } else {
                        try self.out.appendSlice(self.allocator, "true");
                    }
                    try self.out.appendSlice(self.allocator, ") {\n");
                    var nested = try cloneLocals(self.allocator, locals.*);
                    defer nested.deinit();
                    self.indent += 1;
                    try self.emitBlockItems(loop.body, &nested, return_ty);
                    // `continue` lands here, then falls through to re-test the
                    // loop condition.
                    if (jumps.cont) try self.out.print(self.allocator, "    mc_continue_{d}:;\n", .{id});
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "}\n");
                    if (jumps.brk) try self.out.print(self.allocator, "    mc_break_{d}:;\n", .{id});
                } else if (loop.kind == .@"for") {
                    try self.emitForLoop(loop, locals, return_ty);
                } else {
                    try self.writeUnsupportedStmt(stmt);
                }
            },
            .@"switch" => |node| try self.emitSwitch(node, locals, return_ty),
            .if_let => |node| try self.emitIfLet(node, locals, return_ty),
            else => try self.writeUnsupportedStmt(stmt),
        }
    }

    fn emitAsmStmt(self: *CEmitter, asm_stmt: ast.AsmStmt, locals: ?*std.StringHashMap(LocalInfo)) !void {
        if (asm_stmt.form == .precise) return self.emitPreciseAsmStmt(asm_stmt, locals);
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#if defined(__GNUC__) || defined(__clang__)\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, if (asm_stmt.is_volatile) "__asm__ __volatile__(" else "__asm__(");
        try self.emitAsmTemplate(asm_stmt.templates);
        try self.out.appendSlice(self.allocator, " ::: ");
        if (asm_stmt.clobbers.len == 0) {
            try self.out.appendSlice(self.allocator, "\"memory\"");
        } else {
            for (asm_stmt.clobbers, 0..) |clobber, index| {
                if (index > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, clobber);
            }
        }
        try self.out.appendSlice(self.allocator, ");\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#else\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#error \"inline asm emission requires compiler support\"\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#endif\n");
    }

    fn emitAsmTemplate(self: *CEmitter, templates: []const []const u8) !void {
        if (templates.len == 0) {
            try self.out.appendSlice(self.allocator, "\"\"");
            return;
        }
        for (templates, 0..) |template, index| {
            if (index > 0) try self.out.appendSlice(self.allocator, " \"\\n\\t\" ");
            try self.out.appendSlice(self.allocator, template);
        }
    }

    /// Precise asm (§23.2): the compiler trusts the declared inputs, outputs, and
    /// clobbers. Lowers to GCC/Clang extended asm with the operands wired in
    /// declared order — outputs numbered first (`%0..`), then inputs — so the MC
    /// template's `%N` references line up. Outputs bind their named local lvalue
    /// directly (`"=r"(local)`); inputs feed their value expression (`"r"(expr)`).
    /// Generic `"r"` constraints (no C-level physical-register names) keep the
    /// emission target-portable; the requested registers are preserved as a
    /// provenance comment, since the operand registers are an unsafe-contract
    /// fact the compiler trusts rather than verifies.
    fn emitPreciseAsmStmt(self: *CEmitter, asm_stmt: ast.AsmStmt, locals: ?*std.StringHashMap(LocalInfo)) !void {
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#if defined(__GNUC__) || defined(__clang__)\n");

        if (asm_stmt.outputs.len > 0 or asm_stmt.inputs.len > 0) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "/* MC_PRECISE_ASM");
            for (asm_stmt.outputs) |output| {
                try self.out.print(self.allocator, " out({s})->{s}", .{ output.reg, output.name.text });
            }
            for (asm_stmt.inputs) |input| {
                try self.out.print(self.allocator, " in({s})", .{input.reg});
            }
            try self.out.appendSlice(self.allocator, " */\n");
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, if (asm_stmt.is_volatile) "__asm__ __volatile__(" else "__asm__(");
        try self.emitAsmTemplate(asm_stmt.templates);
        try self.out.appendSlice(self.allocator, " : ");
        for (asm_stmt.outputs, 0..) |output, index| {
            if (index > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "\"=r\"({s})", .{try self.cIdent(output.name.text)});
        }
        try self.out.appendSlice(self.allocator, " : ");
        for (asm_stmt.inputs, 0..) |input, index| {
            if (index > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, "\"r\"(");
            try self.emitExprWithTarget(input.value, locals, input.ty);
            try self.out.appendSlice(self.allocator, ")");
        }
        if (asm_stmt.clobbers.len > 0) {
            try self.out.appendSlice(self.allocator, " : ");
            for (asm_stmt.clobbers, 0..) |clobber, index| {
                if (index > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, clobber);
            }
        }
        try self.out.appendSlice(self.allocator, ");\n");

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#else\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#error \"inline asm emission requires compiler support\"\n");
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "#endif\n");
    }

    fn emitMmioReadAssert(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectMmioReadHoistsForExpr(expr, locals, &replacements)) return false;

        for (replacements.items) |replacement| {
            try self.emitMmioReadReplacement(replacement);
        }

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        for (replacements.items) |replacement| {
            try nested.put(replacement.temp_name, .{
                .c_type = replacement.c_type,
                .source_type_name = replacement.source_type_name,
            });
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "if (!(");
        try self.emitMmioReadExprWithReplacements(expr, &nested, null, replacements.items);
        try self.out.appendSlice(self.allocator, ")) mc_trap_Assert();\n");
        return true;
    }

    fn emitMmioReadExprStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (try self.emitMmioReadCallExprStmt(expr, locals)) return true;

        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectMmioReadHoistsForExpr(expr, locals, &replacements)) return false;

        for (replacements.items) |replacement| {
            try self.emitMmioReadReplacement(replacement);
        }

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        try addMmioReadReplacementLocals(&nested, replacements.items);

        try self.writeIndent();
        if (mmioReadReplacementForSpan(expr.span, replacements.items)) |replacement| {
            try self.out.print(self.allocator, "(void){s};\n", .{replacement.temp_name});
        } else {
            try self.emitMmioReadExprWithReplacements(expr, &nested, null, replacements.items);
            try self.out.appendSlice(self.allocator, ";\n");
        }
        return true;
    }

    fn emitMmioReadExprReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        if (return_ty) |target_ty| {
            if (try self.emitMmioReadSequencedBinaryReturn(expr, locals, target_ty)) return true;
        }

        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectMmioReadHoistsForExpr(expr, locals, &replacements)) return false;

        for (replacements.items) |replacement| {
            try self.emitMmioReadReplacement(replacement);
        }

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        try addMmioReadReplacementLocals(&nested, replacements.items);

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitMmioReadExprWithReplacements(expr, &nested, return_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitMmioReadCallReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitMmioReadCallReturn(inner.*, locals),
            else => return false,
        };
        if (call.args.len == 0) return false;

        var found_mmio = false;
        for (call.args) |arg| {
            if (self.exprContainsMmioRead(arg, locals)) {
                found_mmio = true;
                break;
            }
        }
        if (!found_mmio) return false;

        const fn_info = if (calleeIdentName(call.callee.*)) |name| self.functions.get(name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps: std.ArrayList(SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        for (call.args, 0..) |arg, i| {
            try temps.append(self.scratch.allocator(), try self.emitMmioReadCallArgTemp(arg, locals, fn_info.params[i].ty));
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitMmioReadCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        if (!self.exprContainsMmioRead(arg, locals)) {
            return try self.emitSequencedCallArgTemp(arg, locals, target_ty);
        }

        return try self.emitMmioReadOperandTemp(arg, locals, target_ty);
    }

    fn emitMmioReadCallArgTemps(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo) anyerror!std.ArrayList(SequencedArgTemp) {
        var temps: std.ArrayList(SequencedArgTemp) = .empty;
        errdefer temps.deinit(self.scratch.allocator());
        for (call.args, 0..) |arg, i| {
            try temps.append(self.scratch.allocator(), try self.emitMmioReadCallArgTemp(arg, locals, fn_info.params[i].ty));
        }
        return temps;
    }

    fn emitMmioReadCallLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (initializer.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitMmioReadCallLocalInit(name, decl_ty, inner.*, locals),
            else => return false,
        };
        if (!self.callArgsContainMmioRead(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitMmioReadCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitMmioReadCallAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (assignment.value.kind) {
            .call => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .call => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!self.callArgsContainMmioRead(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        const call_return_ty = fn_info.return_type orelse return false;
        if (isVoidType(call_return_ty) or fn_info.params.len < call.args.len) return false;

        var temps = try self.emitMmioReadCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(call_return_ty, .typedef_name), result_temp });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, result_temp);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{result_temp});
        }
        return true;
    }

    fn emitMmioReadCallExprStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitMmioReadCallExprStmt(inner.*, locals),
            else => return false,
        };
        if (!self.callArgsContainMmioRead(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitMmioReadCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitMmioReadWhileLoop(self: *CEmitter, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const condition = loop.iterable orelse return false;

        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectMmioReadHoistsForExpr(condition, locals, &replacements)) return false;

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "while (true) {\n");

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();

        self.indent += 1;
        for (replacements.items) |replacement| {
            try self.emitMmioReadReplacement(replacement);
            try nested.put(replacement.temp_name, .{
                .c_type = replacement.c_type,
                .source_type_name = replacement.source_type_name,
            });
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "if (!(");
        try self.emitMmioReadExprWithReplacements(condition, &nested, null, replacements.items);
        try self.out.appendSlice(self.allocator, ")) break;\n");

        try self.emitBlockItems(loop.body, &nested, return_ty);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
        return true;
    }

    fn emitSequencedConditionAssert(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const condition = (try self.emitSequencedConditionValueTemp(expr, locals)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "if (!{s}) mc_trap_Assert();\n", .{condition.name});
        return true;
    }

    fn emitSequencedConditionWhileLoop(self: *CEmitter, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const condition = loop.iterable orelse return false;
        if (!sequencedConditionCandidate(condition)) return false;

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "while (true) {\n");

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();

        self.indent += 1;
        const condition_temp = (try self.emitSequencedConditionValueTemp(condition, &nested)) orelse {
            self.indent -= 1;
            return false;
        };
        try self.writeIndent();
        try self.out.print(self.allocator, "if (!{s}) break;\n", .{condition_temp.name});

        try self.emitBlockItems(loop.body, &nested, return_ty);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
        return true;
    }

    fn emitSequencedConditionValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
        const node = switch (expr.kind) {
            .grouped => |inner| return try self.emitSequencedConditionValueTemp(inner.*, locals),
            .binary => |node| node,
            else => return null,
        };
        if (!isComparisonOp(node.op)) return null;
        if (!exprContainsCall(node.left.*) and !exprContainsCall(node.right.*)) return null;

        var left_ty = conditionOperandTypeForEmission(self, node.left.*, locals);
        var right_ty = conditionOperandTypeForEmission(self, node.right.*, locals);
        // A bare numeric literal adopts the other operand's storage type, so
        // `call() != 0` compares at the call's width rather than the literal's
        // default `u32` (e.g. `(pte & PTE_V) != 0` over a `u64`).
        if (exprIsNumericLiteral(node.left.*) and right_ty != null) left_ty = right_ty;
        if (exprIsNumericLiteral(node.right.*) and left_ty != null) right_ty = left_ty;
        const lt = left_ty orelse return error.UnsupportedCEmission;
        const rt = right_ty orelse return error.UnsupportedCEmission;
        if (!sameCStorageType(lt, rt)) return error.UnsupportedCEmission;

        const left_temp = try self.emitSequencedCallArgTemp(node.left.*, locals, lt);
        const right_temp = try self.emitSequencedCallArgTemp(node.right.*, locals, rt);
        const bool_ty = simpleNameType("bool", expr.span);
        const condition_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "bool {s} = ({s} {s} {s});\n", .{ condition_temp, left_temp.name, binaryCOp(node.op), right_temp.name });
        return .{ .name = condition_temp, .ty = bool_ty };
    }

    fn emitMmioReadReplacement(self: *CEmitter, replacement: MmioReadReplacement) !void {
        const access = replacement.access;
        try self.writeIndent();
        try self.out.print(
            self.allocator,
            "{s} {s} = ({s})mc_mmio_read_{s}(&{s}->{s});\n",
            .{ replacement.c_type, replacement.temp_name, replacement.c_type, access.width, access.param, access.field },
        );
        if (std.mem.eql(u8, access.ordering, "acquire")) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_barrier_acquire_after();\n");
        }
    }

    fn emitBlockItems(self: *CEmitter, block: ast.Block, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        var deferred: std.ArrayList(ast.Expr) = .empty;
        defer deferred.deinit(self.scratch.allocator());

        for (block.items) |stmt| {
            switch (stmt.kind) {
                .@"defer" => |expr| {
                    try deferred.append(self.scratch.allocator(), expr);
                    continue;
                },
                .@"return", .@"break", .@"continue" => {
                    try self.emitDeferredCleanups(deferred.items, locals, return_ty);
                    try self.emitStmt(stmt, locals, return_ty);
                    return;
                },
                else => {},
            }
            try self.emitStmt(stmt, locals, return_ty);
        }
        try self.emitDeferredCleanups(deferred.items, locals, return_ty);
    }

    fn emitDeferredCleanups(self: *CEmitter, deferred: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        var index = deferred.len;
        while (index > 0) {
            index -= 1;
            try self.emitDeferredCleanup(deferred[index], locals, return_ty);
        }
    }

    fn emitDeferredCleanup(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        switch (expr.kind) {
            .block => |block| {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "{\n");
                var nested = try cloneLocals(self.allocator, locals.*);
                defer nested.deinit();
                self.indent += 1;
                try self.emitBlockItems(block, &nested, return_ty);
                self.indent -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "}\n");
            },
            else => {
                if (try self.emitNeverExprStmt(expr, locals)) return;
                if (try self.emitMmioWriteStmt(expr, locals)) return;
                if (try self.emitRawStoreStmt(expr, locals)) return;
                if (try self.emitCpuPauseStmt(expr)) return;
                if (try self.emitFenceStmt(expr)) return;
                if (try self.emitResultTryExprStmt(expr, locals, return_ty)) return;
                if (try self.emitNullableTryExprStmt(expr, locals)) return;
                if (try self.emitMmioReadExprStmt(expr, locals)) return;
                if (try self.emitSequencedCallExprStmt(expr, locals)) return;
                try self.writeIndent();
                try self.emitExpr(expr, locals);
                try self.out.appendSlice(self.allocator, ";\n");
            },
        }
    }

    fn writeIndent(self: *CEmitter) !void {
        for (0..self.indent) |_| try self.out.appendSlice(self.allocator, "    ");
    }

    fn writeUnsupportedStmt(self: *CEmitter, stmt: ast.Stmt) !void {
        try self.writeIndent();
        try self.out.print(
            self.allocator,
            "/* unsupported statement for C emission: {s} */\n",
            .{@tagName(stmt.kind)},
        );
        return error.UnsupportedCEmission;
    }

    fn emitSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        if (try self.emitResultSwitch(node, locals, return_ty)) return;
        if (try self.emitTaggedUnionSwitch(node, locals, return_ty)) return;
        if (try self.emitNullableSwitch(node, locals, return_ty)) return;
        if (try self.emitEnumCallSwitch(node, locals, return_ty)) return;

        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (try self.collectMmioReadHoistsForExpr(node.subject, locals, &replacements)) {
            for (replacements.items) |replacement| {
                try self.emitMmioReadReplacement(replacement);
            }

            var switch_locals = try cloneLocals(self.allocator, locals.*);
            defer switch_locals.deinit();
            try addMmioReadReplacementLocals(&switch_locals, replacements.items);
            return try self.emitGenericSwitch(node, &switch_locals, return_ty, replacements.items);
        }

        try self.emitGenericSwitch(node, locals, return_ty, &[_]MmioReadReplacement{});
    }

    fn emitEnumCallSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        const enum_ty = self.enumReturnTypeForExpr(node.subject) orelse return false;
        const temp = try self.emitSequencedCallArgTemp(node.subject, locals, enum_ty);

        var switch_locals = try cloneLocals(self.allocator, locals.*);
        defer switch_locals.deinit();
        try switch_locals.put(temp.name, try self.localInfoFromType(enum_ty));
        const temp_subject = ast.Expr{ .kind = .{ .ident = .{ .text = temp.name, .span = node.subject.span } }, .span = node.subject.span };
        try self.emitGenericSwitch(.{ .subject = temp_subject, .arms = node.arms }, &switch_locals, return_ty, &[_]MmioReadReplacement{});
        return true;
    }

    fn emitGenericSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, subject_replacements: []const MmioReadReplacement) anyerror!void {
        const subject_enum_name = self.enumNameForExpr(node.subject, locals);
        const subject_is_bool = self.exprIsBoolForEmission(node.subject, locals);
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "switch (");
        if (subject_is_bool) try self.out.appendSlice(self.allocator, "(int)(");
        if (subject_replacements.len > 0) {
            try self.emitMmioReadExprWithReplacements(node.subject, locals, null, subject_replacements);
        } else {
            try self.emitExpr(node.subject, locals);
        }
        if (subject_is_bool) try self.out.appendSlice(self.allocator, ")");
        try self.out.appendSlice(self.allocator, ") {\n");

        self.indent += 1;
        var has_wildcard = false;
        for (node.arms) |arm| {
            for (arm.patterns) |pattern| {
                if (pattern.kind == .wildcard) has_wildcard = true;
                try self.emitSwitchPatternLabel(pattern, subject_enum_name);
            }
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "{\n");
            var nested = try cloneLocals(self.allocator, locals.*);
            defer nested.deinit();
            self.indent += 1;
            try self.emitSwitchBody(arm.body, &nested, return_ty);
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "break;\n");
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        }
        if ((subject_enum_name != null or subject_is_bool) and !has_wildcard) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "default:\n");
            self.indent += 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_trap_InvalidRepresentation();\n");
            self.indent -= 1;
        }
        self.indent -= 1;

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitResultSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        const subject = if (self.resultSubjectForExpr(node.subject, locals)) |subject|
            subject
        else blk: {
            const result_ty = self.resultTypeForExpr(node.subject, locals) orelse return false;
            const temp = try self.emitSequencedCallArgTemp(node.subject, locals, result_ty);
            try locals.put(temp.name, try self.localInfoFromType(result_ty));
            break :blk self.resultSubjectForExpr(.{ .kind = .{ .ident = .{ .text = temp.name, .span = node.subject.span } }, .span = node.subject.span }, locals).?;
        };
        var emitted_any = false;
        var seen_ok = false;
        var seen_err = false;
        for (node.arms) |arm| {
            const branch = (try self.resultSwitchBranch(arm.patterns, subject)) orelse {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "/* unsupported result switch pattern */\n");
                return error.UnsupportedCEmission;
            };

            try self.writeIndent();
            if (!emitted_any) {
                if (branch.condition) |condition| {
                    try self.out.print(self.allocator, "if ({s}) {{\n", .{condition});
                } else {
                    try self.out.appendSlice(self.allocator, "{\n");
                }
            } else if (branch.condition) |condition| {
                const complement = if (branch.tag) |tag|
                    (std.mem.eql(u8, tag, "ok") and seen_err) or (std.mem.eql(u8, tag, "err") and seen_ok)
                else
                    false;
                if (complement) {
                    try self.out.appendSlice(self.allocator, "else {\n");
                } else {
                    try self.out.print(self.allocator, "else if ({s}) {{\n", .{condition});
                }
            } else {
                try self.out.appendSlice(self.allocator, "else {\n");
            }
            emitted_any = true;
            if (branch.tag) |tag| {
                if (std.mem.eql(u8, tag, "ok")) seen_ok = true;
                if (std.mem.eql(u8, tag, "err")) seen_err = true;
            }

            var nested = try cloneLocals(self.allocator, locals.*);
            defer nested.deinit();
            self.indent += 1;
            if (branch.binding_name) |binding_name| {
                try nested.put(binding_name, .{ .c_type = branch.binding_type.? });
                try self.writeIndent();
                try self.out.print(self.allocator, "MC_UNUSED {s} {s} = {s}.payload.{s};\n", .{ branch.binding_type.?, binding_name, subject.name, branch.payload_field.? });
            }
            try self.emitSwitchBody(arm.body, &nested, return_ty);
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        }
        return emitted_any;
    }

    fn emitNullableSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        const subject = if (try self.nullableSwitchSubjectForExpr(node.subject, locals)) |subject|
            subject
        else
            return false;

        var emitted_any = false;
        for (node.arms) |arm| {
            if (arm.patterns.len != 1) return false;
            const pattern = arm.patterns[0];
            const branch = switch (pattern.kind) {
                .bind => |binding| NullableSwitchBranch{
                    .condition = try std.fmt.allocPrint(self.scratch.allocator(), "{s} != NULL", .{subject.name}),
                    .binding_name = binding.text,
                },
                .wildcard => NullableSwitchBranch{ .condition = null },
                else => return false,
            };

            try self.writeIndent();
            if (!emitted_any) {
                if (branch.condition) |condition| {
                    try self.out.print(self.allocator, "if ({s}) {{\n", .{condition});
                } else {
                    try self.out.appendSlice(self.allocator, "{\n");
                }
            } else if (branch.condition) |condition| {
                try self.out.print(self.allocator, "else if ({s}) {{\n", .{condition});
            } else {
                try self.out.appendSlice(self.allocator, "else {\n");
            }
            emitted_any = true;

            var nested = try cloneLocals(self.allocator, locals.*);
            defer nested.deinit();
            self.indent += 1;
            if (branch.binding_name) |binding_name| {
                try nested.put(binding_name, .{ .c_type = subject.inner_c_type });
                try self.writeIndent();
                try self.out.print(self.allocator, "MC_UNUSED {s} {s} = {s};\n", .{ subject.inner_c_type, binding_name, subject.name });
            }
            try self.emitSwitchBody(arm.body, &nested, return_ty);
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        }
        return emitted_any;
    }

    fn emitTaggedUnionSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!bool {
        const subject = if (self.taggedUnionSubjectForExpr(node.subject, locals)) |subject|
            subject
        else blk: {
            const union_ty = self.taggedUnionReturnTypeForExpr(node.subject) orelse return false;
            const temp = try self.emitSequencedCallArgTemp(node.subject, locals, union_ty);
            try locals.put(temp.name, try self.localInfoFromType(union_ty));
            break :blk self.taggedUnionSubjectForExpr(.{ .kind = .{ .ident = .{ .text = temp.name, .span = node.subject.span } }, .span = node.subject.span }, locals).?;
        };
        var emitted_any = false;
        var has_wildcard = false;
        for (node.arms) |arm| {
            const branch = (try self.taggedUnionSwitchBranch(arm.patterns, subject)) orelse {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "/* unsupported tagged union switch pattern */\n");
                return error.UnsupportedCEmission;
            };
            if (branch.is_wildcard) has_wildcard = true;

            try self.writeIndent();
            if (!emitted_any) {
                if (branch.condition) |condition| {
                    try self.out.print(self.allocator, "if ({s}) {{\n", .{condition});
                } else {
                    try self.out.appendSlice(self.allocator, "{\n");
                }
            } else if (branch.condition) |condition| {
                try self.out.print(self.allocator, "else if ({s}) {{\n", .{condition});
            } else {
                try self.out.appendSlice(self.allocator, "else {\n");
            }
            emitted_any = true;

            var nested = try cloneLocals(self.allocator, locals.*);
            defer nested.deinit();
            self.indent += 1;
            if (branch.binding_name) |binding_name| {
                try nested.put(binding_name, .{ .c_type = branch.binding_type.? });
                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = {s}.payload.{s};\n", .{
                    branch.binding_type.?,
                    binding_name,
                    subject.name,
                    try self.cPayloadFieldName(branch.payload_field.?),
                });
            }
            try self.emitSwitchBody(arm.body, &nested, return_ty);
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        }
        if (!has_wildcard) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "else {\n");
            self.indent += 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_trap_InvalidRepresentation();\n");
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        }
        return emitted_any;
    }

    fn emitSwitchBody(self: *CEmitter, body: ast.SwitchBody, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        switch (body) {
            .block => |block| try self.emitBlockItems(block, locals, return_ty),
            .expr => |expr| {
                if (try self.emitNeverExprStmt(expr, locals)) return;
                if (try self.emitMmioWriteStmt(expr, locals)) return;
                if (try self.emitRawStoreStmt(expr, locals)) return;
                if (try self.emitCpuPauseStmt(expr)) return;
                if (try self.emitFenceStmt(expr)) return;
                if (try self.emitResultTryExprStmt(expr, locals, return_ty)) return;
                if (try self.emitNullableTryExprStmt(expr, locals)) return;
                if (try self.emitMmioReadExprStmt(expr, locals)) return;
                if (try self.emitSequencedCallExprStmt(expr, locals)) return;
                try self.writeIndent();
                try self.emitExpr(expr, locals);
                try self.out.appendSlice(self.allocator, ";\n");
            },
        }
    }

    fn resultSubjectForExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ResultSwitchSubject {
        _ = self;
        const name = switch (expr.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident.text,
                else => return null,
            },
            else => return null,
        };
        const info = locals.get(name) orelse return null;
        const ok_ty = info.result_ok_c_type orelse return null;
        const err_ty = info.result_err_c_type orelse return null;
        return .{ .name = name, .ok_c_type = ok_ty, .err_c_type = err_ty };
    }

    fn resultSwitchBranch(self: *CEmitter, patterns: []const ast.Pattern, subject: ResultSwitchSubject) !?ResultSwitchBranch {
        if (patterns.len == 0) return null;
        if (patterns.len == 1) {
            return switch (patterns[0].kind) {
                .tag => |tag| blk: {
                    if (std.mem.eql(u8, tag.text, "ok")) break :blk .{
                        .condition = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.is_ok", .{subject.name}),
                        .tag = "ok",
                    };
                    if (std.mem.eql(u8, tag.text, "err")) break :blk .{
                        .condition = try std.fmt.allocPrint(self.scratch.allocator(), "!{s}.is_ok", .{subject.name}),
                        .tag = "err",
                    };
                    break :blk null;
                },
                .tag_bind => |tag_bind| blk: {
                    if (std.mem.eql(u8, tag_bind.tag.text, "ok")) break :blk .{
                        .condition = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.is_ok", .{subject.name}),
                        .tag = "ok",
                        .binding_name = tag_bind.binding.text,
                        .binding_type = subject.ok_c_type,
                        .payload_field = "ok",
                    };
                    if (std.mem.eql(u8, tag_bind.tag.text, "err")) break :blk .{
                        .condition = try std.fmt.allocPrint(self.scratch.allocator(), "!{s}.is_ok", .{subject.name}),
                        .tag = "err",
                        .binding_name = tag_bind.binding.text,
                        .binding_type = subject.err_c_type,
                        .payload_field = "err",
                    };
                    break :blk null;
                },
                .wildcard => .{ .condition = null },
                else => null,
            };
        }

        var condition: std.ArrayList(u8) = .empty;
        for (patterns, 0..) |pattern, index| {
            const tag = switch (pattern.kind) {
                .tag => |tag| tag,
                else => return null,
            };
            const tag_condition = if (std.mem.eql(u8, tag.text, "ok"))
                try std.fmt.allocPrint(self.scratch.allocator(), "{s}.is_ok", .{subject.name})
            else if (std.mem.eql(u8, tag.text, "err"))
                try std.fmt.allocPrint(self.scratch.allocator(), "!{s}.is_ok", .{subject.name})
            else
                return null;
            if (index > 0) try condition.appendSlice(self.scratch.allocator(), " || ");
            try condition.appendSlice(self.scratch.allocator(), tag_condition);
        }
        return .{ .condition = try condition.toOwnedSlice(self.scratch.allocator()) };
    }

    fn taggedUnionSubjectForExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?TaggedUnionSwitchSubject {
        const name = switch (expr.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident.text,
                else => return null,
            },
            else => return null,
        };
        const info = locals.get(name) orelse return null;
        const type_name = info.source_type_name orelse return null;
        const union_decl = self.tagged_unions.get(type_name) orelse return null;
        return .{ .name = name, .type_name = type_name, .decl = union_decl };
    }

    fn nullableSwitchSubjectForExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?NullableSwitchSubject {
        const source_name = switch (expr.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident.text,
                else => null,
            },
            else => null,
        } orelse blk: {
            const nullable_ty = self.nullableReturnTypeForExpr(expr) orelse return null;
            const inner_c_type = try self.nullableInnerCTypeForExpr(expr, locals) orelse return null;
            const temp = try self.emitSequencedCallArgTemp(expr, locals, nullable_ty);
            try locals.put(temp.name, .{
                .source_ty = nullable_ty,
                .c_type = inner_c_type,
                .nullable_inner_c_type = inner_c_type,
            });
            break :blk temp.name;
        };
        const source_info = locals.get(source_name) orelse return null;
        const inner_c_type = source_info.nullable_inner_c_type orelse return null;
        return .{ .name = source_name, .inner_c_type = inner_c_type };
    }

    fn taggedUnionReturnTypeForExpr(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .call => |node| blk: {
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                const ret_ty = info.return_type orelse break :blk null;
                const type_name = typeName(ret_ty) orelse break :blk null;
                break :blk if (self.tagged_unions.contains(type_name)) ret_ty else null;
            },
            .grouped => |inner| self.taggedUnionReturnTypeForExpr(inner.*),
            else => null,
        };
    }

    fn taggedUnionSwitchBranch(self: *CEmitter, patterns: []const ast.Pattern, subject: TaggedUnionSwitchSubject) !?TaggedUnionSwitchBranch {
        if (patterns.len == 0) return null;
        if (patterns.len == 1) {
            return switch (patterns[0].kind) {
                .tag => |tag| .{
                    .condition = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.tag == {s}Tag_{s}", .{ subject.name, subject.type_name, tag.text }),
                },
                .tag_bind => |tag_bind| blk: {
                    const case = taggedUnionCase(subject.decl, tag_bind.tag.text) orelse break :blk null;
                    const payload_ty = case.ty orelse break :blk null;
                    break :blk .{
                        .condition = try std.fmt.allocPrint(self.scratch.allocator(), "{s}.tag == {s}Tag_{s}", .{ subject.name, subject.type_name, tag_bind.tag.text }),
                        .binding_name = tag_bind.binding.text,
                        .binding_type = try self.cTypeFor(payload_ty, .typedef_name),
                        .payload_field = tag_bind.tag.text,
                    };
                },
                .wildcard => .{ .condition = null, .is_wildcard = true },
                else => null,
            };
        }

        var condition: std.ArrayList(u8) = .empty;
        for (patterns, 0..) |pattern, index| {
            const tag = switch (pattern.kind) {
                .tag => |tag| tag,
                else => return null,
            };
            if (index > 0) try condition.appendSlice(self.scratch.allocator(), " || ");
            try condition.appendSlice(
                self.scratch.allocator(),
                try std.fmt.allocPrint(self.scratch.allocator(), "{s}.tag == {s}Tag_{s}", .{ subject.name, subject.type_name, tag.text }),
            );
        }
        return .{ .condition = try condition.toOwnedSlice(self.scratch.allocator()) };
    }

    fn emitForLoop(self: *CEmitter, loop: ast.Loop, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const binding = loop.label orelse {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "/* unsupported for loop without binding */\n");
            return error.UnsupportedCEmission;
        };
        const iterable = loop.iterable orelse {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "/* unsupported for loop without iterable */\n");
            return error.UnsupportedCEmission;
        };
        if (try self.emitForLoopCallIterable(loop, binding, iterable, locals, return_ty)) return;
        const element_c_type = iterableElementCTypeForExpr(iterable, locals) orelse {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "/* unsupported for iterable */\n");
            return error.UnsupportedCEmission;
        };
        const index_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_i{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "for (uintptr_t {s} = 0; {s} < ", .{ index_name, index_name });
        if (sliceAccessForExpr(iterable, locals)) |slice| {
            try self.emitExpr(iterable, locals);
            try self.out.print(self.allocator, ".{s}", .{slice.len_field});
        } else if (arrayLenForExpr(iterable, locals)) |len| {
            try self.out.appendSlice(self.allocator, len);
        } else {
            try self.out.appendSlice(self.allocator, "0");
        }
        try self.out.print(self.allocator, "; {s} += 1) {{\n", .{index_name});

        const id = self.next_loop_id;
        self.next_loop_id += 1;
        const jumps = loopBodyHasOwnBreakContinue(loop.body);
        try self.loop_ids.append(self.allocator, id);
        defer _ = self.loop_ids.pop();

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        try nested.put(binding.text, .{ .c_type = element_c_type });

        self.indent += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ element_c_type, binding.text });
        if (sliceAccessForExpr(iterable, locals)) |slice| {
            try self.emitExpr(iterable, locals);
            try self.out.print(self.allocator, ".{s}[{s}]", .{ slice.ptr_field, index_name });
        } else {
            try self.emitExpr(iterable, locals);
            if (arrayElemsFieldForExpr(iterable, locals)) |elems_field| {
                try self.out.print(self.allocator, ".{s}[{s}]", .{ elems_field, index_name });
            } else {
                try self.out.print(self.allocator, "[{s}]", .{index_name});
            }
        }
        try self.out.appendSlice(self.allocator, ";\n");
        try self.writeIndent();
        try self.out.print(self.allocator, "(void){s};\n", .{binding.text});
        try self.emitBlockItems(loop.body, &nested, return_ty);
        // `continue` lands here, then the for-step (`i += 1`) runs.
        if (jumps.cont) try self.out.print(self.allocator, "    mc_continue_{d}:;\n", .{id});
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
        if (jumps.brk) try self.out.print(self.allocator, "    mc_break_{d}:;\n", .{id});
    }

    fn emitForLoopCallIterable(self: *CEmitter, loop: ast.Loop, binding: ast.Ident, iterable: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        _ = binding;
        const call = switch (iterable.kind) {
            .call => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .call => |node| node,
                else => return false,
            },
            else => return false,
        };
        const iterable_ty = self.sliceReturnTypeForCall(call) orelse self.arrayReturnTypeForExpr(iterable) orelse return false;
        const temp = try self.emitSequencedCallArgTemp(iterable, locals, iterable_ty);

        var loop_locals = try cloneLocals(self.allocator, locals.*);
        defer loop_locals.deinit();
        try loop_locals.put(temp.name, try self.localInfoFromType(iterable_ty));

        var rewritten = loop;
        const ident = ast.Expr{ .span = iterable.span, .kind = .{ .ident = .{ .span = iterable.span, .text = temp.name } } };
        rewritten.iterable = ident;
        try self.emitForLoop(rewritten, &loop_locals, return_ty);
        return true;
    }

    fn emitSwitchPatternLabel(self: *CEmitter, pattern: ast.Pattern, subject_enum_name: ?[]const u8) !void {
        try self.writeIndent();
        switch (pattern.kind) {
            .literal => |expr| if (intLiteralText(expr)) |literal| {
                try self.out.appendSlice(self.allocator, "case ");
                try appendCIntLiteral(self.allocator, self.out, literal);
                try self.out.appendSlice(self.allocator, ":\n");
            } else if (boolLiteralValue(expr)) |value| {
                try self.out.print(self.allocator, "case {d}:\n", .{@intFromBool(value)});
            } else {
                try self.out.print(self.allocator, "/* unsupported switch pattern: {s} */\n", .{@tagName(pattern.kind)});
                return error.UnsupportedCEmission;
            },
            .tag => |tag| {
                const enum_name = subject_enum_name orelse {
                    try self.out.print(self.allocator, "/* unsupported switch tag without enum subject: {s} */\n", .{tag.text});
                    return error.UnsupportedCEmission;
                };
                try self.out.print(self.allocator, "case {s}_{s}:\n", .{ enum_name, tag.text });
            },
            .wildcard => try self.out.appendSlice(self.allocator, "default:\n"),
            else => {
                try self.out.print(self.allocator, "/* unsupported switch pattern: {s} */\n", .{@tagName(pattern.kind)});
                return error.UnsupportedCEmission;
            },
        }
    }

    fn emitIfLet(self: *CEmitter, node: ast.IfLet, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        if (node.pattern.kind == .tag_bind) return self.emitResultIfLet(node, locals, return_ty);

        const binding = switch (node.pattern.kind) {
            .bind => |ident| ident,
            else => {
                try self.writeIndent();
                try self.out.print(self.allocator, "/* unsupported if-let pattern: {s} */\n", .{@tagName(node.pattern.kind)});
                return error.UnsupportedCEmission;
            },
        };
        const source_name = switch (node.value.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident.text,
                else => null,
            },
            else => null,
        } orelse blk: {
            const nullable_ty = self.nullableReturnTypeForExpr(node.value) orelse {
                try self.writeIndent();
                try self.out.print(self.allocator, "/* unsupported if-let value: {s} */\n", .{@tagName(node.value.kind)});
                return error.UnsupportedCEmission;
            };
            const temp = try self.emitSequencedCallArgTemp(node.value, locals, nullable_ty);
            try locals.put(temp.name, try self.localInfoFromType(nullable_ty));
            break :blk temp.name;
        };
        const source_info = locals.get(source_name) orelse {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported if-let source: {s} */\n", .{source_name});
            return error.UnsupportedCEmission;
        };
        const bind_ty = source_info.nullable_inner_c_type orelse {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported if-let source type: {s} */\n", .{source_name});
            return error.UnsupportedCEmission;
        };

        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s} != NULL) {{\n", .{source_name});
        var then_locals = try cloneLocals(self.allocator, locals.*);
        defer then_locals.deinit();
        try then_locals.put(binding.text, .{ .c_type = bind_ty });
        self.indent += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "MC_UNUSED {s} {s} = {s};\n", .{ bind_ty, try self.cIdent(binding.text), source_name });
        try self.emitBlockItems(node.then_block, &then_locals, return_ty);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}");
        if (node.else_block) |else_block| {
            try self.out.appendSlice(self.allocator, " else {\n");
            var else_locals = try cloneLocals(self.allocator, locals.*);
            defer else_locals.deinit();
            self.indent += 1;
            try self.emitBlockItems(else_block, &else_locals, return_ty);
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}");
        }
        try self.out.appendSlice(self.allocator, "\n");
    }

    fn emitResultIfLet(self: *CEmitter, node: ast.IfLet, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) anyerror!void {
        const tag_bind = switch (node.pattern.kind) {
            .tag_bind => |tag_bind| tag_bind,
            else => unreachable,
        };
        const is_ok = if (std.mem.eql(u8, tag_bind.tag.text, "ok"))
            true
        else if (std.mem.eql(u8, tag_bind.tag.text, "err"))
            false
        else {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported result if-let tag: {s} */\n", .{tag_bind.tag.text});
            return error.UnsupportedCEmission;
        };
        const source_name = switch (node.value.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident.text,
                else => null,
            },
            else => null,
        } orelse blk: {
            const result_ty = self.resultTypeForExpr(node.value, locals) orelse {
                try self.writeIndent();
                try self.out.print(self.allocator, "/* unsupported result if-let value: {s} */\n", .{@tagName(node.value.kind)});
                return error.UnsupportedCEmission;
            };
            const temp = try self.emitSequencedCallArgTemp(node.value, locals, result_ty);
            try locals.put(temp.name, try self.localInfoFromType(result_ty));
            break :blk temp.name;
        };
        const source_info = locals.get(source_name) orelse {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported result if-let source: {s} */\n", .{source_name});
            return error.UnsupportedCEmission;
        };
        const bind_ty = (if (is_ok) source_info.result_ok_c_type else source_info.result_err_c_type) orelse {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported result if-let source type: {s} */\n", .{source_name});
            return error.UnsupportedCEmission;
        };
        const payload_field = if (is_ok) "ok" else "err";

        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s}{s}.is_ok) {{\n", .{ if (is_ok) "" else "!", source_name });
        var then_locals = try cloneLocals(self.allocator, locals.*);
        defer then_locals.deinit();
        try then_locals.put(tag_bind.binding.text, .{ .c_type = bind_ty });
        self.indent += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "MC_UNUSED {s} {s} = {s}.payload.{s};\n", .{ bind_ty, tag_bind.binding.text, source_name, payload_field });
        try self.emitBlockItems(node.then_block, &then_locals, return_ty);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}");
        if (node.else_block) |else_block| {
            try self.out.appendSlice(self.allocator, " else {\n");
            var else_locals = try cloneLocals(self.allocator, locals.*);
            defer else_locals.deinit();
            self.indent += 1;
            try self.emitBlockItems(else_block, &else_locals, return_ty);
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}");
        }
        try self.out.appendSlice(self.allocator, "\n");
    }

    fn emitNeverExprStmt(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        switch (expr.kind) {
            .unreachable_expr => {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "mc_trap_Unreachable();\n");
                return true;
            },
            .call => |node| {
                if (trapHelperForCall(node)) |helper| {
                    try self.writeIndent();
                    try self.out.print(self.allocator, "{s}();\n", .{helper});
                    return true;
                }
                return false;
            },
            .grouped => |inner| return try self.emitNeverExprStmt(inner.*, locals),
            else => return false,
        }
    }

    fn emitMmioWriteStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitMmioWriteStmt(inner.*, locals),
            else => return false,
        };
        const access = self.mmioAccess(call.callee.*, call.args, locals) orelse return false;
        if (!std.mem.eql(u8, access.kind, "write")) return false;
        if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;
        if (call.args.len == 0) return error.UnsupportedCEmission;

        const value_ty = simpleNameType(access.value_type, call.args[0].span);
        const value_temp = try self.emitSequencedCallArgTemp(call.args[0], locals, value_ty);
        if (std.mem.eql(u8, access.ordering, "release")) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_barrier_release_before();\n");
        }
        try self.writeIndent();
        try self.out.print(self.allocator, "mc_mmio_write_{s}(&{s}->{s}, {s});\n", .{ access.width, access.param, access.field, value_temp.name });
        return true;
    }

    fn emitRawStoreStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitRawStoreStmt(inner.*, locals),
            else => return false,
        };
        if (!isRawStoreCall(call.callee.*)) return false;
        if (call.type_args.len != 1 or call.args.len != 2) return error.UnsupportedCEmission;
        const type_name = typeName(call.type_args[0]) orelse return error.UnsupportedCEmission;
        const suffix = rawScalarSuffix(type_name) orelse return error.UnsupportedCEmission;

        const addr_temp = try self.emitSequencedCallArgTemp(call.args[0], locals, simpleNameType("PAddr", call.args[0].span));
        const value_temp = try self.emitSequencedCallArgTemp(call.args[1], locals, call.type_args[0]);
        try self.writeIndent();
        try self.out.print(self.allocator, "mc_raw_store_{s}({s}, {s});\n", .{ suffix, addr_temp.name, value_temp.name });
        return true;
    }

    fn emitCpuPauseStmt(self: *CEmitter, expr: ast.Expr) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitCpuPauseStmt(inner.*),
            else => return false,
        };
        if (!isCpuPauseCall(call.callee.*)) return false;
        if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedCEmission;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "mc_cpu_pause();\n");
        return true;
    }

    // `fence.full()` / `fence.release()` / `fence.acquire()` lower to the
    // target-aware `__atomic_thread_fence` helpers (riscv `fence`, x86 `mfence`,
    // arm `dmb`), so explicit memory barriers are real CPU fences, not just
    // compiler barriers.
    fn emitFenceStmt(self: *CEmitter, expr: ast.Expr) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitFenceStmt(inner.*),
            else => return false,
        };
        const helper = fenceHelperForCall(call.callee.*) orelse return false;
        if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedCEmission;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s}();\n", .{helper});
        return true;
    }

    fn emitMmioReadReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitMmioReadReturn(inner.*, locals),
            else => return false,
        };
        const access = self.mmioAccess(call.callee.*, call.args, locals) orelse return false;
        if (!std.mem.eql(u8, access.kind, "read")) return false;
        if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;
        const value_c_type = self.cTypeForMmioValue(access.value_type);

        if (std.mem.eql(u8, access.ordering, "acquire")) {
            const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = ({s})mc_mmio_read_{s}(&{s}->{s});\n", .{ value_c_type, temp_name, value_c_type, access.width, access.param, access.field });
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_barrier_acquire_after();\n");
            try self.writeIndent();
            try self.out.print(self.allocator, "return {s};\n", .{temp_name});
        } else {
            try self.writeIndent();
            try self.out.print(self.allocator, "return ({s})mc_mmio_read_{s}(&{s}->{s});\n", .{ value_c_type, access.width, access.param, access.field });
        }
        return true;
    }

    fn emitMmioReadAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (assignment.value.kind) {
            .call => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .call => |node| node,
                else => return false,
            },
            else => return false,
        };
        const access = self.mmioAccess(call.callee.*, call.args, locals) orelse return false;
        if (!std.mem.eql(u8, access.kind, "read")) return false;
        if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;

        const value_c_type = self.cTypeForMmioValue(access.value_type);
        const global_target = self.globalAssignmentTarget(assignment.target, locals);
        if (std.mem.eql(u8, access.ordering, "acquire") or global_target != null) {
            const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = ({s})mc_mmio_read_{s}(&{s}->{s});\n", .{ value_c_type, temp_name, value_c_type, access.width, access.param, access.field });
            if (std.mem.eql(u8, access.ordering, "acquire")) {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "mc_barrier_acquire_after();\n");
            }
            try self.writeIndent();
            if (global_target) |target| {
                try self.emitGlobalStoreValue(target, temp_name);
            } else {
                try self.emitExpr(assignment.target, locals);
                try self.out.print(self.allocator, " = {s};\n", .{temp_name});
            }
            return true;
        }

        try self.writeIndent();
        try self.emitExpr(assignment.target, locals);
        try self.out.print(self.allocator, " = ({s})mc_mmio_read_{s}(&{s}->{s});\n", .{ value_c_type, access.width, access.param, access.field });
        return true;
    }

    fn emitMmioReadExprAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (try self.emitMmioReadSequencedBinaryAssignmentStmt(assignment, locals)) return true;
        if (try self.emitMmioReadCallAssignmentStmt(assignment, locals)) return true;

        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectMmioReadHoistsForExpr(assignment.value, locals, &replacements)) return false;

        for (replacements.items) |replacement| {
            try self.emitMmioReadReplacement(replacement);
        }

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        try addMmioReadReplacementLocals(&nested, replacements.items);

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStorePrefix(target);
            try self.emitMmioReadExprWithReplacements(assignment.value, &nested, null, replacements.items);
            try self.emitGlobalStoreSuffix(target);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.appendSlice(self.allocator, " = ");
            try self.emitMmioReadExprWithReplacements(assignment.value, &nested, self.assignmentTargetType(assignment.target, locals), replacements.items);
            try self.out.appendSlice(self.allocator, ";\n");
        }
        return true;
    }

    fn emitMmioReadLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (initializer.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitMmioReadLocalInit(name, decl_ty, inner.*, locals),
            else => return false,
        };
        const access = self.mmioAccess(call.callee.*, call.args, locals) orelse return false;
        if (!std.mem.eql(u8, access.kind, "read")) return false;
        if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;

        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.print(self.allocator, " = ({s})mc_mmio_read_{s}(&{s}->{s});\n", .{ try self.cTypeFor(decl_ty, .typedef_name), access.width, access.param, access.field });
        if (std.mem.eql(u8, access.ordering, "acquire")) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_barrier_acquire_after();\n");
        }
        return true;
    }

    fn emitMmioReadExprLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (try self.emitMmioReadSequencedBinaryLocalInit(name, decl_ty, initializer, locals)) return true;
        if (try self.emitMmioReadCallLocalInit(name, decl_ty, initializer, locals)) return true;

        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectMmioReadHoistsForExpr(initializer, locals, &replacements)) return false;

        for (replacements.items) |replacement| {
            try self.emitMmioReadReplacement(replacement);
        }

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        try addMmioReadReplacementLocals(&nested, replacements.items);

        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.appendSlice(self.allocator, " = ");
        try self.emitMmioReadExprWithReplacements(initializer, &nested, decl_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitMmioReadSequencedBinaryReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
        const temp = (try self.emitMmioReadSequencedBinaryValueTemp(expr, locals, target_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitMmioReadSequencedBinaryLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitMmioReadSequencedBinaryValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitMmioReadSequencedBinaryAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const temp = (try self.emitMmioReadSequencedBinaryValueTemp(assignment.value, locals, target_ty)) orelse return false;
        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitMmioReadSequencedBinaryValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        if (!self.exprContainsMmioRead(expr, locals)) return null;
        const node = switch (expr.kind) {
            .grouped => |inner| return try self.emitMmioReadSequencedBinaryValueTemp(inner.*, locals, target_ty),
            .binary => |node| node,
            else => return null,
        };
        const plan = try self.sequencedBinaryPlan(node, target_ty, locals) orelse return null;

        const left_temp = try self.emitMmioReadOperandTemp(node.left.*, locals, target_ty);
        const right_temp = try self.emitMmioReadOperandTemp(node.right.*, locals, target_ty);
        return try self.emitSequencedBinaryPlanResultTemp(plan, target_ty, left_temp.name, right_temp.name);
    }

    fn emitMmioReadOperandTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        _ = try self.collectMmioReadHoistsForExpr(expr, locals, &replacements);

        for (replacements.items) |replacement| {
            try self.emitMmioReadReplacement(replacement);
        }

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        try addMmioReadReplacementLocals(&nested, replacements.items);

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp_name });
        try self.emitMmioReadExprWithReplacements(expr, &nested, target_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitMmioReadExprInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var replacements: std.ArrayList(MmioReadReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectMmioReadHoistsForExpr(initializer, locals, &replacements)) return false;

        for (replacements.items) |replacement| {
            try self.emitMmioReadReplacement(replacement);
        }

        var nested = try cloneLocals(self.allocator, locals.*);
        defer nested.deinit();
        try addMmioReadReplacementLocals(&nested, replacements.items);

        try locals.put(name, .{
            .source_ty = .{ .span = initializer.span, .kind = .{ .name = .{ .text = "u32", .span = initializer.span } } },
            .c_type = "uint32_t",
            .source_type_name = "u32",
        });
        try self.writeIndent();
        try self.out.print(self.allocator, "uint32_t {s} = ", .{name});
        try self.emitMmioReadExprWithReplacements(initializer, &nested, locals.get(name).?.source_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitMmioReadInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (initializer.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitMmioReadInferredLocalInit(name, inner.*, locals),
            else => return false,
        };
        const access = self.mmioAccess(call.callee.*, call.args, locals) orelse return false;
        if (!std.mem.eql(u8, access.kind, "read")) return false;
        if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;

        const value_c_type = self.cTypeForMmioValue(access.value_type);
        try locals.put(name, .{
            .c_type = value_c_type,
            .source_type_name = access.value_type,
        });

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ({s})mc_mmio_read_{s}(&{s}->{s});\n", .{ value_c_type, name, value_c_type, access.width, access.param, access.field });
        if (std.mem.eql(u8, access.ordering, "acquire")) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_barrier_acquire_after();\n");
        }
        return true;
    }

    fn emitExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (!local_set.contains(ident.text)) {
                        if (self.globals.get(ident.text)) |global| {
                            try self.emitGlobalLoadExpr(ident.text, global);
                            return;
                        }
                    }
                }
                try self.out.appendSlice(self.allocator, try self.cIdent(ident.text));
            },
            .int_literal => |literal| try appendCIntLiteral(self.allocator, self.out, literal),
            .float_literal => |literal| try self.out.appendSlice(self.allocator, literal),
            .char_literal => |literal| try self.out.appendSlice(self.allocator, literal),
            .bool_literal => |value| try self.out.appendSlice(self.allocator, if (value) "true" else "false"),
            .null_literal => try self.out.appendSlice(self.allocator, "NULL"),
            .void_literal => try self.out.appendSlice(self.allocator, "0"),
            .array_literal => {
                try self.out.appendSlice(self.allocator, "/* unsupported targetless array literal */0");
                return error.UnsupportedCEmission;
            },
            .struct_literal => {
                try self.out.appendSlice(self.allocator, "/* unsupported targetless struct literal */0");
                return error.UnsupportedCEmission;
            },
            .grouped => |inner| {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExpr(inner.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            .unreachable_expr => try self.out.appendSlice(self.allocator, "mc_trap_Unreachable()"),
            .unary => |node| {
                if (node.op == .neg and !self.exprResolvesToFloat(node.expr.*, locals)) {
                    // Signed negation can overflow (`-INT_MIN`); like checked
                    // binary ops it must keep its trap edge even with no target
                    // type, e.g. as a comparison operand `(-a) == b`. wrap/sat
                    // operands negate with plain C operators (no trap), so they
                    // fall through to the plain emission below.
                    if (self.numericExprTypeForEmission(node.expr.*, locals)) |inferred| {
                        const resolved = self.resolveAliasType(inferred);
                        if (!isWrapType(resolved) and !isSatType(resolved)) {
                            if (try self.emitCheckedUnaryWithTarget(node, locals, inferred)) return;
                        }
                    }
                }
                try self.out.appendSlice(self.allocator, unaryCOp(node.op));
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExpr(node.expr.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            .binary => |node| {
                if (isCheckedBinaryOp(node.op) and !self.binaryIsFloat(node, locals)) {
                    // A checked integer op used where no target type is supplied
                    // (e.g. an operand of a comparison: `(a + b) == c`). Recover
                    // the operand storage type and lower through the checked
                    // helper so the trap edge is still emitted.
                    if (self.numericExprTypeForEmission(expr, locals)) |inferred| {
                        if (try self.emitCheckedBinaryWithTarget(node, locals, inferred)) return;
                    }
                    return error.UnsupportedCEmission;
                }
                // A comparison with an enum-literal operand (`s == .Ready`): the
                // literal needs the enum's type, taken from the other operand.
                if (isComparisonOp(node.op)) {
                    const left_enum = node.left.*.kind == .enum_literal;
                    const right_enum = node.right.*.kind == .enum_literal;
                    if (left_enum or right_enum) {
                        const enum_ty = if (left_enum) self.operandEmitType(node.right.*, locals) else self.operandEmitType(node.left.*, locals);
                        if (enum_ty) |ety| {
                            try self.out.appendSlice(self.allocator, "(");
                            try self.emitExprWithTarget(node.left.*, locals, ety);
                            try self.out.print(self.allocator, " {s} ", .{binaryCOp(node.op)});
                            try self.emitExprWithTarget(node.right.*, locals, ety);
                            try self.out.appendSlice(self.allocator, ")");
                            return;
                        }
                    }
                }
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExpr(node.left.*, locals);
                try self.out.print(self.allocator, " {s} ", .{binaryCOp(node.op)});
                try self.emitExpr(node.right.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            .call => |node| {
                if (trapHelperForCall(node)) |helper| {
                    try self.out.print(self.allocator, "{s}()", .{helper});
                    return;
                }
                // `drop(x)` consumes its argument and yields void; emit a cast to
                // void so the value is evaluated and discarded (linearity is
                // erased — it was a compile-time check).
                if (calleeIdentName(node.callee.*)) |name| {
                    if (std.mem.eql(u8, name, "drop") and node.args.len == 1) {
                        try self.out.appendSlice(self.allocator, "(void)(");
                        try self.emitExpr(node.args[0], locals);
                        try self.out.appendSlice(self.allocator, ")");
                        return;
                    }
                    // `bind(&env, f)` builds a closure: a {code, env} fat value. The
                    // env pointer is type-erased to void* and the function pointer
                    // (whose first param is the typed env) is cast to take void* —
                    // both casts are ABI-identity, so user code stays typed/cast-free.
                    if (std.mem.eql(u8, name, "bind") and node.args.len == 2) {
                        try self.emitBind(node, locals);
                        return;
                    }
                }
                // Calling a closure-typed value: `c(args)` -> `c.code(c.env, args)`.
                if (self.closureCalleeType(node.callee.*, locals)) |clos| {
                    try self.emitClosureCall(node, clos, locals);
                    return;
                }
                // `raw.load<T>(addr)` reads a `T` from a raw address.
                if (isRawLoadCall(node.callee.*)) {
                    if (node.type_args.len != 1 or node.args.len != 1) return error.UnsupportedCEmission;
                    const type_name = typeName(node.type_args[0]) orelse return error.UnsupportedCEmission;
                    const suffix = rawScalarSuffix(type_name) orelse return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, "mc_raw_load_{s}(", .{suffix});
                    try self.emitExpr(node.args[0], locals);
                    try self.out.appendSlice(self.allocator, ")");
                    return;
                }
                // `raw.ptr<T>(addr)` mints a `T *` from a raw address (any T).
                if (isRawPtrCall(node.callee.*)) {
                    if (node.type_args.len != 1 or node.args.len != 1) return error.UnsupportedCEmission;
                    try self.out.appendSlice(self.allocator, "(");
                    try self.out.appendSlice(self.allocator, try self.cTypeFor(node.type_args[0], .typedef_name));
                    try self.out.appendSlice(self.allocator, " *)(");
                    try self.emitExpr(node.args[0], locals);
                    try self.out.appendSlice(self.allocator, ")");
                    return;
                }
                if (try self.emitAtomicInitCall(node, locals)) return;
                if (try self.emitAtomicCall(node, locals)) return;
                if (try self.emitPhysCall(node, locals)) return;
                if (try self.emitEnumRawCall(node, locals)) return;
                if (try self.emitConversionCall(node, locals)) return;
                if (try self.emitResidueCall(node, locals)) return;
                if (try self.emitDomainOpCall(node, locals)) return;
                if (try self.emitReflectionCall(node)) return;
                if (try self.emitConstGetCall(node, locals)) return;
                if (try self.emitRawManyOffsetCall(node, locals)) return;
                if (try self.emitAssumeNoaliasCall(node, locals)) return;
                if (try self.emitWrappingCall(node, locals)) return;
                if (try self.emitReduceSumCheckedCall(node, locals)) return;
                if (try self.emitUncheckedCall(node, locals)) return;
                const fn_info = if (calleeIdentName(node.callee.*)) |name| self.functions.get(name) else null;
                try self.emitExpr(node.callee.*, locals);
                try self.out.appendSlice(self.allocator, "(");
                for (node.args, 0..) |arg, i| {
                    if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                    const target_ty = if (fn_info) |info| if (i < info.params.len) info.params[i].ty else null else null;
                    try self.emitExprWithTarget(arg, locals, target_ty);
                }
                try self.out.appendSlice(self.allocator, ")");
            },
            .index => |node| {
                if (self.globalArrayElementAccess(node, locals)) |access| {
                    try self.emitGlobalArrayElementLoadExpr(access, locals);
                } else if (sliceAccessForExpr(node.base.*, locals)) |slice| {
                    try self.emitExpr(node.base.*, locals);
                    try self.out.print(self.allocator, ".{s}[mc_check_index_usize(", .{slice.ptr_field});
                    try self.emitExpr(node.index.*, locals);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitExpr(node.base.*, locals);
                    try self.out.print(self.allocator, ".{s})]", .{slice.len_field});
                } else if (self.arrayTypeForExpr(node.base.*, locals)) |base_arr| {
                    // Array (possibly the element of an outer array, e.g.
                    // `m[i][j]` over `[N][M]T`): index the `.elems` member with a
                    // bounds check against this dimension's length.
                    try self.emitExpr(node.base.*, locals);
                    try self.out.appendSlice(self.allocator, ".elems[mc_check_index_usize(");
                    try self.emitExpr(node.index.*, locals);
                    const len = try self.arrayLenTextForExpr(base_arr.kind.array.len);
                    try self.out.print(self.allocator, ", {s})]", .{len});
                } else {
                    try self.emitExpr(node.base.*, locals);
                    try self.out.appendSlice(self.allocator, "[");
                    try self.emitExpr(node.index.*, locals);
                    try self.out.appendSlice(self.allocator, "]");
                }
            },
            .address_of => |inner| {
                try self.out.appendSlice(self.allocator, "&");
                try self.emitAddressOperand(inner.*, locals);
            },
            .deref => |inner| {
                try self.out.appendSlice(self.allocator, "*");
                try self.emitExpr(inner.*, locals);
            },
            .member => |node| {
                if (try self.emitPackedBitsMember(node, locals)) return;
                if (self.globalMemberAccess(node, locals)) |access| {
                    try self.emitGlobalLoadExpr(access.name, access.info);
                    return;
                }
                const op: []const u8 = if (self.exprIsPointer(node.base.*, locals)) "->" else ".";
                try self.emitExpr(node.base.*, locals);
                try self.out.print(self.allocator, "{s}{s}", .{ op, try self.cIdent(node.name.text) });
            },
            .cast => |node| {
                try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(node.ty.*, .typedef_name)});
                try self.emitExpr(node.value.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            else => {
                try self.out.print(self.allocator, "/* unsupported expr: {s} */0", .{@tagName(expr.kind)});
                return error.UnsupportedCEmission;
            },
        }
    }

    fn emitAddressOperand(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (!local_set.contains(ident.text) and self.globals.contains(ident.text)) {
                        try self.out.appendSlice(self.allocator, try self.cIdent(ident.text));
                        return;
                    }
                }
                try self.out.appendSlice(self.allocator, try self.cIdent(ident.text));
            },
            .grouped => |inner| {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitAddressOperand(inner.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            .index => |node| {
                if (sliceAccessForExpr(node.base.*, locals)) |slice| {
                    try self.emitExpr(node.base.*, locals);
                    try self.out.print(self.allocator, ".{s}[mc_check_index_usize(", .{slice.ptr_field});
                    try self.emitExpr(node.index.*, locals);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitExpr(node.base.*, locals);
                    try self.out.print(self.allocator, ".{s})]", .{slice.len_field});
                } else if (self.arrayTypeForExpr(node.base.*, locals)) |base_arr| {
                    // An array lvalue — a local, or a struct field (`s.contexts`),
                    // or an outer-array element: index its `.elems` member with a
                    // bounds check. Mirrors the value-read path so `&arr[i]` and
                    // `arr[i]` agree.
                    try self.emitAddressOperand(node.base.*, locals);
                    try self.out.appendSlice(self.allocator, ".elems[mc_check_index_usize(");
                    try self.emitExpr(node.index.*, locals);
                    const len = try self.arrayLenTextForExpr(base_arr.kind.array.len);
                    try self.out.print(self.allocator, ", {s})]", .{len});
                } else {
                    try self.emitAddressOperand(node.base.*, locals);
                    try self.out.appendSlice(self.allocator, "[");
                    try self.emitExpr(node.index.*, locals);
                    try self.out.appendSlice(self.allocator, "]");
                }
            },
            .member => |node| {
                const op: []const u8 = if (self.exprIsPointer(node.base.*, locals)) "->" else ".";
                try self.emitAddressOperand(node.base.*, locals);
                try self.out.print(self.allocator, "{s}{s}", .{ op, try self.cIdent(node.name.text) });
            },
            else => try self.emitExpr(expr, locals),
        }
    }

    fn emitEnumRawCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        if (call.type_args.len != 0) return false;
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!std.mem.eql(u8, member.name.text, "raw")) return false;
        if (call.args.len != 0) return error.UnsupportedCEmission;
        const enum_name = self.enumNameForValueExpr(member.base.*, locals) orelse return false;
        const enum_decl = self.enums.get(enum_name) orelse return false;
        if (!enum_decl.is_open) return false;
        try self.emitExpr(member.base.*, locals);
        return true;
    }

    // Cast-style scalar/domain conversions (`from`, `wrap_from`, `from_mod`) lower
    // to a plain C cast; `wrap<T>` already lowers to its inner integer type.
    // Checked conversions (`trap_from`/`sat_from`/`try_from`) are not yet emitted.
    fn emitConversionCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        if (call.type_args.len != 0) return false;
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        const op = member.name.text;
        const is_cast = std.mem.eql(u8, op, "from") or std.mem.eql(u8, op, "wrap_from") or std.mem.eql(u8, op, "from_mod");
        const is_checked = std.mem.eql(u8, op, "trap_from") or std.mem.eql(u8, op, "sat_from") or std.mem.eql(u8, op, "try_from");
        if (!is_cast and !is_checked) return false;
        const ident = switch (member.base.kind) {
            .ident => |id| id,
            else => return false,
        };
        if (locals) |ls| {
            if (ls.contains(ident.text)) return false;
        }
        const resolved = self.resolveAliasType(simpleNameType(ident.text, ident.span));
        const target_name = typeName(resolved);
        const numeric_target = isNumericStorageType(resolved) or (target_name != null and primitiveCTypeName(target_name.?) != null);
        if (!numeric_target) return false;
        if (call.args.len != 1) return error.UnsupportedCEmission;
        const cty = try self.cTypeFor(resolved, .typedef_name);

        if (is_checked) {
            const dst_name = self.underlyingIntTypeName(resolved) orelse return error.UnsupportedCEmission;
            const dst_range = intTypeRange(dst_name) orelse return error.UnsupportedCEmission;
            const src_ty = self.numericExprTypeForEmission(call.args[0], locals) orelse return error.UnsupportedCEmission;
            const src_name = self.underlyingIntTypeName(src_ty) orelse return error.UnsupportedCEmission;
            const src_range = intTypeRange(src_name) orelse return error.UnsupportedCEmission;
            const need_lower = src_range.min < dst_range.min;
            const need_upper = src_range.max > dst_range.max;

            // try_from -> Result<T, ConversionError> (section 3): ok on success,
            // a conversion error when the source is out of the target range.
            if (std.mem.eql(u8, op, "try_from")) {
                const struct_name = try self.resultTypeName(resolved, simpleNameType("ConversionError", member.name.span));
                if (!need_lower and !need_upper) {
                    try self.out.print(self.allocator, "(({s}){{ .is_ok = true, .payload.ok = ({s})(", .{ struct_name, cty });
                    try self.emitExpr(call.args[0], locals);
                    try self.out.appendSlice(self.allocator, ") })");
                    return true;
                }
                try self.out.appendSlice(self.allocator, "(");
                try self.emitConversionBound(call.args[0], locals, dst_range, need_lower, need_upper);
                try self.out.print(self.allocator, " ? (({s}){{ .is_ok = false, .payload.err = 0 }}) : (({s}){{ .is_ok = true, .payload.ok = ({s})(", .{ struct_name, struct_name, cty });
                try self.emitExpr(call.args[0], locals);
                try self.out.appendSlice(self.allocator, ") }))");
                return true;
            }

            if (!need_lower and !need_upper) {
                try self.out.print(self.allocator, "(({s})(", .{cty});
                try self.emitExpr(call.args[0], locals);
                try self.out.appendSlice(self.allocator, "))");
                return true;
            }

            if (std.mem.eql(u8, op, "trap_from")) {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitConversionBound(call.args[0], locals, dst_range, need_lower, need_upper);
                try self.out.print(self.allocator, " ? (mc_trap_IntegerOverflow(), ({s})0) : ({s})(", .{ cty, cty });
                try self.emitExpr(call.args[0], locals);
                try self.out.appendSlice(self.allocator, "))");
                return true;
            }

            // sat_from: clamp into the destination range.
            try self.out.print(self.allocator, "(({s})(", .{cty});
            if (need_lower) {
                try self.out.appendSlice(self.allocator, "(__int128)(");
                try self.emitExpr(call.args[0], locals);
                try self.out.print(self.allocator, ") < (__int128)({s}) ? ({s}) : (", .{ dst_range.c_min, dst_range.c_min });
            }
            if (need_upper) {
                try self.out.appendSlice(self.allocator, "(__int128)(");
                try self.emitExpr(call.args[0], locals);
                try self.out.print(self.allocator, ") > (__int128)({s}) ? ({s}) : (", .{ dst_range.c_max, dst_range.c_max });
            }
            try self.emitExpr(call.args[0], locals);
            if (need_upper) try self.out.appendSlice(self.allocator, ")");
            if (need_lower) try self.out.appendSlice(self.allocator, ")");
            try self.out.appendSlice(self.allocator, "))");
            return true;
        }

        try self.out.print(self.allocator, "(({s})(", .{cty});
        try self.emitExpr(call.args[0], locals);
        try self.out.appendSlice(self.allocator, "))");
        return true;
    }

    fn emitConversionBound(self: *CEmitter, value: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), range: IntTypeRange, need_lower: bool, need_upper: bool) !void {
        if (need_lower) {
            try self.out.appendSlice(self.allocator, "(__int128)(");
            try self.emitExpr(value, locals);
            try self.out.print(self.allocator, ") < (__int128)({s})", .{range.c_min});
        }
        if (need_lower and need_upper) try self.out.appendSlice(self.allocator, " || ");
        if (need_upper) {
            try self.out.appendSlice(self.allocator, "(__int128)(");
            try self.emitExpr(value, locals);
            try self.out.print(self.allocator, ") > (__int128)({s})", .{range.c_max});
        }
    }

    fn underlyingIntTypeName(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .name => |n| if (intTypeRange(n.text) != null) n.text else null,
            .generic => |g| if ((std.mem.eql(u8, g.base.text, "wrap") or std.mem.eql(u8, g.base.text, "sat") or
                std.mem.eql(u8, g.base.text, "serial") or std.mem.eql(u8, g.base.text, "counter")) and g.args.len == 1)
                self.underlyingIntTypeName(g.args[0])
            else
                null,
            .qualified => |q| self.underlyingIntTypeName(q.child.*),
            else => null,
        };
    }

    // `wrap<T>.residue()` exposes the raw representative; `wrap<T>` already lowers
    // to its inner integer type, so this is the identity on the C value.
    fn emitResidueCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        if (call.type_args.len != 0) return false;
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!std.mem.eql(u8, member.name.text, "residue")) return false;
        _ = self.numericExprTypeForEmission(member.base.*, locals) orelse return false;
        if (call.args.len != 0) return error.UnsupportedCEmission;
        try self.emitExpr(member.base.*, locals);
        return true;
    }

    // Serial/counter domain operations. `serial<T>`/`counter<T>` lower to their
    // unsigned inner integer, so the modular difference is plain wrapping
    // subtraction; serial ordering reinterprets that difference as signed.
    fn emitDomainOpCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        if (call.type_args.len != 0) return false;
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        const op = member.name.text;
        const is_serial_op = std.mem.eql(u8, op, "before") or std.mem.eql(u8, op, "after") or
            std.mem.eql(u8, op, "distance") or std.mem.eql(u8, op, "compare");
        const is_counter_op = std.mem.eql(u8, op, "delta_mod") or
            std.mem.eql(u8, op, "elapsed_assume_within") or std.mem.eql(u8, op, "elapsed_bounded");
        if (!is_serial_op and !is_counter_op) return false;
        const ident = switch (member.base.kind) {
            .ident => |id| id,
            else => return false,
        };
        if (locals) |ls| {
            if (ls.contains(ident.text)) return false;
        }
        const resolved = self.resolveAliasType(simpleNameType(ident.text, ident.span));
        const node = switch (resolved.kind) {
            .generic => |n| n,
            else => return false,
        };
        const is_serial = std.mem.eql(u8, node.base.text, "serial");
        const is_counter = std.mem.eql(u8, node.base.text, "counter");
        if ((!is_serial and !is_counter) or node.args.len != 1) return false;
        if (is_serial_op and !is_serial) return false;
        if (is_counter_op and !is_counter) return false;
        if (call.args.len < 2) return error.UnsupportedCEmission;
        const inner_name = typeName(node.args[0]) orelse return error.UnsupportedCEmission;
        const unsigned_c = primitiveCTypeName(inner_name) orelse return error.UnsupportedCEmission;

        // serial.compare -> Result<Order, AmbiguousSerialOrder> (section 5.4).
        // Ambiguous exactly when the signed modular difference is the half-window
        // boundary (the wrapped INT_MIN), otherwise a three-way Order (-1/0/+1).
        if (std.mem.eql(u8, op, "compare")) {
            const signed_c = signedCTypeForInner(inner_name) orelse return error.UnsupportedCEmission;
            const min_macro = signedMinMacroForInner(inner_name) orelse return error.UnsupportedCEmission;
            const struct_name = try self.resultTypeName(simpleNameType("Order", member.name.span), simpleNameType("AmbiguousSerialOrder", member.name.span));
            try self.out.appendSlice(self.allocator, "(");
            try self.emitSignedSerialDiff(call.args[0], call.args[1], locals, signed_c, unsigned_c);
            try self.out.print(self.allocator, " == {s} ? (({s}){{ .is_ok = false, .payload.err = 0 }}) : (({s}){{ .is_ok = true, .payload.ok = (", .{ min_macro, struct_name, struct_name });
            try self.emitSignedSerialDiff(call.args[0], call.args[1], locals, signed_c, unsigned_c);
            try self.out.appendSlice(self.allocator, " < 0 ? -1 : (");
            try self.emitSignedSerialDiff(call.args[0], call.args[1], locals, signed_c, unsigned_c);
            try self.out.appendSlice(self.allocator, " > 0 ? 1 : 0)) }))");
            return true;
        }

        // counter.elapsed_bounded -> Result<Duration<T>, AmbiguousCounterInterval>
        // (section 5.5). Ok when the modular delta does not exceed the supplied
        // maximum interval, otherwise the interval is ambiguous.
        if (std.mem.eql(u8, op, "elapsed_bounded")) {
            if (call.args.len != 3) return error.UnsupportedCEmission;
            const duration_ty: ast.TypeExpr = .{ .span = member.name.span, .kind = .{ .generic = .{ .base = .{ .text = "Duration", .span = member.name.span }, .args = node.args } } };
            const struct_name = try self.resultTypeName(duration_ty, simpleNameType("AmbiguousCounterInterval", member.name.span));
            try self.out.print(self.allocator, "((({s})(", .{unsigned_c});
            try self.emitExpr(call.args[0], locals);
            try self.out.appendSlice(self.allocator, " - ");
            try self.emitExpr(call.args[1], locals);
            try self.out.appendSlice(self.allocator, ")) <= (");
            try self.emitExpr(call.args[2], locals);
            try self.out.print(self.allocator, ") ? (({s}){{ .is_ok = true, .payload.ok = ({s})(", .{ struct_name, unsigned_c });
            try self.emitExpr(call.args[0], locals);
            try self.out.appendSlice(self.allocator, " - ");
            try self.emitExpr(call.args[1], locals);
            try self.out.print(self.allocator, ") }}) : (({s}){{ .is_ok = false, .payload.err = 0 }}))", .{struct_name});
            return true;
        }

        // `elapsed_assume_within` is a pure modular delta at runtime: the temporal
        // assumption grants the optimizer no extra license (section 5.5).
        if (std.mem.eql(u8, op, "distance") or std.mem.eql(u8, op, "delta_mod") or std.mem.eql(u8, op, "elapsed_assume_within")) {
            try self.out.print(self.allocator, "(({s})(", .{unsigned_c});
            try self.emitExpr(call.args[0], locals);
            try self.out.appendSlice(self.allocator, " - ");
            try self.emitExpr(call.args[1], locals);
            try self.out.appendSlice(self.allocator, "))");
            return true;
        }

        const signed_c = signedCTypeForInner(inner_name) orelse return error.UnsupportedCEmission;
        const cmp: []const u8 = if (std.mem.eql(u8, op, "before")) "<" else ">";
        try self.out.print(self.allocator, "(({s})(({s})(", .{ signed_c, unsigned_c });
        try self.emitExpr(call.args[0], locals);
        try self.out.appendSlice(self.allocator, " - ");
        try self.emitExpr(call.args[1], locals);
        try self.out.print(self.allocator, ")) {s} 0)", .{cmp});
        return true;
    }

    fn emitSignedSerialDiff(self: *CEmitter, a: ast.Expr, b: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), signed_c: []const u8, unsigned_c: []const u8) !void {
        try self.out.print(self.allocator, "({s})({s})(", .{ signed_c, unsigned_c });
        try self.emitExpr(a, locals);
        try self.out.appendSlice(self.allocator, " - ");
        try self.emitExpr(b, locals);
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitPhysCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        if (!isIdentNamed(call.callee.*, "phys")) return false;
        if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedCEmission;
        try self.out.appendSlice(self.allocator, "((uintptr_t)(");
        try self.emitExpr(call.args[0], locals);
        try self.out.appendSlice(self.allocator, "))");
        return true;
    }

    fn emitReflectionCall(self: *CEmitter, call: anytype) !bool {
        const kind = reflectionCallKind(call.callee.*) orelse return false;
        if (call.type_args.len != 1) return error.UnsupportedCEmission;
        const target_ty = call.type_args[0];
        switch (kind) {
            .size => {
                if (call.args.len != 0) return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "((uintptr_t)sizeof({s}))", .{try self.reflectionCTypeFor(target_ty)});
                return true;
            },
            .alignment => {
                if (call.args.len != 0) return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "((uintptr_t)alignof({s}))", .{try self.reflectionCTypeFor(target_ty)});
                return true;
            },
            .field_offset => {
                if (call.args.len != 1) return error.UnsupportedCEmission;
                const field_name = reflectionFieldName(call.args[0]) orelse return error.UnsupportedCEmission;
                if (typeName(target_ty)) |type_name| {
                    if (self.overlay_unions.get(type_name)) |overlay| {
                        if (!overlay.fields.contains(field_name)) return error.UnsupportedCEmission;
                        try self.out.appendSlice(self.allocator, "((uintptr_t)0)");
                        return true;
                    }
                }
                try self.out.print(self.allocator, "((uintptr_t)offsetof({s}, {s}))", .{ try self.reflectionCTypeFor(target_ty), field_name });
                return true;
            },
            .bit_offset => {
                if (call.args.len != 1) return error.UnsupportedCEmission;
                const field_name = reflectionFieldName(call.args[0]) orelse return error.UnsupportedCEmission;
                const type_name = typeName(target_ty) orelse return error.UnsupportedCEmission;
                if (self.packed_bits.get(type_name)) |info| {
                    const field = info.fields.get(field_name) orelse return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, "((uintptr_t){d})", .{field.bit_index});
                    return true;
                }
                try self.out.print(self.allocator, "((uintptr_t)(offsetof({s}, {s}) * CHAR_BIT))", .{ try self.reflectionCTypeFor(target_ty), field_name });
                return true;
            },
            .repr => {
                if (call.args.len != 0) return error.UnsupportedCEmission;
                const type_name = typeName(target_ty) orelse return error.UnsupportedCEmission;
                if (self.enums.get(type_name)) |enum_decl| {
                    const repr = enum_decl.repr orelse simpleNameType("isize", target_ty.span);
                    try self.out.print(self.allocator, "((uintptr_t)sizeof({s}))", .{try self.reflectionCTypeFor(repr)});
                    return true;
                }
                if (self.packed_bits.get(type_name)) |info| {
                    try self.out.print(self.allocator, "((uintptr_t)sizeof({s}))", .{info.repr_c_type});
                    return true;
                }
                return error.UnsupportedCEmission;
            },
        }
    }

    fn reflectionCTypeFor(self: *CEmitter, ty: ast.TypeExpr) ![]const u8 {
        if (typeName(ty)) |name| {
            if (self.mmio_structs.contains(name)) return name;
        }
        if (ty.kind == .generic) {
            const generic = ty.kind.generic;
            if (std.mem.eql(u8, generic.base.text, "DmaBuf") and generic.args.len == 2) return "uintptr_t";
        }
        return try self.cTypeFor(ty, .typedef_name);
    }

    fn emitUncheckedCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const op = uncheckedNoOverflowCallOp(call) orelse return false;
        if (call.args.len != 2) return error.UnsupportedCEmission;

        try self.out.appendSlice(self.allocator, "(");
        try self.emitExpr(call.args[0], locals);
        try self.out.print(self.allocator, " {s} ", .{uncheckedNoOverflowOperator(op)});
        try self.emitExpr(call.args[1], locals);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    // `wrapping.add(a, b)` is explicit modular addition (no trap edge); it
    // lowers to plain C `+`, matching how `a + b` on `wrap<T>` operands already
    // emits (unsigned/two's-complement wraparound is well-defined).
    fn emitWrappingCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!isIdentNamed(member.base.*, "wrapping")) return false;
        if (!std.mem.eql(u8, member.name.text, "add")) return error.UnsupportedCEmission;
        if (call.args.len != 2) return error.UnsupportedCEmission;

        try self.out.appendSlice(self.allocator, "(");
        try self.emitExpr(call.args[0], locals);
        try self.out.appendSlice(self.allocator, " + ");
        try self.emitExpr(call.args[1], locals);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    // reduce.sum_checked<T>(xs) -> Result<T, Overflow> (section 8.2). Sum the
    // slice in a wide (`__int128`) accumulator, then range-check the final result
    // into T — distinct from stepwise checked addition, which would trap on an
    // intermediate overflow. Lowered as a GCC/Clang statement-expression so it is
    // a self-contained value; the slice is bound once to avoid double evaluation.
    fn emitReduceSumCheckedCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!isIdentNamed(member.base.*, "reduce")) return false;
        if (!std.mem.eql(u8, member.name.text, "sum_checked")) return error.UnsupportedCEmission;
        if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedCEmission;

        const t_ty = call.type_args[0];
        const t_cty = try self.cTypeFor(t_ty, .typedef_name);
        const int_name = self.underlyingIntTypeName(t_ty) orelse return error.UnsupportedCEmission;
        const range = intTypeRange(int_name) orelse return error.UnsupportedCEmission;
        const struct_name = try self.resultTypeName(t_ty, simpleNameType("Overflow", member.name.span));

        const n = self.temp_index;
        self.temp_index += 1;

        try self.out.print(self.allocator, "({{ __auto_type mc_xs{d} = (", .{n});
        try self.emitExpr(call.args[0], locals);
        try self.out.print(self.allocator, "); __int128 mc_acc{d} = 0; for (uintptr_t mc_i{d} = 0; mc_i{d} < mc_xs{d}.len; mc_i{d}++) mc_acc{d} += (__int128)mc_xs{d}.ptr[mc_i{d}]; ", .{ n, n, n, n, n, n, n, n });
        try self.out.print(self.allocator, "(mc_acc{d} < (__int128)({s}) || mc_acc{d} > (__int128)({s})) ? (({s}){{ .is_ok = false, .payload.err = 0 }}) : (({s}){{ .is_ok = true, .payload.ok = ({s})mc_acc{d} }}); }})", .{ n, range.c_min, n, range.c_max, struct_name, struct_name, t_cty, n });
        return true;
    }

    fn emitAssumeNoaliasCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        if (!isAssumeNoaliasCall(call)) return false;
        if (call.args.len != 2) return error.UnsupportedCEmission;

        try self.out.appendSlice(self.allocator, "((void)(");
        try self.emitExpr(call.args[1], locals);
        try self.out.appendSlice(self.allocator, "), ");
        try self.emitExpr(call.args[0], locals);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    // Payload type name of an `atomic<T>` local referenced by `expr`, or null
    // if `expr` is not such a local.
    fn atomicLocalPayload(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        const name = switch (expr.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| return self.atomicLocalPayload(inner.*, locals),
            // An atomic struct field (`lock.next` over `struct { next: atomic<T> }`):
            // resolve the field's declared type and unwrap the `atomic<>`.
            .member => {
                if (self.operandEmitType(expr, locals)) |field_ty| {
                    if (genericChildType(field_ty, "atomic")) |child| return typeName(child);
                }
                return null;
            },
            else => return null,
        };
        // A local atomic variable...
        if (locals) |local_set| {
            if (local_set.get(name)) |info| {
                if (info.source_ty) |source_ty| {
                    if (genericChildType(source_ty, "atomic")) |child| return typeName(child);
                }
            }
        }
        // ...or a global atomic (e.g. an interrupt-shared counter).
        if (self.globals.get(name)) |global| {
            if (global.source_ty) |source_ty| {
                if (genericChildType(source_ty, "atomic")) |child| return typeName(child);
            }
        }
        return null;
    }

    // Emit the address-of operand for an atomic op: the raw storage, so a global
    // atomic yields `&g` (not the relaxed-access wrapper a bare global read uses) and
    // an atomic struct field yields `&lock->next`.
    fn emitAtomicBaseAddr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| try self.out.appendSlice(self.allocator, ident.text),
            .grouped => |inner| try self.emitAtomicBaseAddr(inner.*, locals),
            .member => |m| {
                try self.emitAtomicBaseAddr(m.base.*, locals);
                try self.out.appendSlice(self.allocator, if (self.exprIsPointer(m.base.*, locals)) "->" else ".");
                try self.out.appendSlice(self.allocator, m.name.text);
            },
            else => return error.UnsupportedCEmission,
        }
    }

    // `atomic.init(v)` constructs an atomic with initial value `v`. The atomic
    // storage lowers to the plain payload object (operated on with `__atomic_*`
    // builtins), so construction is just the initial value.
    fn emitAtomicInitCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!isIdentNamed(member.base.*, "atomic")) return false;
        if (!std.mem.eql(u8, member.name.text, "init")) return false;
        if (call.args.len != 1) return false;
        try self.emitExpr(call.args[0], locals);
        return true;
    }

    // `obj.load/store/fetch_add(..., .ordering)` on an `atomic<T>` local lower to
    // the matching `__atomic_*` builtin on `&obj`, mirroring the inspector's
    // `atomics-lowering` facts (load_n / store_n / fetch_add).
    fn emitAtomicCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        const payload = self.atomicLocalPayload(member.base.*, locals) orelse return false;
        const op = member.name.text;
        if (std.mem.eql(u8, op, "load")) {
            const ordering = atomicOrderingArg(call.args, 0);
            if (!isAtomicLoadOrdering(ordering)) return false;
            const order_c = atomicOrderCConstant(ordering) orelse return false;
            try self.out.appendSlice(self.allocator, "__atomic_load_n(&");
            try self.emitAtomicBaseAddr(member.base.*, locals);
            try self.out.print(self.allocator, ", {s})", .{order_c});
            return true;
        }
        if (std.mem.eql(u8, op, "store")) {
            if (call.args.len < 1) return false;
            const ordering = atomicOrderingArg(call.args, 1);
            if (!isAtomicStoreOrdering(ordering)) return false;
            const order_c = atomicOrderCConstant(ordering) orelse return false;
            try self.out.appendSlice(self.allocator, "__atomic_store_n(&");
            try self.emitAtomicBaseAddr(member.base.*, locals);
            try self.out.appendSlice(self.allocator, ", ");
            try self.emitExpr(call.args[0], locals);
            try self.out.print(self.allocator, ", {s})", .{order_c});
            return true;
        }
        if (std.mem.eql(u8, op, "fetch_add") or std.mem.eql(u8, op, "fetch_sub")) {
            if (call.args.len < 1) return false;
            if (!isAtomicIntegerPayload(payload)) return false;
            const ordering = atomicOrderingArg(call.args, 1);
            const order_c = atomicOrderCConstant(ordering) orelse return false;
            const builtin = if (std.mem.eql(u8, op, "fetch_sub")) "__atomic_fetch_sub(&" else "__atomic_fetch_add(&";
            try self.out.appendSlice(self.allocator, builtin);
            try self.emitAtomicBaseAddr(member.base.*, locals);
            try self.out.appendSlice(self.allocator, ", ");
            try self.emitExpr(call.args[0], locals);
            try self.out.print(self.allocator, ", {s})", .{order_c});
            return true;
        }
        return false;
    }

    fn emitConstGetCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const info = constGetCallInfo(call) orelse return false;
        try self.emitExpr(info.base.*, locals);
        if (arrayElemsFieldForExpr(info.base.*, locals)) |elems_field| {
            try self.out.print(self.allocator, ".{s}", .{elems_field});
        }
        try self.out.print(self.allocator, "[{d}]", .{info.index});
        return true;
    }

    fn emitRawManyOffsetCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        if (call.type_args.len != 0) return false;
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!std.mem.eql(u8, member.name.text, "offset")) return false;
        if (call.args.len != 1) return error.UnsupportedCEmission;
        if (self.rawManyOffsetExprTypeForEmission(member.base.*, locals) == null) return false;

        try self.out.appendSlice(self.allocator, "(");
        try self.emitExpr(member.base.*, locals);
        try self.out.appendSlice(self.allocator, " + ");
        try self.emitExpr(call.args[0], locals);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    fn emitExprWithTarget(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!void {
        switch (expr.kind) {
            .array_literal => |items| {
                const target = target_ty orelse return error.UnsupportedCEmission;
                try self.emitArrayLiteral(items, locals, target);
            },
            .struct_literal => |fields| {
                const target = target_ty orelse return error.UnsupportedCEmission;
                if (try self.emitPackedBitsLiteral(fields, locals, target)) return;
                try self.emitStructLiteral(fields, locals, target);
            },
            .binary => |node| {
                if (try self.emitWrapBinaryWithTarget(node, locals, target_ty)) return;
                if (try self.emitSatBinaryWithTarget(node, locals, target_ty)) return;
                if (try self.emitCheckedBinaryWithTarget(node, locals, target_ty)) return;
                try self.emitExpr(expr, locals);
            },
            .unary => |node| {
                if (try self.emitCheckedUnaryWithTarget(node, locals, target_ty)) return;
                try self.emitExpr(expr, locals);
            },
            .call => |node| {
                if (target_ty) |ty| {
                    if (try self.emitResultConstructor(node, locals, ty)) return;
                    if (try self.emitTaggedUnionConstructor(node, locals, ty)) return;
                }
                try self.emitExpr(expr, locals);
            },
            .enum_literal => |literal| {
                const enum_name = if (target_ty) |ty| self.enumNameForType(ty) else null;
                if (enum_name) |name| return self.emitEnumLiteral(literal, name);
                try self.out.print(self.allocator, "/* unsupported enum literal: {s} */0", .{literal.text});
                return error.UnsupportedCEmission;
            },
            .string_literal => |literal| {
                // String literals require a target type (sema rejects targetless
                // ones). They lower to a C string literal cast to the target
                // pointer type, e.g. `*const u8` -> `(uint8_t const *)"…"`.
                const target = target_ty orelse return error.UnsupportedCEmission;
                if (!isStringLiteralTarget(self.resolveAliasType(target))) return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(target, .typedef_name)});
                try self.out.appendSlice(self.allocator, literal);
                try self.out.appendSlice(self.allocator, ")");
            },
            .grouped => |inner| {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExprWithTarget(inner.*, locals, target_ty);
                try self.out.appendSlice(self.allocator, ")");
            },
            else => try self.emitExpr(expr, locals),
        }
    }

    fn emitArrayLiteral(self: *CEmitter, items: []const ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void {
        const resolved_target_ty = self.resolveAliasType(target_ty);
        const child_ty = self.arrayChildTypeForResolvedTarget(resolved_target_ty) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "({s}){{ .elems = {{ ", .{try self.cTypeFor(resolved_target_ty, .typedef_name)});
        for (items, 0..) |item, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.emitExprWithTarget(item, locals, child_ty);
        }
        try self.out.appendSlice(self.allocator, " } }");
    }

    fn emitStructLiteral(self: *CEmitter, fields: []const ast.StructLiteralField, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void {
        const resolved_target_ty = self.resolveAliasType(target_ty);
        const struct_decl = self.structDeclForResolvedTarget(resolved_target_ty) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "({s}){{ ", .{try self.cTypeFor(resolved_target_ty, .typedef_name)});
        for (fields, 0..) |field, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
            try self.out.print(self.allocator, ".{s} = ", .{try self.cIdent(field.name.text)});
            try self.emitExprWithTarget(field.value, locals, field_ty);
        }
        try self.out.appendSlice(self.allocator, " }");
    }

    fn emitArrayLiteralWithTemps(self: *CEmitter, items: []const ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, temps: []const ?SequencedArgTemp) anyerror!void {
        const resolved_target_ty = self.resolveAliasType(target_ty);
        const child_ty = self.arrayChildTypeForResolvedTarget(resolved_target_ty) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "({s}){{ .elems = {{ ", .{try self.cTypeFor(resolved_target_ty, .typedef_name)});
        for (items, 0..) |item, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            if (i < temps.len) {
                if (temps[i]) |temp| {
                    try self.out.appendSlice(self.allocator, temp.name);
                    continue;
                }
            }
            try self.emitExprWithTarget(item, locals, child_ty);
        }
        try self.out.appendSlice(self.allocator, " } }");
    }

    fn emitStructLiteralWithTemps(self: *CEmitter, fields: []const ast.StructLiteralField, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, temps: []const ?SequencedArgTemp) anyerror!void {
        const resolved_target_ty = self.resolveAliasType(target_ty);
        const struct_decl = self.structDeclForResolvedTarget(resolved_target_ty) orelse return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "({s}){{ ", .{try self.cTypeFor(resolved_target_ty, .typedef_name)});
        for (fields, 0..) |field, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
            try self.out.print(self.allocator, ".{s} = ", .{try self.cIdent(field.name.text)});
            if (i < temps.len) {
                if (temps[i]) |temp| {
                    try self.out.appendSlice(self.allocator, temp.name);
                    continue;
                }
            }
            try self.emitExprWithTarget(field.value, locals, field_ty);
        }
        try self.out.appendSlice(self.allocator, " }");
    }

    fn arrayChildTypeForTarget(self: *CEmitter, target_ty: ast.TypeExpr) ?ast.TypeExpr {
        return self.arrayChildTypeForResolvedTarget(self.resolveAliasType(target_ty));
    }

    fn arrayChildTypeForResolvedTarget(self: *CEmitter, target_ty: ast.TypeExpr) ?ast.TypeExpr {
        _ = self;
        return switch (target_ty.kind) {
            .array => |node| node.child.*,
            .qualified => |node| switch (node.child.kind) {
                .array => |array_node| array_node.child.*,
                else => null,
            },
            else => null,
        };
    }

    fn structDeclForTarget(self: *CEmitter, target_ty: ast.TypeExpr) ?ast.StructDecl {
        return self.structDeclForResolvedTarget(self.resolveAliasType(target_ty));
    }

    fn structDeclForResolvedTarget(self: *CEmitter, target_ty: ast.TypeExpr) ?ast.StructDecl {
        const struct_name = structTypeName(target_ty) orelse return null;
        return self.structs.get(struct_name);
    }

    fn emitPackedBitsLiteral(self: *CEmitter, fields: []const ast.StructLiteralField, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!bool {
        const resolved_target_ty = self.resolveAliasType(target_ty);
        const packed_name = typeName(resolved_target_ty) orelse return false;
        const info = self.packed_bits.get(packed_name) orelse return false;
        try self.out.print(self.allocator, "({s})(", .{packed_name});
        if (fields.len == 0) {
            try self.out.print(self.allocator, "({s})0", .{packed_name});
        }
        for (fields, 0..) |field, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, " | ");
            const packed_field = info.fields.get(field.name.text) orelse return error.UnsupportedCEmission;
            const mask = try self.packedBitsMaskLiteral(info, packed_field.bit_index);
            try self.out.appendSlice(self.allocator, "(");
            try self.emitExprWithTarget(field.value, locals, simpleNameType("bool", field.value.span));
            try self.out.print(self.allocator, " ? {s} : ({s})0)", .{ mask, packed_name });
        }
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    fn emitWrapBinaryWithTarget(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
        const target = if (target_ty) |ty| self.resolveAliasType(ty) else return false;
        const inner = genericChildType(target, "wrap") orelse return false;
        const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
        if (unsignedTypeSuffix(inner_name) == null) return error.UnsupportedCEmission;

        switch (node.op) {
            .add, .sub, .mul, .bit_and, .bit_or, .bit_xor => {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExprWithTarget(node.left.*, locals, target);
                try self.out.print(self.allocator, " {s} ", .{binaryCOp(node.op)});
                try self.emitExprWithTarget(node.right.*, locals, target);
                try self.out.appendSlice(self.allocator, ")");
                return true;
            },
            .shl, .shr => {
                const suffix = unsignedTypeSuffix(inner_name) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "mc_wrap_{s}_{s}(", .{ if (node.op == .shl) "shl" else "shr", suffix });
                try self.emitExprWithTarget(node.left.*, locals, target);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitExprWithTarget(node.right.*, locals, target);
                try self.out.appendSlice(self.allocator, ")");
                return true;
            },
            .div, .mod => {
                const helper = checkedHelperParts(node.op, inner_name) orelse return error.UnsupportedCEmission;
                try self.out.print(self.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
                try self.emitExprWithTarget(node.left.*, locals, target);
                try self.out.appendSlice(self.allocator, ", ");
                try self.emitExprWithTarget(node.right.*, locals, target);
                try self.out.appendSlice(self.allocator, ")");
                return true;
            },
            else => return false,
        }
    }

    fn emitSatBinaryWithTarget(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
        const target = if (target_ty) |ty| self.resolveAliasType(ty) else return false;
        const inner = genericChildType(target, "sat") orelse return false;
        const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
        const helper = satHelperParts(node.op, inner_name) orelse return false;

        try self.out.print(self.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
        try self.emitExprWithTarget(node.left.*, locals, target);
        try self.out.appendSlice(self.allocator, ", ");
        try self.emitExprWithTarget(node.right.*, locals, target);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    fn emitCheckedBinaryWithTarget(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
        if (!isCheckedBinaryOp(node.op)) return false;
        // No target type (e.g. RHS of a `.member`/`.index` assignment): decline
        // so the caller falls through to the plain `emitExpr` path, which infers
        // the type from the operands.
        const target = if (target_ty) |ty| self.resolveAliasType(ty) else return false;
        if (isWrapType(target) or isSatType(target)) return false;
        const target_name = typeName(target) orelse return error.UnsupportedCEmission;

        // Value-range proof: constant operands that provably cannot overflow lower
        // to plain arithmetic with no overflow check.
        if (constBinaryProvenNoOverflow(node, target_name, locals)) {
            const cty = try self.cTypeFor(target, .typedef_name);
            try self.out.print(self.allocator, "(({s})(", .{cty});
            try self.emitExprWithTarget(node.left.*, locals, target);
            try self.out.print(self.allocator, " {s} ", .{binaryCOp(node.op)});
            try self.emitExprWithTarget(node.right.*, locals, target);
            try self.out.appendSlice(self.allocator, "))");
            return true;
        }

        const helper = checkedHelperParts(node.op, target_name) orelse return false;

        try self.out.print(self.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
        try self.emitExprWithTarget(node.left.*, locals, target);
        try self.out.appendSlice(self.allocator, ", ");
        try self.emitExprWithTarget(node.right.*, locals, target);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    fn emitCheckedUnaryWithTarget(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) !bool {
        if (node.op != .neg) return false;
        // No target type: decline so the caller falls through to `emitExpr`,
        // which infers the operand type.
        const target = if (target_ty) |ty| self.resolveAliasType(ty) else return false;
        if (isWrapType(target) or isSatType(target)) return false;
        const target_name = typeName(target) orelse return error.UnsupportedCEmission;
        const suffix = signedTypeSuffix(target_name) orelse return false;

        if (node.expr.kind == .int_literal) {
            try self.out.print(self.allocator, "(({s})-", .{try self.cTypeFor(target, .typedef_name)});
            try appendCIntLiteral(self.allocator, self.out, node.expr.kind.int_literal);
            try self.out.appendSlice(self.allocator, ")");
            return true;
        }

        try self.out.print(self.allocator, "mc_checked_neg_{s}(", .{suffix});
        try self.emitExprWithTarget(node.expr.*, locals, target);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    fn emitCheckedUnaryWithTryReplacements(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const TryReplacement) anyerror!bool {
        if (node.op != .neg) return false;
        const target = if (target_ty) |ty| self.resolveAliasType(ty) else return error.UnsupportedCEmission;
        if (isWrapType(target) or isSatType(target)) return false;
        const target_name = typeName(target) orelse return error.UnsupportedCEmission;
        const suffix = signedTypeSuffix(target_name) orelse return false;

        try self.out.print(self.allocator, "mc_checked_neg_{s}(", .{suffix});
        try self.emitResultTryExprWithReplacements(node.expr.*, locals, target, replacements);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    fn emitCheckedUnaryWithMmioReplacements(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const MmioReadReplacement) anyerror!bool {
        if (node.op != .neg) return false;
        const target = if (target_ty) |ty| self.resolveAliasType(ty) else return error.UnsupportedCEmission;
        if (isWrapType(target) or isSatType(target)) return false;
        const target_name = typeName(target) orelse return error.UnsupportedCEmission;
        const suffix = signedTypeSuffix(target_name) orelse return false;

        try self.out.print(self.allocator, "mc_checked_neg_{s}(", .{suffix});
        try self.emitMmioReadExprWithReplacements(node.expr.*, locals, target, replacements);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    fn emitCheckedUnaryWithNullableReplacements(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const TryReplacement) anyerror!bool {
        if (node.op != .neg) return false;
        const target = if (target_ty) |ty| self.resolveAliasType(ty) else return error.UnsupportedCEmission;
        if (isWrapType(target) or isSatType(target)) return false;
        const target_name = typeName(target) orelse return error.UnsupportedCEmission;
        const suffix = signedTypeSuffix(target_name) orelse return false;

        try self.out.print(self.allocator, "mc_checked_neg_{s}(", .{suffix});
        try self.emitNullableTryExprWithReplacements(node.expr.*, locals, target, replacements);
        try self.out.appendSlice(self.allocator, ")");
        return true;
    }

    fn emitResultConstructor(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
        const tag = calleeIdentName(call.callee.*) orelse return false;
        if (!std.mem.eql(u8, tag, "ok") and !std.mem.eql(u8, tag, "err")) return false;
        if (call.args.len != 1) return error.UnsupportedCEmission;
        const payload_ty = resultPayloadTypeForTag(target_ty, tag) orelse return false;
        const result_ty = try self.cTypeFor(target_ty, .typedef_name);

        try self.out.print(self.allocator, "(({s}){{ .is_ok = ", .{result_ty});
        try self.out.appendSlice(self.allocator, if (std.mem.eql(u8, tag, "ok")) "true, .payload.ok = " else "false, .payload.err = ");
        try self.emitExprWithTarget(call.args[0], locals, payload_ty);
        try self.out.appendSlice(self.allocator, " })");
        return true;
    }

    fn emitTaggedUnionConstructor(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
        const tag = calleeIdentName(call.callee.*) orelse return false;
        const union_name = typeName(target_ty) orelse return false;
        const union_decl = self.tagged_unions.get(union_name) orelse return false;
        const case = taggedUnionCase(union_decl, tag) orelse return false;
        const c_union_ty = try self.cTypeFor(target_ty, .typedef_name);

        if (case.ty) |payload_ty| {
            if (call.args.len != 1) return error.UnsupportedCEmission;
            try self.out.print(self.allocator, "(({s}){{ .tag = {s}Tag_{s}, .payload.{s} = ", .{
                c_union_ty,
                union_name,
                tag,
                try self.cPayloadFieldName(tag),
            });
            try self.emitExprWithTarget(call.args[0], locals, payload_ty);
            try self.out.appendSlice(self.allocator, " })");
            return true;
        }

        if (call.args.len != 0) return error.UnsupportedCEmission;
        try self.out.print(self.allocator, "(({s}){{ .tag = {s}Tag_{s} }})", .{ c_union_ty, union_name, tag });
        return true;
    }

    fn enumNameForType(self: *CEmitter, ty: ast.TypeExpr) ?[]const u8 {
        const name = typeName(ty) orelse return null;
        return if (self.enums.contains(name)) name else null;
    }

    fn emitEnumLiteral(self: *CEmitter, literal: ast.Ident, enum_name: []const u8) !void {
        try self.out.print(self.allocator, "{s}_{s}", .{ enum_name, literal.text });
    }

    fn emitPackedBitsMember(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) !bool {
        const base_ty = self.packedBitsNameForExpr(node.base.*, locals) orelse return false;
        const info = self.packed_bits.get(base_ty) orelse return false;
        const field = info.fields.get(node.name.text) orelse return false;
        try self.emitPackedBitsMaskTest(node.base.*, locals, info, field.bit_index);
        return true;
    }

    fn emitPackedBitsMaskTest(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), info: PackedBitsInfo, bit_index: usize) !void {
        try self.out.appendSlice(self.allocator, "((");
        try self.emitExpr(base, locals);
        try self.out.print(self.allocator, " & {s}) != 0)", .{try self.packedBitsMaskLiteral(info, bit_index)});
    }

    fn emitPackedBitsMaskTestWithMmioReplacements(self: *CEmitter, base: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), info: PackedBitsInfo, bit_index: usize, replacements: []const MmioReadReplacement) !void {
        try self.out.appendSlice(self.allocator, "((");
        try self.emitMmioReadExprWithReplacements(base, locals, null, replacements);
        try self.out.print(self.allocator, " & {s}) != 0)", .{try self.packedBitsMaskLiteral(info, bit_index)});
    }

    fn emitPackedBitsFieldWriteStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const member = switch (assignment.target.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return false,
            },
            else => return false,
        };
        const base_ty = self.packedBitsNameForExpr(member.base.*, locals) orelse return false;
        const info = self.packed_bits.get(base_ty) orelse return false;
        const field = info.fields.get(member.name.text) orelse return false;
        const mask = try self.packedBitsMaskLiteral(info, field.bit_index);
        if (self.packedBitsGlobalBase(member.base.*, locals, base_ty)) |global_name| {
            const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
            self.temp_index += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = ({s})mc_race_load_{s}(&{s});\n", .{ base_ty, temp_name, base_ty, info.repr_name, global_name });
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} = ({s})(({s} & ({s})~{s}) | (", .{ temp_name, base_ty, temp_name, base_ty, mask });
            try self.emitExpr(assignment.value, locals);
            try self.out.print(self.allocator, " ? {s} : ({s})0));\n", .{ mask, base_ty });
            try self.writeIndent();
            try self.out.print(self.allocator, "mc_race_store_{s}(&{s}, ({s}){s});\n", .{ info.repr_name, global_name, info.repr_c_type, temp_name });
            return true;
        }

        try self.writeIndent();
        try self.emitExpr(member.base.*, locals);
        try self.out.print(self.allocator, " = ({s})((", .{base_ty});
        try self.emitExpr(member.base.*, locals);
        try self.out.print(self.allocator, " & ({s})~{s}) | (", .{ base_ty, mask });
        try self.emitExpr(assignment.value, locals);
        try self.out.print(self.allocator, " ? {s} : ({s})0));\n", .{ mask, base_ty });
        return true;
    }

    fn packedBitsNameForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| if (locals) |local_set| blk: {
                if (local_set.get(ident.text)) |info| break :blk info.source_type_name;
                if (self.globals.get(ident.text)) |global| break :blk global.type_name;
                break :blk null;
            } else null,
            .grouped => |inner| self.packedBitsNameForExpr(inner.*, locals),
            else => null,
        };
    }

    fn packedBitsGlobalBase(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), base_ty: []const u8) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| {
                if (locals.contains(ident.text)) return null;
                const global = self.globals.get(ident.text) orelse return null;
                return if (std.mem.eql(u8, global.type_name, base_ty)) ident.text else null;
            },
            .grouped => |inner| self.packedBitsGlobalBase(inner.*, locals, base_ty),
            else => null,
        };
    }

    fn packedBitsMaskLiteral(self: *CEmitter, info: PackedBitsInfo, bit_index: usize) ![]const u8 {
        if (std.mem.eql(u8, info.repr_name, "u8")) return std.fmt.allocPrint(self.scratch.allocator(), "UINT8_C({d})", .{@as(u64, 1) << @intCast(bit_index)});
        if (std.mem.eql(u8, info.repr_name, "u16")) return std.fmt.allocPrint(self.scratch.allocator(), "UINT16_C({d})", .{@as(u64, 1) << @intCast(bit_index)});
        if (std.mem.eql(u8, info.repr_name, "u32")) return std.fmt.allocPrint(self.scratch.allocator(), "UINT32_C({d})", .{@as(u64, 1) << @intCast(bit_index)});
        if (std.mem.eql(u8, info.repr_name, "u64")) return std.fmt.allocPrint(self.scratch.allocator(), "UINT64_C({d})", .{@as(u64, 1) << @intCast(bit_index)});
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{@as(u64, 1) << @intCast(bit_index)});
    }

    fn globalAssignmentTarget(self: *CEmitter, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        return switch (target.kind) {
            .ident => |ident| if (!locals.contains(ident.text))
                if (self.globals.get(ident.text)) |global| .{ .name = ident.text, .info = global } else null
            else
                null,
            .member => |member| self.globalMemberAccess(member, locals),
            .grouped => |inner| self.globalAssignmentTarget(inner.*, locals),
            else => null,
        };
    }

    fn globalMemberAccess(self: *CEmitter, member: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?GlobalAccess {
        const base_ident = switch (member.base.kind) {
            .ident => |ident| ident,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident,
                else => return null,
            },
            else => return null,
        };
        if (locals) |local_set| if (local_set.contains(base_ident.text)) return null;
        const global = self.globals.get(base_ident.text) orelse return null;
        const struct_decl = self.structs.get(global.type_name) orelse return null;
        for (struct_decl.fields) |field| {
            if (!std.mem.eql(u8, field.name.text, member.name.text)) continue;
            const info = self.globalInfoFromType(field.ty) catch return null;
            return .{
                .name = std.fmt.allocPrint(self.scratch.allocator(), "{s}.{s}", .{ base_ident.text, member.name.text }) catch return null,
                .info = info,
            };
        }
        return null;
    }

    fn globalArrayElementAccess(self: *CEmitter, index: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?GlobalArrayElementAccess {
        const base_ident = switch (index.base.kind) {
            .ident => |ident| ident,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident,
                else => return null,
            },
            else => return null,
        };
        if (locals) |local_set| if (local_set.contains(base_ident.text)) return null;
        const global = self.globals.get(base_ident.text) orelse return null;
        const element_info = global.array_element_info orelse return null;
        const len = global.array_len orelse return null;
        return .{
            .base_name = base_ident.text,
            .index = index.index.*,
            .len = len,
            .element_info = element_info,
        };
    }

    fn emitGlobalArrayElementLoadExpr(self: *CEmitter, access: GlobalArrayElementAccess, locals: ?*std.StringHashMap(LocalInfo)) !void {
        if (access.element_info.aggregate) {
            // Plain aggregate read: no scalar race helper exists for a struct/closure.
            try self.out.print(self.allocator, "({s}.elems[mc_check_index_usize(", .{access.base_name});
            try self.emitExpr(access.index, locals);
            try self.out.print(self.allocator, ", {s})])", .{access.len});
            return;
        }
        if (access.element_info.pointer_like) {
            try self.out.print(self.allocator, "(({s})__atomic_load_n(&{s}.elems[mc_check_index_usize(", .{ access.element_info.c_type, access.base_name });
            try self.emitExpr(access.index, locals);
            try self.out.print(self.allocator, ", {s})], __ATOMIC_RELAXED))", .{access.len});
            return;
        }
        try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&{s}.elems[mc_check_index_usize(", .{ access.element_info.c_type, access.element_info.race_type_name, access.base_name });
        try self.emitExpr(access.index, locals);
        try self.out.print(self.allocator, ", {s})]))", .{access.len});
    }

    fn emitGlobalArrayIndexAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const index = switch (assignment.target.kind) {
            .index => |node| node,
            .grouped => |inner| return try self.emitGlobalArrayIndexAssignmentStmt(.{ .target = inner.*, .value = assignment.value }, locals),
            else => return false,
        };
        const access = self.globalArrayElementAccess(index, locals) orelse return false;
        const index_temp = try self.emitSequencedCallArgTemp(access.index, locals, simpleNameType("usize", access.index.span));
        const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, access.element_info.source_ty);
        try self.writeIndent();
        if (access.element_info.aggregate) {
            // Plain aggregate store: a struct/closure element has no scalar race helper.
            try self.out.print(
                self.allocator,
                "{s}.elems[mc_check_index_usize({s}, {s})] = ({s}){s};\n",
                .{ access.base_name, index_temp.name, access.len, access.element_info.c_type, value_temp.name },
            );
            return true;
        }
        if (access.element_info.pointer_like) {
            try self.out.print(
                self.allocator,
                "__atomic_store_n(&{s}.elems[mc_check_index_usize({s}, {s})], ({s}){s}, __ATOMIC_RELAXED);\n",
                .{ access.base_name, index_temp.name, access.len, access.element_info.c_type, value_temp.name },
            );
            return true;
        }
        try self.out.print(
            self.allocator,
            "mc_race_store_{s}(&{s}.elems[mc_check_index_usize({s}, {s})], ({s}){s});\n",
            .{ access.element_info.race_type_name, access.base_name, index_temp.name, access.len, access.element_info.race_c_type, value_temp.name },
        );
        return true;
    }

    fn emitGlobalLoadExpr(self: *CEmitter, name: []const u8, global: GlobalInfo) !void {
        if (global.aggregate) {
            try self.out.print(self.allocator, "({s})", .{name}); // plain struct read (copy)
        } else if (global.pointer_like) {
            try self.out.print(self.allocator, "(({s})__atomic_load_n(&{s}, __ATOMIC_RELAXED))", .{ global.c_type, name });
        } else {
            try self.out.print(self.allocator, "(({s})mc_race_load_{s}(&{s}))", .{ global.c_type, global.race_type_name, name });
        }
    }

    fn emitGlobalStorePrefix(self: *CEmitter, target: GlobalAccess) !void {
        if (target.info.aggregate) {
            try self.out.print(self.allocator, "{s} = ({s})(", .{ target.name, target.info.c_type }); // plain struct copy
        } else if (target.info.pointer_like) {
            try self.out.print(self.allocator, "__atomic_store_n(&{s}, ({s})", .{ target.name, target.info.c_type });
        } else {
            try self.out.print(self.allocator, "mc_race_store_{s}(&{s}, ({s})", .{ target.info.race_type_name, target.name, target.info.race_c_type });
        }
    }

    fn emitGlobalStoreSuffix(self: *CEmitter, target: GlobalAccess) !void {
        if (target.info.aggregate) {
            try self.out.appendSlice(self.allocator, ");\n");
        } else if (target.info.pointer_like) {
            try self.out.appendSlice(self.allocator, ", __ATOMIC_RELAXED);\n");
        } else {
            try self.out.appendSlice(self.allocator, ");\n");
        }
    }

    fn emitGlobalStoreValue(self: *CEmitter, target: GlobalAccess, value: []const u8) !void {
        try self.emitGlobalStorePrefix(target);
        try self.out.appendSlice(self.allocator, value);
        try self.emitGlobalStoreSuffix(target);
    }

    fn emitStaticCInitializer(self: *CEmitter, expr: ast.Expr) !bool {
        switch (expr.kind) {
            .grouped => |inner| {
                if (!isDirectStaticCInitializer(inner.*)) return false;
                try self.out.appendSlice(self.allocator, "(");
                if (!try self.emitStaticCInitializer(inner.*)) return false;
                try self.out.appendSlice(self.allocator, ")");
                return true;
            },
            .unary => |node| {
                if (node.op != .neg) return false;
                const literal = switch (node.expr.kind) {
                    .int_literal => |value| value,
                    else => return false,
                };
                try self.out.appendSlice(self.allocator, "-");
                try appendCIntLiteral(self.allocator, self.out, literal);
                return true;
            },
            else => return false,
        }
    }

    fn staticCInitializer(self: *CEmitter, expr: ast.Expr) ?ast.Expr {
        return switch (expr.kind) {
            .ident => |ident| self.static_initializers.get(ident.text),
            .grouped => |inner| if (self.staticCInitializer(inner.*)) |resolved| resolved else if (isStaticCInitializer(expr)) expr else null,
            // `atomic.init(X)` initializes the underlying scalar directly (an
            // `atomic<u32>` lowers to `uint32_t`), so a global atomic seeds from X.
            .call => |node| if (isAtomicInitCallee(node.callee.*) and node.args.len == 1) self.staticCInitializer(node.args[0]) else null,
            else => if (isStaticCInitializer(expr)) expr else null,
        };
    }

    fn isAtomicInitCallee(callee: ast.Expr) bool {
        return switch (callee.kind) {
            .member => |m| isIdentNamed(m.base.*, "atomic") and std.mem.eql(u8, m.name.text, "init"),
            .grouped => |inner| isAtomicInitCallee(inner.*),
            else => false,
        };
    }

    fn assignmentTargetType(self: *CEmitter, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        // Resolves a local, a struct field, or an array element (`a.b[i].c`), so an
        // assignment's value gets the right target type (e.g. an enum-literal RHS).
        return self.operandEmitType(target, locals);
    }

    fn enumNameForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (local_set.get(ident.text)) |info| {
                        if (info.source_type_name) |name| if (self.enums.contains(name)) return name;
                    }
                }
                return null;
            },
            .grouped => |inner| self.enumNameForExpr(inner.*, locals),
            else => null,
        };
    }

    fn exprIsBoolForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .bool_literal => true,
            .ident => |ident| {
                if (locals) |local_set| {
                    if (local_set.get(ident.text)) |info| {
                        if (info.source_ty) |ty| return isBoolType(ty);
                    }
                }
                if (self.globals.get(ident.text)) |global| {
                    if (global.source_ty) |ty| return isBoolType(ty);
                }
                return false;
            },
            .call => if (self.callReturnTypeForExpr(expr, locals)) |ty| isBoolType(ty) else false,
            // A bool-typed struct field — including a field of an array element
            // (`table[i].used`), resolved through operandEmitType so a `switch` on it
            // is cast to int (no -Wswitch-bool).
            .member => {
                if (self.operandEmitType(expr, locals)) |ty| return isBoolType(self.resolveAliasType(ty));
                return false;
            },
            .grouped => |inner| self.exprIsBoolForEmission(inner.*, locals),
            // Comparison / logical operators produce a C bool; mark them so a
            // `switch a < b { … }` casts the subject to int and gets a trap
            // default (avoiding -Wswitch-bool / -Wreturn-type).
            .binary => |node| switch (node.op) {
                .eq, .ne, .lt, .le, .gt, .ge, .logical_and, .logical_or => true,
                else => false,
            },
            .unary => |node| node.op == .logical_not,
            else => false,
        };
    }

    fn enumNameForValueExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (local_set.get(ident.text)) |info| {
                        if (info.source_type_name) |name| if (self.enums.contains(name)) return name;
                    }
                }
                if (self.globals.get(ident.text)) |global| {
                    if (self.enums.contains(global.type_name)) return global.type_name;
                }
                return null;
            },
            .call => |node| blk: {
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                const ret_ty = info.return_type orelse break :blk null;
                const name = typeName(ret_ty) orelse break :blk null;
                break :blk if (self.enums.contains(name)) name else null;
            },
            .cast => |node| {
                const name = typeName(node.ty.*) orelse return null;
                return if (self.enums.contains(name)) name else null;
            },
            .grouped => |inner| self.enumNameForValueExpr(inner.*, locals),
            else => null,
        };
    }

    fn emitOverlayFieldReadReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        switch (expr.kind) {
            .grouped => |inner| return try self.emitOverlayFieldReadReturn(inner.*, locals, return_ty),
            .member => |node| {
                const access = self.overlayFieldAccess(node, locals) orelse return false;
                if (access.field.byte_array_len != null) return false;
                const temp_ty = if (return_ty) |ty| ty else access.field.ty;
                const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
                self.temp_index += 1;

                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s};\n", .{ try self.cTypeFor(temp_ty, .typedef_name), temp_name });
                try self.writeIndent();
                try self.out.print(self.allocator, "__builtin_memcpy(&{s}, ", .{temp_name});
                try self.emitExpr(access.base, locals);
                try self.out.print(self.allocator, ".storage, {d});\n", .{access.field.layout.size});
                try self.writeIndent();
                try self.out.print(self.allocator, "return {s};\n", .{temp_name});
                return true;
            },
            .index => |node| {
                const member = switch (node.base.kind) {
                    .member => |member| member,
                    .grouped => |inner| switch (inner.kind) {
                        .member => |member| member,
                        else => return false,
                    },
                    else => return false,
                };
                const access = self.overlayFieldAccess(member, locals) orelse return false;
                const len = access.field.byte_array_len orelse return false;

                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "return ");
                try self.emitExpr(access.base, locals);
                try self.out.appendSlice(self.allocator, ".storage[mc_check_index_usize(");
                try self.emitExpr(node.index.*, locals);
                try self.out.print(self.allocator, ", {s})];\n", .{len});
                return true;
            },
            else => return false,
        }
    }

    fn emitOverlayFieldWriteStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        switch (assignment.target.kind) {
            .grouped => |inner| return try self.emitOverlayFieldWriteStmt(.{ .target = inner.*, .value = assignment.value }, locals),
            .member => |node| {
                const access = self.overlayFieldAccess(node, locals) orelse return false;
                if (access.field.byte_array_len != null) return false;
                const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
                self.temp_index += 1;

                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(access.field.ty, .typedef_name), temp_name });
                try self.emitExprWithTarget(assignment.value, locals, access.field.ty);
                try self.out.appendSlice(self.allocator, ";\n");

                try self.writeIndent();
                try self.out.print(self.allocator, "__builtin_memcpy(", .{});
                try self.emitExpr(access.base, locals);
                try self.out.print(self.allocator, ".storage, &{s}, {d});\n", .{ temp_name, access.field.layout.size });
                return true;
            },
            .index => |node| {
                const member = overlayMemberFromIndexBase(node.base.*) orelse return false;
                const access = self.overlayFieldAccess(member, locals) orelse return false;
                const len = access.field.byte_array_len orelse return false;
                const element_ty = overlayByteArrayElementType(access.field.ty) orelse return false;

                try self.writeIndent();
                try self.emitExpr(access.base, locals);
                try self.out.appendSlice(self.allocator, ".storage[mc_check_index_usize(");
                try self.emitExpr(node.index.*, locals);
                try self.out.print(self.allocator, ", {s})] = ", .{len});
                try self.emitExprWithTarget(assignment.value, locals, element_ty);
                try self.out.appendSlice(self.allocator, ";\n");
                return true;
            },
            else => return false,
        }
    }

    fn emitDirectCallSliceIndexReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const value_temp = (try self.emitDirectCallSliceIndexValueTemp(expr, locals, null)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{value_temp.name});
        return true;
    }

    fn emitDirectCallSliceIndexLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const value_temp = (try self.emitDirectCallSliceIndexValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        return true;
    }

    fn emitDirectCallSliceIndexAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = self.assignmentTargetType(assignment.target, locals) orelse blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const value_temp = (try self.emitDirectCallSliceIndexValueTemp(assignment.value, locals, target_ty)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, value_temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        }
        return true;
    }

    fn emitDirectCallSliceIndexValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!?SequencedArgTemp {
        const index = switch (expr.kind) {
            .index => |node| node,
            .grouped => |inner| return try self.emitDirectCallSliceIndexValueTemp(inner.*, locals, target_ty),
            else => return null,
        };
        const call = switch (index.base.kind) {
            .call => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .call => |node| node,
                else => return null,
            },
            else => return null,
        };
        const slice_ty = self.sliceReturnTypeForCall(call) orelse return null;
        const slice_temp = try self.emitSequencedCallArgTemp(index.base.*, locals, slice_ty);
        const usize_ty = simpleNameType("usize", index.index.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        const value_ty = target_ty orelse sliceElementType(slice_ty) orelse return error.UnsupportedCEmission;
        const value_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}.ptr[mc_check_index_usize({s}, {s}.len)];\n", .{
            try self.cTypeFor(value_ty, .typedef_name),
            value_temp,
            slice_temp.name,
            index_temp.name,
            slice_temp.name,
        });
        return .{ .name = value_temp, .ty = value_ty };
    }

    fn emitDirectCallArrayIndexReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const value_temp = (try self.emitDirectCallArrayIndexValueTemp(expr, locals, null)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{value_temp.name});
        return true;
    }

    fn emitDirectCallArrayIndexLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const value_temp = (try self.emitDirectCallArrayIndexValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        return true;
    }

    fn emitDirectCallArrayIndexAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = self.assignmentTargetType(assignment.target, locals) orelse blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const value_temp = (try self.emitDirectCallArrayIndexValueTemp(assignment.value, locals, target_ty)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, value_temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        }
        return true;
    }

    fn emitDirectCallArrayIndexValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!?SequencedArgTemp {
        const index = switch (expr.kind) {
            .index => |node| node,
            .grouped => |inner| return try self.emitDirectCallArrayIndexValueTemp(inner.*, locals, target_ty),
            else => return null,
        };
        const array_ty = self.arrayReturnTypeForExpr(index.base.*) orelse return null;
        const element_ty = target_ty orelse arrayElementType(array_ty) orelse return error.UnsupportedCEmission;
        const len = (try self.arrayLenText(array_ty)) orelse return error.UnsupportedCEmission;

        const array_temp = try self.emitSequencedCallArgTemp(index.base.*, locals, array_ty);
        const usize_ty = simpleNameType("usize", index.index.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        const value_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s}.elems[mc_check_index_usize({s}, {s})];\n", .{
            try self.cTypeFor(element_ty, .typedef_name),
            value_temp,
            array_temp.name,
            index_temp.name,
            len,
        });
        return .{ .name = value_temp, .ty = element_ty };
    }

    fn emitLocalIndexReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const value_temp = (try self.emitLocalIndexValueTemp(expr, locals, return_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{value_temp.name});
        return true;
    }

    fn emitLocalIndexLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const value_temp = (try self.emitLocalIndexValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        return true;
    }

    fn emitLocalIndexAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = self.assignmentTargetType(assignment.target, locals) orelse blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const value_temp = (try self.emitLocalIndexValueTemp(assignment.value, locals, target_ty)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, value_temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        }
        return true;
    }

    fn emitLocalIndexTargetAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const index = switch (assignment.target.kind) {
            .index => |node| node,
            .grouped => |inner| return try self.emitLocalIndexTargetAssignmentStmt(.{ .target = inner.*, .value = assignment.value }, locals),
            else => return false,
        };
        if (!exprContainsCall(index.index.*) and !exprContainsCall(assignment.value)) return false;
        const element_ty = localIndexElementType(index.base.*, locals) orelse return false;

        const usize_ty = simpleNameType("usize", index.index.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, element_ty);

        try self.writeIndent();
        if (sliceAccessForExpr(index.base.*, locals)) |slice| {
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp.name });
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s})] = {s};\n", .{ slice.len_field, value_temp.name });
            return true;
        }

        if (arrayLenForExpr(index.base.*, locals)) |len| {
            try self.emitExpr(index.base.*, locals);
            if (arrayElemsFieldForExpr(index.base.*, locals)) |elems_field| {
                try self.out.print(self.allocator, ".{s}", .{elems_field});
            }
            try self.out.print(self.allocator, "[mc_check_index_usize({s}, {s})] = {s};\n", .{ index_temp.name, len, value_temp.name });
            return true;
        }

        return false;
    }

    fn emitLocalIndexAddressReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const value_temp = (try self.emitLocalIndexAddressValueTemp(expr, locals, target_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{value_temp.name});
        return true;
    }

    fn emitLocalIndexAddressLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const value_temp = (try self.emitLocalIndexAddressValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        return true;
    }

    fn emitLocalIndexAddressAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = self.assignmentTargetType(assignment.target, locals) orelse blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const value_temp = (try self.emitLocalIndexAddressValueTemp(assignment.value, locals, target_ty)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, value_temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{value_temp.name});
        }
        return true;
    }

    fn emitLocalIndexAddressValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const operand = switch (expr.kind) {
            .address_of => |inner| inner.*,
            .grouped => |inner| return try self.emitLocalIndexAddressValueTemp(inner.*, locals, target_ty),
            else => return null,
        };
        const index = switch (operand.kind) {
            .index => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .index => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!exprContainsCall(index.index.*)) return null;
        if (localIndexElementType(index.base.*, locals) == null) return null;

        const usize_ty = simpleNameType("usize", index.index.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        const value_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = &", .{ try self.cTypeFor(target_ty, .typedef_name), value_temp });
        if (sliceAccessForExpr(index.base.*, locals)) |slice| {
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp.name });
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s})];\n", .{slice.len_field});
            return .{ .name = value_temp, .ty = target_ty };
        }

        if (arrayLenForExpr(index.base.*, locals)) |len| {
            try self.emitExpr(index.base.*, locals);
            if (arrayElemsFieldForExpr(index.base.*, locals)) |elems_field| {
                try self.out.print(self.allocator, ".{s}", .{elems_field});
            }
            try self.out.print(self.allocator, "[mc_check_index_usize({s}, {s})];\n", .{ index_temp.name, len });
            return .{ .name = value_temp, .ty = target_ty };
        }

        return null;
    }

    fn emitLocalIndexValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr) anyerror!?SequencedArgTemp {
        const index = switch (expr.kind) {
            .index => |node| node,
            .grouped => |inner| return try self.emitLocalIndexValueTemp(inner.*, locals, target_ty),
            else => return null,
        };
        if (!exprContainsCall(index.index.*)) return null;

        const element_ty = target_ty orelse localIndexElementType(index.base.*, locals) orelse return error.UnsupportedCEmission;
        const usize_ty = simpleNameType("usize", index.index.span);
        const index_temp = try self.emitSequencedCallArgTemp(index.index.*, locals, usize_ty);
        const value_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        if (sliceAccessForExpr(index.base.*, locals)) |slice| {
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(element_ty, .typedef_name), value_temp });
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s}[mc_check_index_usize({s}, ", .{ slice.ptr_field, index_temp.name });
            try self.emitExpr(index.base.*, locals);
            try self.out.print(self.allocator, ".{s})];\n", .{slice.len_field});
            return .{ .name = value_temp, .ty = element_ty };
        }

        if (arrayLenForExpr(index.base.*, locals)) |len| {
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(element_ty, .typedef_name), value_temp });
            try self.emitExpr(index.base.*, locals);
            if (arrayElemsFieldForExpr(index.base.*, locals)) |elems_field| {
                try self.out.print(self.allocator, ".{s}", .{elems_field});
            }
            try self.out.print(self.allocator, "[mc_check_index_usize({s}, {s})];\n", .{ index_temp.name, len });
            return .{ .name = value_temp, .ty = element_ty };
        }

        return null;
    }

    fn emitArrayCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const array_ty = self.arrayReturnTypeForExpr(initializer) orelse return false;
        try locals.put(name, try self.localInfoFromType(array_ty));
        try self.emitInferredCallLocalInitValue(name, array_ty, initializer, locals);
        return true;
    }

    fn emitSliceCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (initializer.kind) {
            .call => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .call => |node| node,
                else => return false,
            },
            else => return false,
        };
        const slice_ty = self.sliceReturnTypeForCall(call) orelse return false;
        try locals.put(name, try self.localInfoFromType(slice_ty));
        try self.emitInferredCallLocalInitValue(name, slice_ty, initializer, locals);
        return true;
    }

    fn emitEnumCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const enum_ty = self.enumReturnTypeForExpr(initializer) orelse return false;
        try locals.put(name, try self.localInfoFromType(enum_ty));
        try self.emitInferredCallLocalInitValue(name, enum_ty, initializer, locals);
        return true;
    }

    fn emitTaggedUnionCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const union_ty = self.taggedUnionReturnTypeForExpr(initializer) orelse return false;
        try locals.put(name, try self.localInfoFromType(union_ty));
        try self.emitInferredCallLocalInitValue(name, union_ty, initializer, locals);
        return true;
    }

    fn emitResultCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const result_ty = self.resultTypeForExpr(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(result_ty));
        try self.emitInferredCallLocalInitValue(name, result_ty, initializer, locals);
        return true;
    }

    fn emitNullableCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const nullable_ty = self.nullableReturnTypeForExpr(initializer) orelse return false;
        try locals.put(name, try self.localInfoFromType(nullable_ty));
        try self.emitInferredCallLocalInitValue(name, nullable_ty, initializer, locals);
        return true;
    }

    fn emitInferredCallLocalInitValue(self: *CEmitter, name: []const u8, inferred_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !void {
        if (try self.emitSequencedCallLocalInit(name, inferred_ty, initializer, locals)) return;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(initializer, locals);
        try self.out.appendSlice(self.allocator, ";\n");
    }

    fn emitLocalCopyInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const inferred_ty = localCopyTypeForInitializer(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(inferred_ty));

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitNumericInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const inferred_ty = self.numericExprTypeForEmission(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(inferred_ty));

        if (try self.emitSequencedCheckedBinaryLocalInit(name, inferred_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(inferred_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExprWithTarget(initializer, locals, inferred_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn numericExprTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (local_set.get(ident.text)) |info| {
                        const source_ty = info.source_ty orelse return null;
                        return if (isNumericStorageType(source_ty)) source_ty else null;
                    }
                }
                // A `const` global (e.g. `IPV4_HDR_LEN`) used in checked arithmetic
                // recovers its declared type so `(GLOBAL + x) as T` lowers checked.
                if (self.globals.get(ident.text)) |global| {
                    const source_ty = global.source_ty orelse return null;
                    return if (isNumericStorageType(source_ty)) source_ty else null;
                }
                return null;
            },
            .call => {
                const return_ty = self.callReturnTypeForExpr(expr, locals) orelse return null;
                return if (isNumericStorageType(return_ty)) return_ty else null;
            },
            // A numeric struct field (`s.len`) recovers its declared type, so
            // `s.len + 1` and similar lower through the checked helper.
            .member => |node| {
                const struct_name = self.structTypeNameForExpr(node.base.*, locals) orelse return null;
                const struct_decl = self.structs.get(struct_name) orelse return null;
                for (struct_decl.fields) |field| {
                    if (std.mem.eql(u8, field.name.text, node.name.text)) {
                        const resolved = self.resolveAliasType(field.ty);
                        return if (isNumericStorageType(resolved)) resolved else null;
                    }
                }
                return null;
            },
            .index => |node| {
                const elem = self.arrayTypeForExpr(node.base.*, locals) orelse return null;
                const resolved = self.resolveAliasType(elem.kind.array.child.*);
                return if (isNumericStorageType(resolved)) resolved else null;
            },
            // `p.*` over `p: *T` recovers `T`, so `p.* + 1` lowers checked.
            .deref => |inner| {
                const pointee = self.derefPointeeType(inner.*, locals) orelse return null;
                const resolved = self.resolveAliasType(pointee);
                return if (isNumericStorageType(resolved)) resolved else null;
            },
            // A cast's result type is its target type, so `(x as u32) << 8` and
            // similar recover their width.
            .cast => |node| {
                const resolved = self.resolveAliasType(node.ty.*);
                return if (isNumericStorageType(resolved)) resolved else null;
            },
            .grouped => |inner| self.numericExprTypeForEmission(inner.*, locals),
            .unary => |node| self.numericExprTypeForEmission(node.expr.*, locals),
            .binary => |node| {
                if (!isNumericValueBinaryOp(node.op)) return null;
                const left_ty = self.numericExprTypeForEmission(node.left.*, locals);
                // A shift's result type is the left (shifted) operand's type; the
                // shift amount may be a different width (`u64 >> u32`), so it does
                // not have to match.
                if (node.op == .shl or node.op == .shr) return left_ty;
                const right_ty = self.numericExprTypeForEmission(node.right.*, locals);
                if (left_ty != null and right_ty != null) {
                    return if (sameCStorageType(left_ty.?, right_ty.?)) left_ty else null;
                }
                // A bare numeric literal adopts its sibling operand's storage
                // type, so `i + 1` resolves to `i`'s type (e.g. as a comparison
                // or loop-condition operand: `while (i + 1) < n`).
                if (left_ty) |lt| return if (exprIsNumericLiteral(node.right.*)) lt else null;
                if (right_ty) |rt| return if (exprIsNumericLiteral(node.left.*)) rt else null;
                return null;
            },
            else => null,
        };
    }

    // Floating-point arithmetic lowers to plain C operators: IEEE semantics
    // never raise a language trap, so no overflow/divide checks are emitted.
    fn binaryIsFloat(self: *CEmitter, node: anytype, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return self.exprResolvesToFloat(node.left.*, locals) or self.exprResolvesToFloat(node.right.*, locals);
    }

    fn exprResolvesToFloat(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                const local_set = locals orelse break :blk false;
                const info = local_set.get(ident.text) orelse break :blk false;
                const source_ty = info.source_ty orelse break :blk false;
                break :blk floatCTypeName(source_ty) != null;
            },
            .grouped => |inner| self.exprResolvesToFloat(inner.*, locals),
            .unary => |node| self.exprResolvesToFloat(node.expr.*, locals),
            .binary => |node| self.exprResolvesToFloat(node.left.*, locals) or self.exprResolvesToFloat(node.right.*, locals),
            // indexing a local array/slice of float (e.g. `w[i] + h[j]`): resolve element type
            .index => |node| blk: {
                const local_set = locals orelse break :blk false;
                const elem = localIndexElementType(node.base.*, local_set) orelse break :blk false;
                break :blk floatCTypeName(elem) != null;
            },
            // A float literal (`2.0`) is float: this lets `raw.load<f32>(..) + 2.0`
            // be recognized as float arithmetic (plain C operators, no integer
            // trap helper) even when the other operand's type can't be resolved.
            .float_literal => true,
            .call => |node| blk: {
                // `raw.load<T>(addr)` is not a regular function, so its return
                // type comes from the type argument rather than the function table.
                if (isRawLoadCall(node.callee.*) and node.type_args.len == 1) {
                    break :blk floatCTypeName(node.type_args[0]) != null;
                }
                const return_ty = self.callReturnTypeForExpr(expr, locals) orelse break :blk false;
                break :blk floatCTypeName(return_ty) != null;
            },
            else => false,
        };
    }

    fn emitCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const return_ty = self.callReturnTypeForExpr(initializer, locals) orelse return false;
        if (isCVoidType(return_ty)) return false;
        try locals.put(name, try self.localInfoFromType(return_ty));

        if (try self.emitSequencedCallLocalInit(name, return_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(return_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(initializer, locals);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    // Emit the `?` early-return on error: propagate the original error, or — for
    // `EXPR? else MAPPED` — `err(MAPPED)` mapped into the enclosing error type.
    fn emitTryErrReturn(self: *CEmitter, enclosing_return_ty: ast.TypeExpr, temp_name: []const u8, mapped: ?*ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) !void {
        const ret_c = try self.cTypeFor(enclosing_return_ty, .typedef_name);
        if (mapped) |m| {
            try self.out.print(self.allocator, "return (({s}){{ .is_ok = false, .payload.err = ", .{ret_c});
            if (resultPayloadTypeForTag(enclosing_return_ty, "err")) |err_ty| {
                try self.emitExprWithTarget(m.*, locals, err_ty);
            } else {
                try self.emitExpr(m.*, locals);
            }
            try self.out.appendSlice(self.allocator, " });\n");
        } else {
            try self.out.print(self.allocator, "return (({s}){{ .is_ok = false, .payload.err = {s}.payload.err }});\n", .{ ret_c, temp_name });
        }
    }

    fn emitResultTryLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const try_mapped: ?*ast.Expr = switch (initializer.kind) {
            .try_expr => |inner| inner.mapped,
            else => null,
        };
        const operand = switch (initializer.kind) {
            .try_expr => |inner| inner.operand.*,
            .grouped => |inner| return try self.emitResultTryLocalInit(name, decl_ty, inner.*, locals, return_ty),
            else => return false,
        };
        const enclosing_return_ty = return_ty orelse return false;
        if (resultPayloadTypeForTag(enclosing_return_ty, "err") == null) return false;
        const operand_result_ty = self.resultTypeForExpr(operand, locals) orelse return false;
        _ = resultPayloadTypeForTag(operand_result_ty, "ok") orelse return false;
        _ = resultPayloadTypeForTag(operand_result_ty, "err") orelse return false;

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(operand_result_ty, .typedef_name), temp_name });
        try self.emitExpr(operand, locals);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeIndent();
        try self.out.print(self.allocator, "if (!{s}.is_ok) {{\n", .{temp_name});
        self.indent += 1;
        try self.writeIndent();
        try self.emitTryErrReturn(enclosing_return_ty, temp_name, try_mapped, locals);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");

        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.print(self.allocator, " = {s}.payload.ok;\n", .{temp_name});
        return true;
    }

    fn emitResultTryExprLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        // When the enclosing function returns a Result, `?` propagates the err;
        // otherwise `?` handles it by unwrapping (trapping on err). The local
        // init must support both, mirroring the return/stmt dispatch.
        const propagates = if (return_ty) |ty| resultPayloadTypeForTag(ty, "err") != null else false;

        if (propagates) {
            const enclosing_return_ty = return_ty.?;
            if (try self.emitResultTrySequencedBinaryLocalInit(name, decl_ty, initializer, locals, enclosing_return_ty)) return true;
            if (try self.emitResultTryCallLocalInit(name, decl_ty, initializer, locals, enclosing_return_ty)) return true;
        }

        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        const found = if (propagates)
            try self.collectResultTryHoistsForLocalInit(initializer, locals, return_ty.?, &replacements)
        else
            try self.collectResultTryHoistsForReturn(initializer, locals, &replacements);
        if (!found) return false;

        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.appendSlice(self.allocator, " = ");
        try self.emitResultTryExprWithReplacements(initializer, locals, decl_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitNullableTryExprLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (try self.emitNullableTrySequencedBinaryLocalInit(name, decl_ty, initializer, locals)) return true;
        if (try self.emitNullableTryCallLocalInit(name, decl_ty, initializer, locals)) return true;

        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectNullableTryHoistsForReturn(initializer, locals, &replacements)) return false;

        try self.writeIndent();
        try self.emitDeclarator(decl_ty, name);
        try self.out.appendSlice(self.allocator, " = ");
        try self.emitNullableTryExprWithReplacements(initializer, locals, decl_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitResultTryAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        if (try self.emitResultTrySequencedBinaryAssignmentStmt(assignment, locals, return_ty)) return true;
        if (try self.emitResultTryCallAssignmentStmt(assignment, locals, return_ty)) return true;

        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectResultTryHoistsForStmt(assignment.value, locals, return_ty, &replacements)) return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStorePrefix(target);
            try self.emitResultTryExprWithReplacements(assignment.value, locals, null, replacements.items);
            try self.emitGlobalStoreSuffix(target);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.appendSlice(self.allocator, " = ");
            try self.emitResultTryExprWithReplacements(assignment.value, locals, null, replacements.items);
            try self.out.appendSlice(self.allocator, ";\n");
        }
        return true;
    }

    fn emitNullableTryAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (try self.emitNullableTrySequencedBinaryAssignmentStmt(assignment, locals)) return true;
        if (try self.emitNullableTryCallAssignmentStmt(assignment, locals)) return true;

        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectNullableTryHoistsForReturn(assignment.value, locals, &replacements)) return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStorePrefix(target);
            try self.emitNullableTryExprWithReplacements(assignment.value, locals, null, replacements.items);
            try self.emitGlobalStoreSuffix(target);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.appendSlice(self.allocator, " = ");
            try self.emitNullableTryExprWithReplacements(assignment.value, locals, null, replacements.items);
            try self.out.appendSlice(self.allocator, ";\n");
        }
        return true;
    }

    fn emitResultTryExprReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const temp = (try self.emitResultTrySequencedBinaryValueTemp(expr, locals, target_ty, return_ty, .stmt)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitNullableTryExprReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const temp = (try self.emitNullableTrySequencedBinaryValueTemp(expr, locals, target_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitResultTrySequencedBinaryLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast.TypeExpr) !bool {
        const temp = (try self.emitResultTrySequencedBinaryValueTemp(initializer, locals, decl_ty, enclosing_return_ty, .local_init)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitNullableTrySequencedBinaryLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitNullableTrySequencedBinaryValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitResultTrySequencedBinaryAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const temp = (try self.emitResultTrySequencedBinaryValueTemp(assignment.value, locals, target_ty, return_ty, .stmt)) orelse return false;
        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitNullableTrySequencedBinaryAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const temp = (try self.emitNullableTrySequencedBinaryValueTemp(assignment.value, locals, target_ty)) orelse return false;
        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitResultTryCallLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast.TypeExpr) !bool {
        const call = switch (initializer.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitResultTryCallLocalInit(name, decl_ty, inner.*, locals, enclosing_return_ty),
            else => return false,
        };
        if (!self.callArgsContainResultTry(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitResultTryCallArgTemps(call, locals, fn_info, enclosing_return_ty, .local_init);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitNullableTryCallLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (initializer.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitNullableTryCallLocalInit(name, decl_ty, inner.*, locals),
            else => return false,
        };
        if (!try self.callArgsContainNullableTry(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitNullableTryCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitResultTryCallAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const call = switch (assignment.value.kind) {
            .call => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .call => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!self.callArgsContainResultTry(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        const call_return_ty = fn_info.return_type orelse return false;
        if (isVoidType(call_return_ty) or fn_info.params.len < call.args.len) return false;

        var temps = try self.emitResultTryCallArgTemps(call, locals, fn_info, return_ty, .stmt);
        defer temps.deinit(self.scratch.allocator());

        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(call_return_ty, .typedef_name), result_temp });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, result_temp);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{result_temp});
        }
        return true;
    }

    fn emitNullableTryCallAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (assignment.value.kind) {
            .call => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .call => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (!try self.callArgsContainNullableTry(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        const call_return_ty = fn_info.return_type orelse return false;
        if (isVoidType(call_return_ty) or fn_info.params.len < call.args.len) return false;

        var temps = try self.emitNullableTryCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(call_return_ty, .typedef_name), result_temp });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, result_temp);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{result_temp});
        }
        return true;
    }

    fn emitResultTryCallExprStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitResultTryCallExprStmt(inner.*, locals, return_ty),
            else => return false,
        };
        if (!self.callArgsContainResultTry(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitResultTryCallArgTemps(call, locals, fn_info, return_ty, .stmt);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitNullableTryCallExprStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitNullableTryCallExprStmt(inner.*, locals),
            else => return false,
        };
        if (!try self.callArgsContainNullableTry(call.args, locals)) return false;
        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitNullableTryCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    const ResultTrySequenceMode = enum { local_init, stmt };

    fn emitResultTrySequencedBinaryValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!?SequencedArgTemp {
        if (!self.exprContainsResultTry(expr, locals)) return null;
        const node = switch (expr.kind) {
            .grouped => |inner| return try self.emitResultTrySequencedBinaryValueTemp(inner.*, locals, target_ty, return_ty, mode),
            .binary => |node| node,
            else => return null,
        };
        const plan = try self.sequencedBinaryPlan(node, target_ty, locals) orelse return null;

        const left_temp = try self.emitResultTryOperandTemp(node.left.*, locals, target_ty, return_ty, mode);
        const right_temp = try self.emitResultTryOperandTemp(node.right.*, locals, target_ty, return_ty, mode);
        return try self.emitSequencedBinaryPlanResultTemp(plan, target_ty, left_temp.name, right_temp.name);
    }

    fn emitNullableTrySequencedBinaryValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        if (!try self.exprContainsNullableTry(expr, locals)) return null;
        const node = switch (expr.kind) {
            .grouped => |inner| return try self.emitNullableTrySequencedBinaryValueTemp(inner.*, locals, target_ty),
            .binary => |node| node,
            else => return null,
        };
        const plan = try self.sequencedBinaryPlan(node, target_ty, locals) orelse return null;

        const left_temp = try self.emitNullableTryOperandTemp(node.left.*, locals, target_ty);
        const right_temp = try self.emitNullableTryOperandTemp(node.right.*, locals, target_ty);
        return try self.emitSequencedBinaryPlanResultTemp(plan, target_ty, left_temp.name, right_temp.name);
    }

    fn emitResultTryOperandTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!SequencedArgTemp {
        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        const found = switch (mode) {
            .local_init => blk: {
                const enclosing_return_ty = return_ty orelse return error.UnsupportedCEmission;
                break :blk try self.collectResultTryHoistsForLocalInit(expr, locals, enclosing_return_ty, &replacements);
            },
            .stmt => try self.collectResultTryHoistsForStmt(expr, locals, return_ty, &replacements),
        };
        _ = found;
        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp_name });
        try self.emitResultTryExprWithReplacements(expr, locals, target_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitNullableTryOperandTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        _ = try self.collectNullableTryHoistsForReturn(expr, locals, &replacements);

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp_name });
        try self.emitNullableTryExprWithReplacements(expr, locals, target_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitResultTryExprStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        if (try self.emitResultTryCallExprStmt(expr, locals, return_ty)) return true;

        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectResultTryHoistsForStmt(expr, locals, return_ty, &replacements)) return false;
        if (resultTryOperand(expr) != null) return true;

        try self.writeIndent();
        try self.emitResultTryExprWithReplacements(expr, locals, null, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitNullableTryExprStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (try self.emitNullableTryCallExprStmt(expr, locals)) return true;

        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectNullableTryHoistsForReturn(expr, locals, &replacements)) return false;
        if (resultTryOperand(expr) != null) return true;

        try self.writeIndent();
        try self.emitNullableTryExprWithReplacements(expr, locals, null, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitResultTryReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const operand = switch (expr.kind) {
            .try_expr => |inner| inner.operand.*,
            .grouped => |inner| return try self.emitResultTryReturn(inner.*, locals, return_ty),
            else => return false,
        };
        const operand_result_ty = self.resultTypeForExpr(operand, locals) orelse return false;
        _ = resultPayloadTypeForTag(operand_result_ty, "ok") orelse return false;
        _ = resultPayloadTypeForTag(operand_result_ty, "err") orelse return false;
        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(operand_result_ty, .typedef_name), temp_name });
        try self.emitExpr(operand, locals);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeIndent();
        try self.out.print(self.allocator, "if (!{s}.is_ok) mc_trap_InvalidRepresentation();\n", .{temp_name});
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.out.print(self.allocator, "{s}.payload.ok;\n", .{temp_name});
        return true;
    }

    fn emitResultTryCallReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitResultTryCallReturn(inner.*, locals),
            else => return false,
        };

        var found_try = false;

        for (call.args) |arg| {
            if (self.exprContainsResultTry(arg, locals)) {
                found_try = true;
                break;
            }
        }

        if (!found_try) return false;

        const fn_info = if (calleeIdentName(call.callee.*)) |name| self.functions.get(name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitResultTryCallArgTemps(call, locals, fn_info, null, .stmt);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    // `return ok(<expr-with-?>)` / `return err(<expr-with-?>)`: the `ok`/`err`
    // Result constructor isn't a registered function, so `emitResultTryCallReturn`
    // skips it. Hoist any `?` in the payload argument (reusing the call-arg-temp
    // machinery), then wrap the resulting value in the Result aggregate.
    fn emitResultTryConstructorReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitResultTryConstructorReturn(inner.*, locals, return_ty),
            else => return false,
        };
        const tag = calleeIdentName(call.callee.*) orelse return false;
        if (!std.mem.eql(u8, tag, "ok") and !std.mem.eql(u8, tag, "err")) return false;
        if (call.args.len != 1) return false;
        if (!self.exprContainsResultTry(call.args[0], locals)) return false;
        const payload_ty = resultPayloadTypeForTag(target_ty, tag) orelse return false;

        const temp = try self.emitResultTryCallArgTempWithMode(call.args[0], locals, payload_ty, return_ty, .stmt);

        try self.writeIndent();
        try self.out.print(self.allocator, "return (({s}){{ .is_ok = ", .{try self.cTypeFor(target_ty, .typedef_name)});
        try self.out.appendSlice(self.allocator, if (std.mem.eql(u8, tag, "ok")) "true, .payload.ok = " else "false, .payload.err = ");
        try self.out.appendSlice(self.allocator, temp.name);
        try self.out.appendSlice(self.allocator, " });\n");
        return true;
    }

    fn emitResultTryCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        return try self.emitResultTryCallArgTempWithMode(arg, locals, target_ty, null, .stmt);
    }

    fn emitResultTryCallArgTemps(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!std.ArrayList(SequencedArgTemp) {
        var temps: std.ArrayList(SequencedArgTemp) = .empty;
        errdefer temps.deinit(self.scratch.allocator());
        for (call.args, 0..) |arg, i| {
            try temps.append(self.scratch.allocator(), try self.emitResultTryCallArgTempWithMode(arg, locals, fn_info.params[i].ty, return_ty, mode));
        }
        return temps;
    }

    fn emitResultTryCallArgTempWithMode(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, return_ty: ?ast.TypeExpr, mode: ResultTrySequenceMode) anyerror!SequencedArgTemp {
        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        const found_try = switch (mode) {
            .local_init => blk: {
                const enclosing_return_ty = return_ty orelse return error.UnsupportedCEmission;
                break :blk try self.collectResultTryHoistsForLocalInit(arg, locals, enclosing_return_ty, &replacements);
            },
            .stmt => try self.collectResultTryHoistsForStmt(arg, locals, return_ty, &replacements),
        };
        if (!found_try) {
            return try self.emitSequencedCallArgTemp(arg, locals, target_ty);
        }

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp_name });
        try self.emitResultTryExprWithReplacements(arg, locals, target_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitSequencedCallReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitSequencedCallReturn(inner.*, locals),
            else => return false,
        };
        if (call.args.len == 0) return false;

        const fn_info = if (calleeIdentName(call.callee.*)) |name| self.functions.get(name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitSequencedCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    const SequencedArgTemp = struct {
        name: []const u8,
        ty: ast.TypeExpr,
    };

    fn emitSequencedCallArgTemps(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo) anyerror!std.ArrayList(SequencedArgTemp) {
        var temps: std.ArrayList(SequencedArgTemp) = .empty;
        errdefer temps.deinit(self.scratch.allocator());

        for (call.args, 0..) |arg, i| {
            const target_ty = fn_info.params[i].ty;
            try temps.append(self.scratch.allocator(), try self.emitSequencedCallArgTemp(arg, locals, target_ty));
        }

        return temps;
    }

    fn emitSequencedCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        switch (arg.kind) {
            .grouped => |inner| return try self.emitSequencedCallArgTemp(inner.*, locals, target_ty),
            .address_of => {
                if (try self.emitRawManyOffsetDerefAddressValueTemp(arg, locals, target_ty)) |temp| return temp;
                if (try self.emitLocalIndexAddressValueTemp(arg, locals, target_ty)) |temp| return temp;
            },
            .index => {
                if (try self.emitDirectCallSliceIndexValueTemp(arg, locals, target_ty)) |temp| return temp;
                if (try self.emitDirectCallArrayIndexValueTemp(arg, locals, target_ty)) |temp| return temp;
                if (try self.emitLocalIndexValueTemp(arg, locals, target_ty)) |temp| return temp;
            },
            .binary => {
                if (try self.emitSequencedConditionValueTemp(arg, locals)) |temp| return temp;
                if (try self.emitSequencedBinaryValueTemp(arg, locals, target_ty)) |temp| return temp;
            },
            .deref => {
                if (try self.emitRawManyOffsetDerefValueTemp(arg, locals, target_ty)) |temp| return temp;
            },
            .array_literal, .struct_literal => {
                if (try self.emitUncheckedAddAggregateCallArgTemp(arg, locals, target_ty)) |temp| return temp;
            },
            .cast => {
                if (try self.emitUncheckedAddValueTemp(arg, locals, target_ty, "call_arg")) |temp| return temp;
            },
            .call => |call| {
                if (try self.emitBitcastValueTempFromCall(call, locals)) |temp| return temp;
                if (try self.emitExternNonNullCallValueTemp(arg, locals)) |temp| return temp;
                if (try self.emitRawManyOffsetValueTempFromCall(call, locals, target_ty)) |temp| return temp;
                if (try self.emitUncheckedAddValueTempFromCall(call, arg.span, locals, target_ty, "call_arg")) |temp| return temp;
                if (calleeIdentName(call.callee.*)) |callee_name| {
                    if (self.functions.get(callee_name)) |fn_info| {
                        if (fn_info.return_type) |return_ty| {
                            if (!isVoidType(return_ty) and fn_info.params.len >= call.args.len) {
                                var nested_temps = try self.emitSequencedCallArgTemps(call, locals, fn_info);
                                defer nested_temps.deinit(self.scratch.allocator());

                                const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
                                self.temp_index += 1;
                                try self.writeIndent();
                                try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(return_ty, .typedef_name), temp_name });
                                try self.emitExpr(call.callee.*, locals);
                                try self.emitSequencedCallArgList(nested_temps.items);
                                try self.out.appendSlice(self.allocator, ";\n");
                                return .{ .name = temp_name, .ty = return_ty };
                            }
                        }
                    }
                }
            },
            else => {},
        }

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp_name });
        const cast_pointer_to_paddr = isPAddrType(target_ty) and blk: {
            const source_ty = self.exprSourceTypeForEmission(arg, locals) orelse break :blk false;
            break :blk isPointerLikeAddressType(source_ty);
        };
        if (cast_pointer_to_paddr) {
            try self.out.appendSlice(self.allocator, "((uintptr_t)(");
            try self.emitExpr(arg, locals);
            try self.out.appendSlice(self.allocator, "))");
        } else {
            try self.emitExprWithTarget(arg, locals, target_ty);
        }
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitRawManyOffsetDerefAddressValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const deref_expr = switch (expr.kind) {
            .grouped => |grouped| return try self.emitRawManyOffsetDerefAddressValueTemp(grouped.*, locals, target_ty),
            .address_of => |inner| inner.*,
            else => return null,
        };
        const offset_expr = switch (deref_expr.kind) {
            .grouped => |grouped| switch (grouped.kind) {
                .deref => |inner| inner.*,
                else => return null,
            },
            .deref => |inner| inner.*,
            else => return null,
        };
        const call = switch (offset_expr.kind) {
            .grouped => |grouped| switch (grouped.kind) {
                .call => |call| call,
                else => return null,
            },
            .call => |call| call,
            else => return null,
        };
        const ptr_ty = self.rawManyOffsetReturnTypeForCall(call, locals) orelse return null;
        const ptr_temp = (try self.emitRawManyOffsetValueTempFromCallForce(call, locals, ptr_ty, true)) orelse return null;

        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(target_ty, .typedef_name), result_temp, ptr_temp.name });
        return .{ .name = result_temp, .ty = target_ty };
    }

    fn emitRawManyOffsetDerefAddressReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const temp = (try self.emitRawManyOffsetDerefAddressValueTemp(expr, locals, target_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitRawManyOffsetDerefAddressLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitRawManyOffsetDerefAddressValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitRawManyOffsetDerefAddressAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const temp = (try self.emitRawManyOffsetDerefAddressValueTemp(assignment.value, locals, target_ty)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitRawManyOffsetDerefValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const inner = switch (expr.kind) {
            .grouped => |grouped| return try self.emitRawManyOffsetDerefValueTemp(grouped.*, locals, target_ty),
            .deref => |inner| inner.*,
            else => return null,
        };
        const ptr_ty = self.rawManyOffsetTypeForExpr(inner, locals) orelse return null;
        const ptr_temp = (try self.emitRawManyOffsetValueTemp(inner, locals, ptr_ty)) orelse return null;
        const value_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = *{s};\n", .{ try self.cTypeFor(target_ty, .typedef_name), value_temp, ptr_temp.name });
        return .{ .name = value_temp, .ty = target_ty };
    }

    fn emitRawManyOffsetDerefReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const temp = (try self.emitRawManyOffsetDerefValueTemp(expr, locals, target_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitRawManyOffsetDerefLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitRawManyOffsetDerefValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitRawManyOffsetDerefInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const element_ty = self.rawManyOffsetDerefTypeForExpr(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(element_ty));
        if (try self.emitRawManyOffsetDerefLocalInit(name, element_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(element_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(initializer, locals);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitRawManyOffsetDerefAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const temp = (try self.emitRawManyOffsetDerefValueTemp(assignment.value, locals, target_ty)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitRawManyOffsetDerefTargetAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const inner = switch (assignment.target.kind) {
            .grouped => |grouped| return try self.emitRawManyOffsetDerefTargetAssignmentStmt(.{ .target = grouped.*, .value = assignment.value }, locals),
            .deref => |inner| inner.*,
            else => return false,
        };
        const call = switch (inner.kind) {
            .grouped => |grouped| switch (grouped.kind) {
                .call => |call| call,
                else => return false,
            },
            .call => |call| call,
            else => return false,
        };
        const ptr_ty = self.rawManyOffsetReturnTypeForCall(call, locals) orelse return false;
        const element_ty = rawManyElementType(ptr_ty) orelse return false;
        const should_sequence = exprContainsCall(inner) or exprContainsCall(assignment.value);
        if (!should_sequence) return false;

        const ptr_temp = (try self.emitRawManyOffsetValueTempFromCallForce(call, locals, ptr_ty, true)) orelse return false;
        const value_temp = try self.emitSequencedCallArgTemp(assignment.value, locals, element_ty);

        try self.writeIndent();
        try self.out.print(self.allocator, "*{s} = {s};\n", .{ ptr_temp.name, value_temp.name });
        return true;
    }

    fn emitBitcastValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
        return switch (expr.kind) {
            .grouped => |inner| try self.emitBitcastValueTemp(inner.*, locals),
            .call => |call| try self.emitBitcastValueTempFromCall(call, locals),
            else => null,
        };
    }

    fn emitBitcastValueTempFromCall(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
        if (!isBitcastCall(call) or call.type_args.len != 1 or call.args.len != 1) return null;
        const target_ty = self.resolveAliasType(call.type_args[0]);
        const source_ty = self.exprSourceTypeForEmission(call.args[0], locals) orelse return error.UnsupportedCEmission;
        const source_temp = try self.emitSequencedCallArgTemp(call.args[0], locals, source_ty);
        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s};\n", .{ try self.cTypeFor(target_ty, .typedef_name), result_temp });
        try self.writeIndent();
        try self.out.print(self.allocator, "__builtin_memcpy(&{s}, &{s}, sizeof({s}));\n", .{ result_temp, source_temp.name, result_temp });
        return .{ .name = result_temp, .ty = target_ty };
    }

    fn emitBitcastLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (initializer.kind) {
            .grouped => |inner| return try self.emitBitcastLocalInit(name, decl_ty, inner.*, locals),
            .call => |node| node,
            else => return false,
        };
        if (!isBitcastCall(call)) return false;
        if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedCEmission;
        const source_ty = self.exprSourceTypeForEmission(call.args[0], locals) orelse return error.UnsupportedCEmission;
        const source_temp = try self.emitSequencedCallArgTemp(call.args[0], locals, source_ty);

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name) });
        try self.writeIndent();
        try self.out.print(self.allocator, "__builtin_memcpy(&{s}, &{s}, sizeof({s}));\n", .{ name, source_temp.name, name });
        return true;
    }

    fn emitBitcastInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (initializer.kind) {
            .grouped => |inner| return try self.emitBitcastInferredLocalInit(name, inner.*, locals),
            .call => |node| node,
            else => return false,
        };
        if (!isBitcastCall(call) or call.type_args.len != 1 or call.args.len != 1) return false;
        try locals.put(name, try self.localInfoFromType(call.type_args[0]));
        return try self.emitBitcastLocalInit(name, call.type_args[0], initializer, locals);
    }

    fn emitBitcastReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        _ = return_ty;
        const temp = (try self.emitBitcastValueTemp(expr, locals)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitBitcastAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitBitcastValueTemp(assignment.value, locals)) orelse return false;
        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn externNonNullReturnInfo(self: *CEmitter, call: anytype) ?FnInfo {
        const callee_name = calleeIdentName(call.callee.*) orelse return null;
        const fn_info = self.functions.get(callee_name) orelse return null;
        const return_ty = fn_info.return_type orelse return null;
        if (!fn_info.is_extern or !isNonNullPointerType(return_ty) or fn_info.params.len < call.args.len) return null;
        return fn_info;
    }

    fn emitExternNonNullCallValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) anyerror!?SequencedArgTemp {
        const call = switch (expr.kind) {
            .grouped => |inner| return try self.emitExternNonNullCallValueTemp(inner.*, locals),
            .call => |node| node,
            else => return null,
        };
        const fn_info = self.externNonNullReturnInfo(call) orelse return null;
        const return_ty = fn_info.return_type orelse return null;

        var temps = try self.emitSequencedCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(return_ty, .typedef_name), temp_name });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s} == NULL) mc_trap_InvalidRepresentation();\n", .{temp_name});
        return .{ .name = temp_name, .ty = return_ty };
    }

    fn emitExternNonNullCallLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitExternNonNullCallValueTemp(initializer, locals)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitExternNonNullCallInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitExternNonNullCallValueTemp(initializer, locals)) orelse return false;
        try locals.put(name, try self.localInfoFromType(temp.ty));
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(temp.ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitExternNonNullCallReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitExternNonNullCallValueTemp(expr, locals)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitExternNonNullCallAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitExternNonNullCallValueTemp(assignment.value, locals)) orelse return false;
        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitRawManyOffsetValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        return switch (expr.kind) {
            .grouped => |inner| try self.emitRawManyOffsetValueTemp(inner.*, locals, target_ty),
            .call => |call| try self.emitRawManyOffsetValueTempFromCallForce(call, locals, target_ty, false),
            else => null,
        };
    }

    fn emitRawManyOffsetValueTempFromCall(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        return try self.emitRawManyOffsetValueTempFromCallForce(call, locals, target_ty, false);
    }

    fn emitRawManyOffsetValueTempFromCallForce(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, force: bool) anyerror!?SequencedArgTemp {
        const info = self.rawManyOffsetCallInfo(call, locals) orelse return null;
        if (!force and !exprContainsCall(info.base) and !exprContainsCall(call.args[0])) return null;

        const base_temp = try self.emitSequencedCallArgTemp(info.base, locals, info.ty);
        const index_temp = try self.emitSequencedCallArgTemp(call.args[0], locals, simpleNameType("usize", call.args[0].span));
        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ({s} + {s});\n", .{ try self.cTypeFor(target_ty, .typedef_name), result_temp, base_temp.name, index_temp.name });
        return .{ .name = result_temp, .ty = target_ty };
    }

    fn emitRawManyOffsetReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const temp = (try self.emitRawManyOffsetValueTemp(expr, locals, target_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitRawManyOffsetLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitRawManyOffsetValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitRawManyOffsetInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const raw_ty = self.rawManyOffsetTypeForExpr(initializer, locals) orelse return false;
        try locals.put(name, try self.localInfoFromType(raw_ty));
        if (try self.emitRawManyOffsetLocalInit(name, raw_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(raw_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(initializer, locals);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitRawManyOffsetAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const temp = (try self.emitRawManyOffsetValueTemp(assignment.value, locals, target_ty)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitUncheckedAddValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        return switch (expr.kind) {
            .grouped => |inner| try self.emitUncheckedAddValueTemp(inner.*, locals, target_ty, range_target),
            .cast => |node| try self.emitUncheckedAddValueTemp(node.value.*, locals, node.ty.*, range_target),
            .call => |call| try self.emitUncheckedAddValueTempFromCall(call, expr.span, locals, target_ty, range_target),
            else => null,
        };
    }

    fn emitUncheckedAddValueTempFromCall(self: *CEmitter, call: anytype, call_span: ast.Span, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, range_target: []const u8) anyerror!?SequencedArgTemp {
        const op = uncheckedNoOverflowCallOp(call) orelse return null;
        if (!self.hasMirNoOverflowRangeFact(range_target, op, call_span)) return null;

        try self.writeIndent();
        try self.out.print(self.allocator, "/* MC_MIR_RANGE no_overflow target={s} op={s} */\n", .{ range_target, op });

        const left_temp = try self.emitSequencedCallArgTemp(call.args[0], locals, target_ty);
        const right_temp = try self.emitSequencedCallArgTemp(call.args[1], locals, target_ty);
        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ({s} {s} {s});\n", .{ try self.cTypeFor(target_ty, .typedef_name), result_temp, left_temp.name, uncheckedNoOverflowOperator(op), right_temp.name });
        return .{ .name = result_temp, .ty = target_ty };
    }

    fn emitUncheckedAddReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const temp = (try self.emitUncheckedAddValueTemp(expr, locals, target_ty, "value")) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitUncheckedAddLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitUncheckedAddValueTemp(initializer, locals, decl_ty, name)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitUncheckedAddInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const inferred_ty = simpleNameType("u32", initializer.span);
        const temp = (try self.emitUncheckedAddValueTemp(initializer, locals, inferred_ty, name)) orelse return false;
        try locals.put(name, try self.localInfoFromType(inferred_ty));
        try self.writeIndent();
        try self.out.print(self.allocator, "uint32_t {s} = {s};\n", .{ try self.cIdent(name), temp.name });
        return true;
    }

    fn emitUncheckedAddAggregateReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        return switch (expr.kind) {
            .grouped => |inner| try self.emitUncheckedAddAggregateReturn(inner.*, locals, return_ty),
            .array_literal => |items| try self.emitUncheckedAddArrayAggregateReturn(items, locals, target_ty),
            .struct_literal => |fields| try self.emitUncheckedAddStructAggregateReturn(fields, locals, target_ty),
            else => false,
        };
    }

    fn emitUncheckedAddAggregateLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        return switch (initializer.kind) {
            .grouped => |inner| try self.emitUncheckedAddAggregateLocalInit(name, decl_ty, inner.*, locals),
            .array_literal => |items| try self.emitUncheckedAddArrayAggregateLocalInit(name, decl_ty, items, locals),
            .struct_literal => |fields| try self.emitUncheckedAddStructAggregateLocalInit(name, decl_ty, fields, locals),
            else => false,
        };
    }

    fn emitUncheckedAddAggregateCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        return switch (arg.kind) {
            .grouped => |inner| try self.emitUncheckedAddAggregateCallArgTemp(inner.*, locals, target_ty),
            .array_literal => |items| try self.emitUncheckedAddArrayAggregateCallArgTemp(items, locals, target_ty),
            .struct_literal => |fields| try self.emitUncheckedAddStructAggregateCallArgTemp(fields, locals, target_ty),
            else => null,
        };
    }

    fn emitUncheckedAddAggregateAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        return switch (assignment.value.kind) {
            .grouped => |inner| try self.emitUncheckedAddAggregateAssignmentStmt(.{ .target = assignment.target, .value = inner.* }, locals),
            .array_literal => |items| try self.emitUncheckedAddArrayAggregateAssignmentStmt(assignment.target, items, locals, target_ty),
            .struct_literal => |fields| try self.emitUncheckedAddStructAggregateAssignmentStmt(assignment.target, fields, locals, target_ty),
            else => false,
        };
    }

    fn emitUncheckedAddArrayAggregateReturn(self: *CEmitter, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
        var temps: std.ArrayList(?SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        if (!try self.collectUncheckedAddArrayLiteralTemps(items, locals, target_ty, &temps)) return false;

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitArrayLiteralWithTemps(items, locals, target_ty, temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitUncheckedAddStructAggregateReturn(self: *CEmitter, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
        var temps: std.ArrayList(?SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        if (!try self.collectUncheckedAddStructLiteralTemps(fields, locals, target_ty, &temps)) return false;

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitStructLiteralWithTemps(fields, locals, target_ty, temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitUncheckedAddArrayAggregateLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        var temps: std.ArrayList(?SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        if (!try self.collectUncheckedAddArrayLiteralTemps(items, locals, decl_ty, &temps)) return false;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name) });
        try self.emitArrayLiteralWithTemps(items, locals, decl_ty, temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitUncheckedAddStructAggregateLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo)) !bool {
        var temps: std.ArrayList(?SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        if (!try self.collectUncheckedAddStructLiteralTemps(fields, locals, decl_ty, &temps)) return false;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name) });
        try self.emitStructLiteralWithTemps(fields, locals, decl_ty, temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitUncheckedAddArrayAggregateCallArgTemp(self: *CEmitter, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        var temps: std.ArrayList(?SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        if (!try self.collectUncheckedAddArrayLiteralTemps(items, locals, target_ty, &temps)) return null;

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp_name });
        try self.emitArrayLiteralWithTemps(items, locals, target_ty, temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitUncheckedAddStructAggregateCallArgTemp(self: *CEmitter, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        var temps: std.ArrayList(?SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        if (!try self.collectUncheckedAddStructLiteralTemps(fields, locals, target_ty, &temps)) return null;

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp_name });
        try self.emitStructLiteralWithTemps(fields, locals, target_ty, temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitUncheckedAddArrayAggregateAssignmentStmt(self: *CEmitter, target_expr: ast.Expr, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
        var temps: std.ArrayList(?SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        if (!try self.collectUncheckedAddArrayLiteralTemps(items, locals, target_ty, &temps)) return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(target_expr, locals)) |target| {
            try self.emitGlobalStorePrefix(target);
            try self.emitArrayLiteralWithTemps(items, locals, target_ty, temps.items);
            try self.emitGlobalStoreSuffix(target);
        } else {
            try self.emitExpr(target_expr, locals);
            try self.out.appendSlice(self.allocator, " = ");
            try self.emitArrayLiteralWithTemps(items, locals, target_ty, temps.items);
            try self.out.appendSlice(self.allocator, ";\n");
        }
        return true;
    }

    fn emitUncheckedAddStructAggregateAssignmentStmt(self: *CEmitter, target_expr: ast.Expr, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) !bool {
        var temps: std.ArrayList(?SequencedArgTemp) = .empty;
        defer temps.deinit(self.scratch.allocator());
        if (!try self.collectUncheckedAddStructLiteralTemps(fields, locals, target_ty, &temps)) return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(target_expr, locals)) |target| {
            try self.emitGlobalStorePrefix(target);
            try self.emitStructLiteralWithTemps(fields, locals, target_ty, temps.items);
            try self.emitGlobalStoreSuffix(target);
        } else {
            try self.emitExpr(target_expr, locals);
            try self.out.appendSlice(self.allocator, " = ");
            try self.emitStructLiteralWithTemps(fields, locals, target_ty, temps.items);
            try self.out.appendSlice(self.allocator, ";\n");
        }
        return true;
    }

    fn collectUncheckedAddArrayLiteralTemps(self: *CEmitter, items: []const ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, temps: *std.ArrayList(?SequencedArgTemp)) !bool {
        const child_ty = self.arrayChildTypeForTarget(target_ty) orelse return false;
        var emitted = false;
        for (items) |item| {
            const temp = try self.emitUncheckedAddValueTemp(item, locals, child_ty, "aggregate_element");
            if (temp != null) emitted = true;
            try temps.append(self.scratch.allocator(), temp);
        }
        return emitted;
    }

    fn collectUncheckedAddStructLiteralTemps(self: *CEmitter, fields: []const ast.StructLiteralField, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr, temps: *std.ArrayList(?SequencedArgTemp)) !bool {
        const struct_decl = self.structDeclForTarget(target_ty) orelse return false;
        var emitted = false;
        for (fields) |field| {
            const field_ty = structFieldType(struct_decl, field.name.text) orelse return error.UnsupportedCEmission;
            const temp = try self.emitUncheckedAddValueTemp(field.value, locals, field_ty, field.name.text);
            if (temp != null) emitted = true;
            try temps.append(self.scratch.allocator(), temp);
        }
        return emitted;
    }

    fn emitUncheckedAddAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const range_target = assignmentRangeTargetName(assignment.target) orelse return false;
        const temp = (try self.emitUncheckedAddValueTemp(assignment.value, locals, target_ty, range_target)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn hasMirNoOverflowRangeFact(self: *CEmitter, target: []const u8, op: []const u8, span: ast.Span) bool {
        const function_name = self.current_function orelse return false;
        for (self.mir_module.functions) |function| {
            if (!std.mem.eql(u8, function.name, function_name)) continue;
            for (function.range_facts) |fact| {
                if (!std.mem.eql(u8, fact.target, target)) continue;
                if (!std.mem.eql(u8, fact.op, op)) continue;
                if (fact.line != span.line or fact.column != span.column) continue;
                return true;
            }
        }
        return false;
    }

    fn emitSequencedComparisonReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        if (!isBoolType(target_ty)) return false;
        const temp = (try self.emitSequencedConditionValueTemp(expr, locals)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitSequencedComparisonLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (!isBoolType(decl_ty)) return false;
        const temp = (try self.emitSequencedConditionValueTemp(initializer, locals)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "bool {s} = {s};\n", .{ name, temp.name });
        return true;
    }

    fn emitBoolInferredLocalInit(self: *CEmitter, name: []const u8, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        if (!comparisonExpr(initializer)) return false;
        const bool_ty = simpleNameType("bool", initializer.span);
        try locals.put(name, try self.localInfoFromType(bool_ty));
        if (try self.emitSequencedComparisonLocalInit(name, bool_ty, initializer, locals)) return true;

        try self.writeIndent();
        try self.out.print(self.allocator, "bool {s} = ", .{name});
        try self.emitExprWithTarget(initializer, locals, bool_ty);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitSequencedComparisonAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        if (!isBoolType(target_ty)) return false;
        const temp = (try self.emitSequencedConditionValueTemp(assignment.value, locals)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitSequencedBinaryValueTemp(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!?SequencedArgTemp {
        const node = switch (expr.kind) {
            .grouped => |inner| return try self.emitSequencedBinaryValueTemp(inner.*, locals, target_ty),
            .binary => |node| node,
            else => return null,
        };
        if (isNoTrapBitwiseInfixOp(node.op) and !exprContainsCall(node.left.*) and !exprContainsCall(node.right.*)) return null;
        const plan = try self.sequencedBinaryPlan(node, target_ty, locals) orelse return null;

        const left_temp = try self.emitSequencedBinaryOperandTemp(node.left.*, locals, target_ty);
        const right_temp = try self.emitSequencedBinaryOperandTemp(node.right.*, locals, target_ty);
        return try self.emitSequencedBinaryPlanResultTemp(plan, target_ty, left_temp.name, right_temp.name);
    }

    fn emitSequencedBinaryOperandTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        if (try self.emitUncheckedAddValueTemp(arg, locals, target_ty, "binary_operand")) |temp| return temp;
        return try self.emitSequencedCallArgTemp(arg, locals, target_ty);
    }

    fn emitSequencedBinaryPlanResultTemp(self: *CEmitter, plan: SequencedBinaryPlan, target_ty: ast.TypeExpr, left_name: []const u8, right_name: []const u8) anyerror!SequencedArgTemp {
        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), result_temp });
        switch (plan) {
            .infix => |op_text| try self.out.print(self.allocator, "({s} {s} {s})", .{ left_name, op_text, right_name }),
            .helper => |helper| try self.out.print(self.allocator, "{s}{s}({s}, {s})", .{ helper.prefix, helper.suffix, left_name, right_name }),
        }
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = result_temp, .ty = target_ty };
    }

    const SequencedBinaryPlan = union(enum) {
        infix: []const u8,
        helper: CheckedHelperParts,
    };

    // The constant value of an integer local initializer, but only when it fits
    // the declared type (so the local genuinely holds that constant at runtime).
    fn constLocalValue(self: *CEmitter, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?i128 {
        const resolved = self.resolveAliasType(decl_ty);
        const tn = typeName(resolved) orelse return null;
        const range = intTypeRange(tn) orelse return null;
        const v = constIntValue(initializer, locals) orelse return null;
        if (@as(i256, v) >= @as(i256, range.min) and @as(i256, v) <= @as(i256, range.max)) return v;
        return null;
    }

    fn sequencedBinaryPlan(self: *CEmitter, node: anytype, target_ty: ast.TypeExpr, locals: ?*std.StringHashMap(LocalInfo)) !?SequencedBinaryPlan {
        const op = node.op;
        const resolved_target_ty = self.resolveAliasType(target_ty);
        if (genericChildType(resolved_target_ty, "wrap")) |inner| {
            const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
            if (unsignedTypeSuffix(inner_name) == null) return error.UnsupportedCEmission;
            return switch (op) {
                .add, .sub, .mul, .bit_and, .bit_or, .bit_xor => .{ .infix = binaryCOp(op) },
                .shl, .shr => .{ .helper = .{
                    .prefix = try std.fmt.allocPrint(self.scratch.allocator(), "mc_wrap_{s}_", .{if (op == .shl) "shl" else "shr"}),
                    .suffix = unsignedTypeSuffix(inner_name).?,
                } },
                .div, .mod => .{ .helper = checkedHelperParts(op, inner_name) orelse return error.UnsupportedCEmission },
                else => null,
            };
        }

        if (genericChildType(resolved_target_ty, "sat")) |inner| {
            const inner_name = typeName(inner) orelse return error.UnsupportedCEmission;
            return if (satHelperParts(op, inner_name)) |helper| .{ .helper = helper } else null;
        }

        const target_name = typeName(resolved_target_ty) orelse return error.UnsupportedCEmission;
        if (isNoTrapBitwiseInfixOp(op)) {
            if (unsignedTypeSuffix(target_name) == null) return error.UnsupportedCEmission;
            return .{ .infix = binaryCOp(op) };
        }
        if (!isCheckedBinaryOp(op)) return null;
        // Value-range proof: constant operands that cannot overflow lower to a
        // plain infix operator instead of the checked-overflow helper.
        if (constBinaryProvenNoOverflow(node, target_name, locals)) return .{ .infix = binaryCOp(op) };
        return if (checkedHelperParts(op, target_name)) |helper| .{ .helper = helper } else null;
    }

    fn emitSequencedCheckedBinaryReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr) !bool {
        const target_ty = return_ty orelse return false;
        const temp = (try self.emitSequencedBinaryValueTemp(expr, locals, target_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp.name});
        return true;
    }

    fn emitSequencedCheckedBinaryLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const temp = (try self.emitSequencedBinaryValueTemp(initializer, locals, decl_ty)) orelse return false;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name), temp.name });
        return true;
    }

    fn emitSequencedCheckedBinaryAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const target_ty = if (self.assignmentTargetType(assignment.target, locals)) |ty| ty else blk: {
            const target = self.globalAssignmentTarget(assignment.target, locals) orelse return false;
            break :blk simpleNameType(target.info.type_name, assignment.value.span);
        };
        const temp = (try self.emitSequencedBinaryValueTemp(assignment.value, locals, target_ty)) orelse return false;

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, temp.name);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{temp.name});
        }
        return true;
    }

    fn emitSequencedCallArgList(self: *CEmitter, temps: []const SequencedArgTemp) !void {
        try self.out.appendSlice(self.allocator, "(");
        for (temps, 0..) |temp, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, temp.name);
        }
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitSequencedCallLocalInit(self: *CEmitter, name: []const u8, decl_ty: ast.TypeExpr, initializer: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (initializer.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitSequencedCallLocalInit(name, decl_ty, inner.*, locals),
            else => return false,
        };
        if (call.args.len == 0) return false;

        const fn_info = if (calleeIdentName(call.callee.*)) |callee_name| self.functions.get(callee_name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitSequencedCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(decl_ty, .typedef_name), try self.cIdent(name) });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitSequencedCallExprStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitSequencedCallExprStmt(inner.*, locals),
            else => return false,
        };
        if (call.args.len == 0) return false;

        const fn_info = if (calleeIdentName(call.callee.*)) |name| self.functions.get(name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitSequencedCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitSequencedCallAssignmentStmt(self: *CEmitter, assignment: anytype, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (assignment.value.kind) {
            .call => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .call => |node| node,
                else => return false,
            },
            else => return false,
        };
        if (call.args.len == 0) return false;

        const fn_info = if (calleeIdentName(call.callee.*)) |name| self.functions.get(name) orelse return false else return false;
        const return_ty = fn_info.return_type orelse return false;
        if (isVoidType(return_ty) or fn_info.params.len < call.args.len) return false;

        var temps = try self.emitSequencedCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        const result_temp = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(return_ty, .typedef_name), result_temp });
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeIndent();
        if (self.globalAssignmentTarget(assignment.target, locals)) |target| {
            try self.emitGlobalStoreValue(target, result_temp);
        } else {
            try self.emitExpr(assignment.target, locals);
            try self.out.print(self.allocator, " = {s};\n", .{result_temp});
        }
        return true;
    }

    fn emitNullableTryCallReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const call = switch (expr.kind) {
            .call => |node| node,
            .grouped => |inner| return try self.emitNullableTryCallReturn(inner.*, locals),
            else => return false,
        };

        var found_try = false;

        for (call.args) |arg| {
            if (try self.exprContainsNullableTry(arg, locals)) {
                found_try = true;
                break;
            }
        }

        if (!found_try) return false;

        const fn_info = if (calleeIdentName(call.callee.*)) |name| self.functions.get(name) orelse return false else return false;
        if (fn_info.params.len < call.args.len) return false;

        var temps = try self.emitNullableTryCallArgTemps(call, locals, fn_info);
        defer temps.deinit(self.scratch.allocator());

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "return ");
        try self.emitExpr(call.callee.*, locals);
        try self.emitSequencedCallArgList(temps.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return true;
    }

    fn emitNullableTryCallArgTemp(self: *CEmitter, arg: ast.Expr, locals: *std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!SequencedArgTemp {
        var replacements: std.ArrayList(TryReplacement) = .empty;
        defer replacements.deinit(self.scratch.allocator());
        if (!try self.collectNullableTryHoistsForReturn(arg, locals, &replacements)) {
            return try self.emitSequencedCallArgTemp(arg, locals, target_ty);
        }

        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(target_ty, .typedef_name), temp_name });
        try self.emitNullableTryExprWithReplacements(arg, locals, target_ty, replacements.items);
        try self.out.appendSlice(self.allocator, ";\n");
        return .{ .name = temp_name, .ty = target_ty };
    }

    fn emitNullableTryCallArgTemps(self: *CEmitter, call: anytype, locals: *std.StringHashMap(LocalInfo), fn_info: FnInfo) anyerror!std.ArrayList(SequencedArgTemp) {
        var temps: std.ArrayList(SequencedArgTemp) = .empty;
        errdefer temps.deinit(self.scratch.allocator());
        for (call.args, 0..) |arg, i| {
            try temps.append(self.scratch.allocator(), try self.emitNullableTryCallArgTemp(arg, locals, fn_info.params[i].ty));
        }
        return temps;
    }

    fn collectResultTryHoistsForReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(TryReplacement)) !bool {
        switch (expr.kind) {
            .try_expr => |inner| {
                const operand_result_ty = self.resultTypeForExpr(inner.operand.*, locals) orelse return false;
                _ = resultPayloadTypeForTag(operand_result_ty, "ok") orelse return false;
                _ = resultPayloadTypeForTag(operand_result_ty, "err") orelse return false;
                const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
                self.temp_index += 1;
                try replacements.append(self.scratch.allocator(), .{ .span = expr.span, .temp_name = temp_name });

                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(operand_result_ty, .typedef_name), temp_name });
                try self.emitExpr(inner.operand.*, locals);
                try self.out.appendSlice(self.allocator, ";\n");

                try self.writeIndent();
                try self.out.print(self.allocator, "if (!{s}.is_ok) mc_trap_InvalidRepresentation();\n", .{temp_name});
                return true;
            },
            .grouped => |inner| return try self.collectResultTryHoistsForReturn(inner.*, locals, replacements),
            .call => |node| {
                var found = false;
                for (node.args) |arg| found = (try self.collectResultTryHoistsForReturn(arg, locals, replacements)) or found;
                return found;
            },
            .unary => |node| return try self.collectResultTryHoistsForReturn(node.expr.*, locals, replacements),
            .binary => |node| {
                // Evaluate both operands without short-circuiting so `a? OP b?`
                // hoists both tries, not just the left one.
                const left_found = try self.collectResultTryHoistsForReturn(node.left.*, locals, replacements);
                const right_found = try self.collectResultTryHoistsForReturn(node.right.*, locals, replacements);
                return left_found or right_found;
            },
            .index => |node| {
                const base_found = try self.collectResultTryHoistsForReturn(node.base.*, locals, replacements);
                const index_found = try self.collectResultTryHoistsForReturn(node.index.*, locals, replacements);
                return base_found or index_found;
            },
            .member => |node| return try self.collectResultTryHoistsForReturn(node.base.*, locals, replacements),
            .cast => |node| return try self.collectResultTryHoistsForReturn(node.value.*, locals, replacements),
            else => return false,
        }
    }

    fn collectResultTryHoistsForStmt(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), return_ty: ?ast.TypeExpr, replacements: *std.ArrayList(TryReplacement)) !bool {
        if (return_ty) |ty| {
            if (resultPayloadTypeForTag(ty, "err") != null) {
                return try self.collectResultTryHoistsForLocalInit(expr, locals, ty, replacements);
            }
        }
        return try self.collectResultTryHoistsForReturn(expr, locals, replacements);
    }

    fn collectResultTryHoistsForLocalInit(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), enclosing_return_ty: ast.TypeExpr, replacements: *std.ArrayList(TryReplacement)) !bool {
        switch (expr.kind) {
            .try_expr => |inner| {
                const operand_result_ty = self.resultTypeForExpr(inner.operand.*, locals) orelse return false;
                _ = resultPayloadTypeForTag(operand_result_ty, "ok") orelse return false;
                _ = resultPayloadTypeForTag(operand_result_ty, "err") orelse return false;
                const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
                self.temp_index += 1;
                try replacements.append(self.scratch.allocator(), .{ .span = expr.span, .temp_name = temp_name });

                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = ", .{ try self.cTypeFor(operand_result_ty, .typedef_name), temp_name });
                try self.emitExpr(inner.operand.*, locals);
                try self.out.appendSlice(self.allocator, ";\n");

                try self.writeIndent();
                try self.out.print(self.allocator, "if (!{s}.is_ok) {{\n", .{temp_name});
                self.indent += 1;
                try self.writeIndent();
                try self.emitTryErrReturn(enclosing_return_ty, temp_name, inner.mapped, locals);
                self.indent -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "}\n");
                return true;
            },
            .grouped => |inner| return try self.collectResultTryHoistsForLocalInit(inner.*, locals, enclosing_return_ty, replacements),
            .call => |node| {
                var found = false;
                for (node.args) |arg| found = (try self.collectResultTryHoistsForLocalInit(arg, locals, enclosing_return_ty, replacements)) or found;
                return found;
            },
            .unary => |node| return try self.collectResultTryHoistsForLocalInit(node.expr.*, locals, enclosing_return_ty, replacements),
            .binary => |node| {
                // Evaluate both operands without short-circuiting so `a? OP b?`
                // hoists both tries, not just the left one.
                const left_found = try self.collectResultTryHoistsForLocalInit(node.left.*, locals, enclosing_return_ty, replacements);
                const right_found = try self.collectResultTryHoistsForLocalInit(node.right.*, locals, enclosing_return_ty, replacements);
                return left_found or right_found;
            },
            .index => |node| {
                const base_found = try self.collectResultTryHoistsForLocalInit(node.base.*, locals, enclosing_return_ty, replacements);
                const index_found = try self.collectResultTryHoistsForLocalInit(node.index.*, locals, enclosing_return_ty, replacements);
                return base_found or index_found;
            },
            .member => |node| return try self.collectResultTryHoistsForLocalInit(node.base.*, locals, enclosing_return_ty, replacements),
            .cast => |node| return try self.collectResultTryHoistsForLocalInit(node.value.*, locals, enclosing_return_ty, replacements),
            else => return false,
        }
    }

    fn collectNullableTryHoistsForReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(TryReplacement)) !bool {
        switch (expr.kind) {
            .try_expr => |inner| {
                const inner_c_type = try self.nullableInnerCTypeForExpr(inner.operand.*, locals) orelse return false;
                const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
                self.temp_index += 1;
                try replacements.append(self.scratch.allocator(), .{ .span = expr.span, .temp_name = temp_name });

                try self.writeIndent();
                try self.out.print(self.allocator, "{s} {s} = ", .{ inner_c_type, temp_name });
                try self.emitExpr(inner.operand.*, locals);
                try self.out.appendSlice(self.allocator, ";\n");

                try self.writeIndent();
                try self.out.print(self.allocator, "if ({s} == NULL) mc_trap_NullUnwrap();\n", .{temp_name});
                return true;
            },
            .grouped => |inner| return try self.collectNullableTryHoistsForReturn(inner.*, locals, replacements),
            .call => |node| {
                var found = false;
                for (node.args) |arg| found = (try self.collectNullableTryHoistsForReturn(arg, locals, replacements)) or found;
                return found;
            },
            .unary => |node| return try self.collectNullableTryHoistsForReturn(node.expr.*, locals, replacements),
            .binary => |node| {
                // Evaluate both operands without short-circuiting (see the
                // Result collectors) so both nested tries are hoisted.
                const left_found = try self.collectNullableTryHoistsForReturn(node.left.*, locals, replacements);
                const right_found = try self.collectNullableTryHoistsForReturn(node.right.*, locals, replacements);
                return left_found or right_found;
            },
            .index => |node| {
                const base_found = try self.collectNullableTryHoistsForReturn(node.base.*, locals, replacements);
                const index_found = try self.collectNullableTryHoistsForReturn(node.index.*, locals, replacements);
                return base_found or index_found;
            },
            .member => |node| return try self.collectNullableTryHoistsForReturn(node.base.*, locals, replacements),
            .cast => |node| return try self.collectNullableTryHoistsForReturn(node.value.*, locals, replacements),
            else => return false,
        }
    }

    fn collectMmioReadHoistsForExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo), replacements: *std.ArrayList(MmioReadReplacement)) !bool {
        switch (expr.kind) {
            .call => |node| {
                if (self.mmioAccess(node.callee.*, node.args, locals)) |access| {
                    if (!std.mem.eql(u8, access.kind, "read")) return false;
                    if (primitiveCTypeName(access.width) == null) return error.UnsupportedCEmission;

                    const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
                    self.temp_index += 1;
                    const c_type = self.cTypeForMmioValue(access.value_type);
                    try replacements.append(self.scratch.allocator(), .{
                        .span = expr.span,
                        .temp_name = temp_name,
                        .source_type_name = access.value_type,
                        .c_type = c_type,
                        .access = access,
                    });
                    return true;
                }

                var found = false;
                for (node.args) |arg| found = (try self.collectMmioReadHoistsForExpr(arg, locals, replacements)) or found;
                return found;
            },
            .grouped, .address_of, .deref => |inner| return try self.collectMmioReadHoistsForExpr(inner.*, locals, replacements),
            .unary => |node| return try self.collectMmioReadHoistsForExpr(node.expr.*, locals, replacements),
            .binary => |node| return (try self.collectMmioReadHoistsForExpr(node.left.*, locals, replacements)) or (try self.collectMmioReadHoistsForExpr(node.right.*, locals, replacements)),
            .index => |node| return (try self.collectMmioReadHoistsForExpr(node.base.*, locals, replacements)) or (try self.collectMmioReadHoistsForExpr(node.index.*, locals, replacements)),
            .member => |node| return try self.collectMmioReadHoistsForExpr(node.base.*, locals, replacements),
            .cast => |node| return try self.collectMmioReadHoistsForExpr(node.value.*, locals, replacements),
            else => return false,
        }
    }

    fn emitResultTryExprWithReplacements(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const TryReplacement) !void {
        if (!exprHasTryReplacement(expr, replacements)) return self.emitExprWithTarget(expr, locals, target_ty);
        switch (expr.kind) {
            .try_expr => {
                const temp_name = tryReplacementForSpan(expr.span, replacements).?;
                try self.out.print(self.allocator, "{s}.payload.ok", .{temp_name});
            },
            .grouped => |inner| {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitResultTryExprWithReplacements(inner.*, locals, target_ty, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            .call => |node| {
                const fn_info = if (calleeIdentName(node.callee.*)) |name| self.functions.get(name) else null;
                try self.emitExpr(node.callee.*, locals);
                try self.out.appendSlice(self.allocator, "(");
                for (node.args, 0..) |arg, i| {
                    if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                    const arg_target_ty = if (fn_info) |info| if (i < info.params.len) info.params[i].ty else null else null;
                    try self.emitResultTryExprWithReplacements(arg, locals, arg_target_ty, replacements);
                }
                try self.out.appendSlice(self.allocator, ")");
            },
            .unary => |node| {
                if (try self.emitCheckedUnaryWithTryReplacements(node, locals, target_ty, replacements)) return;
                try self.out.appendSlice(self.allocator, unaryCOp(node.op));
                try self.out.appendSlice(self.allocator, "(");
                try self.emitResultTryExprWithReplacements(node.expr.*, locals, null, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            .binary => |node| {
                if (isCheckedBinaryOp(node.op)) {
                    const target = target_ty orelse return error.UnsupportedCEmission;
                    const target_name = typeName(target) orelse return error.UnsupportedCEmission;
                    const helper = checkedHelperParts(node.op, target_name) orelse return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
                    try self.emitResultTryExprWithReplacements(node.left.*, locals, target, replacements);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitResultTryExprWithReplacements(node.right.*, locals, target, replacements);
                    try self.out.appendSlice(self.allocator, ")");
                } else {
                    try self.out.appendSlice(self.allocator, "(");
                    try self.emitResultTryExprWithReplacements(node.left.*, locals, null, replacements);
                    try self.out.print(self.allocator, " {s} ", .{binaryCOp(node.op)});
                    try self.emitResultTryExprWithReplacements(node.right.*, locals, null, replacements);
                    try self.out.appendSlice(self.allocator, ")");
                }
            },
            .cast => |node| {
                try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(node.ty.*, .typedef_name)});
                try self.emitResultTryExprWithReplacements(node.value.*, locals, null, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            else => try self.emitExprWithTarget(expr, locals, target_ty),
        }
    }

    fn emitMmioReadExprWithReplacements(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const MmioReadReplacement) anyerror!void {
        if (!exprHasMmioReadReplacement(expr, replacements)) return self.emitExprWithTarget(expr, locals, target_ty);
        if (mmioReadReplacementForSpan(expr.span, replacements)) |replacement| {
            try self.out.appendSlice(self.allocator, replacement.temp_name);
            return;
        }

        switch (expr.kind) {
            .grouped => |inner| {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitMmioReadExprWithReplacements(inner.*, locals, target_ty, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            .call => |node| {
                const fn_info = if (calleeIdentName(node.callee.*)) |name| self.functions.get(name) else null;
                try self.emitExpr(node.callee.*, locals);
                try self.out.appendSlice(self.allocator, "(");
                for (node.args, 0..) |arg, i| {
                    if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                    const arg_target_ty = if (fn_info) |info| if (i < info.params.len) info.params[i].ty else null else null;
                    try self.emitMmioReadExprWithReplacements(arg, locals, arg_target_ty, replacements);
                }
                try self.out.appendSlice(self.allocator, ")");
            },
            .unary => |node| {
                if (try self.emitCheckedUnaryWithMmioReplacements(node, locals, target_ty, replacements)) return;
                try self.out.appendSlice(self.allocator, unaryCOp(node.op));
                try self.out.appendSlice(self.allocator, "(");
                try self.emitMmioReadExprWithReplacements(node.expr.*, locals, null, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            .binary => |node| {
                if (isCheckedBinaryOp(node.op)) {
                    const target = target_ty orelse return error.UnsupportedCEmission;
                    const target_name = typeName(target) orelse return error.UnsupportedCEmission;
                    const helper = checkedHelperParts(node.op, target_name) orelse return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
                    try self.emitMmioReadExprWithReplacements(node.left.*, locals, target, replacements);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitMmioReadExprWithReplacements(node.right.*, locals, target, replacements);
                    try self.out.appendSlice(self.allocator, ")");
                } else {
                    try self.out.appendSlice(self.allocator, "(");
                    try self.emitMmioReadExprWithReplacements(node.left.*, locals, null, replacements);
                    try self.out.print(self.allocator, " {s} ", .{binaryCOp(node.op)});
                    try self.emitMmioReadExprWithReplacements(node.right.*, locals, null, replacements);
                    try self.out.appendSlice(self.allocator, ")");
                }
            },
            .index => |node| {
                try self.emitMmioReadExprWithReplacements(node.base.*, locals, null, replacements);
                try self.out.appendSlice(self.allocator, "[");
                try self.emitMmioReadExprWithReplacements(node.index.*, locals, null, replacements);
                try self.out.appendSlice(self.allocator, "]");
            },
            .member => |node| {
                if (mmioReadReplacementValueTypeForExpr(node.base.*, replacements)) |base_ty| {
                    if (self.packed_bits.get(base_ty)) |info| {
                        if (info.fields.get(node.name.text)) |field| {
                            try self.emitPackedBitsMaskTestWithMmioReplacements(node.base.*, locals, info, field.bit_index, replacements);
                            return;
                        }
                    }
                }
                try self.emitMmioReadExprWithReplacements(node.base.*, locals, null, replacements);
                try self.out.print(self.allocator, ".{s}", .{node.name.text});
            },
            .cast => |node| {
                try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(node.ty.*, .typedef_name)});
                try self.emitMmioReadExprWithReplacements(node.value.*, locals, null, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            else => try self.emitExprWithTarget(expr, locals, target_ty),
        }
    }

    fn emitNullableTryExprWithReplacements(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ?ast.TypeExpr, replacements: []const TryReplacement) !void {
        if (!exprHasTryReplacement(expr, replacements)) return self.emitExprWithTarget(expr, locals, target_ty);
        switch (expr.kind) {
            .try_expr => try self.out.appendSlice(self.allocator, tryReplacementForSpan(expr.span, replacements).?),
            .grouped => |inner| {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitNullableTryExprWithReplacements(inner.*, locals, target_ty, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            .call => |node| {
                const fn_info = if (calleeIdentName(node.callee.*)) |name| self.functions.get(name) else null;
                try self.emitExpr(node.callee.*, locals);
                try self.out.appendSlice(self.allocator, "(");
                for (node.args, 0..) |arg, i| {
                    if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                    const arg_target_ty = if (fn_info) |info| if (i < info.params.len) info.params[i].ty else null else null;
                    try self.emitNullableTryExprWithReplacements(arg, locals, arg_target_ty, replacements);
                }
                try self.out.appendSlice(self.allocator, ")");
            },
            .unary => |node| {
                if (try self.emitCheckedUnaryWithNullableReplacements(node, locals, target_ty, replacements)) return;
                try self.out.appendSlice(self.allocator, unaryCOp(node.op));
                try self.out.appendSlice(self.allocator, "(");
                try self.emitNullableTryExprWithReplacements(node.expr.*, locals, null, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            .binary => |node| {
                if (isCheckedBinaryOp(node.op)) {
                    const target = target_ty orelse return error.UnsupportedCEmission;
                    const target_name = typeName(target) orelse return error.UnsupportedCEmission;
                    const helper = checkedHelperParts(node.op, target_name) orelse return error.UnsupportedCEmission;
                    try self.out.print(self.allocator, "{s}{s}(", .{ helper.prefix, helper.suffix });
                    try self.emitNullableTryExprWithReplacements(node.left.*, locals, target, replacements);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitNullableTryExprWithReplacements(node.right.*, locals, target, replacements);
                    try self.out.appendSlice(self.allocator, ")");
                } else {
                    try self.out.appendSlice(self.allocator, "(");
                    try self.emitNullableTryExprWithReplacements(node.left.*, locals, null, replacements);
                    try self.out.print(self.allocator, " {s} ", .{binaryCOp(node.op)});
                    try self.emitNullableTryExprWithReplacements(node.right.*, locals, null, replacements);
                    try self.out.appendSlice(self.allocator, ")");
                }
            },
            .cast => |node| {
                try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(node.ty.*, .typedef_name)});
                try self.emitNullableTryExprWithReplacements(node.value.*, locals, null, replacements);
                try self.out.appendSlice(self.allocator, ")");
            },
            else => try self.emitExprWithTarget(expr, locals, target_ty),
        }
    }

    fn emitNullableTryReturn(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        const operand = switch (expr.kind) {
            .try_expr => |inner| inner.operand.*,
            .grouped => |inner| return try self.emitNullableTryReturn(inner.*, locals),
            else => return false,
        };
        const inner_c_type = try self.nullableInnerCTypeForExpr(operand, locals) orelse return false;
        const temp_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_tmp{d}", .{self.temp_index});
        self.temp_index += 1;

        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = ", .{ inner_c_type, temp_name });
        try self.emitExpr(operand, locals);
        try self.out.appendSlice(self.allocator, ";\n");

        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s} == NULL) mc_trap_NullUnwrap();\n", .{temp_name});
        try self.writeIndent();
        try self.out.print(self.allocator, "return {s};\n", .{temp_name});
        return true;
    }

    fn sliceReturnTypeForCall(self: *CEmitter, call: anytype) ?ast.TypeExpr {
        const fn_name = calleeIdentName(call.callee.*) orelse return null;
        const info = self.functions.get(fn_name) orelse return null;
        const return_ty = info.return_type orelse return null;
        return if (return_ty.kind == .slice) return_ty else null;
    }

    fn sliceElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
        return switch (ty.kind) {
            .slice => |node| node.child.*,
            .qualified => |node| sliceElementType(node.child.*),
            else => null,
        };
    }

    fn arrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
        return switch (ty.kind) {
            .array => |node| node.child.*,
            .qualified => |node| arrayElementType(node.child.*),
            else => null,
        };
    }

    fn arrayLenText(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
        return switch (ty.kind) {
            .array => |node| try self.arrayLenTextForExpr(node.len),
            .qualified => |node| try self.arrayLenText(node.child.*),
            else => null,
        };
    }

    fn arrayLenTextForExpr(self: *CEmitter, expr: ast.Expr) ![]const u8 {
        const value = constArrayLenValue(expr, &self.const_fns, &self.const_globals) orelse return error.UnsupportedCEmission;
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    // The array type of `expr`, if it is an array — including the element of an
    // outer array access (`m[i]` over `[N][M]T` yields `[M]T`), which enables
    // nested indexing `m[i][j]`. Returns null for non-array expressions.
    // The declared type of a value expression (a local, global, struct field, or
    // array element) — enough to give an enum-literal comparison operand its type.
    fn operandEmitType(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        switch (expr.kind) {
            .ident => |ident| {
                if (locals) |ls| {
                    if (ls.get(ident.text)) |info| return info.source_ty;
                }
                if (self.globals.get(ident.text)) |g| return g.source_ty;
                return null;
            },
            .grouped => |inner| return self.operandEmitType(inner.*, locals),
            .member => |node| {
                const base_ty = self.operandEmitType(node.base.*, locals) orelse return null;
                var resolved = self.resolveAliasType(base_ty);
                if (resolved.kind == .pointer) resolved = self.resolveAliasType(resolved.kind.pointer.child.*);
                const struct_name = switch (resolved.kind) {
                    .name => |n| n.text,
                    else => return null,
                };
                const struct_decl = self.structs.get(struct_name) orelse return null;
                for (struct_decl.fields) |field| {
                    if (std.mem.eql(u8, field.name.text, node.name.text)) return field.ty;
                }
                return null;
            },
            .index => |node| {
                const base_ty = self.operandEmitType(node.base.*, locals) orelse return null;
                const resolved = self.resolveAliasType(base_ty);
                return if (resolved.kind == .array) resolved.kind.array.child.* else null;
            },
            else => return null,
        }
    }

    fn arrayTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const local_set = locals orelse return null;
        switch (expr.kind) {
            .ident => |ident| {
                // A local array, or — falling back — a global array (so taking the
                // address of a global array element, `&g_buf[i]`, indexes `.elems`).
                const source_ty = if (local_set.get(ident.text)) |info|
                    (info.source_ty orelse return null)
                else if (self.globals.get(ident.text)) |g|
                    (g.source_ty orelse return null)
                else
                    return null;
                const resolved = self.resolveAliasType(source_ty);
                return if (resolved.kind == .array) resolved else null;
            },
            .grouped => |inner| return self.arrayTypeForExpr(inner.*, locals),
            .index => |node| {
                const base_arr = self.arrayTypeForExpr(node.base.*, locals) orelse return null;
                const resolved_child = self.resolveAliasType(base_arr.kind.array.child.*);
                return if (resolved_child.kind == .array) resolved_child else null;
            },
            // An array-typed struct field (`s.items` over `struct { items: [N]T }`)
            // is indexed through its `.elems` member like any array.
            .member => |node| {
                const struct_name = self.structTypeNameForExpr(node.base.*, locals) orelse return null;
                const struct_decl = self.structs.get(struct_name) orelse return null;
                for (struct_decl.fields) |field| {
                    if (std.mem.eql(u8, field.name.text, node.name.text)) {
                        const resolved = self.resolveAliasType(field.ty);
                        return if (resolved.kind == .array) resolved else null;
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    // Whether an expression has a pointer type, so member access lowers as `->`.
    // MMIO/slice/array accesses take dedicated paths before reaching here, so this
    // covers ordinary `*T` struct pointers (e.g. a borrowed `move` handle).
    fn exprIsPointer(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) bool {
        const set = locals orelse return false;
        return switch (expr.kind) {
            .ident => |id| blk: {
                const info = set.get(id.text) orelse break :blk false;
                const ty = info.source_ty orelse break :blk false;
                break :blk self.resolveAliasType(ty).kind == .pointer;
            },
            // A struct field that is itself a pointer (`vq.desc` over
            // `struct Virtq { desc: *mut DescTable }`), so a chained `vq.desc.d`
            // lowers as `vq->desc->d`.
            .member => |m| blk: {
                const sname = self.structTypeNameForExpr(m.base.*, locals) orelse break :blk false;
                const sdecl = self.structs.get(sname) orelse break :blk false;
                for (sdecl.fields) |f| {
                    if (std.mem.eql(u8, f.name.text, m.name.text)) {
                        break :blk self.resolveAliasType(f.ty).kind == .pointer;
                    }
                }
                break :blk false;
            },
            .grouped => |inner| self.exprIsPointer(inner.*, locals),
            else => false,
        };
    }

    // The pointee type of a pointer-typed expression (`p` where `p: *T` → `T`).
    fn derefPointeeType(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const set = locals orelse return null;
        return switch (expr.kind) {
            .ident => |id| blk: {
                const info = set.get(id.text) orelse break :blk null;
                const ty = info.source_ty orelse break :blk null;
                const resolved = self.resolveAliasType(ty);
                break :blk switch (resolved.kind) {
                    .pointer => |p| p.child.*,
                    else => null,
                };
            },
            .grouped => |inner| self.derefPointeeType(inner.*, locals),
            else => null,
        };
    }

    fn structTypeNameForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |id| blk: {
                const set = locals orelse break :blk null;
                const info = set.get(id.text) orelse break :blk null;
                const ty = info.source_ty orelse break :blk null;
                const resolved = self.resolveAliasType(ty);
                break :blk switch (resolved.kind) {
                    .name => |n| n.text,
                    // Member access auto-derefs a pointer-to-struct.
                    .pointer => |p| switch (self.resolveAliasType(p.child.*).kind) {
                        .name => |n| n.text,
                        else => null,
                    },
                    else => null,
                };
            },
            // A field whose type is a struct (or pointer-to-struct), so a chained
            // `vq.desc.d` resolves `vq.desc` to its struct for the next access.
            .member => |m| blk: {
                const sname = self.structTypeNameForExpr(m.base.*, locals) orelse break :blk null;
                const sdecl = self.structs.get(sname) orelse break :blk null;
                for (sdecl.fields) |f| {
                    if (std.mem.eql(u8, f.name.text, m.name.text)) {
                        const resolved = self.resolveAliasType(f.ty);
                        break :blk switch (resolved.kind) {
                            .name => |n| n.text,
                            .pointer => |p| switch (self.resolveAliasType(p.child.*).kind) {
                                .name => |n| n.text,
                                else => null,
                            },
                            else => null,
                        };
                    }
                }
                break :blk null;
            },
            // An array element whose type is a struct (`table[i]` over `[N]S`), so a
            // chained `table[i].field` resolves `table[i]` to its struct — needed to
            // index a field-array of an array element (`table[i].name[j]`).
            .index => blk: {
                const ty = self.operandEmitType(expr, locals) orelse break :blk null;
                const resolved = self.resolveAliasType(ty);
                break :blk switch (resolved.kind) {
                    .name => |n| n.text,
                    .pointer => |p| switch (self.resolveAliasType(p.child.*).kind) {
                        .name => |n| n.text,
                        else => null,
                    },
                    else => null,
                };
            },
            .grouped => |inner| self.structTypeNameForExpr(inner.*, locals),
            else => null,
        };
    }

    fn arrayReturnTypeForExpr(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .call => |node| blk: {
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                const ret_ty = info.return_type orelse break :blk null;
                break :blk if (ret_ty.kind == .array) ret_ty else null;
            },
            .grouped => |inner| self.arrayReturnTypeForExpr(inner.*),
            else => null,
        };
    }

    fn resultTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                const info = locals.get(ident.text) orelse break :blk null;
                break :blk info.result_ty;
            },
            .call => |node| blk: {
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                const ret_ty = info.return_type orelse break :blk null;
                break :blk if (resultPayloadTypeForTag(ret_ty, "ok") != null and resultPayloadTypeForTag(ret_ty, "err") != null) ret_ty else null;
            },
            .grouped => |inner| self.resultTypeForExpr(inner.*, locals),
            else => null,
        };
    }

    fn enumReturnTypeForExpr(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .call => |node| blk: {
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                const ret_ty = info.return_type orelse break :blk null;
                const enum_name = typeName(ret_ty) orelse break :blk null;
                break :blk if (self.enums.contains(enum_name)) ret_ty else null;
            },
            .grouped => |inner| self.enumReturnTypeForExpr(inner.*),
            else => null,
        };
    }

    fn nullableReturnTypeForExpr(self: *CEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .call => |node| blk: {
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                const ret_ty = info.return_type orelse break :blk null;
                break :blk if (ret_ty.kind == .nullable) ret_ty else null;
            },
            .grouped => |inner| self.nullableReturnTypeForExpr(inner.*),
            else => null,
        };
    }

    fn callReturnTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .call => |node| blk: {
                if (bitcastReturnTypeForCall(node)) |ty| break :blk ty;
                if (self.assumeNoaliasReturnTypeForCall(node, locals)) |ty| break :blk ty;
                if (self.rawManyOffsetReturnTypeForCall(node, locals)) |ty| break :blk ty;
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                break :blk info.return_type;
            },
            .grouped => |inner| self.callReturnTypeForExpr(inner.*, locals),
            else => null,
        };
    }

    fn assumeNoaliasReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        if (!isAssumeNoaliasCall(call) or call.args.len != 2) return null;
        return self.exprSourceTypeForEmission(call.args[0], locals);
    }

    fn exprSourceTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (local_set.get(ident.text)) |info| return info.source_ty;
                }
                if (self.globals.get(ident.text)) |info| return info.source_ty;
                return null;
            },
            .call => |node| blk: {
                if (bitcastReturnTypeForCall(node)) |ty| break :blk ty;
                if (self.assumeNoaliasReturnTypeForCall(node, locals)) |ty| break :blk ty;
                if (self.rawManyOffsetReturnTypeForCall(node, locals)) |ty| break :blk ty;
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                break :blk info.return_type;
            },
            .cast => |node| node.ty.*,
            .grouped => |inner| self.exprSourceTypeForEmission(inner.*, locals),
            else => null,
        };
    }

    fn nullableInnerCTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                const info = locals.get(ident.text) orelse break :blk null;
                break :blk info.nullable_inner_c_type;
            },
            .call => |node| blk: {
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                const ret_ty = info.return_type orelse break :blk null;
                break :blk try self.nullableInnerCTypeForType(ret_ty);
            },
            .grouped => |inner| try self.nullableInnerCTypeForExpr(inner.*, locals),
            else => null,
        };
    }

    fn nullableInnerCTypeForType(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
        return switch (ty.kind) {
            .nullable => |child| try self.nullableInnerCType(child.*),
            .qualified => |node| try self.nullableInnerCTypeForType(node.child.*),
            else => null,
        };
    }

    fn exprContainsResultTry(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .try_expr => |inner| self.resultTypeForExpr(inner.operand.*, locals) != null,
            .grouped, .address_of, .deref => |inner| self.exprContainsResultTry(inner.*, locals),
            .unary => |node| self.exprContainsResultTry(node.expr.*, locals),
            .binary => |node| self.exprContainsResultTry(node.left.*, locals) or self.exprContainsResultTry(node.right.*, locals),
            .call => |node| {
                for (node.args) |arg| if (self.exprContainsResultTry(arg, locals)) return true;
                return false;
            },
            .index => |node| self.exprContainsResultTry(node.base.*, locals) or self.exprContainsResultTry(node.index.*, locals),
            .member => |node| self.exprContainsResultTry(node.base.*, locals),
            .cast => |node| self.exprContainsResultTry(node.value.*, locals),
            else => false,
        };
    }

    fn callArgsContainResultTry(self: *CEmitter, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        for (args) |arg| {
            if (self.exprContainsResultTry(arg, locals)) return true;
        }
        return false;
    }

    fn exprContainsNullableTry(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        return switch (expr.kind) {
            .try_expr => |inner| (try self.nullableInnerCTypeForExpr(inner.operand.*, locals)) != null,
            .grouped, .address_of, .deref => |inner| try self.exprContainsNullableTry(inner.*, locals),
            .unary => |node| try self.exprContainsNullableTry(node.expr.*, locals),
            .binary => |node| (try self.exprContainsNullableTry(node.left.*, locals)) or (try self.exprContainsNullableTry(node.right.*, locals)),
            .call => |node| {
                for (node.args) |arg| if (try self.exprContainsNullableTry(arg, locals)) return true;
                return false;
            },
            .index => |node| (try self.exprContainsNullableTry(node.base.*, locals)) or (try self.exprContainsNullableTry(node.index.*, locals)),
            .member => |node| try self.exprContainsNullableTry(node.base.*, locals),
            .cast => |node| try self.exprContainsNullableTry(node.value.*, locals),
            else => false,
        };
    }

    fn callArgsContainNullableTry(self: *CEmitter, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) !bool {
        for (args) |arg| {
            if (try self.exprContainsNullableTry(arg, locals)) return true;
        }
        return false;
    }

    fn exprContainsMmioRead(self: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        return switch (expr.kind) {
            .call => |node| {
                if (self.mmioAccess(node.callee.*, node.args, locals)) |access| return std.mem.eql(u8, access.kind, "read");
                for (node.args) |arg| if (self.exprContainsMmioRead(arg, locals)) return true;
                return false;
            },
            .grouped, .address_of, .deref => |inner| self.exprContainsMmioRead(inner.*, locals),
            .unary => |node| self.exprContainsMmioRead(node.expr.*, locals),
            .binary => |node| self.exprContainsMmioRead(node.left.*, locals) or self.exprContainsMmioRead(node.right.*, locals),
            .index => |node| self.exprContainsMmioRead(node.base.*, locals) or self.exprContainsMmioRead(node.index.*, locals),
            .member => |node| self.exprContainsMmioRead(node.base.*, locals),
            .cast => |node| self.exprContainsMmioRead(node.value.*, locals),
            else => false,
        };
    }

    fn callArgsContainMmioRead(self: *CEmitter, args: []const ast.Expr, locals: *std.StringHashMap(LocalInfo)) bool {
        for (args) |arg| {
            if (self.exprContainsMmioRead(arg, locals)) return true;
        }
        return false;
    }

    fn localIndexElementType(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| {
                const info = locals.get(ident.text) orelse return null;
                const source_ty = info.source_ty orelse return null;
                return arrayElementType(source_ty) orelse sliceElementType(source_ty);
            },
            .grouped => |inner| localIndexElementType(inner.*, locals),
            else => null,
        };
    }

    fn mmioAccess(self: *CEmitter, callee: ast.Expr, args: []ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?MmioAccess {
        const member = switch (callee.kind) {
            .member => |node| node,
            else => return null,
        };
        const kind: []const u8 = if (std.mem.eql(u8, member.name.text, "read"))
            "read"
        else if (std.mem.eql(u8, member.name.text, "write"))
            "write"
        else
            return null;

        const reg_member = switch (member.base.kind) {
            .member => |node| node,
            else => return null,
        };
        const param = switch (reg_member.base.kind) {
            .ident => |ident| ident.text,
            else => return null,
        };
        const struct_name = if (locals.get(param)) |info| info.mmio_pointee orelse return null else return null;
        const mmio_struct = self.mmio_structs.get(struct_name) orelse return null;
        const field = mmio_struct.fields.get(reg_member.name.text) orelse return null;
        return .{
            .kind = kind,
            .param = param,
            .struct_name = struct_name,
            // Output name matches the (cIdent-mangled) C struct field declarator;
            // the lookup above stays on the raw MC name.
            .field = self.cIdent(reg_member.name.text) catch reg_member.name.text,
            .value_type = field.value_type,
            .width = field.width,
            .ordering = orderingArg(args),
        };
    }

    fn cTypeForMmioValue(self: *CEmitter, value_type: []const u8) []const u8 {
        if (self.packed_bits.contains(value_type)) return value_type;
        return primitiveCTypeName(value_type) orelse "uint8_t";
    }

    fn localInfoFromType(self: *CEmitter, ty: ast.TypeExpr) !LocalInfo {
        const resolved_ty = self.resolveAliasType(ty);
        const source_type_name = typeName(resolved_ty);
        const mmio_pointee = mmioPointee(resolved_ty);
        return switch (resolved_ty.kind) {
            .array => |node| .{ .source_ty = resolved_ty, .c_type = try self.cTypeFor(resolved_ty, .typedef_name), .source_type_name = source_type_name, .array_len = try self.arrayLenTextForExpr(node.len), .array_elems_field = "elems", .iterable_element_c_type = try self.cTypeFor(node.child.*, .typedef_name), .mmio_pointee = mmio_pointee },
            .slice => |node| .{
                .source_ty = resolved_ty,
                .c_type = try self.cTypeFor(resolved_ty, .typedef_name),
                .source_type_name = source_type_name,
                .slice_ptr_field = "ptr",
                .slice_len_field = "len",
                .iterable_element_c_type = try self.cTypeFor(node.child.*, .typedef_name),
                .mmio_pointee = mmio_pointee,
            },
            .nullable => |child| .{
                .source_ty = resolved_ty,
                .c_type = try self.cTypeFor(resolved_ty, .typedef_name),
                .source_type_name = source_type_name,
                .nullable_inner_c_type = try self.nullableInnerCType(child.*),
                .mmio_pointee = mmio_pointee,
            },
            .generic => |node| .{
                .source_ty = resolved_ty,
                .c_type = try self.cTypeFor(resolved_ty, .typedef_name),
                .source_type_name = source_type_name,
                .result_ty = if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) resolved_ty else null,
                .result_ok_c_type = if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) try self.cTypeFor(node.args[0], .typedef_name) else null,
                .result_err_c_type = if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2) try self.cTypeFor(node.args[1], .typedef_name) else null,
                .mmio_pointee = mmio_pointee,
            },
            else => .{ .source_ty = resolved_ty, .c_type = try self.cTypeFor(resolved_ty, .typedef_name), .source_type_name = source_type_name, .mmio_pointee = mmio_pointee },
        };
    }

    fn globalInfoFromType(self: *CEmitter, ty: ast.TypeExpr) !GlobalInfo {
        const resolved_ty = self.resolveAliasType(ty);
        const name = typeName(resolved_ty) orelse "unknown";
        const c_type = try self.cTypeFor(resolved_ty, .typedef_name);
        if (arrayElementType(resolved_ty)) |element_ty| {
            const element_info = try self.globalElementInfoFromType(element_ty);
            return .{
                .type_name = name,
                .c_type = c_type,
                .race_type_name = name,
                .race_c_type = c_type,
                .width_bits = widthBits(name),
                .pointer_like = false,
                .source_ty = resolved_ty,
                .array_element_info = element_info,
                .array_len = try self.arrayLenText(resolved_ty),
            };
        }
        // A closure field is a `{ code, env }` fat struct: read/write it as a plain
        // aggregate copy, not via a (nonexistent) per-type race helper. A function-pointer
        // field is a single scalar pointer: the relaxed-atomic pointer path fits it.
        if (resolved_ty.kind == .closure_type) {
            return .{
                .type_name = name,
                .c_type = c_type,
                .race_type_name = name,
                .race_c_type = c_type,
                .width_bits = widthBits(name),
                .pointer_like = false,
                .aggregate = true,
                .source_ty = resolved_ty,
            };
        }
        if (resolved_ty.kind == .fn_pointer) {
            return .{
                .type_name = name,
                .c_type = c_type,
                .race_type_name = name,
                .race_c_type = c_type,
                .width_bits = widthBits(name),
                .pointer_like = true,
                .source_ty = resolved_ty,
            };
        }
        if (self.enums.get(name)) |enum_decl| {
            if (enum_decl.repr) |repr| {
                const repr_name = typeName(repr) orelse name;
                return .{
                    .type_name = name,
                    .c_type = c_type,
                    .race_type_name = repr_name,
                    .race_c_type = try self.cTypeFor(repr, .typedef_name),
                    .width_bits = widthBits(repr_name),
                    .pointer_like = false,
                    .source_ty = resolved_ty,
                };
            }
            return .{
                .type_name = name,
                .c_type = c_type,
                .race_type_name = "isize",
                .race_c_type = "intptr_t",
                .width_bits = widthBits("isize"),
                .pointer_like = false,
                .source_ty = resolved_ty,
            };
        }
        if (self.packed_bits.get(name)) |packed_bits| {
            return .{
                .type_name = name,
                .c_type = c_type,
                .race_type_name = packed_bits.repr_name,
                .race_c_type = packed_bits.repr_c_type,
                .width_bits = widthBits(packed_bits.repr_name),
                .pointer_like = false,
                .source_ty = resolved_ty,
            };
        }
        const is_aggregate = self.structs.contains(name) or
            self.overlay_unions.contains(name) or
            self.tagged_unions.contains(name);
        // Address newtypes (PAddr/VAddr/DmaAddr) are scalar uintptr_t values, so they use
        // the usize scalar race helper rather than a (nonexistent) per-name helper.
        if (isOpaqueAddressTypeName(name)) {
            return .{
                .type_name = name,
                .c_type = c_type,
                .race_type_name = "usize",
                .race_c_type = "uintptr_t",
                .width_bits = widthBits("usize"),
                .pointer_like = false,
                .source_ty = resolved_ty,
            };
        }
        return .{
            .type_name = name,
            .c_type = c_type,
            .race_type_name = name,
            .race_c_type = c_type,
            .width_bits = widthBits(name),
            .pointer_like = isPointerLikeGlobalType(resolved_ty),
            .aggregate = is_aggregate,
            .source_ty = resolved_ty,
        };
    }

    fn globalElementInfoFromType(self: *CEmitter, ty: ast.TypeExpr) !GlobalElementInfo {
        const resolved_ty = self.resolveAliasType(ty);
        const name = typeName(resolved_ty) orelse "unknown";
        const c_type = try self.cTypeFor(resolved_ty, .typedef_name);
        if (self.enums.get(name)) |enum_decl| {
            const repr = enum_decl.repr orelse return .{
                .source_ty = resolved_ty,
                .c_type = c_type,
                .race_type_name = "isize",
                .race_c_type = "intptr_t",
            };
            const repr_name = typeName(repr) orelse name;
            return .{
                .source_ty = resolved_ty,
                .c_type = c_type,
                .race_type_name = repr_name,
                .race_c_type = try self.cTypeFor(repr, .typedef_name),
            };
        }
        if (self.packed_bits.get(name)) |packed_bits| {
            return .{
                .source_ty = resolved_ty,
                .c_type = c_type,
                .race_type_name = packed_bits.repr_name,
                .race_c_type = packed_bits.repr_c_type,
            };
        }
        // Struct/union/closure elements have no scalar race helper: access them as plain
        // aggregates. Function-pointer elements are scalar pointers (relaxed-atomic).
        const is_aggregate = self.structs.contains(name) or
            self.overlay_unions.contains(name) or
            self.tagged_unions.contains(name) or
            resolved_ty.kind == .closure_type;
        return .{
            .source_ty = resolved_ty,
            .c_type = c_type,
            .race_type_name = name,
            .race_c_type = c_type,
            .aggregate = is_aggregate,
            .pointer_like = resolved_ty.kind == .fn_pointer,
        };
    }

    fn nullableInnerCType(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
        return switch (ty.kind) {
            .pointer, .raw_many_pointer => try self.cTypeFor(ty, .typedef_name),
            .qualified => |node| try self.nullableInnerCType(node.child.*),
            else => null,
        };
    }

    fn rawManyOffsetTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .call => |call| self.rawManyOffsetReturnTypeForCall(call, locals),
            .grouped => |inner| self.rawManyOffsetTypeForExpr(inner.*, locals),
            else => null,
        };
    }

    fn rawManyOffsetDerefTypeForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const inner = switch (expr.kind) {
            .grouped => |grouped| return self.rawManyOffsetDerefTypeForExpr(grouped.*, locals),
            .deref => |inner| inner.*,
            else => return null,
        };
        const ptr_ty = self.rawManyOffsetTypeForExpr(inner, locals) orelse return null;
        return rawManyElementType(ptr_ty);
    }

    fn rawManyOffsetReturnTypeForCall(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        const info = self.rawManyOffsetCallInfo(call, locals) orelse return null;
        return info.ty;
    }

    fn rawManyOffsetCallInfo(self: *CEmitter, call: anytype, locals: ?*std.StringHashMap(LocalInfo)) ?RawManyOffsetInfo {
        if (call.type_args.len != 0 or call.args.len != 1) return null;
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "offset")) return null;
        const base_ty = self.rawManyOffsetExprTypeForEmission(member.base.*, locals) orelse return null;
        if (!isRawManyPointerType(base_ty)) return null;
        return .{ .base = member.base.*, .ty = base_ty };
    }

    fn rawManyOffsetExprTypeForEmission(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| {
                const local_set = locals orelse return null;
                const info = local_set.get(ident.text) orelse return null;
                return info.source_ty;
            },
            .call => |node| blk: {
                if (self.rawManyOffsetReturnTypeForCall(node, locals)) |ty| break :blk ty;
                const fn_name = calleeIdentName(node.callee.*) orelse break :blk null;
                const info = self.functions.get(fn_name) orelse break :blk null;
                break :blk info.return_type;
            },
            .grouped => |inner| self.rawManyOffsetExprTypeForEmission(inner.*, locals),
            else => null,
        };
    }

    fn cPayloadFieldName(self: *CEmitter, name: []const u8) ![]const u8 {
        if (!isCKeyword(name)) return name;
        return std.fmt.allocPrint(self.scratch.allocator(), "{s}_", .{name});
    }

    fn overlayFieldAccess(self: *CEmitter, member: anytype, locals: *std.StringHashMap(LocalInfo)) ?OverlayFieldAccess {
        const name = overlayUnionNameForExpr(member.base.*, locals) orelse return null;
        const info = self.overlay_unions.get(name) orelse return null;
        const field = info.fields.get(member.name.text) orelse return null;
        return .{ .base = member.base.*, .field = field };
    }
};

const LocalInfo = struct {
    source_ty: ?ast.TypeExpr = null,
    c_type: ?[]const u8 = null,
    source_type_name: ?[]const u8 = null,
    // Value-range propagation: compile-time-constant value of an immutable (`let`)
    // integer local whose initializer is constant and in range.
    const_int: ?i128 = null,
    array_len: ?[]const u8 = null,
    array_elems_field: ?[]const u8 = null,
    slice_ptr_field: ?[]const u8 = null,
    slice_len_field: ?[]const u8 = null,
    iterable_element_c_type: ?[]const u8 = null,
    nullable_inner_c_type: ?[]const u8 = null,
    result_ty: ?ast.TypeExpr = null,
    result_ok_c_type: ?[]const u8 = null,
    result_err_c_type: ?[]const u8 = null,
    mmio_pointee: ?[]const u8 = null,
};

const ArrayInfo = struct {
    name: []const u8,
    element_ty: ast.TypeExpr,
    element_c_type: []const u8,
    len: []const u8,
};

// A by-value aggregate typedef emitted in dependency order (see
// `emitOrderedAggregates`).
const AggregateEmitUnit = union(enum) {
    struct_decl: ast.StructDecl,
    array: ArrayInfo,
    result: ResultInfo,
    tagged_union: ast.UnionDecl,
};

const RawManyOffsetInfo = struct {
    base: ast.Expr,
    ty: ast.TypeExpr,
};

fn numericExprType(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const local_set = locals orelse return null;
            const info = local_set.get(ident.text) orelse return null;
            const source_ty = info.source_ty orelse return null;
            return if (isNumericStorageType(source_ty)) source_ty else null;
        },
        .grouped => |inner| numericExprType(inner.*, locals),
        .unary => |node| numericExprType(node.expr.*, locals),
        .binary => |node| {
            if (!isNumericValueBinaryOp(node.op)) return null;
            const left_ty = numericExprType(node.left.*, locals) orelse return null;
            const right_ty = numericExprType(node.right.*, locals) orelse return null;
            if (!sameCStorageType(left_ty, right_ty)) return null;
            return left_ty;
        },
        else => null,
    };
}

fn localCopyTypeForInitializer(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const info = locals.get(ident.text) orelse return null;
            return info.source_ty;
        },
        .grouped => |inner| localCopyTypeForInitializer(inner.*, locals),
        else => null,
    };
}

fn isNumericStorageType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .name => |ident| checkedTypeSuffix(ident.text) != null,
        .generic => |node| {
            if ((!std.mem.eql(u8, node.base.text, "wrap") and !std.mem.eql(u8, node.base.text, "sat")) or node.args.len != 1) return false;
            return isNumericStorageType(node.args[0]);
        },
        .qualified => |node| isNumericStorageType(node.child.*),
        else => false,
    };
}

// Which of `break`/`continue` does this loop body use targeting *this* loop
// (i.e. not nested inside an inner loop)? Each needs a labeled target so a
// `break`/`continue` inside a `switch` reaches the loop, not the switch.
const LoopJumps = struct {
    brk: bool = false,
    cont: bool = false,
};

fn loopBodyHasOwnBreakContinue(block: ast.Block) LoopJumps {
    var out = LoopJumps{};
    for (block.items) |stmt| {
        const j = stmtOwnBreakContinue(stmt);
        out.brk = out.brk or j.brk;
        out.cont = out.cont or j.cont;
    }
    return out;
}

fn stmtOwnBreakContinue(stmt: ast.Stmt) LoopJumps {
    return switch (stmt.kind) {
        .@"break" => .{ .brk = true },
        .@"continue" => .{ .cont = true },
        .block, .unsafe_block, .comptime_block => |b| loopBodyHasOwnBreakContinue(b),
        .contract_block => |n| loopBodyHasOwnBreakContinue(n.block),
        .if_let => |n| blk: {
            var j = loopBodyHasOwnBreakContinue(n.then_block);
            if (n.else_block) |e| {
                const ej = loopBodyHasOwnBreakContinue(e);
                j.brk = j.brk or ej.brk;
                j.cont = j.cont or ej.cont;
            }
            break :blk j;
        },
        .@"switch" => |n| blk: {
            var j = LoopJumps{};
            for (n.arms) |arm| {
                switch (arm.body) {
                    .block => |b| {
                        const aj = loopBodyHasOwnBreakContinue(b);
                        j.brk = j.brk or aj.brk;
                        j.cont = j.cont or aj.cont;
                    },
                    .expr => {},
                }
            }
            break :blk j;
        },
        // A nested loop captures its own break/continue.
        .loop => .{},
        else => .{},
    };
}

fn exprIsNumericLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        // A char literal is a byte value; in arithmetic it adopts its sibling
        // operand's integer storage type (e.g. `c - '0'` over a `u8`).
        .int_literal, .float_literal, .char_literal => true,
        .grouped => |inner| exprIsNumericLiteral(inner.*),
        .unary => |node| node.op == .neg and exprIsNumericLiteral(node.expr.*),
        else => false,
    };
}

fn isNumericValueBinaryOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr, .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

fn sameCStorageType(left: ast.TypeExpr, right: ast.TypeExpr) bool {
    return switch (left.kind) {
        .name => |left_name| switch (right.kind) {
            .name => |right_name| std.mem.eql(u8, left_name.text, right_name.text),
            .qualified => |right_node| sameCStorageType(left, right_node.child.*),
            else => false,
        },
        .generic => |left_node| switch (right.kind) {
            .generic => |right_node| {
                if (!std.mem.eql(u8, left_node.base.text, right_node.base.text)) return false;
                if (left_node.args.len != right_node.args.len) return false;
                for (left_node.args, right_node.args) |left_arg, right_arg| {
                    if (!sameCStorageType(left_arg, right_arg)) return false;
                }
                return true;
            },
            .qualified => |right_node| sameCStorageType(left, right_node.child.*),
            else => false,
        },
        .qualified => |left_node| sameCStorageType(left_node.child.*, right),
        else => false,
    };
}

fn isRawManyPointerType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .raw_many_pointer => true,
        .qualified => |node| isRawManyPointerType(node.child.*),
        else => false,
    };
}

fn isNonNullPointerType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer, .raw_many_pointer => true,
        .qualified => |node| isNonNullPointerType(node.child.*),
        else => false,
    };
}

fn rawManyElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .raw_many_pointer => |node| node.child.*,
        .qualified => |node| rawManyElementType(node.child.*),
        else => null,
    };
}

const FnInfo = struct {
    params: []const ast.Param,
    return_type: ?ast.TypeExpr,
    is_extern: bool,
};

const TryReplacement = struct {
    span: ast.Span,
    temp_name: []const u8,
};

const MmioReadReplacement = struct {
    span: ast.Span,
    temp_name: []const u8,
    source_type_name: []const u8,
    c_type: []const u8,
    access: MmioAccess,
};

const SliceAccess = struct {
    ptr_field: []const u8,
    len_field: []const u8,
};

const SliceInfo = struct {
    name: []const u8,
    ptr_type: []const u8,
};

const PackedBitsInfo = struct {
    repr_name: []const u8,
    repr_c_type: []const u8,
    fields: std.StringHashMap(PackedBitsField),
};

const PackedBitsField = struct {
    bit_index: usize,
};

const OverlayUnionInfo = struct {
    size: usize,
    alignment: usize,
    fields: std.StringHashMap(OverlayFieldInfo),
};

const OverlayFieldInfo = struct {
    ty: ast.TypeExpr,
    layout: OverlayLayout,
    byte_array_len: ?[]const u8,
};

const OverlayFieldAccess = struct {
    base: ast.Expr,
    field: OverlayFieldInfo,
};

const OverlayLayout = struct {
    size: usize,
    alignment: usize,
};

const ReflectionCallKind = enum {
    size,
    alignment,
    field_offset,
    bit_offset,
    repr,
};

const ResultInfo = struct {
    name: []const u8,
    ok_ty: ast.TypeExpr,
    err_ty: ast.TypeExpr,
};

const ResultSwitchSubject = struct {
    name: []const u8,
    ok_c_type: []const u8,
    err_c_type: []const u8,
};

const ResultSwitchBranch = struct {
    condition: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    binding_name: ?[]const u8 = null,
    binding_type: ?[]const u8 = null,
    payload_field: ?[]const u8 = null,
};

const NullableSwitchSubject = struct {
    name: []const u8,
    inner_c_type: []const u8,
};

const NullableSwitchBranch = struct {
    condition: ?[]const u8 = null,
    binding_name: ?[]const u8 = null,
};

const TaggedUnionSwitchSubject = struct {
    name: []const u8,
    type_name: []const u8,
    decl: ast.UnionDecl,
};

const TaggedUnionSwitchBranch = struct {
    condition: ?[]const u8 = null,
    is_wildcard: bool = false,
    binding_name: ?[]const u8 = null,
    binding_type: ?[]const u8 = null,
    payload_field: ?[]const u8 = null,
};

const StructTypeStyle = enum { typedef_name, struct_tag };

fn cloneLocals(allocator: std.mem.Allocator, locals: std.StringHashMap(LocalInfo)) !std.StringHashMap(LocalInfo) {
    var cloned = std.StringHashMap(LocalInfo).init(allocator);
    errdefer cloned.deinit();
    var it = locals.iterator();
    while (it.next()) |entry| try cloned.put(entry.key_ptr.*, entry.value_ptr.*);
    return cloned;
}

fn addMmioReadReplacementLocals(locals: *std.StringHashMap(LocalInfo), replacements: []const MmioReadReplacement) !void {
    for (replacements) |replacement| {
        try locals.put(replacement.temp_name, .{
            .c_type = replacement.c_type,
            .source_type_name = replacement.source_type_name,
        });
    }
}

const Inspector = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mmio_structs: std.StringHashMap(MmioStruct),
    structs: std.StringHashMap(ast.StructDecl),
    globals: std.StringHashMap(GlobalInfo),

    fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) Inspector {
        return .{
            .allocator = allocator,
            .out = out,
            .mmio_structs = std.StringHashMap(MmioStruct).init(allocator),
            .structs = std.StringHashMap(ast.StructDecl).init(allocator),
            .globals = std.StringHashMap(GlobalInfo).init(allocator),
        };
    }

    fn deinit(self: *Inspector) void {
        var structs = self.mmio_structs.valueIterator();
        while (structs.next()) |mmio_struct| mmio_struct.fields.deinit();
        self.mmio_structs.deinit();
        self.structs.deinit();
        self.globals.deinit();
    }

    fn inspectModule(self: *Inspector, module: ast.Module) anyerror!void {
        defer self.deinit();
        try self.collectDeclFacts(module);
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl, .extern_fn => |fn_decl| if (fn_decl.body) |body| try self.inspectFn(fn_decl, body),
                .type_alias, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectDeclFacts(self: *Inspector, module: ast.Module) !void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |struct_decl| {
                    if (struct_decl.abi) |abi| {
                        if (std.mem.eql(u8, abi, "mmio")) try self.collectMmioStruct(struct_decl);
                    } else {
                        try self.structs.put(struct_decl.name.text, struct_decl);
                    }
                },
                .packed_bits_decl => |packed_bits| try self.writePackedBitsLowering(packed_bits),
                .overlay_union_decl => |overlay_union| try self.writeOverlayUnionLowering(overlay_union),
                .global_decl => |global| {
                    if (global.ty) |ty| try self.globals.put(global.name.text, globalInfoFromType(ty));
                },
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .union_decl, .opaque_decl => {},
            }
        }
    }

    fn writePackedBitsLowering(self: *Inspector, packed_bits: ast.PackedBitsDecl) !void {
        try self.out.print(
            self.allocator,
            "lower packed_bits name={s} repr={s} strategy=mask_shift c_bitfields=false semantic_source=mc_bits\n",
            .{ packed_bits.name.text, typeName(packed_bits.repr) orelse "unknown" },
        );
    }

    fn writeOverlayUnionLowering(self: *Inspector, overlay_union: ast.OverlayUnionDecl) !void {
        try self.out.print(
            self.allocator,
            "lower overlay_union name={s} strategy=byte_storage c_union=false semantic_source=mc_bytes\n",
            .{overlay_union.name.text},
        );
    }

    fn collectMmioStruct(self: *Inspector, struct_decl: ast.StructDecl) !void {
        var fields = std.StringHashMap(MmioField).init(self.allocator);
        errdefer fields.deinit();
        for (struct_decl.fields) |field| {
            if (mmioFieldFromType(field.ty)) |mmio_field| {
                if (!fields.contains(field.name.text)) try fields.put(field.name.text, mmio_field);
            }
        }
        try self.mmio_structs.put(struct_decl.name.text, .{ .fields = fields });
    }

    fn inspectFn(self: *Inspector, fn_decl: ast.FnDecl, body: ast.Block) anyerror!void {
        var ctx = FnContext.init(self.allocator, fn_decl.name.text);
        defer ctx.deinit();

        for (fn_decl.params) |param| {
            try ctx.locals.put(param.name.text, {});
            try ctx.recordLocalType(param.name.text, param.ty);
            if (mmioPointee(param.ty)) |struct_name| try ctx.mmio_params.put(param.name.text, struct_name);
            // §19.1: an IrqOff parameter is a compile-time capability witnessing
            // interrupts are disabled; it lowers to a 1-byte token with no
            // runtime effect.
            if (param.ty.kind == .name and std.mem.eql(u8, param.ty.kind.name.text, "IrqOff")) {
                try self.out.print(self.allocator, "lower irq_off fn={s} param={s} capability=interrupts_disabled c_type=uint8_t witness=true\n", .{ fn_decl.name.text, param.name.text });
            }
        }

        try self.inspectBlock(body, &ctx);
    }

    fn inspectBlock(self: *Inspector, block: ast.Block, ctx: *FnContext) anyerror!void {
        for (block.items) |stmt| try self.inspectStmt(stmt, ctx);
    }

    fn inspectStmt(self: *Inspector, stmt: ast.Stmt, ctx: *FnContext) anyerror!void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                for (local.names) |name| {
                    try ctx.locals.put(name.text, {});
                    if (local.ty) |ty| try ctx.recordLocalType(name.text, ty);
                }
                if (local.init) |expr| try self.inspectExpr(expr, ctx);
            },
            .loop => |node| {
                if (node.iterable) |expr| try self.inspectExpr(expr, ctx);
                try self.inspectBlock(node.body, ctx);
            },
            .if_let => |node| {
                try self.inspectExpr(node.value, ctx);
                try self.inspectBlock(node.then_block, ctx);
                if (node.else_block) |else_block| try self.inspectBlock(else_block, ctx);
            },
            .@"switch" => |node| {
                try self.inspectExpr(node.subject, ctx);
                for (node.arms) |arm| switch (arm.body) {
                    .block => |body| try self.inspectBlock(body, ctx),
                    .expr => |expr| try self.inspectExpr(expr, ctx),
                };
            },
            .unsafe_block, .comptime_block, .block => |body| try self.inspectBlock(body, ctx),
            .contract_block => |contract| {
                const name = contractName(contract.attr);
                try self.out.print(
                    self.allocator,
                    "lower contract_scope fn={s} contract={s} region=1 metadata_begin=1 contained=true\n",
                    .{ ctx.name, name },
                );
                const previous_active = ctx.active_contract;
                const previous_ended = ctx.ended_contract;
                ctx.active_contract = name;
                ctx.ended_contract = null;
                try self.inspectBlock(contract.block, ctx);
                ctx.active_contract = previous_active;
                ctx.ended_contract = name;
                try self.out.print(
                    self.allocator,
                    "lower contract_scope fn={s} contract={s} region=1 metadata_end=1 contained=true\n",
                    .{ ctx.name, name },
                );
                try self.out.print(
                    self.allocator,
                    "lower metadata_containment fn={s} contract={s} region=1 metadata_begin=1 metadata_end=1 metadata_attached_after_region=false contained=true\n",
                    .{ ctx.name, name },
                );
                if (previous_ended) |ended| ctx.ended_contract = ended;
            },
            .asm_stmt => |asm_stmt| try self.writeAsmMetadata(ctx.name, asm_stmt),
            .@"return" => |maybe| if (maybe) |expr| try self.inspectExpr(expr, ctx),
            .@"break", .@"continue" => {},
            .@"defer", .expr, .assert => |expr| try self.inspectExpr(expr, ctx),
            .assignment => |node| {
                if (ordinaryGlobalTarget(self.allocator, node.target, ctx.*, self.globals, self.structs)) |target| {
                    defer if (target.owned_name) self.allocator.free(target.name);
                    try self.writeOrdinaryAccess(ctx.name, target, "store");
                    if (node.target.kind == .index) try self.inspectExpr(node.target.kind.index.index.*, ctx);
                } else if (localOrdinaryTarget(node.target, ctx.*)) |target| {
                    try self.writeLocalOrdinaryAccess(ctx.name, target, "store");
                }
                try self.inspectExpr(node.value, ctx);
            },
        }
    }

    fn inspectExpr(self: *Inspector, expr: ast.Expr, ctx: *FnContext) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| {
                if (!ctx.locals.contains(ident.text)) {
                    if (self.globals.get(ident.text)) |global| {
                        try self.writeOrdinaryAccess(ctx.name, .{ .name = ident.text, .info = global }, "load");
                    }
                } else if (isFixtureLocalAccess(ctx.name, ident.text) and ctx.locals.contains(ident.text)) {
                    try self.writeLocalOrdinaryAccess(ctx.name, ident.text, "load");
                }
            },
            .int_literal, .float_literal, .string_literal, .char_literal, .bool_literal, .null_literal, .uninit_literal, .void_literal, .enum_literal, .unreachable_expr => {},
            .array_literal => |items| for (items) |item| try self.inspectExpr(item, ctx),
            .struct_literal => |fields| for (fields) |field| try self.inspectExpr(field.value, ctx),
            .grouped, .address_of, .deref => |inner| try self.inspectExpr(inner.*, ctx),
            .try_expr => |inner| try self.inspectExpr(inner.operand.*, ctx),
            .block => |body| try self.inspectBlock(body, ctx),
            .unary => |node| {
                if (node.op == .neg) {
                    if (exprType(node.expr.*, ctx)) |ty| {
                        try self.writeCheckedArithmetic(ctx, .neg, ty, .integer_overflow);
                    }
                }
                try self.inspectExpr(node.expr.*, ctx);
            },
            .binary => |node| {
                const op = CheckedOp{ .binary = node.op };
                if (arithmeticDomainForBinary(node, ctx)) |domain| {
                    try self.writeArithmeticDomainLowering(ctx, domain, node.op);
                } else if (node.op == .shl) {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, op, ty, .invalid_shift);
                    try self.writeCheckedArithmetic(ctx, op, ty, .integer_overflow);
                } else if (node.op == .shr) {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, op, ty, .invalid_shift);
                } else if (checkedOpName(op)) |_| {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, op, ty, trapKindForBinary(node, ty));
                }
                try self.inspectExpr(node.left.*, ctx);
                try self.inspectExpr(node.right.*, ctx);
            },
            .cast => |node| try self.inspectExpr(node.value.*, ctx),
            .call => |node| {
                try self.writeContractCallMetadata(node.callee.*, ctx);
                try self.writeRaceCallMetadata(node.callee.*, ctx);
                try self.writeAtomicCallMetadata(node.callee.*, node.args, ctx);
                try self.writeDmaCallMetadata(node.callee.*, node.args, ctx);
                try self.writeBitcastMetadata(node, ctx);
                if (try self.mmioAccess(node.callee.*, node.args, ctx)) |access| {
                    const bits = widthBits(access.width);
                    try self.out.print(
                        self.allocator,
                        "lower mmio_access fn={s} op={s} register={s}.{s} value_type={s} register_width={s} emitted_width={s} volatile=true address_space=mmio ordering={s}\n",
                        .{ ctx.name, access.kind, access.struct_name, access.field, access.value_type, bits, bits, access.ordering },
                    );
                    try self.writeMmioBackendAccess(ctx.name, access, bits);
                    // section 18: a typed MMIO write whose value is a buf.dma_addr()
                    // is a DMA-descriptor handoff — it programs a device register
                    // with a DMA address. Per section 17 it participates in the
                    // MMIO acquire/release ordering set, so its ordering composes
                    // with cache/ordinary/atomic/MMIO operations.
                    if (std.mem.eql(u8, access.kind, "write") and node.args.len > 0) {
                        if (dmaAddrHandoffObject(node.args[0], ctx.*)) |dma_object| {
                            try self.out.print(
                                self.allocator,
                                "lower dma_descriptor fn={s} register={s}.{s} object={s} value=dma_addr ordering={s} handoff=true composes_with=section17_mmio participants=ordinary,atomic,dma_descriptor,mmio\n",
                                .{ ctx.name, access.struct_name, access.field, dma_object, access.ordering },
                            );
                        }
                    }
                    if (std.mem.eql(u8, access.ordering, "release")) {
                        if (ctx.mmio_sequence.cache_clean_seen) {
                            try self.out.print(
                                self.allocator,
                                "lower mmio_sequence fn={s} edge=cache_clean_before_release before=cache.clean barrier={s}.{s}.{s} ordering=release prevents_reorder=true\n",
                                .{ ctx.name, access.struct_name, access.field, access.kind },
                            );
                        }
                        if (ctx.mmio_sequence.ordinary_store_seen) {
                            try self.out.print(
                                self.allocator,
                                "lower mmio_sequence fn={s} edge=ordinary_before_release before=raw.store barrier={s}.{s}.{s} ordering=release prevents_reorder=true\n",
                                .{ ctx.name, access.struct_name, access.field, access.kind },
                            );
                        }
                        try self.out.print(
                            self.allocator,
                            "lower mmio_order fn={s} op={s} register={s}.{s} ordering=release barrier_before=true prevents_before_after=true\n",
                            .{ ctx.name, access.kind, access.struct_name, access.field },
                        );
                        try self.writeMmioBackendBarrier(ctx.name, access, "before", "mc_barrier_release_before");
                    } else if (std.mem.eql(u8, access.ordering, "acquire")) {
                        ctx.mmio_sequence.pending_acquire = access;
                        try self.out.print(
                            self.allocator,
                            "lower mmio_order fn={s} op={s} register={s}.{s} ordering=acquire barrier_after=true prevents_after_before=true\n",
                            .{ ctx.name, access.kind, access.struct_name, access.field },
                        );
                        try self.writeMmioBackendBarrier(ctx.name, access, "after", "mc_barrier_acquire_after");
                    }
                }
                if (isRawStoreCall(node.callee.*)) {
                    if (ctx.mmio_sequence.pending_acquire) |access| {
                        try self.out.print(
                            self.allocator,
                            "lower mmio_sequence fn={s} edge=ordinary_after_acquire barrier={s}.{s}.{s} ordering=acquire after=raw.store prevents_reorder=true\n",
                            .{ ctx.name, access.struct_name, access.field, access.kind },
                        );
                        ctx.mmio_sequence.pending_acquire = null;
                    }
                    ctx.mmio_sequence.ordinary_store_seen = true;
                }
                try self.inspectExpr(node.callee.*, ctx);
                for (node.args) |arg| try self.inspectExpr(arg, ctx);
            },
            .index => |node| {
                if (ordinaryGlobalTarget(self.allocator, expr, ctx.*, self.globals, self.structs)) |target| {
                    defer if (target.owned_name) self.allocator.free(target.name);
                    try self.writeOrdinaryAccess(ctx.name, target, "load");
                } else {
                    try self.inspectExpr(node.base.*, ctx);
                }
                try self.inspectExpr(node.index.*, ctx);
            },
            .member => |node| {
                if (ordinaryGlobalTarget(self.allocator, expr, ctx.*, self.globals, self.structs)) |target| {
                    defer if (target.owned_name) self.allocator.free(target.name);
                    try self.writeOrdinaryAccess(ctx.name, target, "load");
                    return;
                }
                try self.inspectExpr(node.base.*, ctx);
            },
        }
    }

    fn writeMmioBackendAccess(self: *Inspector, fn_name: []const u8, access: MmioAccess, bits: []const u8) !void {
        const helper_base = if (std.mem.eql(u8, access.kind, "read")) "mc_mmio_read" else "mc_mmio_write";
        if (std.mem.eql(u8, access.kind, "read")) {
            try self.out.print(
                self.allocator,
                "lower mmio_backend fn={s} op=read register={s}.{s} helper={s}_{s} value_type={s} width_bits={s} volatile=true address_space=mmio c_expr={s}_{s}(&{s}.{s})\n",
                .{ fn_name, access.struct_name, access.field, helper_base, access.width, access.value_type, bits, helper_base, access.width, access.struct_name, access.field },
            );
        } else {
            try self.out.print(
                self.allocator,
                "lower mmio_backend fn={s} op=write register={s}.{s} helper={s}_{s} value_type={s} width_bits={s} volatile=true address_space=mmio c_expr={s}_{s}(&{s}.{s}, <value>)\n",
                .{ fn_name, access.struct_name, access.field, helper_base, access.width, access.value_type, bits, helper_base, access.width, access.struct_name, access.field },
            );
        }
    }

    fn writeMmioBackendBarrier(self: *Inspector, fn_name: []const u8, access: MmioAccess, placement: []const u8, helper: []const u8) !void {
        try self.out.print(
            self.allocator,
            "lower mmio_barrier fn={s} register={s}.{s} ordering={s} placement={s} helper={s} prevents_reorder=true\n",
            .{ fn_name, access.struct_name, access.field, access.ordering, placement, helper },
        );
    }

    fn writeCheckedArithmetic(self: *Inspector, ctx: *FnContext, op: CheckedOp, ty: []const u8, trap: TrapKind) !void {
        const op_name = checkedOpName(op) orelse return;
        try self.out.print(
            self.allocator,
            "lower checked_arith fn={s} op={s} type={s} trap={s} strategy=helper emits_plain_c_overflow=false\n",
            .{ ctx.name, op_name, ty, trap.text() },
        );
        if (ctx.ended_contract) |contract| {
            if (std.mem.eql(u8, contract, "no_overflow") and isOverflowOp(op)) {
                try self.out.print(
                    self.allocator,
                    "lower post_contract_arith fn={s} contract={s} op={s} metadata_attached=false\n",
                    .{ ctx.name, contract, op_name },
                );
            }
        }
    }

    fn writeArithmeticDomainLowering(self: *Inspector, ctx: *FnContext, domain: []const u8, op: ast.BinaryOp) !void {
        const op_name = arithmeticDomainOpName(op);
        const strategy = if (std.mem.eql(u8, domain, "sat")) "saturating_helper" else if (op == .shl or op == .shr) "shift_helper" else "plain_unsigned";
        try self.out.print(
            self.allocator,
            "lower arithmetic_domain fn={s} domain={s} op={s} strategy={s} language_trap=false overflow_trap=false emits_checked_overflow_helper=false\n",
            .{ ctx.name, domain, op_name, strategy },
        );
    }

    fn writeOrdinaryAccess(self: *Inspector, fn_name: []const u8, target: GlobalAccess, access: []const u8) !void {
        const object = target.name;
        const helper_base = if (std.mem.eql(u8, access, "load")) "mc_race_load" else "mc_race_store";
        if (std.mem.eql(u8, access, "load")) {
            try self.out.print(
                self.allocator,
                "lower ordinary_access fn={s} object={s} access={s} race_class=possibly_shared strategy=race_helper helper={s}_{s} type={s} width_bits={s} helper_required=true helper_available=true c_plain_access=false c_expr={s}_{s}(&{s})\n",
                .{ fn_name, object, access, helper_base, target.info.race_type_name, target.info.race_type_name, target.info.width_bits, helper_base, target.info.race_type_name, object },
            );
            try self.out.print(
                self.allocator,
                "lower race_backend fn={s} object={s} access={s} action=emit_helper helper={s}_{s} type={s} width_bits={s} expr={s}_{s}(&{s}) c_plain_access=false reject_if_helper_missing=true\n",
                .{ fn_name, object, access, helper_base, target.info.race_type_name, target.info.race_type_name, target.info.width_bits, helper_base, target.info.race_type_name, object },
            );
        } else {
            try self.out.print(
                self.allocator,
                "lower ordinary_access fn={s} object={s} access={s} race_class=possibly_shared strategy=race_helper helper={s}_{s} type={s} width_bits={s} helper_required=true helper_available=true c_plain_access=false c_expr={s}_{s}(&{s}, <value>)\n",
                .{ fn_name, object, access, helper_base, target.info.race_type_name, target.info.race_type_name, target.info.width_bits, helper_base, target.info.race_type_name, object },
            );
            try self.out.print(
                self.allocator,
                "lower race_backend fn={s} object={s} access={s} action=emit_helper helper={s}_{s} type={s} width_bits={s} expr={s}_{s}(&{s}, value) c_plain_access=false reject_if_helper_missing=true\n",
                .{ fn_name, object, access, helper_base, target.info.race_type_name, target.info.race_type_name, target.info.width_bits, helper_base, target.info.race_type_name, object },
            );
        }
        try self.out.print(
            self.allocator,
            "lower race_semantics fn={s} object={s} creates_happens_before=false assumes_no_race=false\n",
            .{ fn_name, object },
        );
        try self.out.print(
            self.allocator,
            "lower c_ub fn={s} object={s} c_data_race_ub_dependency=false\n",
            .{ fn_name, object },
        );
        if (std.mem.eql(u8, access, "load")) {
            try self.out.print(
                self.allocator,
                "lower racing_load_semantics fn={s} object={s} result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false\n",
                .{ fn_name, object },
            );
        }
    }

    fn writeLocalOrdinaryAccess(self: *Inspector, fn_name: []const u8, object: []const u8, access: []const u8) !void {
        try self.out.print(
            self.allocator,
            "lower ordinary_access fn={s} object={s} access={s} race_class=local strategy=plain_c c_plain_access=true\n",
            .{ fn_name, object, access },
        );
    }

    fn writeContractCallMetadata(self: *Inspector, callee: ast.Expr, ctx: *FnContext) !void {
        const name = knownContractCalleeName(callee) orelse return;
        if (ctx.active_contract) |contract| {
            if (contractMatchesCallee(contract, name)) {
                try self.out.print(
                    self.allocator,
                    "lower contract_metadata fn={s} contract={s} callee={s} metadata_attached=true contained=true\n",
                    .{ ctx.name, contract, name },
                );
            }
        } else if (ctx.ended_contract) |contract| {
            if (std.mem.eql(u8, name, "raw.store")) {
                try self.out.print(
                    self.allocator,
                    "lower post_contract_call fn={s} contract={s} callee={s} metadata_attached=false\n",
                    .{ ctx.name, contract, name },
                );
            }
        }
    }

    fn writeRaceCallMetadata(self: *Inspector, callee: ast.Expr, ctx: *FnContext) !void {
        if (isIdentNamed(callee, "possibly_racing_store") and std.mem.eql(u8, ctx.name, "racing_increment_is_not_atomic")) {
            try self.out.print(
                self.allocator,
                "lower non_atomic_rmw fn={s} object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false c_data_race_ub_dependency=false\n",
                .{ctx.name},
            );
        }
    }

    fn writeAtomicCallMetadata(self: *Inspector, callee: ast.Expr, args: []const ast.Expr, ctx: *FnContext) !void {
        const access = atomicAccess(callee, args, ctx.*) orelse return;
        const order_const = atomicOrderCConstant(access.ordering) orelse "UNKNOWN";
        const builtin = if (std.mem.eql(u8, access.op, "load"))
            "__atomic_load_n"
        else if (std.mem.eql(u8, access.op, "store"))
            "__atomic_store_n"
        else if (std.mem.eql(u8, access.op, "fetch_sub"))
            "__atomic_fetch_sub"
        else
            "__atomic_fetch_add";
        try self.out.print(
            self.allocator,
            "lower atomic_access fn={s} op={s} object={s} type={s} ordering={s} c_order={s} builtin={s} volatile=false ordinary_access=false creates_happens_before={s}\n",
            .{ ctx.name, access.op, access.object, access.payload_type, access.ordering, order_const, builtin, if (atomicOrderSynchronizes(access.ordering)) "true" else "false" },
        );
        try self.out.print(
            self.allocator,
            "lower atomic_backend fn={s} op={s} object={s} c_expr={s}(&{s}, ...) c_plain_access=false volatile=false\n",
            .{ ctx.name, access.op, access.object, builtin, access.object },
        );
    }

    fn writeDmaCallMetadata(self: *Inspector, callee: ast.Expr, args: []const ast.Expr, ctx: *FnContext) !void {
        const op = dmaOperation(callee, args, ctx.*) orelse return;
        if (std.mem.eql(u8, op.kind, "dma_addr")) {
            try self.out.print(
                self.allocator,
                "lower dma_access fn={s} op=dma_addr object={s} payload={s} mode={s} result=DmaAddr address_class=dma_addr not_paddr=true not_vaddr=true\n",
                .{ ctx.name, op.object, op.payload, op.mode },
            );
            return;
        }
        if (std.mem.eql(u8, op.kind, "as_slice")) {
            try self.out.print(
                self.allocator,
                "lower dma_access fn={s} op=as_slice object={s} payload={s} mode={s} result=slice temporal_cache_proven=false core_guarantee=address_class_only\n",
                .{ ctx.name, op.object, op.payload, op.mode },
            );
            return;
        }
        try self.out.print(
            self.allocator,
            "lower dma_cache fn={s} op={s} object={s} payload={s} mode={s} helper=mc_dma_cache_{s} required_for_noncoherent=true\n",
            .{ ctx.name, op.kind, op.object, op.payload, op.mode, op.kind },
        );
        // section 18 + section 17 composition: cache.clean/invalidate are typed
        // ordering barriers, not volatile pokes. clean precedes a device handoff
        // (clean-before-handoff), invalidate precedes a CPU read of the buffer
        // (invalidate-before-read). Each composes with the section 17 MMIO
        // acquire/release ordering: a clean may not move after a later .release
        // descriptor write, an invalidate may not move before an earlier
        // .acquire descriptor read.
        if (std.mem.eql(u8, op.kind, "clean")) {
            try self.out.print(
                self.allocator,
                "lower dma_cache_order fn={s} op=clean object={s} role=before_device_handoff barrier=true composes_with=section17_mmio_release\n",
                .{ ctx.name, op.object },
            );
            ctx.mmio_sequence.cache_clean_seen = true;
        } else if (std.mem.eql(u8, op.kind, "invalidate")) {
            try self.out.print(
                self.allocator,
                "lower dma_cache_order fn={s} op=invalidate object={s} role=before_cpu_read barrier=true composes_with=section17_mmio_acquire\n",
                .{ ctx.name, op.object },
            );
        }
    }

    fn writeBitcastMetadata(self: *Inspector, call: anytype, ctx: *FnContext) !void {
        if (!isBitcastCall(call) or call.type_args.len != 1 or call.args.len != 1) return;
        const target = typeName(call.type_args[0]) orelse "unknown";
        const source = exprType(call.args[0], ctx) orelse "unknown";
        try self.out.print(
            self.allocator,
            "lower bitcast fn={s} source={s} target={s} strategy=memcpy helper=mc_bitcast_memcpy strict_aliasing_cast=false c_expr=mc_bitcast_memcpy\n",
            .{ ctx.name, source, target },
        );
    }

    fn writeAsmMetadata(self: *Inspector, fn_name: []const u8, asm_stmt: ast.AsmStmt) !void {
        if (asm_stmt.form != .@"opaque") return;
        try self.out.print(
            self.allocator,
            "lower asm fn={s} form=opaque volatile={} conservative=true memory_clobber={} optimizer_assumptions=false c_backend=gcc_clang_asm\n",
            .{ fn_name, asm_stmt.is_volatile, asmHasMemoryClobber(asm_stmt) },
        );
    }

    fn mmioAccess(self: *Inspector, callee: ast.Expr, args: []ast.Expr, ctx: *FnContext) !?MmioAccess {
        const member = switch (callee.kind) {
            .member => |node| node,
            else => return null,
        };
        const kind: []const u8 = if (std.mem.eql(u8, member.name.text, "read"))
            "read"
        else if (std.mem.eql(u8, member.name.text, "write"))
            "write"
        else
            return null;

        const reg_member = switch (member.base.kind) {
            .member => |node| node,
            else => return null,
        };
        const param = switch (reg_member.base.kind) {
            .ident => |ident| ident.text,
            else => return null,
        };
        const struct_name = ctx.mmio_params.get(param) orelse return null;
        const mmio_struct = self.mmio_structs.get(struct_name) orelse return null;
        const field = mmio_struct.fields.get(reg_member.name.text) orelse return null;
        return .{
            .kind = kind,
            .struct_name = struct_name,
            .field = reg_member.name.text,
            .value_type = field.value_type,
            .width = field.width,
            .ordering = orderingArg(args),
        };
    }
};

const FnContext = struct {
    name: []const u8,
    locals: std.StringHashMap(void),
    local_types: std.StringHashMap([]const u8),
    local_domains: std.StringHashMap([]const u8),
    local_atomic_payloads: std.StringHashMap([]const u8),
    local_dma_payloads: std.StringHashMap([]const u8),
    local_dma_modes: std.StringHashMap([]const u8),
    mmio_params: std.StringHashMap([]const u8),
    active_contract: ?[]const u8 = null,
    ended_contract: ?[]const u8 = null,
    mmio_sequence: MmioSequenceState = .{},

    fn init(allocator: std.mem.Allocator, name: []const u8) FnContext {
        return .{
            .name = name,
            .locals = std.StringHashMap(void).init(allocator),
            .local_types = std.StringHashMap([]const u8).init(allocator),
            .local_domains = std.StringHashMap([]const u8).init(allocator),
            .local_atomic_payloads = std.StringHashMap([]const u8).init(allocator),
            .local_dma_payloads = std.StringHashMap([]const u8).init(allocator),
            .local_dma_modes = std.StringHashMap([]const u8).init(allocator),
            .mmio_params = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit(self: *FnContext) void {
        self.locals.deinit();
        self.local_types.deinit();
        self.local_domains.deinit();
        self.local_atomic_payloads.deinit();
        self.local_dma_payloads.deinit();
        self.local_dma_modes.deinit();
        self.mmio_params.deinit();
    }

    fn recordLocalType(self: *FnContext, name: []const u8, ty: ast.TypeExpr) !void {
        if (genericChildType(ty, "wrap")) |inner| {
            try self.local_domains.put(name, "wrap");
            if (typeName(inner)) |inner_name| try self.local_types.put(name, inner_name);
            return;
        }
        if (genericChildType(ty, "sat")) |inner| {
            try self.local_domains.put(name, "sat");
            if (typeName(inner)) |inner_name| try self.local_types.put(name, inner_name);
            return;
        }
        if (genericChildType(ty, "atomic")) |inner| {
            if (typeName(inner)) |inner_name| {
                try self.local_atomic_payloads.put(name, inner_name);
                try self.local_types.put(name, inner_name);
            }
            return;
        }
        if (dmaBufInfo(ty)) |info| {
            if (typeName(info.payload)) |payload_name| {
                try self.local_dma_payloads.put(name, payload_name);
                try self.local_dma_modes.put(name, info.mode);
            }
            return;
        }
        if (typeName(ty)) |ty_name| try self.local_types.put(name, ty_name);
    }
};

const MmioSequenceState = struct {
    ordinary_store_seen: bool = false,
    pending_acquire: ?MmioAccess = null,
    // section 18: a cache.clean (clean-for-device) seen before a DMA-descriptor
    // handoff write composes with the section 17 MMIO .release ordering — the
    // clean may not be moved after the handoff.
    cache_clean_seen: bool = false,
};

const MmioStruct = struct {
    fields: std.StringHashMap(MmioField),
};

const MmioField = struct {
    value_type: []const u8,
    width: []const u8,
};

const MmioAccess = struct {
    kind: []const u8,
    param: []const u8 = "",
    struct_name: []const u8,
    field: []const u8,
    value_type: []const u8,
    width: []const u8,
    ordering: []const u8,
};

const AtomicAccess = struct {
    op: []const u8,
    object: []const u8,
    payload_type: []const u8,
    ordering: []const u8,
};

const DmaOperation = struct {
    kind: []const u8,
    object: []const u8,
    payload: []const u8,
    mode: []const u8,
};

const GlobalInfo = struct {
    type_name: []const u8,
    c_type: []const u8,
    race_type_name: []const u8,
    race_c_type: []const u8,
    width_bits: []const u8,
    pointer_like: bool,
    // An aggregate (struct) global: there is no scalar atomic race helper for it, so
    // load/store lower to a plain C struct copy rather than mc_race_load/store_<T>.
    aggregate: bool = false,
    source_ty: ?ast.TypeExpr = null,
    array_element_info: ?GlobalElementInfo = null,
    array_len: ?[]const u8 = null,
};

const GlobalElementInfo = struct {
    source_ty: ast.TypeExpr,
    c_type: []const u8,
    race_type_name: []const u8,
    race_c_type: []const u8,
    aggregate: bool = false,    // struct/union/closure element -> plain `.elems[i]` access
    pointer_like: bool = false, // pointer / fn-pointer element -> relaxed-atomic access
};

const GlobalAccess = struct {
    name: []const u8,
    info: GlobalInfo,
    owned_name: bool = false,
};

const GlobalArrayElementAccess = struct {
    base_name: []const u8,
    index: ast.Expr,
    len: []const u8,
    element_info: GlobalElementInfo,
};

fn globalInfoFromType(ty: ast.TypeExpr) GlobalInfo {
    const name = typeName(ty) orelse "unknown";
    if (globalArrayElementType(ty)) |element_ty| {
        const element_name = typeName(element_ty) orelse "unknown";
        return .{
            .type_name = name,
            .c_type = cType(ty),
            .race_type_name = name,
            .race_c_type = cType(ty),
            .width_bits = widthBits(name),
            .pointer_like = false,
            .source_ty = ty,
            .array_element_info = .{
                .source_ty = element_ty,
                .c_type = cType(element_ty),
                .race_type_name = element_name,
                .race_c_type = cType(element_ty),
            },
            .array_len = globalArrayLenText(ty),
        };
    }
    return .{
        .type_name = name,
        .c_type = cType(ty),
        .race_type_name = name,
        .race_c_type = cType(ty),
        .width_bits = widthBits(name),
        .pointer_like = isPointerLikeGlobalType(ty),
        .source_ty = ty,
    };
}

fn globalArrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| globalArrayElementType(node.child.*),
        else => null,
    };
}

fn globalArrayLenText(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .array => |node| intLiteralText(node.len),
        .qualified => |node| globalArrayLenText(node.child.*),
        else => null,
    };
}

fn isPointerLikeGlobalType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer, .raw_many_pointer, .slice => true,
        .nullable => |child| isPointerLikeGlobalType(child.*),
        .qualified => |node| isPointerLikeGlobalType(node.child.*),
        else => false,
    };
}

fn mmioFieldFromType(ty: ast.TypeExpr) ?MmioField {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (std.mem.eql(u8, generic.base.text, "Reg")) {
        if (generic.args.len == 0) return null;
        const width = typeName(generic.args[0]) orelse "unknown";
        return .{ .value_type = width, .width = width };
    }
    if (std.mem.eql(u8, generic.base.text, "RegBits")) {
        if (generic.args.len == 0) return null;
        const width = typeName(generic.args[0]) orelse "unknown";
        const value_type = if (generic.args.len > 1) typeName(generic.args[1]) orelse width else width;
        return .{ .value_type = value_type, .width = width };
    }
    return null;
}

fn mmioPointee(ty: ast.TypeExpr) ?[]const u8 {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "MmioPtr") or generic.args.len != 1) return null;
    return typeName(generic.args[0]);
}

fn resultPayloadTypeForTag(ty: ast.TypeExpr, tag: []const u8) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return null;
            if (std.mem.eql(u8, tag, "ok")) return node.args[0];
            if (std.mem.eql(u8, tag, "err")) return node.args[1];
            return null;
        },
        .qualified => |node| resultPayloadTypeForTag(node.child.*, tag),
        else => null,
    };
}

fn isMmioStructAbi(struct_decl: ast.StructDecl) bool {
    return if (struct_decl.abi) |abi| std.mem.eql(u8, abi, "mmio") else false;
}

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

// A string literal lowers to a C string literal cast to a `u8` pointer target
// (`*const u8` or `[*]const u8`), the FFI-facing string shape MC's grammar can
// express. Other targets are left unsupported (loud failure by design).
fn isStringLiteralTarget(ty: ast.TypeExpr) bool {
    const child = switch (ty.kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        else => return false,
    };
    const name = typeName(child) orelse return false;
    return std.mem.eql(u8, name, "u8");
}

fn structTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| structTypeName(node.child.*),
        else => null,
    };
}

fn structFieldType(struct_decl: ast.StructDecl, field_name: []const u8) ?ast.TypeExpr {
    for (struct_decl.fields) |field| {
        if (std.mem.eql(u8, field.name.text, field_name)) return field.ty;
    }
    return null;
}

fn isWrapType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapType(node.child.*),
        else => false,
    };
}

fn isSatType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatType(node.child.*),
        else => false,
    };
}

fn genericChildType(ty: ast.TypeExpr, base_name: []const u8) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, base_name) or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| genericChildType(node.child.*, base_name),
        else => null,
    };
}

fn isCVoidType(ty: ast.TypeExpr) bool {
    const name = typeName(ty) orelse return false;
    return std.mem.eql(u8, name, "void") or std.mem.eql(u8, name, "never");
}

fn isVoidType(ty: ast.TypeExpr) bool {
    const name = typeName(ty) orelse return false;
    return std.mem.eql(u8, name, "void");
}

fn isVoidLiteralExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .void_literal => true,
        .grouped => |inner| isVoidLiteralExpr(inner.*),
        else => false,
    };
}

fn simpleNameType(name: []const u8, span: diagnostics.Span) ast.TypeExpr {
    return .{
        .span = span,
        .kind = .{ .name = .{ .text = name, .span = span } },
    };
}

fn isCKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "auto",           "break",         "case",     "char",     "const",      "continue",
        "default",        "do",            "double",   "else",     "enum",       "extern",
        "float",          "for",           "goto",     "if",       "inline",     "int",
        "long",           "register",      "restrict", "return",   "short",      "signed",
        "sizeof",         "static",        "struct",   "switch",   "typedef",    "union",
        "unsigned",       "void",          "volatile", "while",    "_Alignas",   "_Alignof",
        "_Atomic",        "_Bool",         "_Complex", "_Generic", "_Imaginary", "_Noreturn",
        "_Static_assert", "_Thread_local",
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

fn cType(ty: ast.TypeExpr) []const u8 {
    switch (ty.kind) {
        .pointer => |node| return ptrCType(node.child.*, node.mutability),
        .raw_many_pointer => |node| return ptrCType(node.child.*, node.mutability),
        .slice => |node| return ptrCType(node.child.*, node.mutability),
        .array => |node| return ptrCType(node.child.*, .none),
        .nullable => |child| return cType(child.*),
        else => {},
    }
    const name = typeName(ty) orelse return "void *";
    if (std.mem.eql(u8, name, "void")) return "void";
    if (std.mem.eql(u8, name, "c_void")) return "void";
    if (std.mem.eql(u8, name, "never")) return "void";
    if (std.mem.eql(u8, name, "bool")) return "bool";
    if (std.mem.eql(u8, name, "u8")) return "uint8_t";
    if (std.mem.eql(u8, name, "u16")) return "uint16_t";
    if (std.mem.eql(u8, name, "u32")) return "uint32_t";
    if (std.mem.eql(u8, name, "u64")) return "uint64_t";
    if (std.mem.eql(u8, name, "usize")) return "uintptr_t";
    if (isOpaqueAddressTypeName(name)) return "uintptr_t";
    // IrqOff (§19.1) capability token: a 1-byte witness value.
    if (std.mem.eql(u8, name, "IrqOff")) return "uint8_t";
    if (std.mem.eql(u8, name, "i8")) return "int8_t";
    if (std.mem.eql(u8, name, "i16")) return "int16_t";
    if (std.mem.eql(u8, name, "i32")) return "int32_t";
    if (std.mem.eql(u8, name, "i64")) return "int64_t";
    if (std.mem.eql(u8, name, "isize")) return "intptr_t";
    if (std.mem.eql(u8, name, "f32")) return "float";
    if (std.mem.eql(u8, name, "f64")) return "double";
    // Library result/order types (sections 5.4, 5.5). Order is a three-way
    // comparison (-1/0/+1); the ambiguity error types carry no payload.
    if (std.mem.eql(u8, name, "Order")) return "int8_t";
    if (std.mem.eql(u8, name, "AmbiguousSerialOrder")) return "uint8_t";
    if (std.mem.eql(u8, name, "AmbiguousCounterInterval")) return "uint8_t";
    if (std.mem.eql(u8, name, "ConversionError")) return "uint8_t";
    if (std.mem.eql(u8, name, "Overflow")) return "uint8_t";
    return "void *";
}

fn checkedTypeSuffix(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8")) return "u8";
    if (std.mem.eql(u8, name, "u16")) return "u16";
    if (std.mem.eql(u8, name, "u32")) return "u32";
    if (std.mem.eql(u8, name, "u64")) return "u64";
    if (std.mem.eql(u8, name, "usize")) return "usize";
    if (std.mem.eql(u8, name, "i8")) return "i8";
    if (std.mem.eql(u8, name, "i16")) return "i16";
    if (std.mem.eql(u8, name, "i32")) return "i32";
    if (std.mem.eql(u8, name, "i64")) return "i64";
    if (std.mem.eql(u8, name, "isize")) return "isize";
    return null;
}

// Scalar element types valid for `raw.load`/`raw.store`. A superset of the
// checked-arithmetic scalars: it also admits the IEEE floats `f32`/`f64`, which
// are legal raw memory cells (the round-trip float-buffer kernel reads/writes
// them) even though they have no checked-arithmetic helpers.
fn rawScalarSuffix(name: []const u8) ?[]const u8 {
    if (checkedTypeSuffix(name)) |s| return s;
    if (std.mem.eql(u8, name, "f32")) return "f32";
    if (std.mem.eql(u8, name, "f64")) return "f64";
    return null;
}

fn unsignedTypeSuffix(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8")) return "u8";
    if (std.mem.eql(u8, name, "u16")) return "u16";
    if (std.mem.eql(u8, name, "u32")) return "u32";
    if (std.mem.eql(u8, name, "u64")) return "u64";
    if (std.mem.eql(u8, name, "usize")) return "usize";
    return null;
}

fn signedTypeSuffix(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "i8")) return "i8";
    if (std.mem.eql(u8, name, "i16")) return "i16";
    if (std.mem.eql(u8, name, "i32")) return "i32";
    if (std.mem.eql(u8, name, "i64")) return "i64";
    if (std.mem.eql(u8, name, "isize")) return "isize";
    return null;
}

fn isOpaqueAddressTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "PAddr") or
        std.mem.eql(u8, name, "VAddr") or
        std.mem.eql(u8, name, "DmaAddr");
}

const IntTypeRange = struct {
    min: i128,
    max: i128,
    c_min: []const u8,
    c_max: []const u8,
};

// Value ranges for the scalar integer types, used to elide unnecessary bound
// checks in `trap_from`/`sat_from` lowering. `usize`/`isize` are treated as
// 64-bit for elision; the emitted bounds use the portable limit macros.
fn intTypeRange(name: []const u8) ?IntTypeRange {
    if (std.mem.eql(u8, name, "u8")) return .{ .min = 0, .max = 255, .c_min = "0", .c_max = "UINT8_MAX" };
    if (std.mem.eql(u8, name, "u16")) return .{ .min = 0, .max = 65535, .c_min = "0", .c_max = "UINT16_MAX" };
    if (std.mem.eql(u8, name, "u32")) return .{ .min = 0, .max = 4294967295, .c_min = "0", .c_max = "UINT32_MAX" };
    if (std.mem.eql(u8, name, "u64")) return .{ .min = 0, .max = 18446744073709551615, .c_min = "0", .c_max = "UINT64_MAX" };
    if (std.mem.eql(u8, name, "usize")) return .{ .min = 0, .max = 18446744073709551615, .c_min = "0", .c_max = "UINTPTR_MAX" };
    if (std.mem.eql(u8, name, "i8")) return .{ .min = -128, .max = 127, .c_min = "INT8_MIN", .c_max = "INT8_MAX" };
    if (std.mem.eql(u8, name, "i16")) return .{ .min = -32768, .max = 32767, .c_min = "INT16_MIN", .c_max = "INT16_MAX" };
    if (std.mem.eql(u8, name, "i32")) return .{ .min = -2147483648, .max = 2147483647, .c_min = "INT32_MIN", .c_max = "INT32_MAX" };
    if (std.mem.eql(u8, name, "i64")) return .{ .min = -9223372036854775808, .max = 9223372036854775807, .c_min = "INT64_MIN", .c_max = "INT64_MAX" };
    if (std.mem.eql(u8, name, "isize")) return .{ .min = -9223372036854775808, .max = 9223372036854775807, .c_min = "INTPTR_MIN", .c_max = "INTPTR_MAX" };
    return null;
}

fn signedMinMacroForInner(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return "INT8_MIN";
    if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return "INT16_MIN";
    if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return "INT32_MIN";
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return "INT64_MIN";
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return "INTPTR_MIN";
    return null;
}

fn signedCTypeForInner(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return "int8_t";
    if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return "int16_t";
    if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return "int32_t";
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return "int64_t";
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return "intptr_t";
    return null;
}

fn isCReservedWord(name: []const u8) bool {
    const reserved = [_][]const u8{
        // C keywords (C11).
        "auto",     "break",      "case",           "char",          "const",
        "continue", "default",    "do",             "double",        "else",
        "enum",     "extern",     "float",          "for",           "goto",
        "if",       "inline",     "int",            "long",          "register",
        "restrict", "return",     "short",          "signed",        "sizeof",
        "static",   "struct",     "switch",         "typedef",       "union",
        "unsigned", "void",       "volatile",       "while",         "_Bool",
        "_Complex", "_Imaginary", "_Alignas",       "_Alignof",      "_Atomic",
        "_Generic", "_Noreturn",  "_Static_assert", "_Thread_local",
        // Macros from the headers the prelude includes.
        "bool",
        "true",     "false",      "NULL",
    };
    for (reserved) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

fn floatCTypeName(ty: ast.TypeExpr) ?[]const u8 {
    const name = typeName(ty) orelse return null;
    if (std.mem.eql(u8, name, "f32")) return "float";
    if (std.mem.eql(u8, name, "f64")) return "double";
    return null;
}

fn mmioFieldWidthBytes(width: []const u8) u64 {
    if (std.mem.eql(u8, width, "u8") or std.mem.eql(u8, width, "i8") or std.mem.eql(u8, width, "bool")) return 1;
    if (std.mem.eql(u8, width, "u16") or std.mem.eql(u8, width, "i16")) return 2;
    if (std.mem.eql(u8, width, "u32") or std.mem.eql(u8, width, "i32")) return 4;
    if (std.mem.eql(u8, width, "u64") or std.mem.eql(u8, width, "i64") or std.mem.eql(u8, width, "usize")) return 8;
    return 4;
}

fn primitiveCTypeName(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "void")) return "void";
    if (std.mem.eql(u8, name, "c_void")) return "void";
    if (std.mem.eql(u8, name, "never")) return "void";
    if (std.mem.eql(u8, name, "bool")) return "bool";
    if (std.mem.eql(u8, name, "u8")) return "uint8_t";
    if (std.mem.eql(u8, name, "u16")) return "uint16_t";
    if (std.mem.eql(u8, name, "u32")) return "uint32_t";
    if (std.mem.eql(u8, name, "u64")) return "uint64_t";
    if (std.mem.eql(u8, name, "usize")) return "uintptr_t";
    if (isOpaqueAddressTypeName(name)) return "uintptr_t";
    // IrqOff (§19.1) capability token: a 1-byte witness value.
    if (std.mem.eql(u8, name, "IrqOff")) return "uint8_t";
    if (std.mem.eql(u8, name, "i8")) return "int8_t";
    if (std.mem.eql(u8, name, "i16")) return "int16_t";
    if (std.mem.eql(u8, name, "i32")) return "int32_t";
    if (std.mem.eql(u8, name, "i64")) return "int64_t";
    if (std.mem.eql(u8, name, "isize")) return "intptr_t";
    if (std.mem.eql(u8, name, "f32")) return "float";
    if (std.mem.eql(u8, name, "f64")) return "double";
    return null;
}

fn ptrCType(child: ast.TypeExpr, mutability: ast.Mutability) []const u8 {
    const child_ty = cType(child);
    const is_const = mutability == .@"const";
    if (std.mem.eql(u8, child_ty, "uint8_t")) return if (is_const) "uint8_t const *" else "uint8_t *";
    if (std.mem.eql(u8, child_ty, "uint16_t")) return if (is_const) "uint16_t const *" else "uint16_t *";
    if (std.mem.eql(u8, child_ty, "uint32_t")) return if (is_const) "uint32_t const *" else "uint32_t *";
    if (std.mem.eql(u8, child_ty, "uint64_t")) return if (is_const) "uint64_t const *" else "uint64_t *";
    if (std.mem.eql(u8, child_ty, "int8_t")) return if (is_const) "int8_t const *" else "int8_t *";
    if (std.mem.eql(u8, child_ty, "int16_t")) return if (is_const) "int16_t const *" else "int16_t *";
    if (std.mem.eql(u8, child_ty, "int32_t")) return if (is_const) "int32_t const *" else "int32_t *";
    if (std.mem.eql(u8, child_ty, "int64_t")) return if (is_const) "int64_t const *" else "int64_t *";
    if (std.mem.eql(u8, child_ty, "bool")) return if (is_const) "bool const *" else "bool *";
    return "void *";
}

fn isStaticCInitializer(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .bool_literal, .null_literal, .void_literal, .enum_literal => true,
        .address_of => true,
        .unary => |node| node.op == .neg and switch (node.expr.kind) {
            .int_literal => true,
            else => false,
        },
        .grouped => |inner| isStaticCInitializer(inner.*),
        else => false,
    };
}

fn isArrayLiteralExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .array_literal => true,
        .grouped => |inner| isArrayLiteralExpr(inner.*),
        else => false,
    };
}

fn isStructLiteralExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .struct_literal => true,
        .grouped => |inner| isStructLiteralExpr(inner.*),
        else => false,
    };
}

fn boolLiteralValue(expr: ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_literal => |value| value,
        .grouped => |inner| boolLiteralValue(inner.*),
        else => null,
    };
}

fn isDirectStaticCInitializer(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unary => |node| node.op == .neg and switch (node.expr.kind) {
            .int_literal => true,
            else => false,
        },
        .grouped => |inner| isDirectStaticCInitializer(inner.*),
        else => false,
    };
}

fn isUninitLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .uninit_literal => true,
        .grouped => |inner| isUninitLiteral(inner.*),
        else => false,
    };
}

fn sequencedConditionCandidate(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .grouped => |inner| sequencedConditionCandidate(inner.*),
        .binary => |node| isComparisonOp(node.op) and (exprContainsCall(node.left.*) or exprContainsCall(node.right.*)),
        else => false,
    };
}

fn conditionOperandTypeForEmission(emitter: *CEmitter, expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            if (locals.get(ident.text)) |info| return info.source_ty;
            // A module-level (e.g. `const`) global compared against a call result,
            // such as `while tick_count() < LIMIT`.
            if (emitter.globals.get(ident.text)) |g| return g.source_ty;
            return null;
        },
        .bool_literal => simpleNameType("bool", expr.span),
        .int_literal => simpleNameType("u32", expr.span),
        .call => emitter.callReturnTypeForExpr(expr, locals),
        .grouped => |inner| conditionOperandTypeForEmission(emitter, inner.*, locals),
        .unary => |node| conditionOperandTypeForEmission(emitter, node.expr.*, locals),
        .binary => emitter.numericExprTypeForEmission(expr, locals),
        .index => |node| CEmitter.localIndexElementType(node.base.*, locals),
        else => null,
    };
}

fn exprContainsCall(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => true,
        .grouped, .address_of, .deref => |inner| exprContainsCall(inner.*),
        .try_expr => |inner| exprContainsCall(inner.operand.*),
        .unary => |node| exprContainsCall(node.expr.*),
        .binary => |node| exprContainsCall(node.left.*) or exprContainsCall(node.right.*),
        .index => |node| exprContainsCall(node.base.*) or exprContainsCall(node.index.*),
        .member => |node| exprContainsCall(node.base.*),
        .cast => |node| exprContainsCall(node.value.*),
        else => false,
    };
}

fn comparisonExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .binary => |node| isComparisonOp(node.op),
        .grouped => |inner| comparisonExpr(inner.*),
        else => false,
    };
}

fn isBoolType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "bool"),
        .qualified => |node| isBoolType(node.child.*),
        else => false,
    };
}

fn appendCIntLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literal: []const u8) !void {
    for (literal) |ch| {
        if (ch != '_') try out.append(allocator, ch);
    }
}

fn intLiteralText(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .int_literal => |literal| literal,
        .grouped => |inner| intLiteralText(inner.*),
        else => null,
    };
}

fn parseI128Literal(raw: []const u8) ?i128 {
    var cleaned: [160]u8 = undefined;
    if (raw.len > cleaned.len) return null;
    var len: usize = 0;
    for (raw) |ch| {
        if (ch != '_') {
            cleaned[len] = ch;
            len += 1;
        }
    }
    return std.fmt.parseInt(i128, cleaned[0..len], 0) catch null;
}

// Constant value of an integer expression: literals, negation, provably-safe
// `+ - *` of constants, and immutable (`let`) locals known to hold a constant.
fn constIntValue(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?i128 {
    return switch (expr.kind) {
        .int_literal => |literal| parseI128Literal(literal),
        .grouped => |inner| constIntValue(inner.*, locals),
        .unary => |node| if (node.op == .neg) blk: {
            const v = constIntValue(node.expr.*, locals) orelse break :blk null;
            break :blk std.math.negate(v) catch null;
        } else null,
        .ident => |ident| if (locals) |ls| (if (ls.get(ident.text)) |info| info.const_int else null) else null,
        .binary => |node| blk: {
            const l = constIntValue(node.left.*, locals) orelse break :blk null;
            const r = constIntValue(node.right.*, locals) orelse break :blk null;
            break :blk switch (node.op) {
                .add => std.math.add(i128, l, r) catch null,
                .sub => std.math.sub(i128, l, r) catch null,
                .mul => std.math.mul(i128, l, r) catch null,
                else => null,
            };
        },
        else => null,
    };
}

// Value-range proof: a checked `+ - *` on constant operands (literals or
// constant immutable locals) whose exact result fits the target type provably
// cannot overflow, so it lowers to plain C arithmetic instead of a checked
// helper (section I.1 permits omitting a check the compiler can prove
// unnecessary).
fn constBinaryProvenNoOverflow(node: anytype, target_name: []const u8, locals: ?*std.StringHashMap(LocalInfo)) bool {
    switch (node.op) {
        .add, .sub, .mul => {},
        else => return false,
    }
    const l = constIntValue(node.left.*, locals) orelse return false;
    const r = constIntValue(node.right.*, locals) orelse return false;
    const range = intTypeRange(target_name) orelse return false;
    const ll: i256 = l;
    const rr: i256 = r;
    const result: i256 = switch (node.op) {
        .add => ll + rr,
        .sub => ll - rr,
        .mul => ll * rr,
        else => unreachable,
    };
    return result >= @as(i256, range.min) and result <= @as(i256, range.max);
}

fn parseUsizeLiteral(raw: []const u8) ?usize {
    var cleaned: [128]u8 = undefined;
    if (raw.len > cleaned.len) return null;
    var len: usize = 0;
    for (raw) |ch| {
        if (ch != '_') {
            cleaned[len] = ch;
            len += 1;
        }
    }
    return std.fmt.parseInt(usize, cleaned[0..len], 0) catch null;
}

fn constArrayLenValue(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?usize {
    return switch (expr.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .grouped => |inner| constArrayLenValue(inner.*, funcs, globals),
        // Section 22 comptime↔type: a `const fn` result or named `const` global
        // can drive a fixed-array length, so emit the same folded constant.
        .call, .ident => comptimeUsizeArrayLen(expr, funcs, globals),
        .binary => |node| {
            const left = constArrayLenValue(node.left.*, funcs, globals) orelse return null;
            const right = constArrayLenValue(node.right.*, funcs, globals) orelse return null;
            return switch (node.op) {
                .add => std.math.add(usize, left, right) catch null,
                .sub => std.math.sub(usize, left, right) catch null,
                .mul => std.math.mul(usize, left, right) catch null,
                .div => if (right == 0) null else @divTrunc(left, right),
                .mod => if (right == 0) null else @mod(left, right),
                .shl => if (right >= @bitSizeOf(usize)) null else std.math.shl(usize, left, right),
                .shr => if (right >= @bitSizeOf(usize)) null else left >> @intCast(right),
                else => null,
            };
        },
        else => null,
    };
}

// Fold a comptime const-fn call to a usize array length, mirroring the
// front-end's `comptimeUsizeValue`. A stack buffer backs the scope so this
// stays a free function.
fn comptimeUsizeArrayLen(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?usize {
    if (funcs == null and globals == null) return null;
    var buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var scope = eval.ComptimeScope.init(fba.allocator());
    scope.funcs = funcs;
    scope.globals = globals;
    return switch (eval.foldComptimeExpr(&scope, expr)) {
        .value => |v| switch (v) {
            .int => |n| if (n >= 0 and n <= std.math.maxInt(usize)) @intCast(n) else null,
            .boolean, .array, .@"struct" => null,
        },
        else => null,
    };
}

fn arrayLenForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info| info.array_len else null,
        .grouped => |inner| arrayLenForExpr(inner.*, locals),
        else => null,
    };
}

fn arrayElemsFieldForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info| info.array_elems_field else null,
        .grouped => |inner| arrayElemsFieldForExpr(inner.*, locals),
        else => null,
    };
}

const ConstGetCallInfo = struct {
    base: *ast.Expr,
    index: usize,
};

fn constGetCallInfo(call: anytype) ?ConstGetCallInfo {
    if (call.args.len != 0 or call.type_args.len != 1) return null;
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return null,
        },
        else => return null,
    };
    if (!std.mem.eql(u8, member.name.text, "const_get")) return null;
    const index = switch (call.type_args[0].kind) {
        .name => |name| parseUsizeLiteral(name.text) orelse return null,
        else => return null,
    };
    return .{ .base = member.base, .index = index };
}

fn sliceAccessForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?SliceAccess {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info|
            if (info.slice_ptr_field) |ptr_field|
                if (info.slice_len_field) |len_field| .{ .ptr_field = ptr_field, .len_field = len_field } else null
            else
                null
        else
            null,
        .grouped => |inner| sliceAccessForExpr(inner.*, locals),
        else => null,
    };
}

fn overlayUnionNameForExpr(expr: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| if (locals.get(ident.text)) |info| info.source_type_name else null,
        .grouped => |inner| overlayUnionNameForExpr(inner.*, locals),
        else => null,
    };
}

fn overlayByteArrayLen(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .array => |node| {
            const child_name = typeName(node.child.*) orelse return null;
            if (!std.mem.eql(u8, child_name, "u8")) return null;
            return intLiteralText(node.len);
        },
        .qualified => |node| overlayByteArrayLen(node.child.*),
        else => null,
    };
}

fn overlayByteArrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| {
            const child_name = typeName(node.child.*) orelse return null;
            if (!std.mem.eql(u8, child_name, "u8")) return null;
            return node.child.*;
        },
        .qualified => |node| overlayByteArrayElementType(node.child.*),
        else => null,
    };
}

fn overlayMemberFromIndexBase(expr: ast.Expr) ?@TypeOf(expr.kind.member) {
    return switch (expr.kind) {
        .member => |member| member,
        .grouped => |inner| overlayMemberFromIndexBase(inner.*),
        else => null,
    };
}

fn taggedUnionCase(union_decl: ast.UnionDecl, name: []const u8) ?ast.UnionCase {
    for (union_decl.cases) |case| {
        if (std.mem.eql(u8, case.name.text, name)) return case;
    }
    return null;
}

fn resultTryOperand(expr: ast.Expr) ?ast.Expr {
    return switch (expr.kind) {
        .try_expr => |inner| inner.operand.*,
        .grouped => |inner| resultTryOperand(inner.*),
        else => null,
    };
}

fn exprHasTryReplacement(expr: ast.Expr, replacements: []const TryReplacement) bool {
    if (tryReplacementForSpan(expr.span, replacements) != null) return true;
    return switch (expr.kind) {
        .grouped, .address_of, .deref => |inner| exprHasTryReplacement(inner.*, replacements),
        .unary => |node| exprHasTryReplacement(node.expr.*, replacements),
        .try_expr => |inner| exprHasTryReplacement(inner.operand.*, replacements),
        .binary => |node| exprHasTryReplacement(node.left.*, replacements) or exprHasTryReplacement(node.right.*, replacements),
        .call => |node| {
            for (node.args) |arg| if (exprHasTryReplacement(arg, replacements)) return true;
            return false;
        },
        .index => |node| exprHasTryReplacement(node.base.*, replacements) or exprHasTryReplacement(node.index.*, replacements),
        .member => |node| exprHasTryReplacement(node.base.*, replacements),
        .cast => |node| exprHasTryReplacement(node.value.*, replacements),
        else => false,
    };
}

fn exprHasMmioReadReplacement(expr: ast.Expr, replacements: []const MmioReadReplacement) bool {
    if (mmioReadReplacementForSpan(expr.span, replacements) != null) return true;
    return switch (expr.kind) {
        .grouped, .address_of, .deref => |inner| exprHasMmioReadReplacement(inner.*, replacements),
        .unary => |node| exprHasMmioReadReplacement(node.expr.*, replacements),
        .try_expr => |inner| exprHasMmioReadReplacement(inner.operand.*, replacements),
        .binary => |node| exprHasMmioReadReplacement(node.left.*, replacements) or exprHasMmioReadReplacement(node.right.*, replacements),
        .call => |node| {
            for (node.args) |arg| if (exprHasMmioReadReplacement(arg, replacements)) return true;
            return false;
        },
        .index => |node| exprHasMmioReadReplacement(node.base.*, replacements) or exprHasMmioReadReplacement(node.index.*, replacements),
        .member => |node| exprHasMmioReadReplacement(node.base.*, replacements),
        .cast => |node| exprHasMmioReadReplacement(node.value.*, replacements),
        else => false,
    };
}

fn tryReplacementForSpan(span: ast.Span, replacements: []const TryReplacement) ?[]const u8 {
    for (replacements) |replacement| {
        if (sameSpan(span, replacement.span)) return replacement.temp_name;
    }
    return null;
}

fn mmioReadReplacementForSpan(span: ast.Span, replacements: []const MmioReadReplacement) ?MmioReadReplacement {
    for (replacements) |replacement| {
        if (sameSpan(span, replacement.span)) return replacement;
    }
    return null;
}

fn mmioReadReplacementValueTypeForExpr(expr: ast.Expr, replacements: []const MmioReadReplacement) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| mmioReadReplacementValueTypeForExpr(inner.*, replacements),
        else => if (mmioReadReplacementForSpan(expr.span, replacements)) |replacement| replacement.source_type_name else null,
    };
}

fn sameSpan(left: ast.Span, right: ast.Span) bool {
    return left.offset == right.offset and left.len == right.len and left.line == right.line and left.column == right.column;
}

fn calleeIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| calleeIdentName(inner.*),
        else => null,
    };
}

fn unaryCOp(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .bit_not => "~",
        .logical_not => "!",
    };
}

fn binaryCOp(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .logical_or => "||",
        .logical_and => "&&",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .bit_or => "|",
        .bit_xor => "^",
        .bit_and => "&",
        .shl => "<<",
        .shr => ">>",
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
    };
}

fn isCheckedBinaryOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr => true,
        else => false,
    };
}

fn isComparisonOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn isNoTrapBitwiseInfixOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

const CheckedHelperParts = struct {
    prefix: []const u8,
    suffix: []const u8,
};

fn checkedHelperParts(op: ast.BinaryOp, type_name: []const u8) ?CheckedHelperParts {
    const suffix = checkedTypeSuffix(type_name) orelse return null;
    const prefix = switch (op) {
        .add => "mc_checked_add_",
        .sub => "mc_checked_sub_",
        .mul => "mc_checked_mul_",
        .div => "mc_checked_div_",
        .mod => "mc_checked_mod_",
        .shl => "mc_checked_shl_",
        .shr => "mc_checked_shr_",
        else => return null,
    };
    return .{ .prefix = prefix, .suffix = suffix };
}

fn satHelperParts(op: ast.BinaryOp, type_name: []const u8) ?CheckedHelperParts {
    const suffix = unsignedTypeSuffix(type_name) orelse return null;
    const prefix = switch (op) {
        .add => "mc_sat_add_",
        .sub => "mc_sat_sub_",
        .mul => "mc_sat_mul_",
        else => return null,
    };
    return .{ .prefix = prefix, .suffix = suffix };
}

fn isWrapPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
        else => false,
    };
}

fn isSatPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul => true,
        else => false,
    };
}

fn arithmeticDomainOpName(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .bit_and => "bit_and",
        .bit_or => "bit_or",
        .bit_xor => "bit_xor",
        .shl => "shl",
        .shr => "shr",
        else => "unknown",
    };
}

fn trapHelperForCall(call: anytype) ?[]const u8 {
    if (!isTrapCallee(call.callee.*) or call.args.len != 1) return null;
    return switch (call.args[0].kind) {
        .enum_literal => |literal| trapHelperForKind(literal.text),
        else => null,
    };
}

fn isTrapCallee(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "trap"),
        .grouped => |inner| isTrapCallee(inner.*),
        else => false,
    };
}

fn trapHelperForKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "Bounds")) return "mc_trap_Bounds";
    if (std.mem.eql(u8, kind, "NullUnwrap")) return "mc_trap_NullUnwrap";
    if (std.mem.eql(u8, kind, "IntegerOverflow")) return "mc_trap_IntegerOverflow";
    if (std.mem.eql(u8, kind, "DivideByZero")) return "mc_trap_DivideByZero";
    if (std.mem.eql(u8, kind, "InvalidShift")) return "mc_trap_InvalidShift";
    if (std.mem.eql(u8, kind, "InvalidRepresentation")) return "mc_trap_InvalidRepresentation";
    if (std.mem.eql(u8, kind, "Assert")) return "mc_trap_Assert";
    if (std.mem.eql(u8, kind, "Unreachable")) return "mc_trap_Unreachable";
    return null;
}

fn orderingArg(args: []ast.Expr) []const u8 {
    for (args) |arg| {
        if (arg.kind == .enum_literal) return arg.kind.enum_literal.text;
    }
    return "none";
}

fn atomicAccess(callee: ast.Expr, args: []const ast.Expr, ctx: FnContext) ?AtomicAccess {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return atomicAccess(inner.*, args, ctx),
        else => return null,
    };
    const object = switch (member.base.kind) {
        .ident => |ident| ident.text,
        else => return null,
    };
    const payload = ctx.local_atomic_payloads.get(object) orelse return null;
    if (std.mem.eql(u8, member.name.text, "load")) {
        const ordering = atomicOrderingArg(args, 0);
        if (!isAtomicLoadOrdering(ordering)) return null;
        return .{ .op = "load", .object = object, .payload_type = payload, .ordering = ordering };
    }
    if (std.mem.eql(u8, member.name.text, "store")) {
        const ordering = atomicOrderingArg(args, 1);
        if (!isAtomicStoreOrdering(ordering)) return null;
        return .{ .op = "store", .object = object, .payload_type = payload, .ordering = ordering };
    }
    if (std.mem.eql(u8, member.name.text, "fetch_add") or std.mem.eql(u8, member.name.text, "fetch_sub")) {
        if (!isAtomicIntegerPayload(payload)) return null;
        const ordering = atomicOrderingArg(args, 1);
        if (atomicOrderCConstant(ordering) == null) return null;
        return .{ .op = member.name.text, .object = object, .payload_type = payload, .ordering = ordering };
    }
    return null;
}

fn dmaOperation(callee: ast.Expr, args: []const ast.Expr, ctx: FnContext) ?DmaOperation {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return dmaOperation(inner.*, args, ctx),
        else => return null,
    };
    if (isIdentNamed(member.base.*, "cache")) {
        if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return null;
        if (args.len != 1) return null;
        const object = switch (args[0].kind) {
            .ident => |ident| ident.text,
            else => return null,
        };
        const payload = ctx.local_dma_payloads.get(object) orelse return null;
        const mode = ctx.local_dma_modes.get(object) orelse return null;
        if (!std.mem.eql(u8, mode, "noncoherent")) return null;
        return .{ .kind = member.name.text, .object = object, .payload = payload, .mode = mode };
    }
    const object = switch (member.base.kind) {
        .ident => |ident| ident.text,
        else => return null,
    };
    const payload = ctx.local_dma_payloads.get(object) orelse return null;
    const mode = ctx.local_dma_modes.get(object) orelse return null;
    if (std.mem.eql(u8, member.name.text, "dma_addr")) {
        if (args.len != 0) return null;
        return .{ .kind = "dma_addr", .object = object, .payload = payload, .mode = mode };
    }
    if (std.mem.eql(u8, member.name.text, "as_slice")) {
        if (args.len != 0) return null;
        return .{ .kind = "as_slice", .object = object, .payload = payload, .mode = mode };
    }
    return null;
}

// section 18: returns the DmaBuf object name when `value` is a `buf.dma_addr()`
// expression — i.e. the value being written into a device descriptor register
// is a DMA address handoff.
fn dmaAddrHandoffObject(value: ast.Expr, ctx: FnContext) ?[]const u8 {
    return switch (value.kind) {
        .grouped => |inner| dmaAddrHandoffObject(inner.*, ctx),
        .call => |call| blk: {
            const op = dmaOperation(call.callee.*, call.args, ctx) orelse break :blk null;
            if (!std.mem.eql(u8, op.kind, "dma_addr")) break :blk null;
            break :blk op.object;
        },
        else => null,
    };
}

fn atomicOrderingArg(args: []const ast.Expr, index: usize) []const u8 {
    if (index >= args.len) return "none";
    return switch (args[index].kind) {
        .enum_literal => |literal| literal.text,
        else => "none",
    };
}

const DmaBufInfo = struct {
    payload: ast.TypeExpr,
    mode: []const u8,
};

fn dmaBufInfo(ty: ast.TypeExpr) ?DmaBufInfo {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "DmaBuf") or node.args.len != 2) return null;
            const mode = switch (node.args[1].kind) {
                .enum_literal => |literal| literal.text,
                else => return null,
            };
            return .{ .payload = node.args[0], .mode = mode };
        },
        .qualified => |node| dmaBufInfo(node.child.*),
        else => null,
    };
}

fn asmHasMemoryClobber(asm_stmt: ast.AsmStmt) bool {
    if (asm_stmt.clobbers.len == 0) return true;
    for (asm_stmt.clobbers) |clobber| {
        if (std.mem.indexOf(u8, clobber, "memory") != null) return true;
    }
    return false;
}

fn atomicOrderCConstant(ordering: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ordering, "relaxed")) return "__ATOMIC_RELAXED";
    if (std.mem.eql(u8, ordering, "acquire")) return "__ATOMIC_ACQUIRE";
    if (std.mem.eql(u8, ordering, "release")) return "__ATOMIC_RELEASE";
    if (std.mem.eql(u8, ordering, "acq_rel")) return "__ATOMIC_ACQ_REL";
    if (std.mem.eql(u8, ordering, "seq_cst")) return "__ATOMIC_SEQ_CST";
    return null;
}

fn atomicOrderSynchronizes(ordering: []const u8) bool {
    return !std.mem.eql(u8, ordering, "relaxed") and atomicOrderCConstant(ordering) != null;
}

fn isAtomicLoadOrdering(ordering: []const u8) bool {
    return std.mem.eql(u8, ordering, "relaxed") or
        std.mem.eql(u8, ordering, "acquire") or
        std.mem.eql(u8, ordering, "seq_cst");
}

fn isAtomicStoreOrdering(ordering: []const u8) bool {
    return std.mem.eql(u8, ordering, "relaxed") or
        std.mem.eql(u8, ordering, "release") or
        std.mem.eql(u8, ordering, "seq_cst");
}

fn isAtomicIntegerPayload(name: []const u8) bool {
    return std.mem.eql(u8, name, "u8") or
        std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or
        std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "usize") or
        std.mem.eql(u8, name, "i8") or
        std.mem.eql(u8, name, "i16") or
        std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "isize");
}

const CheckedOp = union(enum) {
    binary: ast.BinaryOp,
    neg,
};

const TrapKind = enum {
    integer_overflow,
    divide_by_zero,
    invalid_shift,

    fn text(self: TrapKind) []const u8 {
        return switch (self) {
            .integer_overflow => "IntegerOverflow",
            .divide_by_zero => "DivideByZero",
            .invalid_shift => "InvalidShift",
        };
    }
};

fn checkedOpName(op: CheckedOp) ?[]const u8 {
    return switch (op) {
        .neg => "neg",
        .binary => |binary| switch (binary) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .mod => "mod",
            .shl => "shl",
            .shr => "shr",
            else => null,
        },
    };
}

fn isOverflowOp(op: CheckedOp) bool {
    return switch (op) {
        .neg => true,
        .binary => |binary| switch (binary) {
            .add, .sub, .mul, .div, .mod, .shl => true,
            else => false,
        },
    };
}

fn trapKindForBinary(node: anytype, ty: []const u8) TrapKind {
    if ((node.op == .div or node.op == .mod) and isSignedIntType(ty) and isNegativeOne(node.right.*)) return .integer_overflow;
    if (node.op == .div or node.op == .mod) return .divide_by_zero;
    return .integer_overflow;
}

fn exprType(expr: ast.Expr, ctx: *FnContext) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ctx.local_types.get(ident.text),
        .grouped => |inner| exprType(inner.*, ctx),
        .unary => |node| exprType(node.expr.*, ctx),
        else => null,
    };
}

fn arithmeticDomainForBinary(node: anytype, ctx: *FnContext) ?[]const u8 {
    if (isWrapPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, "wrap") and exprHasArithmeticDomain(node.right.*, ctx, "wrap")) return "wrap";
    if (isSatPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, "sat") and exprHasArithmeticDomain(node.right.*, ctx, "sat")) return "sat";
    return null;
}

fn exprHasArithmeticDomain(expr: ast.Expr, ctx: *FnContext, domain: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| if (ctx.local_domains.get(ident.text)) |found| std.mem.eql(u8, found, domain) else false,
        .grouped => |inner| exprHasArithmeticDomain(inner.*, ctx, domain),
        .binary => |node| if (std.mem.eql(u8, domain, "wrap"))
            isWrapPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, domain) and exprHasArithmeticDomain(node.right.*, ctx, domain)
        else if (std.mem.eql(u8, domain, "sat"))
            isSatPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, domain) and exprHasArithmeticDomain(node.right.*, ctx, domain)
        else
            false,
        else => false,
    };
}

fn iterableElementCTypeForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info| info.iterable_element_c_type else null,
        .grouped => |inner| iterableElementCTypeForExpr(inner.*, locals),
        else => null,
    };
}

fn isSignedIntType(ty: []const u8) bool {
    return ty.len >= 2 and ty[0] == 'i' and std.ascii.isDigit(ty[1]);
}

fn isNegativeOne(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unary => |node| node.op == .neg and isIntLiteral(node.expr.*, "1"),
        else => false,
    };
}

fn isIntLiteral(expr: ast.Expr, value: []const u8) bool {
    return switch (expr.kind) {
        .int_literal => |literal| std.mem.eql(u8, literal, value),
        else => false,
    };
}

fn widthBits(width: []const u8) []const u8 {
    if (std.mem.eql(u8, width, "usize") or std.mem.eql(u8, width, "isize")) return "ptr";
    if (width.len > 1 and (width[0] == 'u' or width[0] == 'i')) return width[1..];
    if (std.mem.eql(u8, width, "bool")) return "1";
    return "unknown";
}

fn ordinaryGlobalTarget(allocator: std.mem.Allocator, target: ast.Expr, ctx: FnContext, globals: std.StringHashMap(GlobalInfo), structs: std.StringHashMap(ast.StructDecl)) ?GlobalAccess {
    return switch (target.kind) {
        .ident => |ident| if (!ctx.locals.contains(ident.text))
            if (globals.get(ident.text)) |global| .{ .name = ident.text, .info = global } else null
        else
            null,
        .index => |index| ordinaryGlobalArrayTarget(allocator, index, ctx, globals),
        .member => |member| ordinaryGlobalMemberTarget(allocator, member, ctx, globals, structs),
        .grouped => |inner| ordinaryGlobalTarget(allocator, inner.*, ctx, globals, structs),
        else => null,
    };
}

fn ordinaryGlobalArrayTarget(allocator: std.mem.Allocator, index: anytype, ctx: FnContext, globals: std.StringHashMap(GlobalInfo)) ?GlobalAccess {
    const base_ident = switch (index.base.kind) {
        .ident => |ident| ident,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident,
            else => return null,
        },
        else => return null,
    };
    if (ctx.locals.contains(base_ident.text)) return null;
    const global = globals.get(base_ident.text) orelse return null;
    const element_info = global.array_element_info orelse return null;
    return .{
        .name = std.fmt.allocPrint(allocator, "{s}[]", .{base_ident.text}) catch return null,
        .info = .{
            .type_name = element_info.race_type_name,
            .c_type = element_info.c_type,
            .race_type_name = element_info.race_type_name,
            .race_c_type = element_info.race_c_type,
            .width_bits = widthBits(element_info.race_type_name),
            .pointer_like = false,
            .source_ty = element_info.source_ty,
        },
        .owned_name = true,
    };
}

fn ordinaryGlobalMemberTarget(allocator: std.mem.Allocator, member: anytype, ctx: FnContext, globals: std.StringHashMap(GlobalInfo), structs: std.StringHashMap(ast.StructDecl)) ?GlobalAccess {
    const base_ident = switch (member.base.kind) {
        .ident => |ident| ident,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident,
            else => return null,
        },
        else => return null,
    };
    if (ctx.locals.contains(base_ident.text)) return null;
    const global = globals.get(base_ident.text) orelse return null;
    const struct_decl = structs.get(global.type_name) orelse return null;
    for (struct_decl.fields) |field| {
        if (!std.mem.eql(u8, field.name.text, member.name.text)) continue;
        return .{
            .name = std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_ident.text, member.name.text }) catch return null,
            .info = globalInfoFromType(field.ty),
            .owned_name = true,
        };
    }
    return null;
}

fn localOrdinaryTarget(target: ast.Expr, ctx: FnContext) ?[]const u8 {
    return switch (target.kind) {
        .ident => |ident| if (ctx.locals.contains(ident.text)) ident.text else null,
        .grouped => |inner| localOrdinaryTarget(inner.*, ctx),
        else => null,
    };
}

fn assignmentRangeTargetName(target: ast.Expr) ?[]const u8 {
    return switch (target.kind) {
        .ident => |ident| ident.text,
        .member => |member| member.name.text,
        .grouped => |inner| assignmentRangeTargetName(inner.*),
        else => null,
    };
}

fn isFixtureLocalAccess(fn_name: []const u8, object: []const u8) bool {
    return std.mem.eql(u8, fn_name, "local_non_racing_access") and std.mem.eql(u8, object, "local");
}

fn knownContractCalleeName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| if (std.mem.eql(u8, ident.text, "compiler.assume_noalias_unchecked")) ident.text else null,
        .member => |member| {
            const base = switch (member.base.kind) {
                .ident => |ident| ident.text,
                else => return null,
            };
            if (std.mem.eql(u8, base, "unchecked")) {
                if (std.mem.eql(u8, member.name.text, "add")) return "unchecked.add";
                if (std.mem.eql(u8, member.name.text, "sub")) return "unchecked.sub";
                if (std.mem.eql(u8, member.name.text, "mul")) return "unchecked.mul";
            }
            if (std.mem.eql(u8, base, "compiler") and std.mem.eql(u8, member.name.text, "assume_noalias_unchecked")) return "compiler.assume_noalias_unchecked";
            if (std.mem.eql(u8, base, "raw") and std.mem.eql(u8, member.name.text, "store")) return "raw.store";
            return null;
        },
        .grouped => |inner| knownContractCalleeName(inner.*),
        else => null,
    };
}

fn contractMatchesCallee(contract: []const u8, callee: []const u8) bool {
    if (std.mem.eql(u8, contract, "no_overflow")) return std.mem.startsWith(u8, callee, "unchecked.");
    if (std.mem.eql(u8, contract, "noalias")) return std.mem.eql(u8, callee, "compiler.assume_noalias_unchecked");
    return false;
}

fn isRawStoreCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "store") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawStoreCall(inner.*),
        else => false,
    };
}

fn isRawLoadCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "load") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawLoadCall(inner.*),
        else => false,
    };
}

fn isRawPtrCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "ptr") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawPtrCall(inner.*),
        else => false,
    };
}

fn reflectionCallKind(callee: ast.Expr) ?ReflectionCallKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            if (std.mem.eql(u8, ident.text, "bit_offset")) return .bit_offset;
            if (std.mem.eql(u8, ident.text, "repr_of")) return .repr;
            return null;
        },
        .grouped => |inner| reflectionCallKind(inner.*),
        else => null,
    };
}

fn reflectionFieldName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| reflectionFieldName(inner.*),
        else => null,
    };
}

fn isAssumeNoaliasCall(call: anytype) bool {
    if (call.type_args.len != 0 or call.args.len != 2) return false;
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return false,
        },
        else => return false,
    };
    return isIdentNamed(member.base.*, "compiler") and std.mem.eql(u8, member.name.text, "assume_noalias_unchecked");
}

fn isPAddrType(ty: ast.TypeExpr) bool {
    const name = typeName(ty) orelse return false;
    return std.mem.eql(u8, name, "PAddr");
}

fn isPointerLikeAddressType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer, .raw_many_pointer => true,
        .qualified => |node| isPointerLikeAddressType(node.child.*),
        else => false,
    };
}

fn uncheckedNoOverflowCallOp(call: anytype) ?[]const u8 {
    if (call.type_args.len != 0 or call.args.len != 2) return null;
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return null,
        },
        else => return null,
    };
    if (!isIdentNamed(member.base.*, "unchecked")) return null;
    if (std.mem.eql(u8, member.name.text, "add")) return "add";
    if (std.mem.eql(u8, member.name.text, "sub")) return "sub";
    if (std.mem.eql(u8, member.name.text, "mul")) return "mul";
    return null;
}

fn uncheckedNoOverflowOperator(op: []const u8) []const u8 {
    if (std.mem.eql(u8, op, "add")) return "+";
    if (std.mem.eql(u8, op, "sub")) return "-";
    if (std.mem.eql(u8, op, "mul")) return "*";
    return "+";
}

fn fenceHelperForCall(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |node| blk: {
            if (!isIdentNamed(node.base.*, "fence")) break :blk null;
            if (std.mem.eql(u8, node.name.text, "full")) break :blk "mc_barrier_full";
            if (std.mem.eql(u8, node.name.text, "release")) break :blk "mc_barrier_release_before";
            if (std.mem.eql(u8, node.name.text, "acquire")) break :blk "mc_barrier_acquire_after";
            break :blk null;
        },
        .grouped => |inner| fenceHelperForCall(inner.*),
        else => null,
    };
}

fn isCpuPauseCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "pause") and isIdentNamed(member.base.*, "cpu"),
        .grouped => |inner| isCpuPauseCall(inner.*),
        else => false,
    };
}

fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        else => false,
    };
}

fn isBitcastCall(call: anytype) bool {
    return switch (call.callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "bitcast"),
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| std.mem.eql(u8, ident.text, "bitcast"),
            else => false,
        },
        else => false,
    };
}

fn bitcastReturnTypeForCall(call: anytype) ?ast.TypeExpr {
    if (!isBitcastCall(call) or call.type_args.len != 1) return null;
    return call.type_args[0];
}

fn contractName(attr: ast.Attr) []const u8 {
    return switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .named => "unknown",
    };
}

test "emits inspection markers for lowering-sensitive spec behavior" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn exercise(uart: MmioPtr<Uart16550>, ch: u8, a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let y = unchecked.add(a, b);
        \\    }
        \\    shared_counter = ch;
        \\    let x = shared_counter;
        \\    uart.thr.write(ch, .release);
        \\    let status = uart.lsr.read(.acquire);
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "lower_c.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendInspection(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower checked_arith") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "op=add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower contract_scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "metadata_begin=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "metadata_end=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower ordinary_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "access=store") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "access=load") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower mmio_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value_type=UartLsr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "register_width=8 emitted_width=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=release") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=acquire") != null);
}

test "emits C support helpers used by lower-c evidence" {
    const source =
        \\fn noop() -> void {}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_IntegerOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_DivideByZero") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidShift") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_NullUnwrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_check_index_usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_UNSIGNED(u32, uint32_t, UINT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_UNSIGNED(u64, uint64_t, UINT64_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_SIGNED(i32, int32_t, INT32_MIN, INT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_NEG_SIGNED(i32, int32_t, INT32_MIN)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_NEG_SIGNED(isize, intptr_t, INTPTR_MIN)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(NAME, TYPE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(bool, bool)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(u32, uint32_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(i32, int32_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(usize, uintptr_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_thread_fence(__ATOMIC_RELEASE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_thread_fence(__ATOMIC_ACQUIRE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_signal_fence") == null);
}

test "emits C for simple MMIO register access" {
    const source =
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: Reg<u8, .read>,
        \\}
        \\
        \\fn putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
        \\    uart.thr.write(ch, .release);
        \\}
        \\
        \\fn read_lsr(uart: MmioPtr<Uart16550>) -> u8 {
        \\    return uart.lsr.read(.acquire);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Uart16550 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t volatile thr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t volatile lsr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void putc(Uart16550 volatile * uart, uint8_t ch)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp0 = ch;\n    mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_lsr(Uart16550 volatile * uart)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp1 = (uint8_t)mc_mmio_read_u8(&uart->lsr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp1;") != null);
}

test "emits C for wider MMIO register access" {
    const source =
        \\extern mmio struct Device {
        \\    lo: Reg<u16, .read>,
        \\    hi: Reg<u32, .write>,
        \\    wide: Reg<u64, .read_write>,
        \\}
        \\
        \\fn read_lo(dev: MmioPtr<Device>) -> u16 {
        \\    return dev.lo.read(.relaxed);
        \\}
        \\
        \\fn write_hi(dev: MmioPtr<Device>, value: u32) -> void {
        \\    dev.hi.write(value, .release);
        \\}
        \\
        \\fn read_wide(dev: MmioPtr<Device>) -> u64 {
        \\    return dev.wide.read(.acquire);
        \\}
        \\
        \\fn write_wide(dev: MmioPtr<Device>, value: u64) -> void {
        \\    dev.wide.write(value, .relaxed);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_wide_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t volatile lo;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t volatile hi;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t volatile wide;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (uint16_t)mc_mmio_read_u16(&dev->lo);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = value;\n    mc_barrier_release_before();\n    mc_mmio_write_u32(&dev->hi, mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t mc_tmp1 = (uint64_t)mc_mmio_read_u64(&dev->wide);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t mc_tmp2 = value;\n    mc_mmio_write_u64(&dev->wide, mc_tmp2);") != null);
}

test "emits C with sequenced MMIO write value before release barrier" {
    const source =
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\}
        \\
        \\extern fn next_byte() -> u8;
        \\extern fn box_byte(value: u8) -> u8;
        \\
        \\fn putc_computed(uart: MmioPtr<Uart16550>) -> void {
        \\    uart.thr.write(box_byte(next_byte()), .release);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_write_order.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp0 = next_byte();\n    uint8_t mc_tmp1 = box_byte(mc_tmp0);\n    mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, box_byte(next_byte()))") == null);
}

test "emits C with sequenced raw store address and value operands" {
    const source =
        \\extern fn next_addr() -> PAddr;
        \\extern fn next_byte() -> u8;
        \\extern fn box_byte(value: u8) -> u8;
        \\
        \\fn store_computed() -> void {
        \\    unsafe {
        \\        raw.store<u8>(next_addr(), box_byte(next_byte()));
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_raw_store_order.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp0 = next_addr();\n        uint8_t mc_tmp1 = next_byte();\n        uint8_t mc_tmp2 = box_byte(mc_tmp1);\n        mc_raw_store_u8(mc_tmp0, mc_tmp2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_raw_store_u8(next_addr(), box_byte(next_byte()))") == null);
}

test "emits C for MMIO read local initializers" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    stat: Reg<u16, .read>,
        \\    flags: RegBits<u8, Status, .read>,
        \\}
        \\
        \\fn read_local(dev: MmioPtr<Device>) -> u16 {
        \\    let value: u16 = dev.stat.read(.acquire);
        \\    return value;
        \\}
        \\
        \\fn read_bits_local(dev: MmioPtr<Device>) -> Status {
        \\    let status: Status = dev.flags.read(.relaxed);
        \\    return status;
        \\}
        \\
        \\fn read_inferred_bits_local(dev: MmioPtr<Device>) -> bool {
        \\    let status = dev.flags.read(.acquire);
        \\    return status.ready;
        \\}
        \\
        \\fn assign_status(dev: MmioPtr<Device>) -> Status {
        \\    var status: Status = dev.flags.read(.relaxed);
        \\    status = dev.flags.read(.acquire);
        \\    return status;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_read_local_init.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t value = (uint16_t)mc_mmio_read_u16(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status status = (Status)mc_mmio_read_u8(&dev->flags);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status status = (Status)mc_mmio_read_u8(&dev->flags);\n    mc_barrier_acquire_after();\n    return ((status & UINT8_C(1)) != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp0 = (Status)mc_mmio_read_u8(&dev->flags);\n    mc_barrier_acquire_after();\n    status = mc_tmp0;\n    return status;") != null);
}

test "emits C for packed bits MMIO reads and field masks" {
    const source =
        \\packed bits UartLsr: u8 {
        \\    data_ready: bool,
        \\    tx_empty: bool,
        \\}
        \\
        \\global status: UartLsr = 0;
        \\
        \\extern mmio struct Uart16550 {
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn read_status(uart: MmioPtr<Uart16550>) -> UartLsr {
        \\    return uart.lsr.read(.acquire);
        \\}
        \\
        \\fn ready(status: UartLsr) -> bool {
        \\    return status.tx_empty;
        \\}
        \\
        \\fn set_ready(status: UartLsr, flag: bool) -> UartLsr {
        \\    status.tx_empty = flag;
        \\    return status;
        \\}
        \\
        \\fn set_global_ready(flag: bool) -> void {
        \\    status.tx_empty = flag;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_packed_bits_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t UartLsr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static UartLsr read_status(Uart16550 volatile * uart)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "UartLsr mc_tmp0 = (UartLsr)mc_mmio_read_u8(&uart->lsr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool ready(UartLsr status)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((status & UINT8_C(2)) != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static UartLsr set_ready(UartLsr status, bool flag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "status = (UartLsr)((status & (UartLsr)~UINT8_C(2)) | (flag ? UINT8_C(2) : (UartLsr)0));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void set_global_ready(bool flag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "UartLsr mc_tmp1 = (UartLsr)mc_race_load_u8(&status);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_tmp1 = (UartLsr)((mc_tmp1 & (UartLsr)~UINT8_C(2)) | (flag ? UINT8_C(2) : (UartLsr)0));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u8(&status, (uint8_t)mc_tmp1);") != null);
}

test "emits C ABI for simple Result types" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume_result(result: Result<u32, Error>) -> void;
        \\
        \\fn pass_result(result: Result<u32, Error>) -> Result<u32, Error> {
        \\    return result;
        \\}
        \\
        \\fn call_consume(result: Result<u32, Error>) -> void {
        \\    consume_result(result);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_result_abi.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_result_u32_Error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "bool is_ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} payload;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error make_result(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "void consume_result(mc_result_u32_Error result);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_result_u32_Error pass_result(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return result;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = result;\n    consume_result(mc_tmp0);") != null);
}

test "emits C ABI for tagged unions" {
    const source =
        \\union Token {
        \\    int: i64,
        \\    eof,
        \\}
        \\
        \\fn pass_token(token: Token) -> Token {
        \\    return token;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_tagged_union_abi.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef enum TokenTag {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag_int = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag_eof = 1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} TokenTag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Token {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag tag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} payload;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} Token;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Token pass_token(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return token;") != null);
}

test "emits C for tagged union switch narrowing" {
    const source =
        \\union Token {
        \\    int: i64,
        \\    eof,
        \\    space,
        \\}
        \\
        \\fn token_value(token: Token) -> i64 {
        \\    switch token {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
        \\
        \\fn token_kind(token: Token) -> u32 {
        \\    switch token {
        \\        .int => { return 1; },
        \\        .eof, .space => { return 0; },
        \\    }
        \\}
        \\
        \\extern fn make_token() -> Token;
        \\
        \\fn token_call_value() -> i64 {
        \\    switch make_token() {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
        \\
        \\fn token_local_value() -> i64 {
        \\    let token = make_token();
        \\    switch token {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_tagged_union_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_value(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = token.payload.int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return v;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (token.tag == TokenTag_eof) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t token_kind(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (token.tag == TokenTag_eof || token.tag == TokenTag_space) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_call_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token mc_tmp0 = make_token();\n    if (mc_tmp0.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = mc_tmp0.payload.int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (mc_tmp0.tag == TokenTag_eof) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_local_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token token = make_token();\n    if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = token.payload.int_;") != null);
}

test "emits C for tagged union constructors" {
    const source =
        \\union Token {
        \\    number: i64,
        \\    eof,
        \\}
        \\
        \\fn id(token: Token) -> Token {
        \\    return token;
        \\}
        \\
        \\fn make_number() -> Token {
        \\    return number(7);
        \\}
        \\
        \\fn make_eof() -> Token {
        \\    return eof();
        \\}
        \\
        \\fn call_id() -> Token {
        \\    return id(number(7));
        \\}
        \\
        \\fn local_number() -> Token {
        \\    let token: Token = number(9);
        \\    return token;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_tagged_union_constructors.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Token){ .tag = TokenTag_number, .payload.number = 7 });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Token){ .tag = TokenTag_eof });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token mc_tmp0 = ((Token){ .tag = TokenTag_number, .payload.number = 7 });\n    return id(mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token token = ((Token){ .tag = TokenTag_number, .payload.number = 9 });") != null);
}

test "emits C for Result ok and err constructors" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn consume_result(result: Result<u32, Error>) -> void;
        \\
        \\fn make_ok(value: u32) -> Result<u32, Error> {
        \\    return ok(value);
        \\}
        \\
        \\fn make_err() -> Result<u32, Error> {
        \\    return err(.denied);
        \\}
        \\
        \\fn send_ok() -> void {
        \\    consume_result(ok(7));
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_result_constructors.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = true, .payload.ok = value });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = Error_denied });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = ((mc_result_u32_Error){ .is_ok = true, .payload.ok = 7 });\n    consume_result(mc_tmp0);") != null);
}

test "emits C for Result try in local initializers" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn add_one() -> Result<u32, Error> {
        \\    let value: u32 = make_result()?;
        \\    return ok(value + 1);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_result_try.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = mc_tmp0.payload.err });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = true, .payload.ok = mc_checked_add_u32(value, 1) });") != null);
}

test "emits C for Result try in return statements" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn unwrap_param(result: Result<u32, Error>) -> u32 {
        \\    return result?;
        \\}
        \\
        \\fn unwrap_call() -> u32 {
        \\    return make_result()?;
        \\}
        \\
        \\fn unwrap_grouped_call() -> u32 {
        \\    return (make_result())?;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_result_try_return.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = result;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp1 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp2 = (make_result());") != null);
}

test "emits C for Result try in return call arguments" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume(value: u32) -> u32;
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\extern fn box_value(value: u32) -> u32;
        \\
        \\fn arg_try() -> u32 {
        \\    return consume(make_result()?);
        \\}
        \\
        \\fn two_arg_try() -> u32 {
        \\    return combine(make_result()?, make_result()?);
        \\}
        \\
        \\fn nested_arg_try() -> u32 {
        \\    return consume(box_value(make_result()?));
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_result_try_call_args.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t arg_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return combine(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "box_value(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume(mc_tmp") != null);
}

test "emits C for nullable try in return statements" {
    const source =
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn make_nullable_mut_pointer() -> ?*mut u8;
        \\
        \\fn unwrap_param(maybe: ?*const u8) -> *const u8 {
        \\    return maybe?;
        \\}
        \\
        \\fn unwrap_call() -> *const u8 {
        \\    return make_nullable_pointer()?;
        \\}
        \\
        \\fn unwrap_grouped_call() -> *mut u8 {
        \\    return (make_nullable_mut_pointer())?;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_nullable_try_return.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp0 = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_tmp0 == NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp2 = (make_nullable_mut_pointer());") != null);
}

test "emits C for nullable try in return call arguments" {
    const source =
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn consume_ptr(ptr: *const u8) -> u32;
        \\extern fn choose(left: *const u8, right: *const u8) -> u32;
        \\extern fn ptr_id(ptr: *const u8) -> *const u8;
        \\
        \\fn arg_try(maybe: ?*const u8) -> u32 {
        \\    return consume_ptr(maybe?);
        \\}
        \\
        \\fn direct_arg_try() -> u32 {
        \\    return consume_ptr(make_nullable_pointer()?);
        \\}
        \\
        \\fn two_arg_try(maybe: ?*const u8) -> u32 {
        \\    return choose(maybe?, make_nullable_pointer()?);
        \\}
        \\
        \\fn nested_arg_try() -> u32 {
        \\    return consume_ptr(ptr_id(make_nullable_pointer()?));
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_nullable_try_call_args.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t arg_try(uint8_t const * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp0 = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_tmp0 == NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return choose(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ptr_id(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
}

test "emits C for try in local initializer call arguments" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn box_value(value: u32) -> u32;
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn ptr_id(ptr: *const u8) -> *const u8;
        \\
        \\fn local_result_try() -> Result<u32, Error> {
        \\    let value: u32 = box_value(make_result()?);
        \\    return ok(value);
        \\}
        \\
        \\fn local_nullable_try() -> *const u8 {
        \\    let ptr: *const u8 = ptr_id(make_nullable_pointer()?);
        \\    return ptr;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_try_local_initializer.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_result_u32_Error local_result_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = mc_tmp0.payload.err });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = box_value(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t const * local_nullable_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr = ptr_id(mc_tmp") != null);
}

test "emits C for try in assignment and expression statements" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\global shared_value: u32 = 0;
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume(value: u32) -> void;
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn consume_ptr(ptr: *const u8) -> void;
        \\
        \\fn assign_result_try() -> Result<u32, Error> {
        \\    var value: u32 = 0;
        \\    value = make_result()?;
        \\    shared_value = make_result()?;
        \\    return ok(value);
        \\}
        \\
        \\fn expr_result_try() -> Result<u32, Error> {
        \\    make_result()?;
        \\    consume(make_result()?);
        \\    return ok(1);
        \\}
        \\
        \\fn assign_nullable_try() -> *const u8 {
        \\    var ptr: *const u8 = make_nullable_pointer()?;
        \\    ptr = make_nullable_pointer()?;
        \\    return ptr;
        \\}
        \\
        \\fn expr_nullable_try() -> void {
        \\    make_nullable_pointer()?;
        \\    consume_ptr(make_nullable_pointer()?);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_try_assignment_expr_stmt.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp1 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&shared_value, (uint32_t)mc_tmp1.payload.ok);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp2 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp2.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp3 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ptr = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_ptr(mc_tmp") != null);
}

test "emits C for simple functions and race-safe globals" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\fn store(x: u32) -> void {
        \\    shared_counter = x;
        \\}
        \\
        \\fn load() -> u32 {
        \\    return shared_counter;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_functions.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "static MC_UNUSED uint32_t shared_counter = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t add(uint32_t a, uint32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&shared_counter, (uint32_t)x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((uint32_t)mc_race_load_u32(&shared_counter));") != null);
}

test "emits C for while loops and loop control" {
    const source =
        \\fn loop_once(flag: bool) -> u32 {
        \\    var out: u32 = 0;
        \\    while flag {
        \\        {
        \\            out = out + 1;
        \\        }
        \\        break;
        \\    }
        \\    while flag {
        \\        continue;
        \\    }
        \\    return out;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_loops.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "while (flag) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "out = mc_tmp") != null);
    // break/continue lower to labeled gotos so they reach the loop through any
    // intervening switch.
    try std.testing.expect(std.mem.indexOf(u8, output.items, "goto mc_break_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "goto mc_continue_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return out;") != null);
}

test "hoists MMIO reads in while conditions" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    ctrl: Reg<u16, .write>,
        \\    stat: RegBits<u8, Status, .read>,
        \\    raw: Reg<u16, .read>,
        \\}
        \\
        \\extern fn pause() -> void;
        \\
        \\fn poll_and_write(dev: MmioPtr<Device>, value: u16) -> void {
        \\    while !dev.stat.read(.acquire).ready {
        \\        pause();
        \\    }
        \\    dev.ctrl.write(value, .release);
        \\}
        \\
        \\fn wait_raw(dev: MmioPtr<Device>) -> void {
        \\    while dev.raw.read(.relaxed) == 0 {
        \\        pause();
        \\    }
        \\}
        \\
        \\fn require_ready(dev: MmioPtr<Device>) -> void {
        \\    assert(dev.stat.read(.acquire).ready);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_read_while_condition.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "while (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp0 = (Status)mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(!(((mc_tmp0 & UINT8_C(1)) != 0)))) break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "pause();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t mc_tmp1 = value;\n    mc_barrier_release_before();\n    mc_mmio_write_u16(&dev->ctrl, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t mc_tmp2 = (uint16_t)mc_mmio_read_u16(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!((mc_tmp2 == 0))) break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp3 = (Status)mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(((mc_tmp3 & UINT8_C(1)) != 0))) mc_trap_Assert();") != null);
}

test "hoists MMIO reads in return and expression statements" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    stat: RegBits<u8, Status, .read>,
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\extern fn observe(status: Status) -> void;
        \\
        \\fn observe_status(dev: MmioPtr<Device>) -> void {
        \\    observe(dev.stat.read(.acquire));
        \\}
        \\
        \\fn read_plus(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    return dev.raw.read(.relaxed) + extra;
        \\}
        \\
        \\fn read_side_effect(dev: MmioPtr<Device>) -> void {
        \\    dev.raw.read(.acquire);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_read_exprs.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "observe(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();\n    (void)mc_tmp") != null);
}

test "hoists MMIO reads in local initializer and assignment expressions" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn local_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    let x: u32 = dev.raw.read(.relaxed) + extra;
        \\    return x;
        \\}
        \\
        \\fn assign_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    var x: u32 = 0;
        \\    x = dev.raw.read(.acquire) + extra;
        \\    return x;
        \\}
        \\
        \\fn local_untyped_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    let x = dev.raw.read(.relaxed) + extra;
        \\    return x;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_read_nested_init_assignment.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
}

test "hoists MMIO reads in switch subjects" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn switch_relaxed(dev: MmioPtr<Device>) -> u32 {
        \\    switch dev.raw.read(.relaxed) {
        \\        0 => { return 1; },
        \\        _ => { return 2; },
        \\    }
        \\}
        \\
        \\fn switch_acquire(dev: MmioPtr<Device>) -> u32 {
        \\    switch dev.raw.read(.acquire) {
        \\        0 => { return 1; },
        \\        _ => { return 2; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_read_switch_subject.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n    switch (mc_tmp0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp1 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n    mc_barrier_acquire_after();\n    switch (mc_tmp1) {") != null);
}

test "hoists MMIO reads in switch arm expressions" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn switch_arm_expr(dev: MmioPtr<Device>, n: u32) -> void {
        \\    switch n {
        \\        0 => dev.raw.read(.acquire),
        \\        _ => dev.raw.read(.relaxed),
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_read_switch_arm_expr.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n            mc_barrier_acquire_after();\n            (void)mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp1 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n            (void)mc_tmp1;") != null);
}

test "emits C for array and slice for loops" {
    const source =
        \\extern fn make_slice() -> []const u32;
        \\extern fn make_array() -> [4]u32;
        \\
        \\fn sum_slice(xs: []const u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_array(xs: [4]u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_call_slice() -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in make_slice() {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn first_call_array() -> u32 {
        \\    for x in make_array() {
        \\        return x;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn sum_inferred_slice() -> u32 {
        \\    let xs = make_slice();
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_inferred_array() -> u32 {
        \\    let xs = make_array();
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_for_loops.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t sum_slice(mc_slice_const_u32 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "for (uintptr_t mc_i0 = 0; mc_i0 < xs.len; mc_i0 += 1) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = xs.ptr[mc_i0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_array_u32_4 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t sum_array(mc_array_u32_4 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " < 4; mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = xs.elems[mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".len; mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".ptr[mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 xs = make_array();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "sum = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return sum;") != null);
}

test "emits C for fixed array indexing with bounds checks" {
    const source =
        \\fn pick_u8(xs: [4]u8, i: usize) -> u8 {
        \\    return xs[i];
        \\}
        \\
        \\fn pick_u32(xs: [4]u32, i: usize) -> u32 {
        \\    return xs[i];
        \\}
        \\
        \\#[no_lang_trap]
        \\fn pick_const(xs: [4]u8) -> u8 {
        \\    return xs.const_get<2>();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_arrays.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u8_4 xs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 xs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.elems[mc_check_index_usize(i, 4)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.elems[2];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_check_index_usize(2, 4)") == null);
}

test "emits C for slice typedefs and indexing" {
    const source =
        \\extern fn make_u8_slice() -> []const u8;
        \\extern fn make_u32_slice() -> []const u32;
        \\
        \\fn read_slice(xs: []const u8, i: usize) -> u8 {
        \\    return xs[i];
        \\}
        \\
        \\fn read_literal(xs: []const u8) -> u8 {
        \\    return xs[0];
        \\}
        \\
        \\fn write_slice(xs: []mut u32, i: usize, value: u32) -> void {
        \\    xs[i] = value;
        \\}
        \\
        \\fn same_slice(xs: []const u8) -> []const u8 {
        \\    return xs;
        \\}
        \\
        \\fn read_direct_literal() -> u8 {
        \\    return make_u8_slice()[0];
        \\}
        \\
        \\fn read_direct_index(i: usize) -> u32 {
        \\    return make_u32_slice()[i];
        \\}
        \\
        \\fn read_inferred_slice(i: usize) -> u32 {
        \\    let xs = make_u32_slice();
        \\    return xs[i];
        \\}
        \\
        \\fn local_direct_literal() -> u8 {
        \\    let x: u8 = make_u8_slice()[0];
        \\    return x;
        \\}
        \\
        \\fn local_direct_index(i: usize) -> u32 {
        \\    let x: u32 = make_u32_slice()[i];
        \\    return x;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_slices.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_const_u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_const_u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t const * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_mut_u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t len;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 make_u8_slice(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 make_u32_slice(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_slice(mc_slice_const_u8 xs, uintptr_t i)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.ptr[mc_check_index_usize(i, xs.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.ptr[mc_check_index_usize(0, xs.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void write_slice(mc_slice_mut_u32 xs, uintptr_t i, uint32_t value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "xs.ptr[mc_check_index_usize(i, xs.len)] = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_slice_const_u8 same_slice(mc_slice_const_u8 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 mc_tmp0 = make_u8_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp1 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp2 = mc_tmp0.ptr[mc_check_index_usize(mc_tmp1, mc_tmp0.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 mc_tmp3 = make_u32_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp4 = i;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp5 = mc_tmp3.ptr[mc_check_index_usize(mc_tmp4, mc_tmp3.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 xs = make_u32_slice();\n    return xs.ptr[mc_check_index_usize(i, xs.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 mc_tmp6 = make_u8_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp7 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp8 = mc_tmp6.ptr[mc_check_index_usize(mc_tmp7, mc_tmp6.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t x = mc_tmp8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 mc_tmp9 = make_u32_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp10 = i;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp11 = mc_tmp9.ptr[mc_check_index_usize(mc_tmp10, mc_tmp9.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = mc_tmp11;") != null);
}

test "emits C checked u32 arithmetic helpers" {
    const source =
        \\fn checked_ops(a: u32, b: u32, n: u32) -> u32 {
        \\    var out: u32 = a - b;
        \\    out = out * b;
        \\    out = out / b;
        \\    out = out % b;
        \\    out = out << n;
        \\    return out >> n;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_checked_ops.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_sub_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mul_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_div_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mod_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_shl_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_shr_u32(") != null);
}

test "emits C for integer switch arms" {
    const source =
        \\fn classify(n: u32) -> u32 {
        \\    switch n {
        \\        0 => {
        \\            let x: u32 = 10;
        \\            return x;
        \\        },
        \\        1, 2 => { return 20; },
        \\        _ => { return 30; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (n) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 10;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 30;") != null);
}

test "emits C for closed enum switch arms" {
    const source =
        \\enum Irq: u8 {
        \\    timer = 32,
        \\    keyboard = 33,
        \\}
        \\
        \\fn classify_irq(irq: Irq) -> u32 {
        \\    switch irq {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
        \\
        \\extern fn read_irq() -> Irq;
        \\
        \\fn classify_read_irq() -> u32 {
        \\    switch read_irq() {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
        \\
        \\fn classify_local_irq() -> u32 {
        \\    let irq = read_irq();
        \\    switch irq {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_enum_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t Irq;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq_timer = 32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq_keyboard = 33") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_irq(Irq irq)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (irq) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case Irq_timer:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case Irq_keyboard:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_read_irq(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq mc_tmp0 = read_irq();\n    switch (mc_tmp0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_local_irq(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq irq = read_irq();\n    switch (irq) {") != null);
}

test "emits C for target-typed enum literals" {
    const source =
        \\enum Mode: u8 {
        \\    read = 1,
        \\    write = 2,
        \\}
        \\
        \\extern fn sink(mode: Mode) -> u32;
        \\
        \\fn default_mode() -> Mode {
        \\    return .read;
        \\}
        \\
        \\fn local_mode() -> Mode {
        \\    let mode: Mode = .write;
        \\    return mode;
        \\}
        \\
        \\fn pass_mode() -> u32 {
        \\    return sink(.read);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_enum_literals.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t Mode;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode_read = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode_write = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t sink(Mode mode);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return Mode_read;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode mode = Mode_write;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode mc_tmp0 = Mode_read;\n    return sink(mc_tmp0);") != null);
}

test "emits C for optional pointer if-let" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\
        \\fn unwrap_or(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
        \\    if let p = maybe {
        \\        return p;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
        \\
        \\fn read_const(maybe: ?*const u8) -> u8 {
        \\    if let p = maybe {
        \\        return p.*;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
        \\fn unwrap_call_or_zero() -> u32 {
        \\    if let p = maybe_ptr() {
        \\        return ptr_value(p);
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn unwrap_local_or_zero() -> u32 {
        \\    let maybe = maybe_ptr();
        \\    if let p = maybe {
        \\        return ptr_value(p);
        \\    }
        \\    return 0;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_if_let.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t * unwrap_or(uint8_t * maybe, uint8_t * fallback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_const(uint8_t const * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return *p;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return fallback;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp0 = maybe_ptr();\n    if (mc_tmp0 != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t unwrap_local_or_zero(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * maybe = maybe_ptr();\n    if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
}

test "emits C for nullable switch binding" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\
        \\fn nullable_switch(maybe: ?*mut u8) -> u32 {
        \\    switch maybe {
        \\        p => { return ptr_value(p); },
        \\        _ => { return 0; },
        \\    }
        \\}
        \\
        \\fn nullable_call_switch() -> u32 {
        \\    switch maybe_ptr() {
        \\        p => { return ptr_value(p); },
        \\        _ => { return 0; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_nullable_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t nullable_switch(uint8_t * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp0 = p;\n        return ptr_value(mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else {\n        return 0;\n    }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp1 = maybe_ptr();\n    if (mc_tmp1 != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = mc_tmp1;") != null);
}

test "emits C for Result if-let narrowing" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn unwrap_or_zero(result: Result<u32, Error>) -> u32 {
        \\    if let ok(v) = result {
        \\        return v;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
        \\fn has_err(result: Result<u32, Error>) -> bool {
        \\    if let err(e) = result {
        \\        return e != 0;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn unwrap_call_or_zero() -> u32 {
        \\    if let ok(v) = make_result() {
        \\        return v;
        \\    }
        \\    return 0;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_result_if_let.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t unwrap_or_zero(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return v;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool has_err(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = result.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (e != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();\n    if (mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = mc_tmp0.payload.ok;") != null);
}

test "emits C for Result switch narrowing" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\fn result_nonzero(result: Result<u32, Error>) -> bool {
        \\    switch result {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn result_call_nonzero() -> bool {
        \\    switch make_result() {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\fn result_local_nonzero() -> bool {
        \\    let result = make_result();
        \\    switch result {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\fn result_payloadless_switch() -> u32 {
        \\    let result = make_result();
        \\    switch result {
        \\        .ok => { return 1; },
        \\        .err => { return 0; },
        \\    }
        \\}
        \\
        \\fn result_multi_payloadless_switch() -> u32 {
        \\    let result = make_result();
        \\    switch result {
        \\        .ok, .err => { return 1; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_result_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_result_u32_Error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool result_nonzero(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (v != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = result.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (e != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();\n    if (mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = mc_tmp0.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool result_local_nonzero(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t result_payloadless_switch(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok) {\n        return 1;\n    }\n    else {\n        return 0;\n    }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t result_multi_payloadless_switch(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok || !result.is_ok) {\n        return 1;\n    }") != null);
}

test "emits C extern structs and member access" {
    const source =
        \\extern struct Packet {
        \\    value: u32,
        \\    ptr: *mut u8,
        \\    next: ?*mut Packet,
        \\}
        \\
        \\fn make_packet() -> Packet;
        \\extern fn make_ptr() -> *mut u8;
        \\
        \\fn id_packet_ptr(p: *mut Packet) -> *mut Packet {
        \\    return p;
        \\}
        \\
        \\fn maybe_packet(maybe: ?*mut Packet, fallback: *mut Packet) -> *mut Packet {
        \\    if let p = maybe {
        \\        return p;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
        \\
        \\fn cast_packet_ptr(raw: *mut u8) -> *mut Packet {
        \\    return raw as *mut Packet;
        \\}
        \\
        \\fn read_value(packet: Packet) -> u32 {
        \\    return packet.value;
        \\}
        \\
        \\fn write_value(packet: Packet, value: u32) -> void {
        \\    packet.value = value;
        \\}
        \\
        \\fn read_ptr(packet: Packet) -> *mut u8 {
        \\    return packet.ptr;
        \\}
        \\
        \\fn read_direct() -> u32 {
        \\    return make_packet().value;
        \\}
        \\
        \\fn inferred_pointer_return() -> *mut u8 {
        \\    let p = make_ptr();
        \\    return p;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_structs.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Packet {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "struct Packet * next;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Packet make_packet(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * id_packet_ptr(Packet * p)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * maybe_packet(Packet * maybe, Packet * fallback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Packet * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * cast_packet_ptr(uint8_t * raw)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Packet *)raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t read_value(Packet packet)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return packet.value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "packet.value = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return packet.ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return make_packet().value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * make_ptr(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t * inferred_pointer_return(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = make_ptr();\n    if (mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " == NULL) mc_trap_InvalidRepresentation();\n    uint8_t * p = mc_tmp") != null);
}

test "emits C overlay unions as byte storage" {
    const source =
        \\overlay union Word {
        \\    u: u32,
        \\    bytes: [4]u8,
        \\}
        \\
        \\fn pass_word(word: Word) -> Word {
        \\    return word;
        \\}
        \\
        \\fn read_u(word: Word) -> u32 {
        \\    return word.u;
        \\}
        \\
        \\fn read_b0(word: Word) -> u8 {
        \\    return word.bytes[0];
        \\}
        \\
        \\fn write_u(word: Word, value: u32) -> Word {
        \\    word.u = value;
        \\    return word;
        \\}
        \\
        \\fn write_b0(word: Word, value: u8) -> Word {
        \\    word.bytes[0] = value;
        \\    return word;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_overlay_union.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Word {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "alignas(4) unsigned char storage[4];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} Word;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Word pass_word(Word word)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return word;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t read_u(Word word)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "memcpy(&mc_tmp0, word.storage, 4);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_b0(Word word)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return word.storage[mc_check_index_usize(0, 4)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Word write_u(Word word, uint32_t value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp1 = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "memcpy(word.storage, &mc_tmp1, 4);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Word write_b0(Word word, uint8_t value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "word.storage[mc_check_index_usize(0, 4)] = value;") != null);
}

test "emits C assert trap" {
    const source =
        \\fn require_flag(flag: bool) -> void {
        \\    assert(flag);
        \\}
        \\
        \\fn require_expr(a: u32, b: u32) -> void {
        \\    assert(a == b || a != 0);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_assert.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(flag)) mc_trap_Assert();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(((a == b) || (a != 0)))) mc_trap_Assert();") != null);
}

test "emits C lexical defer cleanup before return" {
    const source =
        \\extern fn close_a() -> void;
        \\extern fn close_b() -> void;
        \\
        \\fn accept_lexical_cleanup() -> void {
        \\    defer close_a();
        \\    defer close_b();
        \\    return;
        \\}
        \\
        \\fn accept_block_cleanup() -> void {
        \\    defer {
        \\        close_a();
        \\    };
        \\    return;
        \\}
        \\
        \\fn accept_cleanup_before_break(flag: bool) -> void {
        \\    while flag {
        \\        defer close_a();
        \\        break;
        \\    }
        \\}
        \\
        \\fn accept_cleanup_before_continue(flag: bool) -> void {
        \\    while flag {
        \\        defer close_a();
        \\        continue;
        \\    }
        \\}
        \\
        \\fn accept_cleanup_on_fallthrough() -> void {
        \\    defer close_a();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_defer.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "void close_a(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "void close_b(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_lexical_cleanup(void) {\n    close_b();\n    close_a();\n    return;\n}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_block_cleanup(void) {\n    {\n        close_a();\n    }\n    return;\n}") != null);
    // The defer cleanup still runs before the (now labeled-goto) break/continue.
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_before_break(bool flag) {\n    while (flag) {\n        close_a();\n        goto mc_break_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_before_continue(bool flag) {\n    while (flag) {\n        close_a();\n        goto mc_continue_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_on_fallthrough(void) {\n    close_a();\n}") != null);
}

test "emits C unsafe blocks as scoped blocks" {
    const source =
        \\fn accept_unsafe_block() -> u32 {
        \\    var x: u32 = 1;
        \\    unsafe {
        \\        x = x + 1;
        \\    }
        \\    return x;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_unsafe_block.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_unsafe_block(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;\n    {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
}

test "emits C for opaque volatile asm" {
    const source =
        \\fn asm_in_unsafe() -> void {
        \\    unsafe {
        \\        asm opaque volatile {
        \\            "pause"
        \\            clobber("memory")
        \\        }
        \\    }
        \\}
        \\
        \\fn boot_asm() -> void {
        \\    unsafe {
        \\        asm opaque volatile {
        \\            "cli"
        \\            "hlt"
        \\        }
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_asm.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void asm_in_unsafe(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"pause\" ::: \"memory\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"cli\" \"\\n\\t\" \"hlt\" ::: \"memory\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#error \"inline asm emission requires compiler support\"") != null);
}

test "emits C for precise asm with operands" {
    const source =
        \\fn find_first_set(mask: u64) -> u64 {
        \\    var idx: u64 = 0;
        \\    #[unsafe_contract(precise_asm)]
        \\    {
        \\        unsafe {
        \\            asm precise volatile {
        \\                "bsf %1, %0"
        \\                out("rax") idx: u64,
        \\                in("rbx") mask: u64,
        \\                clobber("cc")
        \\            }
        \\        }
        \\    }
        \\    return idx;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_precise_asm.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    // Outputs bind the named local lvalue; inputs feed their value expression;
    // declared registers are preserved as a provenance comment.
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"bsf %1, %0\" : \"=r\"(idx) : \"r\"(mask) : \"cc\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_PRECISE_ASM out(\"rax\")->idx in(\"rbx\") */") != null);
}

test "emits C for reduce.sum_checked" {
    const source =
        \\fn sum(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_reduce.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    // Wide accumulator, final range-check into the result type, Result struct.
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__int128 mc_acc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "> (__int128)(UINT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "(mc_result_u32_Overflow){ .is_ok = true, .payload.ok = (uint32_t)mc_acc") != null);
}

test "emits C unsafe contract blocks as scoped blocks" {
    const source =
        \\extern fn next_value() -> u32;
        \\extern fn consume_value(value: u32) -> void;
        \\extern fn consume_values(values: [1]u32) -> void;
        \\extern fn consume_counter(counter: Counter) -> void;
        \\
        \\struct Counter {
        \\    next: u32,
        \\}
        \\
        \\fn accept_plain_contract_scope() -> u32 {
        \\    var x: u32 = 1;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        x = x + 1;
        \\    }
        \\    return x;
        \\}
        \\
        \\fn accept_unchecked_contract_add(a: u32, b: u32) -> u32 {
        \\    var x: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        x = unchecked.add(a, b);
        \\    }
        \\    return x;
        \\}
        \\
        \\fn accept_unchecked_contract_return_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_return_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(next_value(), next_value()) as u32;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let value: u32 = unchecked.add(next_value(), next_value());
        \\        return value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let cast_value: u32 = unchecked.add(next_value(), next_value()) as u32;
        \\        return cast_value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_inferred_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let inferred = unchecked.add(next_value(), next_value());
        \\        return inferred;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_inferred_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let cast_inferred = unchecked.add(next_value(), next_value()) as u32;
        \\        return cast_inferred;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_assignment_order() -> u32 {
        \\    var value: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        value = unchecked.add(next_value(), next_value());
        \\    }
        \\    return value;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_assignment_order() -> u32 {
        \\    var cast_assigned: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        cast_assigned = unchecked.add(next_value(), next_value()) as u32;
        \\    }
        \\    return cast_assigned;
        \\}
        \\
        \\fn accept_unchecked_contract_arg_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.add(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_arg_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.add(next_value(), next_value()) as u32);
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_arg_sub_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.sub(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_arg_mul_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.mul(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_sub_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.sub(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_mul_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.mul(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_nested_binary_order(a: u32, b: u32, c: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b)) + c;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_return(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_array_return(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_return(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_struct_return(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_local(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let values: [1]u32 = .{ unchecked.sub(a, b) };
        \\        return values;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_local(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let counter: Counter = .{ .next = unchecked.add(a, b) };
        \\        return counter;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_arg(a: u32, b: u32) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_values(.{ unchecked.add(a, b) });
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_arg(a: u32, b: u32) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_counter(.{ .next = unchecked.mul(a, b) });
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_assignment(a: u32, b: u32) -> [1]u32 {
        \\    var values: [1]u32 = .{0};
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        values = .{ unchecked.sub(a, b) };
        \\    }
        \\    return values;
        \\}
        \\
        \\fn accept_unchecked_contract_struct_assignment(a: u32, b: u32) -> Counter {
        \\    var counter: Counter = .{ .next = 0 };
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        counter = .{ .next = unchecked.add(a, b) };
        \\    }
        \\    return counter;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_contract_block.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var checker = sema.Checker.init(&reporter);
    checker.checkModule(module);
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_plain_contract_scope(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;\n    /* MC_CONTRACT_BEGIN no_overflow */\n    {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_unchecked_contract_add(uint32_t a, uint32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=x op=add */") != null);
    var mir_range_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, "/* MC_MIR_RANGE no_overflow target=value op=add */")) |index| {
        mir_range_count += 1;
        search_from = index + 1;
    }
    try std.testing.expectEqual(@as(usize, 4), mir_range_count);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=inferred op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_value op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_inferred op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_assigned op=add */") != null);
    var call_arg_add_count: usize = 0;
    search_from = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, "/* MC_MIR_RANGE no_overflow target=call_arg op=add */")) |index| {
        call_arg_add_count += 1;
        search_from = index + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), call_arg_add_count);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=sub */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=mul */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=binary_operand op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=value op=sub */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=value op=mul */") != null);
    var aggregate_add_count: usize = 0;
    search_from = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, "/* MC_MIR_RANGE no_overflow target=aggregate_element op=add */")) |index| {
        aggregate_add_count += 1;
        search_from = index + 1;
    }
    try std.testing.expectEqual(@as(usize, 3), aggregate_add_count);
    var aggregate_sub_count: usize = 0;
    search_from = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, "/* MC_MIR_RANGE no_overflow target=aggregate_element op=sub */")) |index| {
        aggregate_sub_count += 1;
        search_from = index + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), aggregate_sub_count);
    var next_mul_count: usize = 0;
    search_from = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, "/* MC_MIR_RANGE no_overflow target=next op=mul */")) |index| {
        next_mul_count += 1;
        search_from = index + 1;
    }
    try std.testing.expectEqual(@as(usize, 3), next_mul_count);
    var next_add_count: usize = 0;
    search_from = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, "/* MC_MIR_RANGE no_overflow target=next op=add */")) |index| {
        next_add_count += 1;
        search_from = index + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), next_add_count);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_values(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_counter(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = (mc_tmp") != null);
}

test "omits pure comptime blocks from C runtime output" {
    const source =
        \\fn accept_pure_comptime_block() -> u32 {
        \\    comptime {
        \\        let x: u32 = 1;
        \\        assert(true);
        \\    }
        \\    return 1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_comptime_block.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var checker = sema.Checker.init(&reporter);
    checker.checkModule(module);
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_pure_comptime_block(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(true))") == null);
}

test "emits C explicit traps and unreachable" {
    const source =
        \\fn trap_as_value() -> u32 {
        \\    return trap(.Bounds);
        \\}
        \\
        \\fn unreachable_as_value() -> u32 {
        \\    return unreachable;
        \\}
        \\
        \\fn never_returns_by_trap() -> never {
        \\    return trap(.Assert);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_traps.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t trap_as_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void never_returns_by_trap(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert();") != null);
}

test "C emission rejects non-static global initializers instead of zeroing" {
    const source =
        \\fn source() -> u32 {
        \\    return 1;
        \\}
        \\
        \\global value: u32 = source();
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_reject_global_init.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var checker = sema.Checker.init(&reporter);
    checker.checkModule(module);
    try std.testing.expect(hasTestDiagnosticCode(reporter, "E_GLOBAL_INITIALIZER_NOT_STATIC"));

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendC(std.testing.allocator, module, &output));
}

test "C emission uses type-directed helpers for fixed-width checked arithmetic" {
    const source =
        \\fn add_i32(a: i32, b: i32) -> i32 {
        \\    return a + b;
        \\}
        \\
        \\fn div_i32(a: i32, b: i32) -> i32 {
        \\    return a / b;
        \\}
        \\
        \\fn mul_u64(a: u64, b: u64) -> u64 {
        \\    return a * b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_fixed_width_arith.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_SIGNED(i32, int32_t, INT32_MIN, INT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_i32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_div_i32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mul_u64(") != null);
}

test "C emission sequences return call arguments left to right" {
    const source =
        \\extern fn next_value() -> u32;
        \\extern fn box_value(value: u32) -> u32;
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\extern fn consume(left: u32, right: u32) -> void;
        \\
        \\global ordered_global: u32 = 0;
        \\
        \\fn ordered_two_args() -> u32 {
        \\    return combine(next_value(), next_value());
        \\}
        \\
        \\fn ordered_local_init() -> u32 {
        \\    let value = combine(next_value(), next_value());
        \\    return value;
        \\}
        \\
        \\fn ordered_typed_local_init() -> u32 {
        \\    let value: u32 = combine(next_value(), next_value());
        \\    return value;
        \\}
        \\
        \\fn ordered_expr_stmt() -> void {
        \\    consume(next_value(), next_value());
        \\}
        \\
        \\fn ordered_nested_return() -> u32 {
        \\    return combine(box_value(next_value()), next_value());
        \\}
        \\
        \\fn ordered_nested_local_init() -> u32 {
        \\    let value = combine(box_value(next_value()), next_value());
        \\    return value;
        \\}
        \\
        \\fn ordered_nested_expr_stmt() -> void {
        \\    consume(box_value(next_value()), next_value());
        \\}
        \\
        \\fn ordered_assignment() -> u32 {
        \\    var value: u32 = 0;
        \\    value = combine(next_value(), next_value());
        \\    return value;
        \\}
        \\
        \\fn ordered_nested_assignment() -> u32 {
        \\    var value: u32 = 0;
        \\    value = combine(box_value(next_value()), next_value());
        \\    return value;
        \\}
        \\
        \\fn ordered_global_assignment() -> void {
        \\    ordered_global = combine(next_value(), next_value());
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_eval_order.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = next_value();\n    uint32_t mc_tmp1 = next_value();\n    return combine(mc_tmp0, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp2 = next_value();\n    uint32_t mc_tmp3 = next_value();\n    uint32_t value = combine(mc_tmp2, mc_tmp3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp4 = next_value();\n    uint32_t mc_tmp5 = next_value();\n    uint32_t value = combine(mc_tmp4, mc_tmp5);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp6 = next_value();\n    uint32_t mc_tmp7 = next_value();\n    consume(mc_tmp6, mc_tmp7);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp8 = next_value();\n    uint32_t mc_tmp9 = box_value(mc_tmp8);\n    uint32_t mc_tmp10 = next_value();\n    return combine(mc_tmp9, mc_tmp10);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp11 = next_value();\n    uint32_t mc_tmp12 = box_value(mc_tmp11);\n    uint32_t mc_tmp13 = next_value();\n    uint32_t value = combine(mc_tmp12, mc_tmp13);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp14 = next_value();\n    uint32_t mc_tmp15 = box_value(mc_tmp14);\n    uint32_t mc_tmp16 = next_value();\n    consume(mc_tmp15, mc_tmp16);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp17 = next_value();\n    uint32_t mc_tmp18 = next_value();\n    uint32_t mc_tmp19 = combine(mc_tmp17, mc_tmp18);\n    value = mc_tmp19;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp20 = next_value();\n    uint32_t mc_tmp21 = box_value(mc_tmp20);\n    uint32_t mc_tmp22 = next_value();\n    uint32_t mc_tmp23 = combine(mc_tmp21, mc_tmp22);\n    value = mc_tmp23;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp24 = next_value();\n    uint32_t mc_tmp25 = next_value();\n    uint32_t mc_tmp26 = combine(mc_tmp24, mc_tmp25);\n    mc_race_store_u32(&ordered_global, (uint32_t)mc_tmp26);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value = combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "box_value(next_value())") == null);
}
