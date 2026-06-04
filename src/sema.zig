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
        var structs = std.StringHashMap(StructInfo).init(self.reporter.allocator);
        defer deinitStructs(&structs);
        var enums = std.StringHashMap(EnumInfo).init(self.reporter.allocator);
        defer deinitEnums(&enums);
        var functions = std.StringHashMap(FunctionInfo).init(self.reporter.allocator);
        defer functions.deinit();
        var globals = std.StringHashMap(GlobalInfo).init(self.reporter.allocator);
        defer globals.deinit();
        self.checkTopLevelNames(module);
        self.collectMmioStructs(module, &mmio_structs);
        self.collectStructs(module, &structs);
        self.collectEnums(module, &enums);
        self.collectFunctions(module, &functions);
        self.collectGlobals(module, &globals);

        for (module.decls) |decl| self.checkDecl(decl, &mmio_structs, &structs, &enums, &functions, &globals);
    }

    fn collectMmioStructs(self: *Checker, module: ast.Module, mmio_structs: *std.StringHashMap(MmioStruct)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .extern_struct => |struct_decl| {
                    if (struct_decl.abi) |abi| {
                        if (std.mem.eql(u8, abi, "mmio")) self.collectMmioStruct(struct_decl, mmio_structs);
                    }
                },
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectMmioStruct(self: *Checker, struct_decl: ast.StructDecl, mmio_structs: *std.StringHashMap(MmioStruct)) void {
        if (mmio_structs.contains(struct_decl.name.text)) return;
        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        for (struct_decl.fields) |field| {
            if (isMmioRegisterType(field.ty) and !fields.contains(field.name.text)) fields.put(field.name.text, {}) catch {};
        }
        mmio_structs.put(struct_decl.name.text, .{ .fields = fields }) catch {
            fields.deinit();
        };
    }

    fn collectStructs(self: *Checker, module: ast.Module, structs: *std.StringHashMap(StructInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .extern_struct => |struct_decl| self.collectStruct(struct_decl, structs),
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectStruct(self: *Checker, struct_decl: ast.StructDecl, structs: *std.StringHashMap(StructInfo)) void {
        if (structs.contains(struct_decl.name.text)) return;
        var fields = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        for (struct_decl.fields) |field| {
            if (!fields.contains(field.name.text)) fields.put(field.name.text, field.ty) catch {};
        }
        structs.put(struct_decl.name.text, .{ .fields = fields }) catch {
            fields.deinit();
        };
    }

    fn collectFunctions(self: *Checker, module: ast.Module, functions: *std.StringHashMap(FunctionInfo)) void {
        _ = self;
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl, .extern_fn => |fn_decl| {
                    if (!functions.contains(fn_decl.name.text)) functions.put(fn_decl.name.text, .{ .params = fn_decl.params, .return_ty = fn_decl.return_type }) catch {};
                },
                .extern_struct, .type_alias, .enum_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectEnums(self: *Checker, module: ast.Module, enums: *std.StringHashMap(EnumInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .enum_decl => |enum_decl| self.collectEnum(enum_decl, enums),
                .fn_decl, .extern_fn, .type_alias, .extern_struct, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectEnum(self: *Checker, enum_decl: ast.EnumDecl, enums: *std.StringHashMap(EnumInfo)) void {
        if (enums.contains(enum_decl.name.text)) return;
        var cases = std.StringHashMap(void).init(self.reporter.allocator);
        for (enum_decl.cases) |case| {
            if (!cases.contains(case.name.text)) cases.put(case.name.text, {}) catch {};
        }
        enums.put(enum_decl.name.text, .{ .cases = cases, .is_open = enum_decl.is_open }) catch {
            cases.deinit();
        };
    }

    fn collectGlobals(self: *Checker, module: ast.Module, globals: *std.StringHashMap(GlobalInfo)) void {
        _ = self;
        for (module.decls) |decl| {
            switch (decl.kind) {
                .global_decl => |global| if (global.ty) |ty| {
                    if (!globals.contains(global.name.text)) globals.put(global.name.text, .{ .ty = ty }) catch {};
                },
                .fn_decl, .extern_fn, .extern_struct, .type_alias, .enum_decl, .opaque_decl => {},
            }
        }
    }

    fn checkTopLevelNames(self: *Checker, module: ast.Module) void {
        var names = std.StringHashMap(void).init(self.reporter.allocator);
        defer names.deinit();

        for (module.decls) |decl| {
            const name = declName(decl);
            if (names.contains(name.text)) {
                self.errorCode(name.span, "E_DUPLICATE_DECLARATION", "top-level declarations must have unique names");
            } else {
                names.put(name.text, {}) catch {};
            }
        }
    }

    fn checkDecl(self: *Checker, decl: ast.Decl, mmio_structs: *const std.StringHashMap(MmioStruct), structs: *const std.StringHashMap(StructInfo), enums: *const std.StringHashMap(EnumInfo), functions: *const std.StringHashMap(FunctionInfo), globals: *const std.StringHashMap(GlobalInfo)) void {
        const no_lang_trap = hasNoLangTrap(decl.attrs);
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| self.checkFn(fn_decl, no_lang_trap, mmio_structs, structs, enums, functions, globals),
            .extern_struct => |struct_decl| self.checkStruct(struct_decl),
            .enum_decl => |enum_decl| self.checkEnum(enum_decl),
            .type_alias => |alias| self.checkType(alias.ty, .normal),
            .opaque_decl => {},
            .global_decl => |global| {
                if (global.ty) |ty| self.checkType(ty, .normal);
                if (global.init) |initializer| self.checkGlobalInitializer(global, initializer, .{ .structs = structs, .enums = enums, .functions = functions, .globals = globals });
            },
        }
    }

    fn checkEnum(self: *Checker, enum_decl: ast.EnumDecl) void {
        if (enum_decl.repr) |repr| {
            self.checkType(repr, .normal);
            if (!isCheckedInt(classifyType(repr))) {
                self.errorCode(repr.span, "E_ENUM_REPR_NOT_INTEGER", "enum representation type must be an integer type");
            }
        }

        var cases = std.StringHashMap(void).init(self.reporter.allocator);
        defer cases.deinit();

        for (enum_decl.cases) |case| {
            if (cases.contains(case.name.text)) {
                self.errorCode(case.name.span, "E_DUPLICATE_ENUM_CASE", "enum case names must be unique");
            } else {
                cases.put(case.name.text, {}) catch {};
            }
            if (case.value) |value| _ = self.checkExpr(value, .{});
        }
    }

    fn checkStruct(self: *Checker, struct_decl: ast.StructDecl) void {
        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        defer fields.deinit();

        for (struct_decl.fields) |field| {
            self.checkType(field.ty, .normal);
            if (fields.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_STRUCT_FIELD", "struct field names must be unique");
            } else {
                fields.put(field.name.text, {}) catch {};
            }
        }
    }

    fn checkGlobalInitializer(self: *Checker, global: ast.GlobalDecl, initializer: ast.Expr, ctx: Context) void {
        const ty = global.ty orelse return;
        const target = classifyType(ty);
        const source = self.checkExpr(initializer, ctx);
        if (isUninitLiteral(initializer)) {
            self.errorCode(initializer.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        const literal_checked = self.checkIntegerLiteralInitializer(target, ty, initializer);
        const null_checked = self.checkNullPointerInitializer(target, initializer);
        const array_decay_checked = self.checkArrayDecayInitializer(target, source, initializer);
        const pointer_conversion_checked = self.checkPointerViewInitializer(ty, initializer, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(ty, initializer, ctx);
        const address_checked = self.checkAddressOfInitializer(target, ty, initializer, ctx);
        const enum_checked = self.checkExpectedEnumValue(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        if (!literal_checked and !null_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !enum_checked and !canInitialize(target, source)) {
            self.errorCode(initializer.span, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        }
    }

    fn checkFn(self: *Checker, fn_decl: ast.FnDecl, no_lang_trap: bool, mmio_structs: *const std.StringHashMap(MmioStruct), structs: *const std.StringHashMap(StructInfo), enums: *const std.StringHashMap(EnumInfo), functions: *const std.StringHashMap(FunctionInfo), globals: *const std.StringHashMap(GlobalInfo)) void {
        var scope = Scope.init(self.reporter.allocator);
        defer scope.deinit();
        var mmio_params = std.StringHashMap([]const u8).init(self.reporter.allocator);
        defer mmio_params.deinit();

        for (fn_decl.params) |param| {
            self.checkType(param.ty, .normal);
            if (scope.contains(param.name.text)) {
                self.errorCode(param.name.span, "E_DUPLICATE_PARAMETER", "function parameter names must be unique");
            } else {
                scope.put(param.name.text, .{ .class = classifyType(param.ty), .mutable = false, .ty = param.ty, .origin = .param }) catch {};
                if (mmioPointee(param.ty)) |struct_name| mmio_params.put(param.name.text, struct_name) catch {};
            }
        }
        const return_kind = if (fn_decl.return_type) |ty| classifyType(ty) else TypeClass.void;
        const returns_never = if (fn_decl.return_type) |ty| blk: {
            self.checkType(ty, .normal);
            break :blk isTypeName(ty, "never");
        } else false;
        const returns_void = if (fn_decl.return_type) |ty| isTypeName(ty, "void") else false;
        if (fn_decl.body) |body| {
            const fn_ctx = Context{
                .no_lang_trap = no_lang_trap,
                .returns_never = returns_never,
                .returns_void = returns_void,
                .return_ty = fn_decl.return_type,
                .return_kind = return_kind,
                .unsafe_contracts = .{},
                .scope = &scope,
                .mmio_structs = mmio_structs,
                .mmio_params = &mmio_params,
                .structs = structs,
                .enums = enums,
                .functions = functions,
                .globals = globals,
            };
            self.checkBlock(body, fn_ctx);
            if (fallthroughSpan(body, fn_ctx)) |span| {
                if (returns_never) {
                    self.errorCode(span, "E_NEVER_FALLTHROUGH", "function declared -> never can fall off the end");
                } else if (fn_decl.return_type != null and !returns_void) {
                    self.errorCode(span, "E_RETURN_MISSING", "function return type requires all paths to return a value");
                }
            }
        }
    }

    fn checkBlock(self: *Checker, block: ast.Block, ctx: Context) void {
        for (block.items) |stmt| self.checkStmt(stmt, ctx);
    }

    fn checkStmt(self: *Checker, stmt: ast.Stmt, ctx: Context) void {
        switch (stmt.kind) {
            .let_decl => |local| {
                self.checkLocal(local, ctx, false);
            },
            .var_decl => |local| {
                self.checkLocal(local, ctx, true);
            },
            .loop => |loop| {
                if (loop.iterable) |expr| {
                    const condition = self.checkExpr(expr, ctx);
                    if (loop.kind == .@"while" and !isConditionType(condition)) {
                        self.errorCode(expr.span, "E_CONDITION_NOT_BOOL", "condition must be bool");
                    } else if (loop.kind == .@"for" and !isForIterableBase(condition)) {
                        self.errorCode(expr.span, "E_FOR_BASE_NOT_ARRAY_OR_SLICE", "for loops iterate over arrays and slices");
                    }
                }
                var next = ctx;
                next.loop_depth += 1;
                if (loop.kind == .@"for") {
                    if (ctx.scope) |scope| {
                        self.checkForBody(loop, next, scope);
                    } else {
                        self.checkBlock(loop.body, next);
                    }
                } else {
                    self.checkBlock(loop.body, next);
                }
            },
            .if_let => |node| {
                const value_class = self.checkExpr(node.value, ctx);
                self.checkIfLetPattern(node.pattern, value_class);
                var then_scope = Scope.init(self.reporter.allocator);
                defer then_scope.deinit();
                var then_ctx = ctx;
                if (ctx.scope) |scope| {
                    copyScope(scope, &then_scope) catch {};
                    self.addIfLetBinding(node.pattern, node.value, value_class, &then_scope, ctx);
                    then_ctx.scope = &then_scope;
                }
                self.checkBlock(node.then_block, then_ctx);
                if (node.else_block) |else_block| self.checkBlock(else_block, ctx);
            },
            .@"switch" => |node| {
                self.checkSwitch(node, ctx);
            },
            .unsafe_block => |block| {
                var next = ctx;
                next.in_unsafe = true;
                self.checkBlock(block, next);
            },
            .block => |block| self.checkBlock(block, ctx),
            .asm_stmt => {
                if (!ctx.in_unsafe) {
                    self.errorCode(stmt.span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
                }
            },
            .contract_block => |contract| {
                var next = ctx;
                next.unsafe_contracts = next.unsafe_contracts.with(contract.attr);
                self.checkBlock(contract.block, next);
            },
            .@"return" => |maybe| {
                if (maybe) |expr| {
                    const error_count = self.reporter.diagnostics.items.len;
                    const returned = self.checkExpr(expr, ctx);
                    if (ctx.returns_never and returned != .never) {
                        self.errorCode(stmt.span, "E_NEVER_RETURNS", "function declared -> never cannot return normally");
                    } else if (ctx.returns_void and returned != .void and returned != .never) {
                        self.errorCode(stmt.span, "E_VOID_RETURNS_VALUE", "function declared -> void cannot return a value");
                    } else if (!ctx.returns_never and !ctx.returns_void and self.reporter.diagnostics.items.len == error_count) {
                        self.checkReturnValue(ctx, returned, expr);
                    }
                } else if (ctx.returns_never) {
                    self.errorCode(stmt.span, "E_NEVER_RETURNS", "function declared -> never cannot return normally");
                } else if (ctx.return_ty != null and !ctx.returns_void) {
                    self.errorCode(stmt.span, "E_RETURN_REQUIRES_VALUE", "function return type requires a value");
                }
            },
            .@"break" => {
                if (ctx.loop_depth == 0) {
                    self.errorCode(stmt.span, "E_BREAK_OUTSIDE_LOOP", "break is valid only inside a loop");
                }
            },
            .@"continue" => {
                if (ctx.loop_depth == 0) {
                    self.errorCode(stmt.span, "E_CONTINUE_OUTSIDE_LOOP", "continue is valid only inside a loop");
                }
            },
            .@"defer" => |expr| {
                const cleanup = self.checkExpr(expr, ctx);
                if (cleanup == .never or exprContainsDeferControlFlow(expr, ctx)) {
                    self.errorCode(stmt.span, "E_DEFER_CONTROL_FLOW", "defer is lexical cleanup and must not alter control flow");
                }
            },
            .expr => |expr| _ = self.checkExpr(expr, ctx),
            .assert => |expr| {
                if (ctx.no_lang_trap) {
                    self.errorCode(stmt.span, "E_NO_LANG_TRAP_EDGE", "assert may emit a language trap in #[no_lang_trap]");
                }
                const condition = self.checkExpr(expr, ctx);
                if (!isConditionType(condition)) {
                    self.errorCode(expr.span, "E_CONDITION_NOT_BOOL", "condition must be bool");
                }
            },
            .assignment => |node| {
                if (!isAssignableTarget(node.target)) {
                    self.errorCode(node.target.span, "E_INVALID_ASSIGNMENT_TARGET", "assignment target must be assignable storage");
                }
                if (isMmioRegisterTarget(node.target, ctx)) {
                    self.errorCode(stmt.span, "E_MMIO_DIRECT_ASSIGN", "MMIO registers must be accessed through typed read/write methods");
                }
                self.checkAssignmentTarget(node.target, ctx);
                _ = self.checkExpr(node.target, ctx);
                const value_class = self.checkExpr(node.value, ctx);
                self.checkAssignmentValue(node.target, value_class, node.value, ctx);
                updateAssignmentAddressOrigin(node.target, node.value, ctx);
            },
        }
    }

    fn checkLocal(self: *Checker, local: ast.LocalDecl, ctx: Context, mutable: bool) void {
        const kind = if (local.ty) |ty| classifyType(ty) else TypeClass.unknown;
        var address_origin: AddressOrigin = .none;
        if (local.ty) |ty| self.checkType(ty, .normal);
        if (local.init) |expr| {
            const initializer = self.checkExpr(expr, ctx);
            address_origin = addressOrigin(expr, ctx);
            if (isUninitLiteral(expr)) {
                if (!mutable or local.ty == null) {
                    self.errorCode(expr.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
                }
            } else {
                const literal_checked = if (local.ty) |ty| self.checkIntegerLiteralInitializer(kind, ty, expr) else false;
                const null_checked = if (local.ty != null) self.checkNullPointerInitializer(kind, expr) else false;
                const array_decay_checked = if (local.ty != null) self.checkArrayDecayInitializer(kind, initializer, expr) else false;
                const pointer_conversion_checked = if (local.ty) |ty| self.checkPointerViewInitializer(ty, expr, ctx) else false;
                const c_void_conversion_checked = if (local.ty) |ty| self.checkCVoidPointerConversion(ty, expr, ctx) else false;
                const address_checked = if (local.ty) |ty| self.checkAddressOfInitializer(kind, ty, expr, ctx) else false;
                const enum_checked = if (local.ty) |ty| self.checkExpectedEnumValue(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                if (local.ty != null and !literal_checked and !null_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !enum_checked and !canInitialize(kind, initializer)) {
                    self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion");
                }
            }
        } else {
            self.errorCode(local.names[0].span, "E_LOCAL_REQUIRES_INITIALIZER", "ordinary local variables must be initialized; use '= uninit' for explicit uninitialized storage");
        }
        if (ctx.scope) |scope| {
            for (local.names) |name| scope.put(name.text, .{ .class = kind, .mutable = mutable, .ty = local.ty, .origin = .local, .address_origin = address_origin }) catch {};
        }
    }

    fn checkAssignmentTarget(self: *Checker, target: ast.Expr, ctx: Context) void {
        switch (target.kind) {
            .ident => |ident| {
                const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
                if (binding) |entry| {
                    if (!entry.mutable) {
                        self.errorCode(target.span, "E_ASSIGN_TO_IMMUTABLE_LOCAL", "cannot assign to immutable local binding");
                    }
                }
            },
            .deref => |inner| {
                if (constStorageBase(inner.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_THROUGH_CONST_VIEW", "cannot assign through a const pointer or view");
                }
            },
            .index => |node| {
                if (constStorageBase(node.base.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_THROUGH_CONST_VIEW", "cannot assign through a const pointer or view");
                }
            },
            .grouped => |inner| self.checkAssignmentTarget(inner.*, ctx),
            else => {},
        }
    }

    fn checkAssignmentValue(self: *Checker, target: ast.Expr, value_class: TypeClass, value: ast.Expr, ctx: Context) void {
        const target_ty = assignmentTargetType(target, ctx) orelse return;
        if (isUninitLiteral(value)) {
            self.errorCode(value.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        const target_class = classifyType(target_ty);
        const literal_checked = self.checkIntegerLiteralInitializer(target_class, target_ty, value);
        const null_checked = self.checkNullPointerInitializer(target_class, value);
        const array_decay_checked = self.checkArrayDecayInitializer(target_class, value_class, value);
        const pointer_conversion_checked = self.checkPointerViewInitializer(target_ty, value, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, value, ctx);
        const address_checked = self.checkAddressOfInitializer(target_class, target_ty, value, ctx);
        const enum_checked = self.checkExpectedEnumValue(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        if (!literal_checked and !null_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !enum_checked and !canInitialize(target_class, value_class)) {
            self.errorCode(value.span, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        }
    }

    fn checkExpr(self: *Checker, expr: ast.Expr, ctx: Context) TypeClass {
        return switch (expr.kind) {
            .ident => |ident| if (ctx.scope) |scope|
                if (scope.get(ident.text)) |binding| binding.class else globalClass(ident.text, ctx) orelse .unknown
            else
                globalClass(ident.text, ctx) orelse .unknown,
            .int_literal => .int_literal,
            .void_literal => .void,
            .bool_literal => .bool,
            .null_literal => .null_literal,
            .string_literal, .char_literal, .uninit_literal, .enum_literal => .unknown,
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
                const operand = self.checkExpr(inner.*, ctx);
                if (!isTryOperand(operand)) {
                    self.errorCode(expr.span, "E_TRY_REQUIRES_RESULT_OR_NULLABLE", "postfix '?' requires a Result or nullable operand");
                }
                if (tryPayloadType(inner.*, ctx)) |payload_ty| return classifyType(payload_ty);
                return tryResultType(operand);
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
                if (node.op == .bit_not and isCheckedSigned(inner)) {
                    self.errorCode(expr.span, "E_BITWISE_SIGNED_OPERAND", "bitwise operations are not defined on signed checked integers");
                }
                if (node.op == .bit_not and inner == .bool) {
                    self.errorCode(expr.span, "E_BITWISE_BOOL_OPERAND", "bitwise operations are not defined on bool operands");
                }
                if (node.op == .bit_not and isPointerLike(inner)) {
                    self.errorCode(expr.span, "E_BITWISE_POINTER_OPERAND", "bitwise operations are not defined on pointer operands");
                }
                if (node.op == .bit_not and isForbiddenBitwisePolicy(inner)) {
                    self.errorCode(expr.span, "E_BITWISE_ARITH_DOMAIN_OPERAND", "bitwise operations are not defined on this arithmetic domain");
                }
                if (node.op == .logical_not) {
                    if (!isConditionType(inner)) {
                        self.errorCode(expr.span, "E_BOOL_OPERATOR_OPERAND", "boolean operators are defined only for bool operands");
                    }
                    return .bool;
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
                if (isArithmeticBinary(node.op) or isComparisonBinary(node.op)) {
                    self.checkCheckedIntegerBinaryOperands(expr.span, left, right);
                }
                if (isPointerArithmeticBinary(node.op) and (isSingleObjectPointerLike(left) or isSingleObjectPointerLike(right))) {
                    self.errorCode(expr.span, "E_POINTER_ARITH_SINGLE_OBJECT", "single-object pointers do not support arithmetic");
                }
                if (isBitwiseBinary(node.op) and (isCheckedSigned(left) or isCheckedSigned(right))) {
                    self.errorCode(expr.span, "E_BITWISE_SIGNED_OPERAND", "bitwise operations are not defined on signed checked integers");
                }
                if (isBitwiseBinary(node.op) and (left == .bool or right == .bool)) {
                    self.errorCode(expr.span, "E_BITWISE_BOOL_OPERAND", "bitwise operations are not defined on bool operands");
                }
                if (isBitwiseBinary(node.op) and (isPointerLike(left) or isPointerLike(right))) {
                    self.errorCode(expr.span, "E_BITWISE_POINTER_OPERAND", "bitwise operations are not defined on pointer operands");
                }
                if (isBitwiseBinary(node.op) and (isForbiddenBitwisePolicy(left) or isForbiddenBitwisePolicy(right))) {
                    self.errorCode(expr.span, "E_BITWISE_ARITH_DOMAIN_OPERAND", "bitwise operations are not defined on this arithmetic domain");
                }
                if (isLogicalBinary(node.op)) {
                    if (!isConditionType(left) or !isConditionType(right)) {
                        self.errorCode(expr.span, "E_BOOL_OPERATOR_OPERAND", "boolean operators are defined only for bool operands");
                    }
                    return .bool;
                }
                if (isComparisonBinary(node.op)) return .bool;
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
                if (isUnsafeOperationCall(node.callee.*) and !ctx.in_unsafe) {
                    self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
                }
                if (isCVoidLayoutCall(node.callee.*, node.type_args)) {
                    self.errorCode(expr.span, "E_C_VOID_NO_LAYOUT", "c_void has no size or alignment in MC");
                }
                if (trap_call) self.checkTrapKind(expr.span, node.args);
                _ = self.checkExpr(node.callee.*, ctx);
                for (node.type_args) |ty| self.checkType(ty, .normal);
                const direct_function = if (!trap_call and node.type_args.len == 0) directCallFunction(node.callee.*, ctx) else null;
                if (direct_function) |function| {
                    if (node.args.len != function.params.len) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match function declaration");
                    }
                }
                for (node.args, 0..) |arg, index| {
                    const source = self.checkExpr(arg, ctx);
                    if (direct_function) |function| {
                        if (index < function.params.len) self.checkCallArgument(function.params[index].ty, arg, source, ctx);
                    }
                }
                if (trap_call) return .never;
                if (directCallReturnClass(node.callee.*, ctx)) |class| return class;
                return .unknown;
            },
            .index => |node| {
                if (ctx.no_lang_trap) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "indexing may trap in #[no_lang_trap]");
                }
                const base_class = self.checkExpr(node.base.*, ctx);
                if (!isIndexableBase(base_class)) {
                    self.errorCode(node.base.span, "E_INDEX_BASE_NOT_ARRAY_OR_SLICE", "indexing is defined only for arrays and slices");
                }
                const index_class = self.checkExpr(node.index.*, ctx);
                if (!isIndexType(index_class)) {
                    self.errorCode(node.index.span, "E_INDEX_NOT_USIZE", "array and slice indices must be checked usize");
                }
                if (indexResultType(node, ctx)) |ty| return classifyType(ty);
                return .unknown;
            },
            .deref => |inner| {
                const inner_class = self.checkExpr(inner.*, ctx);
                if (inner_class == .c_void_pointer) {
                    self.errorCode(expr.span, "E_C_VOID_DEREF", "c_void pointer cannot be dereferenced");
                }
                if (isOpaqueAddressClass(inner_class)) {
                    self.errorCode(expr.span, addressDerefDiagnostic(inner_class), addressDerefMessage(inner_class));
                }
                if (derefResultType(inner.*, ctx)) |ty| return classifyType(ty);
                return .unknown;
            },
            .member => |node| {
                const base_class = self.checkExpr(node.base.*, ctx);
                if (base_class == .c_void_pointer) {
                    self.errorCode(expr.span, "E_C_VOID_NO_LAYOUT", "c_void has no fields in MC");
                }
                self.checkKnownStructField(expr.span, node.base.*, node.name.text, ctx);
                if (memberResultFieldType(node, ctx)) |field_ty| return classifyType(field_ty);
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
            .qualified => |node| self.checkType(node.child.*, mode),
            .pointer => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode);
            },
            .raw_many_pointer => |node| {
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

    fn checkIntegerLiteralInitializer(self: *Checker, target: TypeClass, target_ty: ast.TypeExpr, expr: ast.Expr) bool {
        const value = integerLiteralValue(expr) orelse return false;
        if (target == .wrap) {
            const bounds = wrapInnerBounds(target_ty) orelse return false;
            if (value.negative or value.magnitude > bounds.max) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
                return true;
            }
            return false;
        }
        const bounds = checkedIntBounds(target) orelse return false;
        if (value.negative) {
            if (!bounds.signed or value.magnitude > bounds.min_abs) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
            }
            return true;
        }
        if (value.magnitude > bounds.max) {
            self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
        }
        return true;
    }

    fn checkNullPointerInitializer(self: *Checker, target: TypeClass, expr: ast.Expr) bool {
        if (!isNullLiteral(expr)) return false;
        if (isNullablePointerLike(target)) return true;
        if (isNonNullPointerLike(target)) {
            self.errorCode(expr.span, "E_NULL_NON_NULL_POINTER", "null cannot initialize a non-null pointer");
            return true;
        }
        return false;
    }

    fn checkArrayDecayInitializer(self: *Checker, target: TypeClass, initializer: TypeClass, expr: ast.Expr) bool {
        if (initializer != .array) return false;
        if (isPointerLike(target)) {
            self.errorCode(expr.span, "E_ARRAY_TO_POINTER_DECAY", "arrays do not implicitly decay to pointers");
            return true;
        }
        return false;
    }

    fn checkAddressOfInitializer(self: *Checker, target: TypeClass, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        if (!isNonNullPointerLike(target)) return false;
        const operand = addressOfOperand(expr) orelse return false;
        const source_ty = addressableStorageType(operand.*, ctx) orelse return true;
        if (!addressOfMatchesPointerTarget(target_ty, source_ty, operand.*, ctx)) {
            self.errorCode(expr.span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer and view conversions must be explicit");
        }
        return true;
    }

    fn checkPointerViewInitializer(self: *Checker, target: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const source = exprResultType(expr, ctx) orelse return false;
        if (implicitPointerViewConversion(target, source)) {
            self.errorCode(expr.span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer and view conversions must be explicit");
            return true;
        }
        return false;
    }

    fn checkReturnValue(self: *Checker, ctx: Context, returned: TypeClass, expr: ast.Expr) void {
        const target_ty = ctx.return_ty orelse return;
        if (isUninitLiteral(expr)) {
            self.errorCode(expr.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        const target = ctx.return_kind;
        const literal_checked = self.checkIntegerLiteralInitializer(target, target_ty, expr);
        const null_checked = self.checkNullPointerInitializer(target, expr);
        const array_decay_checked = self.checkArrayDecayInitializer(target, returned, expr);
        const pointer_conversion_checked = self.checkPointerViewReturn(target_ty, expr, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, expr, ctx);
        const address_checked = self.checkAddressOfInitializer(target, target_ty, expr, ctx);
        const local_escape_checked = self.checkLocalAddressReturn(target, expr, ctx);
        const enum_checked = self.checkExpectedEnumValue(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        if (!literal_checked and !null_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !local_escape_checked and !enum_checked and !canInitialize(target, returned)) {
            self.errorCode(expr.span, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        }
    }

    fn checkPointerViewReturn(self: *Checker, target: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const source = exprResultType(expr, ctx) orelse return false;
        if (implicitPointerViewConversion(target, source)) {
            self.errorCode(expr.span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer and view conversions must be explicit");
            return true;
        }
        return false;
    }

    fn checkCVoidPointerConversion(self: *Checker, target: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const source = exprResultType(expr, ctx) orelse return false;
        if (implicitCVoidPointerConversion(target, source)) {
            self.errorCode(expr.span, "E_C_VOID_CONVERSION", "c_void pointer conversions require an explicit FFI boundary operation");
            return true;
        }
        return false;
    }

    fn checkCallArgument(self: *Checker, target_ty: ast.TypeExpr, arg: ast.Expr, source: TypeClass, ctx: Context) void {
        if (isUninitLiteral(arg)) {
            self.errorCode(arg.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        const target = classifyType(target_ty);
        const literal_checked = self.checkIntegerLiteralInitializer(target, target_ty, arg);
        const null_checked = self.checkNullPointerInitializer(target, arg);
        const array_decay_checked = self.checkArrayDecayInitializer(target, source, arg);
        const pointer_conversion_checked = self.checkPointerViewInitializer(target_ty, arg, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, arg, ctx);
        const address_checked = self.checkAddressOfInitializer(target, target_ty, arg, ctx);
        const enum_checked = self.checkExpectedEnumValue(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        if (!literal_checked and !null_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !enum_checked and !canInitialize(target, source)) {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        }
    }

    fn checkExpectedEnumValue(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const enum_info = enumInfoForType(target_ty, ctx) orelse return false;
        if (enumLiteralName(expr)) |literal| {
            if (!enum_info.cases.contains(literal.text)) {
                self.errorCode(literal.span, "E_UNKNOWN_ENUM_CASE", "enum has no case with this name");
            }
            return true;
        }
        if (exprResultType(expr, ctx)) |source_ty| {
            if (sameTypeSyntax(target_ty, source_ty)) return true;
        }
        self.errorCode(expr.span, code, message);
        return true;
    }

    fn checkLocalAddressReturn(self: *Checker, target: TypeClass, expr: ast.Expr, ctx: Context) bool {
        if (!isNonNullPointerLike(target) and !isNullablePointerLike(target)) return false;
        if (localAddressRoot(expr, ctx) != null) {
            self.errorCode(expr.span, "E_LOCAL_ADDRESS_ESCAPE", "cannot return the address of local storage");
            return true;
        }
        return false;
    }

    fn checkCheckedIntegerBinaryOperands(self: *Checker, span: diagnostics.Span, left: TypeClass, right: TypeClass) void {
        if (!isCheckedInt(left) or !isCheckedInt(right)) return;
        if (left == right) return;
        if ((isCheckedSigned(left) and isCheckedUnsigned(right)) or (isCheckedUnsigned(left) and isCheckedSigned(right))) {
            self.errorCode(span, "E_SIGNED_UNSIGNED_MIX", "signed and unsigned integers do not implicitly mix");
            return;
        }
        self.errorCode(span, "E_NO_IMPLICIT_INTEGER_PROMOTION", "integer arithmetic requires matching types or an explicit conversion");
    }

    fn checkKnownStructField(self: *Checker, span: diagnostics.Span, base: ast.Expr, field_name: []const u8, ctx: Context) void {
        const base_ty = exprResultType(base, ctx) orelse return;
        const struct_name = structTypeName(base_ty) orelse return;
        const structs = ctx.structs orelse return;
        const struct_info = structs.get(struct_name) orelse return;
        if (!struct_info.fields.contains(field_name)) {
            self.errorCode(span, "E_UNKNOWN_STRUCT_FIELD", "struct has no field with this name");
        }
    }

    fn checkIfLetPattern(self: *Checker, pattern: ast.Pattern, value_class: TypeClass) void {
        switch (pattern.kind) {
            .bind => {
                if (!isNullableValue(value_class)) {
                    self.errorCode(pattern.span, "E_IF_LET_OPTIONAL_REQUIRED", "plain if let binding requires a nullable value");
                }
            },
            .tag_bind => |node| {
                if (!isResultNarrowingTag(node.tag.text)) {
                    self.errorCode(node.tag.span, "E_IF_LET_RESULT_TAG", "if let result narrowing supports only ok(...) or err(...)");
                } else if (value_class != .result) {
                    self.errorCode(pattern.span, "E_IF_LET_RESULT_REQUIRED", "if let ok(...) or err(...) requires a Result value");
                }
            },
            .wildcard, .tag, .literal => {
                self.errorCode(pattern.span, "E_IF_LET_NARROW_PATTERN", "if let supports only optional bindings and Result ok(...) or err(...) bindings");
            },
        }
    }

    fn addIfLetBinding(self: *Checker, pattern: ast.Pattern, value: ast.Expr, value_class: TypeClass, scope: *Scope, ctx: Context) void {
        _ = self;
        var binding_ctx = ctx;
        binding_ctx.scope = scope;
        switch (pattern.kind) {
            .bind => |ident| {
                if (!isNullableValue(value_class)) return;
                const narrowed_ty = if (exprResultType(value, binding_ctx)) |ty| nullableInnerType(ty) else null;
                scope.put(ident.text, .{
                    .class = tryResultType(value_class),
                    .mutable = false,
                    .ty = narrowed_ty,
                    .origin = .local,
                }) catch {};
            },
            .tag_bind => |node| {
                if (!isResultNarrowingTag(node.tag.text) or value_class != .result) return;
                const narrowed_ty = if (exprResultType(value, binding_ctx)) |ty| resultPayloadType(ty, node.tag.text) else null;
                scope.put(node.binding.text, .{
                    .class = if (narrowed_ty) |ty| classifyType(ty) else .unknown,
                    .mutable = false,
                    .ty = narrowed_ty,
                    .origin = .local,
                }) catch {};
            },
            .wildcard, .tag, .literal => {},
        }
    }

    fn addForBinding(self: *Checker, loop: ast.Loop, ctx: Context, scope: *Scope) void {
        _ = self;
        const label = loop.label orelse return;
        const iterable = loop.iterable orelse return;
        const element_ty = if (exprResultType(iterable, ctx)) |ty| iterableElementType(ty) else null;
        scope.put(label.text, .{
            .class = if (element_ty) |ty| classifyType(ty) else .unknown,
            .mutable = false,
            .ty = element_ty,
            .origin = .local,
        }) catch {};
    }

    fn checkForBody(self: *Checker, loop: ast.Loop, ctx: Context, scope: *Scope) void {
        const label = loop.label orelse {
            self.checkBlock(loop.body, ctx);
            return;
        };
        const previous = scope.get(label.text);
        self.addForBinding(loop, ctx, scope);
        self.checkBlock(loop.body, ctx);
        if (previous) |entry| {
            scope.put(label.text, entry) catch {};
        } else {
            _ = scope.remove(label.text);
        }
    }

    fn checkSwitch(self: *Checker, node: ast.Switch, ctx: Context) void {
        const subject_class = self.checkExpr(node.subject, ctx);
        const subject_ty = exprResultType(node.subject, ctx);
        for (node.arms) |arm| {
            self.checkSwitchArmPatterns(arm.patterns, subject_class, subject_ty, ctx);
            var arm_scope = Scope.init(self.reporter.allocator);
            defer arm_scope.deinit();
            var arm_ctx = ctx;
            if (ctx.scope) |scope| {
                copyScope(scope, &arm_scope) catch {};
                self.addSwitchArmBindings(arm.patterns, node.subject, subject_class, &arm_scope, ctx);
                arm_ctx.scope = &arm_scope;
            }
            switch (arm.body) {
                .block => |block| self.checkBlock(block, arm_ctx),
                .expr => |expr| _ = self.checkExpr(expr, arm_ctx),
            }
        }
    }

    fn checkSwitchArmPatterns(self: *Checker, patterns: []const ast.Pattern, subject_class: TypeClass, subject_ty: ?ast.TypeExpr, ctx: Context) void {
        var binding_pattern_count: usize = 0;
        const subject_enum = if (subject_ty) |ty| enumInfoForType(ty, ctx) else null;
        for (patterns) |pattern| {
            switch (pattern.kind) {
                .tag => |tag| {
                    if (subject_enum) |enum_info| {
                        if (!enum_info.cases.contains(tag.text)) {
                            self.errorCode(tag.span, "E_UNKNOWN_ENUM_CASE", "enum has no case with this name");
                        }
                    }
                },
                .tag_bind => |node| {
                    binding_pattern_count += 1;
                    if (!isResultNarrowingTag(node.tag.text)) {
                        self.errorCode(node.tag.span, "E_SWITCH_RESULT_TAG", "switch result binding supports only ok(...) or err(...)");
                    } else if (subject_class != .result) {
                        self.errorCode(pattern.span, "E_SWITCH_RESULT_REQUIRED", "switch ok(...) or err(...) binding requires a Result value");
                    }
                },
                .wildcard, .literal, .bind => {},
            }
        }
        if (binding_pattern_count > 1) {
            self.errorCode(patterns[0].span, "E_SWITCH_MULTI_BINDING_ARM", "switch arms with multiple patterns cannot introduce bindings");
        }
    }

    fn addSwitchArmBindings(self: *Checker, patterns: []const ast.Pattern, subject: ast.Expr, subject_class: TypeClass, scope: *Scope, ctx: Context) void {
        _ = self;
        if (subject_class != .result) return;
        if (patterns.len != 1) return;
        var binding_ctx = ctx;
        binding_ctx.scope = scope;
        const subject_ty = exprResultType(subject, binding_ctx) orelse return;
        for (patterns) |pattern| {
            switch (pattern.kind) {
                .tag_bind => |node| {
                    if (!isResultNarrowingTag(node.tag.text)) continue;
                    const narrowed_ty = resultPayloadType(subject_ty, node.tag.text) orelse continue;
                    scope.put(node.binding.text, .{
                        .class = classifyType(narrowed_ty),
                        .mutable = false,
                        .ty = narrowed_ty,
                        .origin = .local,
                    }) catch {};
                },
                .wildcard, .tag, .literal, .bind => {},
            }
        }
    }
};

const Context = struct {
    no_lang_trap: bool = false,
    in_unsafe: bool = false,
    returns_never: bool = false,
    returns_void: bool = false,
    return_ty: ?ast.TypeExpr = null,
    return_kind: TypeClass = .void,
    loop_depth: usize = 0,
    unsafe_contracts: UnsafeContracts = .{},
    scope: ?*Scope = null,
    mmio_structs: ?*const std.StringHashMap(MmioStruct) = null,
    mmio_params: ?*const std.StringHashMap([]const u8) = null,
    structs: ?*const std.StringHashMap(StructInfo) = null,
    enums: ?*const std.StringHashMap(EnumInfo) = null,
    functions: ?*const std.StringHashMap(FunctionInfo) = null,
    globals: ?*const std.StringHashMap(GlobalInfo) = null,
};

const MmioStruct = struct {
    fields: std.StringHashMap(void),
};

const StructInfo = struct {
    fields: std.StringHashMap(ast.TypeExpr),
};

const EnumInfo = struct {
    cases: std.StringHashMap(void),
    is_open: bool,
};

const FunctionInfo = struct {
    params: []const ast.Param,
    return_ty: ?ast.TypeExpr,
};

const GlobalInfo = struct {
    ty: ast.TypeExpr,
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

const LocalInfo = struct {
    class: TypeClass,
    mutable: bool,
    ty: ?ast.TypeExpr,
    origin: BindingOrigin,
    address_origin: AddressOrigin = .none,
};

const BindingOrigin = enum {
    param,
    local,
};

const AddressOrigin = enum {
    none,
    local,
};

const Scope = std.StringHashMap(LocalInfo);

fn copyScope(source: *const Scope, dest: *Scope) !void {
    var it = source.iterator();
    while (it.next()) |entry| {
        try dest.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn declName(decl: ast.Decl) ast.Ident {
    return switch (decl.kind) {
        .fn_decl, .extern_fn => |fn_decl| fn_decl.name,
        .type_alias => |alias| alias.name,
        .extern_struct => |struct_decl| struct_decl.name,
        .enum_decl => |enum_decl| enum_decl.name,
        .opaque_decl => |name| name,
        .global_decl => |global| global.name,
    };
}

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
    sat,
    serial,
    counter,
    pointer,
    raw_many_pointer,
    slice,
    array,
    c_void_pointer,
    nullable_pointer,
    nullable_c_void_pointer,
    paddr,
    dma_addr,
    user_ptr,
    mmio_ptr,
    phys_ptr,
    result,
    never,
    void,
    bool,
    null_literal,
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

fn isPointerArithmeticBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub => true,
        else => false,
    };
}

fn isBitwiseBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
        else => false,
    };
}

fn isLogicalBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .logical_and, .logical_or => true,
        else => false,
    };
}

fn isComparisonBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
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

fn isPointerLike(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .raw_many_pointer, .slice, .c_void_pointer, .nullable_pointer, .nullable_c_void_pointer => true,
        else => false,
    };
}

fn isNonNullPointerLike(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .raw_many_pointer, .c_void_pointer => true,
        else => false,
    };
}

fn isSingleObjectPointerLike(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .c_void_pointer => true,
        else => false,
    };
}

fn isNullablePointerLike(kind: TypeClass) bool {
    return switch (kind) {
        .nullable_pointer, .nullable_c_void_pointer => true,
        else => false,
    };
}

fn isForbiddenBitwisePolicy(kind: TypeClass) bool {
    return switch (kind) {
        .sat, .serial, .counter => true,
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
        .pointer => |node| if (isTypeName(node.child.*, "c_void")) .c_void_pointer else .pointer,
        .raw_many_pointer => |node| if (isTypeName(node.child.*, "c_void")) .c_void_pointer else .raw_many_pointer,
        .slice => |node| if (isTypeName(node.child.*, "c_void")) .c_void_pointer else .slice,
        .array => .array,
        .nullable => |child| classifyNullableType(child.*),
        .qualified => |node| classifyType(node.child.*),
        .generic => |node| classifyGenericTypeName(node.base.text),
        else => .unknown,
    };
}

fn classifyNullableType(child: ast.TypeExpr) TypeClass {
    return switch (classifyType(child)) {
        .c_void_pointer => .nullable_c_void_pointer,
        .pointer, .raw_many_pointer => .nullable_pointer,
        else => .unknown,
    };
}

fn nullableInnerType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .nullable => |child| child.*,
        .qualified => |node| nullableInnerType(node.child.*),
        else => null,
    };
}

fn resultPayloadType(ty: ast.TypeExpr, tag: []const u8) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return null;
            if (std.mem.eql(u8, tag, "ok")) return node.args[0];
            if (std.mem.eql(u8, tag, "err")) return node.args[1];
            return null;
        },
        .qualified => |node| resultPayloadType(node.child.*, tag),
        else => null,
    };
}

fn tryPayloadType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprResultType(expr, ctx) orelse return null;
    return nullableInnerType(ty) orelse resultPayloadType(ty, "ok");
}

fn iterableElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .slice => |node| node.child.*,
        .array => |node| node.child.*,
        .qualified => |node| iterableElementType(node.child.*),
        else => null,
    };
}

fn storageElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .pointer => |node| node.child.*,
        .slice => |node| node.child.*,
        .array => |node| node.child.*,
        .qualified => |node| storageElementType(node.child.*),
        else => null,
    };
}

fn structTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| structTypeName(node.child.*),
        else => null,
    };
}

fn enumTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| enumTypeName(node.child.*),
        else => null,
    };
}

fn enumInfoForType(ty: ast.TypeExpr, ctx: Context) ?EnumInfo {
    const name = enumTypeName(ty) orelse return null;
    const enums = ctx.enums orelse return null;
    return enums.get(name);
}

fn closedEnumInfoForType(ty: ast.TypeExpr, ctx: Context) ?EnumInfo {
    const enum_info = enumInfoForType(ty, ctx) orelse return null;
    return if (enum_info.is_open) null else enum_info;
}

fn classifyGenericTypeName(name: []const u8) TypeClass {
    if (std.mem.eql(u8, name, "Result")) return .result;
    if (std.mem.eql(u8, name, "UserPtr")) return .user_ptr;
    if (std.mem.eql(u8, name, "MmioPtr")) return .mmio_ptr;
    if (std.mem.eql(u8, name, "PhysPtr")) return .phys_ptr;
    if (std.mem.eql(u8, name, "wrap")) return .wrap;
    if (std.mem.eql(u8, name, "sat")) return .sat;
    if (std.mem.eql(u8, name, "serial")) return .serial;
    if (std.mem.eql(u8, name, "counter")) return .counter;
    return .unknown;
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
    if (std.mem.eql(u8, name, "PAddr")) return .paddr;
    if (std.mem.eql(u8, name, "DmaAddr")) return .dma_addr;
    return .unknown;
}

fn canInitialize(target: TypeClass, initializer: TypeClass) bool {
    if (target == .unknown or initializer == .unknown) return true;
    if (initializer == .never) return true;
    if (target == initializer) return true;
    if (isNullablePointerLike(target) and initializer == .null_literal) return true;
    if (isCheckedInt(target) and initializer == .int_literal) return true;
    return false;
}

const IntBounds = struct {
    signed: bool,
    max: u128,
    min_abs: u128 = 0,
};

fn checkedIntBounds(kind: TypeClass) ?IntBounds {
    return switch (kind) {
        .checked_u8 => .{ .signed = false, .max = maxUnsigned(8) },
        .checked_u16 => .{ .signed = false, .max = maxUnsigned(16) },
        .checked_u32 => .{ .signed = false, .max = maxUnsigned(32) },
        .checked_u64 => .{ .signed = false, .max = maxUnsigned(64) },
        .checked_usize => .{ .signed = false, .max = maxUnsigned(64) },
        .checked_i8 => signedBounds(8),
        .checked_i16 => signedBounds(16),
        .checked_i32 => signedBounds(32),
        .checked_i64 => signedBounds(64),
        .checked_isize => signedBounds(64),
        else => null,
    };
}

fn wrapInnerBounds(ty: ast.TypeExpr) ?IntBounds {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "wrap") or generic.args.len != 1) return null;
    return checkedIntBounds(classifyType(generic.args[0]));
}

fn maxUnsigned(bits: u7) u128 {
    return (@as(u128, 1) << bits) - 1;
}

fn maxSigned(bits: u7) u128 {
    return (@as(u128, 1) << (bits - 1)) - 1;
}

fn signedBounds(bits: u7) IntBounds {
    return .{
        .signed = true,
        .max = maxSigned(bits),
        .min_abs = @as(u128, 1) << (bits - 1),
    };
}

const LiteralValue = struct {
    negative: bool,
    magnitude: u128,
};

fn integerLiteralValue(expr: ast.Expr) ?LiteralValue {
    return switch (expr.kind) {
        .int_literal => |literal| if (parseIntegerLiteral(literal)) |magnitude| .{
            .negative = false,
            .magnitude = magnitude,
        } else null,
        .grouped => |inner| integerLiteralValue(inner.*),
        .unary => |node| {
            if (node.op != .neg) return null;
            const literal = integerLiteralValue(node.expr.*) orelse return null;
            if (literal.negative) return null;
            return .{ .negative = true, .magnitude = literal.magnitude };
        },
        else => null,
    };
}

fn isNullLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .null_literal => true,
        .grouped => |inner| isNullLiteral(inner.*),
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

fn isAddressOfExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .address_of => true,
        .grouped => |inner| isAddressOfExpr(inner.*),
        else => false,
    };
}

fn addressOfOperand(expr: ast.Expr) ?*ast.Expr {
    return switch (expr.kind) {
        .address_of => |inner| inner,
        .grouped => |inner| addressOfOperand(inner.*),
        else => null,
    };
}

fn addressableStorageType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| return entry.ty;
            return globalType(ident.text, ctx);
        },
        .deref => |inner| if (exprStorageType(inner.*, ctx)) |ty| storageElementType(ty) else null,
        .index => |node| if (exprStorageType(node.base.*, ctx)) |ty| storageElementType(ty) else null,
        .member => |node| memberFieldType(node, ctx),
        .grouped => |inner| addressableStorageType(inner.*, ctx),
        else => null,
    };
}

