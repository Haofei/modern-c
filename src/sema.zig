const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

pub const Checker = struct {
    reporter: *diagnostics.Reporter,

    pub fn init(reporter: *diagnostics.Reporter) Checker {
        return .{ .reporter = reporter };
    }

    pub fn checkModule(self: *Checker, module: ast.Module) void {
        var mmio_structs = std.StringHashMap(MmioStruct).init(self.reporter.allocator);
        defer deinitMmioStructs(&mmio_structs);
        self.collectMmioStructs(module, &mmio_structs);

        for (module.decls) |decl| self.checkDecl(decl, &mmio_structs);
    }

    fn collectMmioStructs(self: *Checker, module: ast.Module, mmio_structs: *std.StringHashMap(MmioStruct)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .extern_struct => |struct_decl| {
                    if (struct_decl.abi) |abi| {
                        if (std.mem.eql(u8, abi, "mmio")) self.collectMmioStruct(struct_decl, mmio_structs);
                    }
                },
                .fn_decl, .extern_fn, .type_alias, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectMmioStruct(self: *Checker, struct_decl: ast.StructDecl, mmio_structs: *std.StringHashMap(MmioStruct)) void {
        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        for (struct_decl.fields) |field| {
            if (isMmioRegisterType(field.ty)) fields.put(field.name.text, {}) catch {};
        }
        mmio_structs.put(struct_decl.name.text, .{ .fields = fields }) catch {
            fields.deinit();
        };
    }

    fn checkDecl(self: *Checker, decl: ast.Decl, mmio_structs: *const std.StringHashMap(MmioStruct)) void {
        const no_lang_trap = hasNoLangTrap(decl.attrs);
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| self.checkFn(fn_decl, no_lang_trap, mmio_structs),
            .extern_struct => |struct_decl| {
                for (struct_decl.fields) |field| self.checkType(field.ty, .normal);
            },
            .type_alias => |alias| self.checkType(alias.ty, .normal),
            .opaque_decl => {},
            .global_decl => |global| {
                if (global.ty) |ty| self.checkType(ty, .normal);
                if (global.init) |initializer| _ = self.checkExpr(initializer, .{});
            },
        }
    }

    fn checkFn(self: *Checker, fn_decl: ast.FnDecl, no_lang_trap: bool, mmio_structs: *const std.StringHashMap(MmioStruct)) void {
        var scope = Scope.init(self.reporter.allocator);
        defer scope.deinit();
        var mmio_params = std.StringHashMap([]const u8).init(self.reporter.allocator);
        defer mmio_params.deinit();

        for (fn_decl.params) |param| {
            self.checkType(param.ty, .normal);
            scope.put(param.name.text, classifyType(param.ty)) catch {};
            if (mmioPointee(param.ty)) |struct_name| mmio_params.put(param.name.text, struct_name) catch {};
        }
        const returns_never = if (fn_decl.return_type) |ty| blk: {
            self.checkType(ty, .normal);
            break :blk isTypeName(ty, "never");
        } else false;
        const returns_void = if (fn_decl.return_type) |ty| isTypeName(ty, "void") else false;
        if (fn_decl.body) |body| {
            self.checkBlock(body, .{
                .no_lang_trap = no_lang_trap,
                .returns_never = returns_never,
                .returns_void = returns_void,
                .unsafe_contracts = .{},
                .scope = &scope,
                .mmio_structs = mmio_structs,
                .mmio_params = &mmio_params,
            });
            if (returns_never) {
                if (fallthroughSpan(body)) |span| {
                    self.errorCode(span, "E_NEVER_FALLTHROUGH", "function declared -> never can fall off the end");
                }
            }
        }
    }

    fn checkBlock(self: *Checker, block: ast.Block, ctx: Context) void {
        for (block.items) |stmt| self.checkStmt(stmt, ctx);
    }

    fn checkStmt(self: *Checker, stmt: ast.Stmt, ctx: Context) void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                const kind = if (local.ty) |ty| classifyType(ty) else TypeClass.unknown;
                if (local.ty) |ty| self.checkType(ty, .normal);
                if (local.init) |expr| {
                    const initializer = self.checkExpr(expr, ctx);
                    if (local.ty != null and !canInitialize(kind, initializer)) {
                        self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion");
                    }
                }
                if (ctx.scope) |scope| {
                    for (local.names) |name| scope.put(name.text, kind) catch {};
                }
            },
            .loop => |loop| {
                if (loop.iterable) |expr| _ = self.checkExpr(expr, ctx);
                self.checkBlock(loop.body, ctx);
            },
            .if_let => |node| {
                _ = self.checkExpr(node.value, ctx);
                self.checkBlock(node.then_block, ctx);
                if (node.else_block) |else_block| self.checkBlock(else_block, ctx);
            },
            .@"switch" => |node| {
                _ = self.checkExpr(node.subject, ctx);
                for (node.arms) |arm| switch (arm.body) {
                    .block => |block| self.checkBlock(block, ctx),
                    .expr => |expr| _ = self.checkExpr(expr, ctx),
                };
            },
            .unsafe_block, .block => |block| self.checkBlock(block, ctx),
            .asm_stmt => {},
            .contract_block => |contract| {
                var next = ctx;
                next.unsafe_contracts = next.unsafe_contracts.with(contract.attr);
                self.checkBlock(contract.block, next);
            },
            .@"return" => |maybe| {
                if (maybe) |expr| {
                    const returned = self.checkExpr(expr, ctx);
                    if (ctx.returns_never and returned != .never) {
                        self.errorCode(stmt.span, "E_NEVER_RETURNS", "function declared -> never cannot return normally");
                    } else if (ctx.returns_void and returned != .void and returned != .never) {
                        self.errorCode(stmt.span, "E_VOID_RETURNS_VALUE", "function declared -> void cannot return a value");
                    }
                } else if (ctx.returns_never) {
                    self.errorCode(stmt.span, "E_NEVER_RETURNS", "function declared -> never cannot return normally");
                }
            },
            .@"defer", .expr => |expr| _ = self.checkExpr(expr, ctx),
            .assert => |expr| {
                if (ctx.no_lang_trap) {
                    self.errorCode(stmt.span, "E_NO_LANG_TRAP_EDGE", "assert may emit a language trap in #[no_lang_trap]");
                }
                _ = self.checkExpr(expr, ctx);
            },
            .assignment => |node| {
                if (isMmioRegisterTarget(node.target, ctx)) {
                    self.errorCode(stmt.span, "E_MMIO_DIRECT_ASSIGN", "MMIO registers must be accessed through typed read/write methods");
                }
                _ = self.checkExpr(node.target, ctx);
                _ = self.checkExpr(node.value, ctx);
            },
        }
    }

    fn checkExpr(self: *Checker, expr: ast.Expr, ctx: Context) TypeClass {
        return switch (expr.kind) {
            .ident => |ident| if (ctx.scope) |scope| scope.get(ident.text) orelse .unknown else .unknown,
            .int_literal => .int_literal,
            .void_literal => .void,
            .bool_literal => .bool,
            .string_literal, .char_literal, .null_literal, .uninit_literal, .enum_literal => .unknown,
            .unreachable_expr => {
                if (ctx.no_lang_trap) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "reachable unreachable emits a language trap in #[no_lang_trap]");
                }
                return .never;
            },
            .grouped, .address_of => |inner| self.checkExpr(inner.*, ctx),
            .try_expr => |inner| {
                if (ctx.no_lang_trap) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "unwrap may emit a language trap in #[no_lang_trap]");
                }
                return self.checkExpr(inner.*, ctx);
            },
            .block => |block| {
                self.checkBlock(block, ctx);
                return .unknown;
            },
            .unary => |node| {
                if (ctx.no_lang_trap and node.op == .neg) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "checked unary negation may trap in #[no_lang_trap]");
                }
                const inner = self.checkExpr(node.expr.*, ctx);
                if (node.op == .neg and isCheckedUnsigned(inner)) {
                    self.errorCode(expr.span, "E_UNSIGNED_NEGATION", "unsigned checked integers do not support unary '-'");
                }
                return inner;
            },
            .binary => |node| {
                if (ctx.no_lang_trap and isTrapBinary(node.op)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "checked operation may trap in #[no_lang_trap]");
                }
                const left = self.checkExpr(node.left.*, ctx);
                const right = self.checkExpr(node.right.*, ctx);
                if (isArithmeticBinary(node.op) and ((left == .wrap and isCheckedInt(right)) or (right == .wrap and isCheckedInt(left)))) {
                    self.errorCode(expr.span, "E_ARITH_POLICY_MIX", "arithmetic domains do not implicitly mix");
                }
                return mergeArithmetic(left, right);
            },
            .cast => |node| {
                const source = self.checkExpr(node.value.*, ctx);
                self.checkType(node.ty.*, .normal);
                const target = classifyType(node.ty.*);
                if ((source == .c_void_pointer) != (target == .c_void_pointer)) {
                    self.errorCode(expr.span, "E_C_VOID_CONVERSION", "c_void pointer conversions require an explicit FFI boundary operation");
                }
                return target;
            },
            .call => |node| {
                const trap_call = isTrapCall(node.callee.*);
                if (ctx.no_lang_trap and isTrapCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "explicit trap emits a language trap in #[no_lang_trap]");
                }
                if (ctx.no_lang_trap and isUnwrapCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "unwrap may emit a language trap in #[no_lang_trap]");
                }
                if (uncheckedRequirement(node.callee.*)) |required| {
                    if (!ctx.unsafe_contracts.has(required)) {
                        self.errorCode(expr.span, "E_UNCHECKED_OUTSIDE_CONTRACT", "unchecked operation requires matching #[unsafe_contract]");
                    }
                }
                if (isCVoidLayoutCall(node.callee.*, node.type_args)) {
                    self.errorCode(expr.span, "E_C_VOID_NO_LAYOUT", "c_void has no size or alignment in MC");
                }
                if (trap_call) self.checkTrapKind(expr.span, node.args);
                _ = self.checkExpr(node.callee.*, ctx);
                for (node.type_args) |ty| self.checkType(ty, .normal);
                for (node.args) |arg| _ = self.checkExpr(arg, ctx);
                if (trap_call) return .never;
                return .unknown;
            },
            .index => |node| {
                if (ctx.no_lang_trap) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "indexing may trap in #[no_lang_trap]");
                }
                _ = self.checkExpr(node.base.*, ctx);
                _ = self.checkExpr(node.index.*, ctx);
                return .unknown;
            },
            .deref => |inner| {
                const inner_class = self.checkExpr(inner.*, ctx);
                if (inner_class == .c_void_pointer) {
                    self.errorCode(expr.span, "E_C_VOID_DEREF", "c_void pointer cannot be dereferenced");
                }
                return .unknown;
            },
            .member => |node| {
                const base_class = self.checkExpr(node.base.*, ctx);
                if (base_class == .c_void_pointer) {
                    self.errorCode(expr.span, "E_C_VOID_NO_LAYOUT", "c_void has no fields in MC");
                }
                return .unknown;
            },
        };
    }

    fn checkType(self: *Checker, ty: ast.TypeExpr, mode: TypeMode) void {
        switch (ty.kind) {
            .name => |name| {
                if (mode == .ffi_opaque_pointer and std.mem.eql(u8, name.text, "void")) {
                    self.errorCode(name.span, "E_MC_VOID_POINTER_FFI", "use c_void for C opaque object pointers, not MC void");
                }
            },
            .enum_literal => {},
            .member => |node| self.checkType(node.base.*, .normal),
            .nullable => |child| self.checkType(child.*, mode),
            .pointer => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode);
            },
            .slice => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode);
            },
            .array => |node| {
                _ = self.checkExpr(node.len, .{});
                self.checkType(node.child.*, .normal);
            },
            .generic => |node| {
                for (node.args) |arg| self.checkType(arg, .normal);
            },
        }
    }

    fn errorCode(self: *Checker, span: diagnostics.Span, code: []const u8, message: []const u8) void {
        self.reporter.err(span, "{s}: {s}", .{ code, message });
    }

    fn checkTrapKind(self: *Checker, span: diagnostics.Span, args: []ast.Expr) void {
        if (args.len != 1) {
            self.errorCode(span, "E_INVALID_TRAP_KIND", "trap expects exactly one language TrapKind");
            return;
        }
        const kind = switch (args[0].kind) {
            .enum_literal => |literal| literal,
            else => {
                self.errorCode(args[0].span, "E_INVALID_TRAP_KIND", "trap kind must be a language TrapKind enum literal");
                return;
            },
        };
        if (!isLanguageTrapKind(kind.text)) {
            self.errorCode(kind.span, "E_INVALID_TRAP_KIND", "unknown language TrapKind");
        }
    }
};

