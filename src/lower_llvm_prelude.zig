const std = @import("std");

const ast = @import("ast.zig");
const backend = @import("backend.zig");

// The sanitizer shadow-hook symbols. SINGLE source of truth: this one list drives both the
// weak no-op `define`s in `emitTrapDecl` AND `isKsanHook` (which suppresses a redundant MC
// `extern fn` `declare` of these), so the two can never drift. Names: the KASAN
// poison/unpoison/check hooks (D2.1), the KMSAN init-tracking store hook (D2.2), and the KCSAN
// read/write watchpoint hooks (D2.3). All get weak no-op defaults the linked runtime overrides
// with strong definitions.
const sanitizer_hooks = [_][]const u8{
    "mc_ksan_poison",
    "mc_ksan_unpoison",
    "mc_ksan_check",
    "mc_ksan_store",
    "mc_csan_read",
    "mc_csan_write",
};

// True if the MODULE ITSELF provides a `fn` definition (a body) whose name is `hook`. A pure-MC
// sanitizer runtime does `export fn mc_ksan_check(...) {...}`; in that case we must NOT also emit
// our auto weak no-op `define`, or the symbol would be doubly-defined (invalid IR). Only a body
// counts; an `extern fn` declaration (handled by `isKsanHook`) does not provide a definition.
fn moduleDefinesHook(module: ast.Module, hook: []const u8) bool {
    for (module.decls) |decl| {
        if (decl.kind == .fn_decl) {
            const fn_decl = decl.kind.fn_decl;
            if (fn_decl.body != null and std.mem.eql(u8, fn_decl.name.text, hook)) return true;
        }
    }
    return false;
}

pub fn emitTrapDecl(allocator: std.mem.Allocator, out: *std.ArrayList(u8), module: ast.Module) !void {
    // The checked-arithmetic / bounds / unreachable trap hooks. Like the C backend (which emits
    // them as per-unit `static inline ... __builtin_trap()`), emit a WEAK trapping `define` for
    // each in EVERY LLVM object: a default build self-provides a halting handler (llvm.trap ->
    // an illegal instruction), so no external object has to supply them. A module that defines a
    // hook itself (a custom handler) overrides via its strong `export fn`; a linked C runtime with
    // STRONG definitions likewise wins over these weak ones.
    try out.appendSlice(allocator, "declare void @llvm.trap()\n");
    const trap_hooks = [_][]const u8{
        "mc_trap_IntegerOverflow",       "mc_trap_DivideByZero", "mc_trap_InvalidShift",
        "mc_trap_InvalidRepresentation", "mc_trap_Bounds",       "mc_trap_Assert",
        "mc_trap_NullUnwrap",            "mc_trap_Unreachable",
    };
    for (trap_hooks) |hook| {
        if (moduleDefinesHook(module, hook)) continue;
        try out.print(allocator, "define weak void @{s}() noreturn {{\n  call void @llvm.trap()\n  unreachable\n}}\n", .{hook});
    }
    try out.appendSlice(allocator, "\n");
    // C-ABI varargs intrinsics (for `va.start`/`va.end`; `va.arg` uses the `va_arg` instr).
    try out.appendSlice(allocator, "declare void @llvm.va_start(ptr)\n");
    try out.appendSlice(allocator, "declare void @llvm.va_copy(ptr, ptr)\n");
    try out.appendSlice(allocator, "declare void @llvm.va_end(ptr)\n\n");
    try out.appendSlice(allocator, "declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)\n\n");
    // Weak no-op `define`s for every sanitizer shadow hook so EVERY build links and behaves
    // identically when no sanitizer runtime is present. A linked runtime (the ksan/msan/csan
    // profiles) provides STRONG definitions that override these; a default build never calls
    // them. See `sanitizer_hooks`.
    for (sanitizer_hooks) |hook| {
        // If the module defines this hook itself (a pure-MC sanitizer runtime), yield to that
        // definition: its `export fn` is emitted through normal MIR emission. Emitting the auto
        // weak `define` here too would doubly-define the symbol.
        if (moduleDefinesHook(module, hook)) continue;
        try out.print(allocator, "define weak void @{s}(i64 %a, i64 %b) {{\n  ret void\n}}\n", .{hook});
    }
    try out.appendSlice(allocator, "\n");
}

// A sanitizer shadow-hook symbol gets a weak no-op `define` above, so an MC `extern fn` of the
// same name must NOT also be `declare`d (a `declare` + a `define` of one symbol is invalid IR).
pub fn isKsanHook(name: []const u8) bool {
    for (sanitizer_hooks) |hook| {
        if (std.mem.eql(u8, name, hook)) return true;
    }
    return false;
}

pub fn targetTriple(target_arch: backend.TargetArch) []const u8 {
    return switch (target_arch) {
        .riscv64 => "riscv64-unknown-unknown-elf",
        .x86_64 => "x86_64-unknown-unknown-elf",
        .aarch64 => "aarch64-unknown-unknown-elf",
    };
}

pub fn targetDataLayout(target_arch: backend.TargetArch) []const u8 {
    return switch (target_arch) {
        .riscv64 => "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128",
        .x86_64 => "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128",
        .aarch64 => "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32",
    };
}

pub fn emitTargetTypeDecls(allocator: std.mem.Allocator, out: *std.ArrayList(u8), target_arch: backend.TargetArch) !void {
    switch (target_arch) {
        .riscv64 => {},
        .x86_64 => try out.appendSlice(allocator, "%mc.va_list.x86_64 = type { i32, i32, ptr, ptr }\n\n"),
        .aarch64 => try out.appendSlice(allocator, "%mc.va_list.aarch64 = type { ptr, ptr, ptr, i32, i32 }\n\n"),
    }
}