fn addressOfMatchesPointerTarget(target: ast.TypeExpr, source_child: ast.TypeExpr, operand: ast.Expr, ctx: Context) bool {
    return switch (target.kind) {
        .pointer => |node| {
            if (node.mutability == .mut and !addressableStorageIsMutable(operand, ctx)) return false;
            return sameTypeSyntax(node.child.*, source_child);
        },
        .qualified => |node| addressOfMatchesPointerTarget(node.child.*, source_child, operand, ctx),
        else => false,
    };
}

fn addressableStorageIsMutable(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| return entry.mutable;
            const globals = ctx.globals orelse return true;
            if (globals.contains(ident.text)) return true;
            return true;
        },
        .deref => |inner| !constStorageBase(inner.*, ctx),
        .index => |node| !constStorageBase(node.base.*, ctx),
        .member => |node| addressableStorageIsMutable(node.base.*, ctx),
        .grouped => |inner| addressableStorageIsMutable(inner.*, ctx),
        else => false,
    };
}

fn isNullableValue(kind: TypeClass) bool {
    return switch (kind) {
        .nullable_pointer, .nullable_c_void_pointer => true,
        else => false,
    };
}

fn isIndexType(kind: TypeClass) bool {
    return switch (kind) {
        .checked_usize, .int_literal, .never, .unknown => true,
        else => false,
    };
}