const Context = struct {
    no_lang_trap: bool = false,
    returns_never: bool = false,
    returns_void: bool = false,
    unsafe_contracts: UnsafeContracts = .{},
    scope: ?*Scope = null,
    mmio_structs: ?*const std.StringHashMap(MmioStruct) = null,
    mmio_params: ?*const std.StringHashMap([]const u8) = null,
};

const MmioStruct = struct {
    fields: std.StringHashMap(void),
};

const UnsafeContracts = struct {
    no_overflow: bool = false,
    noalias_contract: bool = false,

    fn with(self: UnsafeContracts, attr: ast.Attr) UnsafeContracts {
        var next = self;
        switch (attr.kind) {
            .unsafe_contract => |contract| {
                if (std.mem.eql(u8, contract.name.text, "no_overflow")) next.no_overflow = true;
                if (std.mem.eql(u8, contract.name.text, "noalias")) next.noalias_contract = true;
            },
            .no_lang_trap, .named => {},
        }
        return next;
    }

    fn has(self: UnsafeContracts, required: ContractKind) bool {
        return switch (required) {
            .no_overflow => self.no_overflow,
            .noalias_contract => self.noalias_contract,
        };
    }
};

const ContractKind = enum {
    no_overflow,
    noalias_contract,
};

const Scope = std.StringHashMap(TypeClass);