fn isIndexableBase(kind: TypeClass) bool {
    return switch (kind) {
        .array, .slice, .never, .unknown => true,
        else => false,
    };
}

fn isForIterableBase(kind: TypeClass) bool {
    return switch (kind) {
        .array, .slice, .never, .unknown => true,
        else => false,
    };
}

fn isConditionType(kind: TypeClass) bool {
    return switch (kind) {
        .bool, .never, .unknown => true,
        else => false,
    };
}

fn isTryOperand(kind: TypeClass) bool {
    return switch (kind) {
        .result, .nullable_pointer, .nullable_c_void_pointer, .never, .unknown => true,
        else => false,
    };
}

fn tryResultType(kind: TypeClass) TypeClass {
    return switch (kind) {
        .nullable_pointer => .pointer,
        .nullable_c_void_pointer => .c_void_pointer,
        .result => .unknown,
        else => kind,
    };
}

fn isOpaqueAddressClass(kind: TypeClass) bool {
    return switch (kind) {
        .paddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr => true,
        else => false,
    };
}

fn addressDerefDiagnostic(kind: TypeClass) []const u8 {
    return switch (kind) {
        .paddr => "E_PADDR_DEREF",
        .dma_addr => "E_DMA_ADDR_DEREF",
        .user_ptr => "E_USER_PTR_DEREF",
        .mmio_ptr => "E_MMIO_PTR_DEREF",
        .phys_ptr => "E_PHYS_PTR_DEREF",
        else => "E_ADDRESS_CLASS_DEREF",
    };
}

fn addressDerefMessage(kind: TypeClass) []const u8 {
    return switch (kind) {
        .paddr => "cannot dereference PAddr; map it into the current virtual address space first",
        .dma_addr => "cannot dereference DmaAddr; convert through the appropriate DMA mapping API first",
        .user_ptr => "cannot directly dereference UserPtr; use user.load or user.copy_from",
        .mmio_ptr => "cannot directly dereference MmioPtr; use typed MMIO register accessors",
        .phys_ptr => "cannot directly dereference PhysPtr; map it into the current virtual address space first",
        else => "cannot directly dereference opaque address class",
    };
}

fn isResultNarrowingTag(name: []const u8) bool {
    return std.mem.eql(u8, name, "ok") or std.mem.eql(u8, name, "err");
}

fn parseIntegerLiteral(raw: []const u8) ?u128 {
    var cleaned: [128]u8 = undefined;
    if (raw.len > cleaned.len) return null;
    var len: usize = 0;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const ch = raw[index];
        if (ch == '_') {
            if (index + 1 < raw.len and std.ascii.isAlphabetic(raw[index + 1])) break;
            continue;
        }
        cleaned[len] = ch;
        len += 1;
    }
    return std.fmt.parseInt(u128, cleaned[0..len], 0) catch null;
}