const TypeClass = enum {
    unknown,
    checked_u8,
    checked_u16,
    checked_u32,
    checked_u64,
    checked_usize,
    checked_i8,
    checked_i16,
    checked_i32,
    checked_i64,
    checked_isize,
    wrap,
    c_void_pointer,
    never,
    void,
    bool,
    int_literal,
};

const TypeMode = enum {
    normal,
    ffi_opaque_pointer,
};

fn hasNoLangTrap(attrs: []ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .no_lang_trap) return true;
    }
    return false;
}

fn isTrapBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr => true,
        else => false,
    };
}

fn isArithmeticBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => true,
        else => false,
    };
}

fn isCheckedInt(kind: TypeClass) bool {
    return isCheckedUnsigned(kind) or isCheckedSigned(kind);
}

fn isCheckedUnsigned(kind: TypeClass) bool {
    return switch (kind) {
        .checked_u8, .checked_u16, .checked_u32, .checked_u64, .checked_usize => true,
        else => false,
    };
}

fn isCheckedSigned(kind: TypeClass) bool {
    return switch (kind) {
        .checked_i8, .checked_i16, .checked_i32, .checked_i64, .checked_isize => true,
        else => false,
    };
}

fn mergeArithmetic(left: TypeClass, right: TypeClass) TypeClass {
    if (left == .wrap or right == .wrap) return .wrap;
    if (isCheckedSigned(left)) return left;
    if (isCheckedSigned(right)) return right;
    if (isCheckedUnsigned(left)) return left;
    if (isCheckedUnsigned(right)) return right;
    return .unknown;
}