fn deinitMmioStructs(mmio_structs: *std.StringHashMap(MmioStruct)) void {
    var structs = mmio_structs.valueIterator();
    while (structs.next()) |mmio_struct| mmio_struct.fields.deinit();
    mmio_structs.deinit();
}

fn deinitStructs(structs: *std.StringHashMap(StructInfo)) void {
    var values = structs.valueIterator();
    while (values.next()) |struct_info| struct_info.fields.deinit();
    structs.deinit();
}

fn deinitEnums(enums: *std.StringHashMap(EnumInfo)) void {
    var values = enums.valueIterator();
    while (values.next()) |enum_info| enum_info.cases.deinit();
    enums.deinit();
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

fn isAssignableTarget(target: ast.Expr) bool {
    return switch (target.kind) {
        .ident => true,
        .deref => |inner| isAssignableTarget(inner.*),
        .index => |node| isAssignableTarget(node.base.*),
        .member => |node| isAssignableTarget(node.base.*),
        .grouped => |inner| isAssignableTarget(inner.*),
        else => false,
    };
}

fn constStorageBase(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.ty) |ty| return isConstStorageType(ty);
                return false;
            }
            if (globalType(ident.text, ctx)) |ty| return isConstStorageType(ty);
            return false;
        },
        .grouped => |inner| constStorageBase(inner.*, ctx),
        else => false,
    };
}

fn exprStorageType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| return entry.ty;
            return globalType(ident.text, ctx);
        },
        .grouped => |inner| exprStorageType(inner.*, ctx),
        else => null,
    };
}

fn globalType(name: []const u8, ctx: Context) ?ast.TypeExpr {
    const globals = ctx.globals orelse return null;
    const global = globals.get(name) orelse return null;
    return global.ty;
}

fn globalClass(name: []const u8, ctx: Context) ?TypeClass {
    const ty = globalType(name, ctx) orelse return null;
    return classifyType(ty);
}

fn exprResultType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |node| if (node.type_args.len == 0) directCallReturnType(node.callee.*, ctx) else null,
        .try_expr => |inner| tryPayloadType(inner.*, ctx),
        .cast => |node| node.ty.*,
        .deref => |inner| derefResultType(inner.*, ctx),
        .index => |node| indexResultType(node, ctx),
        .member => |node| memberResultFieldType(node, ctx),
        .grouped => |inner| exprResultType(inner.*, ctx),
        else => exprStorageType(expr, ctx),
    };
}

fn assignmentTargetType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (!entry.mutable) return null;
                return entry.ty;
            }
            return globalType(ident.text, ctx);
        },
        .deref => |inner| if (exprStorageType(inner.*, ctx)) |ty| storageElementType(ty) else null,
        .index => |node| if (exprStorageType(node.base.*, ctx)) |ty| storageElementType(ty) else null,
        .member => |node| if (isMmioRegisterTarget(expr, ctx)) null else memberFieldType(node, ctx),
        .grouped => |inner| assignmentTargetType(inner.*, ctx),
        else => null,
    };
}