fn classifyType(ty: ast.TypeExpr) TypeClass {
    return switch (ty.kind) {
        .name => |name| classifyTypeName(name.text),
        .pointer => |node| if (isTypeName(node.child.*, "c_void")) .c_void_pointer else .unknown,
        .slice => |node| if (isTypeName(node.child.*, "c_void")) .c_void_pointer else .unknown,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "wrap")) .wrap else .unknown,
        else => .unknown,
    };
}

fn classifyTypeName(name: []const u8) TypeClass {
    if (std.mem.eql(u8, name, "u8")) return .checked_u8;
    if (std.mem.eql(u8, name, "u16")) return .checked_u16;
    if (std.mem.eql(u8, name, "u32")) return .checked_u32;
    if (std.mem.eql(u8, name, "u64")) return .checked_u64;
    if (std.mem.eql(u8, name, "usize")) return .checked_usize;
    if (std.mem.eql(u8, name, "i8")) return .checked_i8;
    if (std.mem.eql(u8, name, "i16")) return .checked_i16;
    if (std.mem.eql(u8, name, "i32")) return .checked_i32;
    if (std.mem.eql(u8, name, "i64")) return .checked_i64;
    if (std.mem.eql(u8, name, "isize")) return .checked_isize;
    if (std.mem.eql(u8, name, "never")) return .never;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    return .unknown;
}

fn canInitialize(target: TypeClass, initializer: TypeClass) bool {
    if (target == .unknown or initializer == .unknown) return true;
    if (initializer == .never) return true;
    if (target == initializer) return true;
    if (isCheckedInt(target) and initializer == .int_literal) return true;
    return false;
}

fn deinitMmioStructs(mmio_structs: *std.StringHashMap(MmioStruct)) void {
    var structs = mmio_structs.valueIterator();
    while (structs.next()) |mmio_struct| mmio_struct.fields.deinit();
    mmio_structs.deinit();
}