fn derefResultType(base: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprResultType(base, ctx) orelse return null;
    return storageElementType(base_ty);
}

fn indexResultType(index: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprResultType(index.base.*, ctx) orelse return null;
    return storageElementType(base_ty);
}

fn memberFieldType(member: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprStorageType(member.base.*, ctx) orelse return null;
    return structFieldType(base_ty, member.name.text, ctx);
}

fn memberResultFieldType(member: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprResultType(member.base.*, ctx) orelse return null;
    return structFieldType(base_ty, member.name.text, ctx);
}

fn structFieldType(base_ty: ast.TypeExpr, field_name: []const u8, ctx: Context) ?ast.TypeExpr {
    const struct_name = structTypeName(base_ty) orelse return null;
    const structs = ctx.structs orelse return null;
    const struct_info = structs.get(struct_name) orelse return null;
    return struct_info.fields.get(field_name);
}

fn directCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const function = directCallFunction(callee, ctx) orelse return null;
    const return_ty = function.return_ty orelse return .void;
    return classifyType(return_ty);
}

fn directCallReturnType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const function = directCallFunction(callee, ctx) orelse return null;
    return function.return_ty;
}

fn directCallFunction(callee: ast.Expr, ctx: Context) ?FunctionInfo {
    const ident = switch (callee.kind) {
        .ident => |ident| ident,
        .grouped => |inner| return directCallFunction(inner.*, ctx),
        else => return null,
    };
    const functions = ctx.functions orelse return null;
    return functions.get(ident.text);
}

fn updateAssignmentAddressOrigin(target: ast.Expr, value: ast.Expr, ctx: Context) void {
    switch (target.kind) {
        .ident => |ident| {
            const scope = ctx.scope orelse return;
            const entry = scope.getPtr(ident.text) orelse return;
            if (!entry.mutable) return;
            entry.address_origin = addressOrigin(value, ctx);
        },
        .grouped => |inner| updateAssignmentAddressOrigin(inner.*, value, ctx),
        else => {},
    }
}

fn localAddressRoot(expr: ast.Expr, ctx: Context) ?diagnostics.Span {
    return switch (expr.kind) {
        .address_of => |inner| localStorageRoot(inner.*, ctx),
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.address_origin == .local) return expr.span;
            }
            return null;
        },
        .grouped => |inner| localAddressRoot(inner.*, ctx),
        else => null,
    };
}

fn addressOrigin(expr: ast.Expr, ctx: Context) AddressOrigin {
    return switch (expr.kind) {
        .address_of => |inner| if (localStorageRoot(inner.*, ctx) != null) .local else .none,
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| return entry.address_origin;
            return .none;
        },
        .grouped => |inner| addressOrigin(inner.*, ctx),
        else => .none,
    };
}

fn localStorageRoot(expr: ast.Expr, ctx: Context) ?diagnostics.Span {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.origin == .local) return expr.span;
            }
            return null;
        },
        .grouped => |inner| localStorageRoot(inner.*, ctx),
        else => null,
    };
}

fn isConstStorageType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer => |node| node.mutability == .@"const",
        .raw_many_pointer => |node| node.mutability == .@"const",
        .slice => |node| node.mutability == .@"const",
        .nullable => |child| isConstStorageType(child.*),
        .qualified => |node| isConstStorageType(node.child.*),
        else => false,
    };
}

const ViewKind = enum {
    pointer,
    raw_many_pointer,
    slice,
};

const ViewType = struct {
    kind: ViewKind,
    mutability: ast.Mutability,
    nullable: bool = false,
};

fn viewType(ty: ast.TypeExpr) ?ViewType {
    return switch (ty.kind) {
        .pointer => |node| .{ .kind = .pointer, .mutability = node.mutability },
        .raw_many_pointer => |node| .{ .kind = .raw_many_pointer, .mutability = node.mutability },
        .slice => |node| .{ .kind = .slice, .mutability = node.mutability },
        .nullable => |child| {
            var view = viewType(child.*) orelse return null;
            view.nullable = true;
            return view;
        },
        .qualified => |node| viewType(node.child.*),
        else => null,
    };
}

fn implicitPointerViewConversion(target: ast.TypeExpr, source: ast.TypeExpr) bool {
    _ = viewType(target) orelse return false;
    _ = viewType(source) orelse return false;
    const target_is_c_void = isCVoidPointerClass(classifyType(target));
    const source_is_c_void = isCVoidPointerClass(classifyType(source));
    if (target_is_c_void != source_is_c_void) return false;
    return !sameTypeSyntax(target, source);
}

fn implicitCVoidPointerConversion(target: ast.TypeExpr, source: ast.TypeExpr) bool {
    _ = viewType(target) orelse return false;
    _ = viewType(source) orelse return false;
    const target_is_c_void = isCVoidPointerClass(classifyType(target));
    const source_is_c_void = isCVoidPointerClass(classifyType(source));
    return target_is_c_void != source_is_c_void;
}

fn isCVoidPointerClass(kind: TypeClass) bool {
    return switch (kind) {
        .c_void_pointer, .nullable_c_void_pointer => true,
        else => false,
    };
}

fn sameTypeSyntax(left: ast.TypeExpr, right: ast.TypeExpr) bool {
    if (std.meta.activeTag(left.kind) != std.meta.activeTag(right.kind)) return false;
    return switch (left.kind) {
        .name => |left_name| std.mem.eql(u8, left_name.text, switch (right.kind) {
            .name => |right_name| right_name.text,
            else => unreachable,
        }),
        .enum_literal => |left_name| std.mem.eql(u8, left_name.text, switch (right.kind) {
            .enum_literal => |right_name| right_name.text,
            else => unreachable,
        }),
        .member => |left_node| blk: {
            const right_node = switch (right.kind) {
                .member => |node| node,
                else => unreachable,
            };
            break :blk sameTypeSyntax(left_node.base.*, right_node.base.*) and
                std.mem.eql(u8, left_node.field.text, right_node.field.text);
        },
        .nullable => |left_child| sameTypeSyntax(left_child.*, switch (right.kind) {
            .nullable => |right_child| right_child.*,
            else => unreachable,
        }),
        .qualified => |left_node| blk: {
            const right_node = switch (right.kind) {
                .qualified => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .pointer => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .raw_many_pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .raw_many_pointer => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .slice => |left_node| blk: {
            const right_node = switch (right.kind) {
                .slice => |node| node,
                else => unreachable,
            };
            break :blk left_node.mutability == right_node.mutability and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .array => |left_node| blk: {
            const right_node = switch (right.kind) {
                .array => |node| node,
                else => unreachable,
            };
            break :blk sameExprSyntax(left_node.len, right_node.len) and
                sameTypeSyntax(left_node.child.*, right_node.child.*);
        },
        .generic => |left_node| blk: {
            const right_node = switch (right.kind) {
                .generic => |node| node,
                else => unreachable,
            };
            if (!std.mem.eql(u8, left_node.base.text, right_node.base.text)) break :blk false;
            if (left_node.args.len != right_node.args.len) break :blk false;
            for (left_node.args, right_node.args) |left_arg, right_arg| {
                if (!sameTypeSyntax(left_arg, right_arg)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn sameExprSyntax(left: ast.Expr, right: ast.Expr) bool {
    if (std.meta.activeTag(left.kind) != std.meta.activeTag(right.kind)) return false;
    return switch (left.kind) {
        .ident => |left_ident| std.mem.eql(u8, left_ident.text, switch (right.kind) {
            .ident => |right_ident| right_ident.text,
            else => unreachable,
        }),
        .int_literal => |left_text| std.mem.eql(u8, left_text, switch (right.kind) {
            .int_literal => |right_text| right_text,
            else => unreachable,
        }),
        .bool_literal => |left_value| left_value == switch (right.kind) {
            .bool_literal => |right_value| right_value,
            else => unreachable,
        },
        .null_literal, .uninit_literal, .unreachable_expr, .void_literal => true,
        .enum_literal => |left_ident| std.mem.eql(u8, left_ident.text, switch (right.kind) {
            .enum_literal => |right_ident| right_ident.text,
            else => unreachable,
        }),
        .grouped => |left_inner| sameExprSyntax(left_inner.*, switch (right.kind) {
            .grouped => |right_inner| right_inner.*,
            else => unreachable,
        }),
        else => false,
    };
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
        .qualified => |node| typeName(node.child.*),
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

fn isUnsafeOperationCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| {
            if (isIdentNamed(node.base.*, "raw") and std.mem.eql(u8, node.name.text, "store")) return true;
            if (isIdentNamed(node.base.*, "mmio") and std.mem.eql(u8, node.name.text, "map")) return true;
            return false;
        },
        .grouped => |inner| isUnsafeOperationCall(inner.*),
        else => false,
    };
}

fn isCVoidLayoutCall(callee: ast.Expr, type_args: []ast.TypeExpr) bool {
    if (!isIdentNamed(callee, "size_of") and
        !isIdentNamed(callee, "sizeof") and
        !isIdentNamed(callee, "alignof") and
        !isIdentNamed(callee, "field_offset") and
        !isIdentNamed(callee, "field_type") and
        !isIdentNamed(callee, "bit_offset") and
        !isIdentNamed(callee, "repr_of"))
    {
        return false;
    }
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
        .qualified => |node| isTypeName(node.child.*, name),
        else => false,
    };
}

fn enumLiteralName(expr: ast.Expr) ?ast.Ident {
    return switch (expr.kind) {
        .enum_literal => |literal| literal,
        .grouped => |inner| enumLiteralName(inner.*),
        else => null,
    };
}

fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        else => false,
    };
}

fn fallthroughSpan(block: ast.Block, ctx: Context) ?diagnostics.Span {
    if (block.items.len == 0) return block.span;
    const last = block.items[block.items.len - 1];
    return if (stmtMayFallThrough(last, ctx)) last.span else null;
}

fn stmtMayFallThrough(stmt: ast.Stmt, ctx: Context) bool {
    return switch (stmt.kind) {
        .@"return", .@"break", .@"continue", .asm_stmt => false,
        .expr => |expr| exprMayFallThrough(expr, ctx),
        .block, .unsafe_block => |block| fallthroughSpan(block, ctx) != null,
        .contract_block => |contract| fallthroughSpan(contract.block, ctx) != null,
        .if_let => |node| node.else_block == null or
            fallthroughSpan(node.then_block, ctx) != null or
            fallthroughSpan(node.else_block.?, ctx) != null,
        .@"switch" => |node| switchMayFallThrough(node, ctx),
        else => true,
    };
}

fn switchMayFallThrough(node: ast.Switch, ctx: Context) bool {
    var has_wildcard = false;
    var has_result_ok = false;
    var has_result_err = false;
    const subject_is_result = if (exprResultType(node.subject, ctx)) |ty| classifyType(ty) == .result else false;
    const closed_enum = if (exprResultType(node.subject, ctx)) |ty| closedEnumInfoForType(ty, ctx) else null;
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .wildcard => has_wildcard = true,
                .tag, .tag_bind => {
                    const tag = switch (pattern.kind) {
                        .tag => |ident| ident.text,
                        .tag_bind => |tag_bind| tag_bind.tag.text,
                        else => unreachable,
                    };
                    if (subject_is_result and std.mem.eql(u8, tag, "ok")) has_result_ok = true;
                    if (subject_is_result and std.mem.eql(u8, tag, "err")) has_result_err = true;
                },
                .literal, .bind => {},
            }
        }
        if (switchBodyMayFallThrough(arm.body, ctx)) return true;
    }
    if (closed_enum) |enum_info| {
        return !has_wildcard and !switchCoversAllEnumCases(node, enum_info);
    }
    return !has_wildcard and !(has_result_ok and has_result_err);
}

fn switchCoversAllEnumCases(node: ast.Switch, enum_info: EnumInfo) bool {
    var cases = enum_info.cases.keyIterator();
    while (cases.next()) |case_name| {
        if (!switchCoversEnumCase(node, case_name.*)) return false;
    }
    return true;
}

fn switchCoversEnumCase(node: ast.Switch, case_name: []const u8) bool {
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .tag => |tag| if (std.mem.eql(u8, tag.text, case_name)) return true,
                .wildcard => return true,
                .tag_bind, .literal, .bind => {},
            }
        }
    }
    return false;
}