fn isMmioRegisterTarget(target: ast.Expr, ctx: Context) bool {
    const member = switch (target.kind) {
        .member => |node| node,
        .grouped => |inner| return isMmioRegisterTarget(inner.*, ctx),
        else => return false,
    };
    const base_name = switch (member.base.kind) {
        .ident => |ident| ident.text,
        else => return false,
    };
    const mmio_params = ctx.mmio_params orelse return false;
    const struct_name = mmio_params.get(base_name) orelse return false;
    const mmio_structs = ctx.mmio_structs orelse return false;
    const mmio_struct = mmio_structs.get(struct_name) orelse return false;
    return mmio_struct.fields.contains(member.name.text);
}

fn isMmioRegisterType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "Reg") or std.mem.eql(u8, node.base.text, "RegBits"),
        else => false,
    };
}

fn mmioPointee(ty: ast.TypeExpr) ?[]const u8 {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "MmioPtr") or generic.args.len != 1) return null;
    return typeName(generic.args[0]);
}

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        else => null,
    };
}

fn uncheckedRequirement(expr: ast.Expr) ?ContractKind {
    return switch (expr.kind) {
        .member => |node| {
            if (isIdentNamed(node.base.*, "unchecked")) return .no_overflow;
            if (isIdentNamed(node.base.*, "compiler") and std.mem.eql(u8, node.name.text, "assume_noalias_unchecked")) return .noalias_contract;
            return null;
        },
        .ident => |ident| if (std.mem.eql(u8, ident.text, "assume_noalias_unchecked")) .noalias_contract else null,
        else => null,
    };
}

fn isCVoidLayoutCall(callee: ast.Expr, type_args: []ast.TypeExpr) bool {
    if (!isIdentNamed(callee, "size_of") and !isIdentNamed(callee, "sizeof") and !isIdentNamed(callee, "alignof")) return false;
    return type_args.len == 1 and isTypeName(type_args[0], "c_void");
}

fn isUnwrapCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "unwrap"),
        .member => |node| std.mem.eql(u8, node.name.text, "unwrap"),
        else => false,
    };
}

fn isTrapCall(callee: ast.Expr) bool {
    return isIdentNamed(callee, "trap");
}

fn isLanguageTrapKind(name: []const u8) bool {
    const names = [_][]const u8{
        "Bounds",
        "NullUnwrap",
        "IntegerOverflow",
        "DivideByZero",
        "InvalidShift",
        "InvalidRepresentation",
        "Assert",
        "Unreachable",
    };
    for (names) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

fn isCAbiOpaqueBoundary(ty: ast.TypeExpr) bool {
    return isTypeName(ty, "void") or isTypeName(ty, "c_void");
}

fn isTypeName(ty: ast.TypeExpr, name: []const u8) bool {
    return switch (ty.kind) {
        .name => |ident| std.mem.eql(u8, ident.text, name),
        else => false,
    };
}

fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        else => false,
    };
}

fn fallthroughSpan(block: ast.Block) ?diagnostics.Span {
    if (block.items.len == 0) return block.span;
    const last = block.items[block.items.len - 1];
    return if (stmtMayFallThrough(last)) last.span else null;
}

fn stmtMayFallThrough(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .@"return", .asm_stmt => false,
        .expr => |expr| exprMayFallThrough(expr),
        .block, .unsafe_block => |block| fallthroughSpan(block) != null,
        .contract_block => |contract| fallthroughSpan(contract.block) != null,
        .if_let => |node| node.else_block == null or
            fallthroughSpan(node.then_block) != null or
            fallthroughSpan(node.else_block.?) != null,
        .@"switch" => |node| switchMayFallThrough(node),
        else => true,
    };
}

fn switchMayFallThrough(node: ast.Switch) bool {
    if (node.arms.len == 0) return true;
    for (node.arms) |arm| {
        const arm_falls_through = switch (arm.body) {
            .block => |block| fallthroughSpan(block) != null,
            .expr => |expr| exprMayFallThrough(expr),
        };
        if (arm_falls_through) return true;
    }
    return false;
}

fn exprMayFallThrough(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unreachable_expr => false,
        .grouped => |inner| exprMayFallThrough(inner.*),
        .call => |node| !isTrapCall(node.callee.*),
        .block => |block| fallthroughSpan(block) != null,
        else => true,
    };
}