fn switchBodyMayFallThrough(body: ast.SwitchBody, ctx: Context) bool {
    return switch (body) {
        .block => |block| fallthroughSpan(block, ctx) != null,
        .expr => |expr| exprMayFallThrough(expr, ctx),
    };
}

fn exprMayFallThrough(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .unreachable_expr => false,
        .grouped => |inner| exprMayFallThrough(inner.*, ctx),
        .call => |node| !isTrapCall(node.callee.*),
        .block => |block| fallthroughSpan(block, ctx) != null,
        else => true,
    };
}

fn blockContainsTry(block: ast.Block) bool {
    for (block.items) |stmt| {
        if (stmtContainsTry(stmt)) return true;
    }
    return false;
}

fn stmtContainsTry(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .let_decl, .var_decl => |local| if (local.init) |expr| exprContainsTry(expr) else false,
        .loop => |node| (if (node.iterable) |iterable| exprContainsTry(iterable) else false) or blockContainsTry(node.body),
        .if_let => |node| exprContainsTry(node.value) or blockContainsTry(node.then_block) or
            (if (node.else_block) |else_block| blockContainsTry(else_block) else false),
        .@"switch" => |node| switchContainsTry(node),
        .unsafe_block, .block => |block| blockContainsTry(block),
        .contract_block => |contract| blockContainsTry(contract.block),
        .@"return" => |maybe| if (maybe) |expr| exprContainsTry(expr) else false,
        .@"break", .@"continue" => false,
        .@"defer", .expr, .assert => |expr| exprContainsTry(expr),
        .assignment => |node| exprContainsTry(node.target) or exprContainsTry(node.value),
        .asm_stmt => false,
    };
}

fn switchContainsTry(node: ast.Switch) bool {
    if (exprContainsTry(node.subject)) return true;
    for (node.arms) |arm| {
        const body_contains_try = switch (arm.body) {
            .block => |block| blockContainsTry(block),
            .expr => |expr| exprContainsTry(expr),
        };
        if (body_contains_try) return true;
    }
    return false;
}

fn exprContainsTry(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .try_expr => true,
        .grouped, .address_of, .deref => |inner| exprContainsTry(inner.*),
        .block => |block| blockContainsTry(block),
        .unary => |node| exprContainsTry(node.expr.*),
        .binary => |node| exprContainsTry(node.left.*) or exprContainsTry(node.right.*),
        .cast => |node| exprContainsTry(node.value.*),
        .call => |node| callContainsTry(node),
        .index => |node| exprContainsTry(node.base.*) or exprContainsTry(node.index.*),
        .member => |node| exprContainsTry(node.base.*),
        else => false,
    };
}

fn callContainsTry(node: anytype) bool {
    if (exprContainsTry(node.callee.*)) return true;
    for (node.args) |arg| {
        if (exprContainsTry(arg)) return true;
    }
    return false;
}

fn blockContainsDeferControlFlow(block: ast.Block, ctx: Context) bool {
    for (block.items) |stmt| {
        if (stmtContainsDeferControlFlow(stmt, ctx)) return true;
    }
    return false;
}

fn stmtContainsDeferControlFlow(stmt: ast.Stmt, ctx: Context) bool {
    return switch (stmt.kind) {
        .@"return", .@"break", .@"continue" => true,
        .let_decl, .var_decl => |local| if (local.init) |expr| exprContainsDeferControlFlow(expr, ctx) else false,
        .loop => |node| (if (node.iterable) |iterable| exprContainsDeferControlFlow(iterable, ctx) else false) or
            blockContainsDeferControlFlow(node.body, ctx),
        .if_let => |node| exprContainsDeferControlFlow(node.value, ctx) or
            blockContainsDeferControlFlow(node.then_block, ctx) or
            (if (node.else_block) |else_block| blockContainsDeferControlFlow(else_block, ctx) else false),
        .@"switch" => |node| switchContainsDeferControlFlow(node, ctx),
        .unsafe_block, .block => |block| blockContainsDeferControlFlow(block, ctx),
        .contract_block => |contract| blockContainsDeferControlFlow(contract.block, ctx),
        .@"defer", .expr, .assert => |expr| exprContainsDeferControlFlow(expr, ctx),
        .assignment => |node| exprContainsDeferControlFlow(node.target, ctx) or exprContainsDeferControlFlow(node.value, ctx),
        .asm_stmt => false,
    };
}

fn switchContainsDeferControlFlow(node: ast.Switch, ctx: Context) bool {
    if (exprContainsDeferControlFlow(node.subject, ctx)) return true;
    for (node.arms) |arm| {
        const body_contains_control_flow = switch (arm.body) {
            .block => |block| blockContainsDeferControlFlow(block, ctx),
            .expr => |expr| exprContainsDeferControlFlow(expr, ctx),
        };
        if (body_contains_control_flow) return true;
    }
    return false;
}

fn exprContainsDeferControlFlow(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .try_expr, .unreachable_expr => true,
        .grouped, .address_of, .deref => |inner| exprContainsDeferControlFlow(inner.*, ctx),
        .block => |block| blockContainsDeferControlFlow(block, ctx),
        .unary => |node| exprContainsDeferControlFlow(node.expr.*, ctx),
        .binary => |node| exprContainsDeferControlFlow(node.left.*, ctx) or exprContainsDeferControlFlow(node.right.*, ctx),
        .cast => |node| exprContainsDeferControlFlow(node.value.*, ctx),
        .call => |node| callContainsDeferControlFlow(node, ctx),
        .index => |node| exprContainsDeferControlFlow(node.base.*, ctx) or exprContainsDeferControlFlow(node.index.*, ctx),
        .member => |node| exprContainsDeferControlFlow(node.base.*, ctx),
        else => if (exprResultType(expr, ctx)) |ty| classifyType(ty) == .never else false,
    };
}

fn callContainsDeferControlFlow(node: anytype, ctx: Context) bool {
    if (isTrapCall(node.callee.*)) return true;
    if (exprContainsDeferControlFlow(node.callee.*, ctx)) return true;
    for (node.args) |arg| {
        if (exprContainsDeferControlFlow(arg, ctx)) return true;
    }
    return false;
}
