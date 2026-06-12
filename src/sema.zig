const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");

pub const Checker = struct {
    reporter: *diagnostics.Reporter,
    // Set when building a symbol table runs out of memory. Surfaced as a fatal
    // diagnostic so an incomplete table never silently passes checking.
    oom: bool = false,
    // Registry of `const fn` declarations, populated for the duration of
    // checkModule so comptime folding can evaluate const-fn calls (section 22).
    const_fns: ?*const std.StringHashMap(ast.FnDecl) = null,
    // Folded values of `const NAME: T = …` globals (section 22), so comptime
    // folding can resolve named compile-time constants.
    const_globals: ?*const std.StringHashMap(eval.ComptimeValue) = null,
    // Functions that declare at least one `comptime` parameter (section 22),
    // keyed by name, so call sites can re-check their comptime assertions with
    // the parameters bound to the call's constant arguments.
    comptime_fns: ?*const std.StringHashMap(ast.FnDecl) = null,
    // Type registries for comptime reflection (`sizeof`/`alignof`), set for the
    // duration of checkModule.
    reflect_env: ?*const ReflectEnv = null,
    // Names of `move struct` linear resource types (section 18.1), set for the
    // duration of checkModule so the move/liveness pass (D.7) can classify
    // bindings. Empty for the common case (no move types → the pass is a no-op).
    move_types: ?*const std.StringHashMap(void) = null,
    // A module-level Context used during the move pass to infer a switch subject's Result
    // type, so an arm binding (`ok(p)`) can be recognized as a linear `move` value.
    move_ctx: ?*const Context = null,

    pub fn init(reporter: *diagnostics.Reporter) Checker {
        return .{ .reporter = reporter };
    }

    pub fn checkModule(self: *Checker, module: ast.Module) void {
        var mmio_structs = std.StringHashMap(MmioStruct).init(self.reporter.allocator);
        defer deinitMmioStructs(&mmio_structs);
        var structs = std.StringHashMap(StructInfo).init(self.reporter.allocator);
        defer deinitStructs(&structs);
        var packed_bits = std.StringHashMap(LayoutFieldInfo).init(self.reporter.allocator);
        defer deinitLayoutFieldInfos(&packed_bits);
        var overlay_unions = std.StringHashMap(LayoutFieldInfo).init(self.reporter.allocator);
        defer deinitLayoutFieldInfos(&overlay_unions);
        var tagged_unions = std.StringHashMap(UnionInfo).init(self.reporter.allocator);
        defer deinitTaggedUnions(&tagged_unions);
        var enums = std.StringHashMap(EnumInfo).init(self.reporter.allocator);
        defer deinitEnums(&enums);
        var functions = std.StringHashMap(FunctionInfo).init(self.reporter.allocator);
        defer functions.deinit();
        var globals = std.StringHashMap(GlobalInfo).init(self.reporter.allocator);
        defer globals.deinit();
        var type_aliases = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        defer type_aliases.deinit();
        self.checkTopLevelNames(module);
        self.collectTypeAliases(module, &type_aliases);
        self.checkTypeAliasCycles(module, &type_aliases);
        self.collectMmioStructs(module, &mmio_structs);
        self.collectStructs(module, &structs);
        self.collectPackedBits(module, &packed_bits);
        self.collectOverlayUnions(module, &overlay_unions);
        self.collectTaggedUnions(module, &tagged_unions);
        self.collectEnums(module, &enums);
        self.collectFunctions(module, &functions);
        self.collectGlobals(module, &globals);

        var const_fns = std.StringHashMap(ast.FnDecl).init(self.reporter.allocator);
        defer const_fns.deinit();
        for (module.decls) |decl| {
            const fn_decl = switch (decl.kind) {
                .fn_decl => |node| node,
                else => continue,
            };
            if (fn_decl.is_const and !const_fns.contains(fn_decl.name.text)) {
                const_fns.put(fn_decl.name.text, fn_decl) catch {
                    self.oom = true;
                };
            }
        }
        self.const_fns = &const_fns;
        defer self.const_fns = null;

        var const_globals = std.StringHashMap(eval.ComptimeValue).init(self.reporter.allocator);
        defer const_globals.deinit();
        eval.collectConstGlobals(self.reporter.allocator, module, &const_fns, &const_globals) catch {
            self.oom = true;
        };
        self.const_globals = &const_globals;
        defer self.const_globals = null;

        var comptime_fns = std.StringHashMap(ast.FnDecl).init(self.reporter.allocator);
        defer comptime_fns.deinit();
        for (module.decls) |decl| {
            const fn_decl = switch (decl.kind) {
                .fn_decl => |node| node,
                else => continue,
            };
            if (fn_decl.body == null or comptime_fns.contains(fn_decl.name.text)) continue;
            for (fn_decl.params) |param| {
                if (param.is_comptime) {
                    comptime_fns.put(fn_decl.name.text, fn_decl) catch {
                        self.oom = true;
                    };
                    break;
                }
            }
        }
        self.comptime_fns = &comptime_fns;
        defer self.comptime_fns = null;

        var reflect_env = ReflectEnv{ .structs = &structs, .enums = &enums, .aliases = &type_aliases };
        self.reflect_env = &reflect_env;
        defer self.reflect_env = null;

        var move_types = std.StringHashMap(void).init(self.reporter.allocator);
        defer move_types.deinit();
        for (module.decls) |decl| {
            if (decl.kind == .struct_decl and decl.kind.struct_decl.is_move) {
                move_types.put(decl.kind.struct_decl.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
        self.move_types = &move_types;
        defer self.move_types = null;

        for (module.decls) |decl| self.checkDecl(decl, &mmio_structs, &structs, &packed_bits, &overlay_unions, &tagged_unions, &enums, &functions, &globals, &type_aliases);

        // Linear `move`/liveness pass (section 18.1, annex D.7). No-op unless the
        // module declares `move` types.
        if (move_types.count() > 0) {
            var move_ctx = Context{
                .functions = &functions,
                .globals = &globals,
                .type_aliases = &type_aliases,
                .structs = &structs,
                .enums = &enums,
                .tagged_unions = &tagged_unions,
            };
            self.move_ctx = &move_ctx;
            defer self.move_ctx = null;
            for (module.decls) |decl| {
                if (decl.kind == .fn_decl) self.checkMoveLinearity(decl.kind.fn_decl, &type_aliases);
            }
        }

        if (self.oom) {
            self.errorCode(.{ .offset = 0, .len = 0, .line = 1, .column = 1 }, "E_INTERNAL_OOM", "compiler ran out of memory while building symbol tables; results are incomplete");
        }
    }

    fn collectTypeAliases(self: *Checker, module: ast.Module, type_aliases: *std.StringHashMap(ast.TypeExpr)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .type_alias => |alias| if (!type_aliases.contains(alias.name.text)) type_aliases.put(alias.name.text, alias.ty) catch {
                    self.oom = true;
                },
                .opaque_decl => |name| if (!type_aliases.contains(name.text)) type_aliases.put(name.text, simpleNameType(name.text, name.span)) catch {
                    self.oom = true;
                },
                .fn_decl, .extern_fn, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .global_decl => {},
            }
        }
    }

    fn checkTypeAliasCycles(self: *Checker, module: ast.Module, type_aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        for (module.decls) |decl| {
            const alias = switch (decl.kind) {
                .type_alias => |alias| alias,
                else => continue,
            };
            var visiting = std.StringHashMap(void).init(self.reporter.allocator);
            defer visiting.deinit();
            if (self.typeExprHasAliasCycle(alias.name.text, alias.ty, type_aliases, &visiting)) {
                self.errorCode(alias.name.span, "E_TYPE_ALIAS_CYCLE", "type aliases must not form recursive cycles");
            }
        }
    }

    fn typeExprHasAliasCycle(self: *Checker, root_name: []const u8, ty: ast.TypeExpr, type_aliases: *const std.StringHashMap(ast.TypeExpr), visiting: *std.StringHashMap(void)) bool {
        switch (ty.kind) {
            .name => |name| {
                if (std.mem.eql(u8, name.text, root_name)) return true;
                const target = type_aliases.get(name.text) orelse return false;
                if (visiting.contains(name.text)) return true;
                visiting.put(name.text, {}) catch return false;
                defer _ = visiting.remove(name.text);
                return self.typeExprHasAliasCycle(root_name, target, type_aliases, visiting);
            },
            .member => |node| return self.typeExprHasAliasCycle(root_name, node.base.*, type_aliases, visiting),
            .nullable => |child| return self.typeExprHasAliasCycle(root_name, child.*, type_aliases, visiting),
            .qualified => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .pointer => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .raw_many_pointer => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .slice => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .array => |node| return self.typeExprHasAliasCycle(root_name, node.child.*, type_aliases, visiting),
            .generic => |node| {
                for (node.args) |arg| {
                    if (self.typeExprHasAliasCycle(root_name, arg, type_aliases, visiting)) return true;
                }
                return false;
            },
            .fn_pointer => |node| {
                for (node.params) |param| {
                    if (self.typeExprHasAliasCycle(root_name, param, type_aliases, visiting)) return true;
                }
                return self.typeExprHasAliasCycle(root_name, node.ret.*, type_aliases, visiting);
            },
            .closure_type => |node| {
                for (node.params) |param| {
                    if (self.typeExprHasAliasCycle(root_name, param, type_aliases, visiting)) return true;
                }
                return self.typeExprHasAliasCycle(root_name, node.ret.*, type_aliases, visiting);
            },
            .enum_literal => return false,
        }
    }

    fn collectMmioStructs(self: *Checker, module: ast.Module, mmio_structs: *std.StringHashMap(MmioStruct)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |struct_decl| {
                    if (struct_decl.abi) |abi| {
                        if (std.mem.eql(u8, abi, "mmio")) self.collectMmioStruct(struct_decl, mmio_structs);
                    }
                },
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectMmioStruct(self: *Checker, struct_decl: ast.StructDecl, mmio_structs: *std.StringHashMap(MmioStruct)) void {
        if (mmio_structs.contains(struct_decl.name.text)) return;
        var fields = std.StringHashMap(MmioFieldInfo).init(self.reporter.allocator);
        for (struct_decl.fields) |field| {
            if (mmioFieldInfoFromType(field.ty)) |info| {
                if (!fields.contains(field.name.text)) fields.put(field.name.text, info) catch {
                    self.oom = true;
                };
            }
        }
        mmio_structs.put(struct_decl.name.text, .{ .fields = fields }) catch {
            fields.deinit();
        };
    }

    fn collectStructs(self: *Checker, module: ast.Module, structs: *std.StringHashMap(StructInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |struct_decl| self.collectStruct(struct_decl, structs),
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectStruct(self: *Checker, struct_decl: ast.StructDecl, structs: *std.StringHashMap(StructInfo)) void {
        if (structs.contains(struct_decl.name.text)) return;
        var fields = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        for (struct_decl.fields) |field| {
            if (!fields.contains(field.name.text)) fields.put(field.name.text, field.ty) catch {
                self.oom = true;
            };
        }
        structs.put(struct_decl.name.text, .{ .fields = fields }) catch {
            fields.deinit();
        };
    }

    fn collectPackedBits(self: *Checker, module: ast.Module, packed_bits: *std.StringHashMap(LayoutFieldInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .packed_bits_decl => |packed_bits_decl| self.collectLayoutFields(packed_bits_decl.name.text, packed_bits_decl.fields, packed_bits),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .enum_decl, .union_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectOverlayUnions(self: *Checker, module: ast.Module, overlay_unions: *std.StringHashMap(LayoutFieldInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .overlay_union_decl => |overlay_union_decl| self.collectLayoutFields(overlay_union_decl.name.text, overlay_union_decl.fields, overlay_unions),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectTaggedUnions(self: *Checker, module: ast.Module, tagged_unions: *std.StringHashMap(UnionInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .union_decl => |union_decl| self.collectTaggedUnion(union_decl, tagged_unions),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .enum_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectTaggedUnion(self: *Checker, union_decl: ast.UnionDecl, tagged_unions: *std.StringHashMap(UnionInfo)) void {
        if (tagged_unions.contains(union_decl.name.text)) return;
        var cases = std.StringHashMap(?ast.TypeExpr).init(self.reporter.allocator);
        for (union_decl.cases) |case| {
            if (!cases.contains(case.name.text)) cases.put(case.name.text, case.ty) catch {
                self.oom = true;
            };
        }
        tagged_unions.put(union_decl.name.text, .{ .cases = cases }) catch {
            cases.deinit();
        };
    }

    fn collectLayoutFields(self: *Checker, name: []const u8, fields_in: []const ast.Field, infos: *std.StringHashMap(LayoutFieldInfo)) void {
        if (infos.contains(name)) return;
        var fields = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        for (fields_in) |field| {
            if (!fields.contains(field.name.text)) fields.put(field.name.text, field.ty) catch {
                self.oom = true;
            };
        }
        infos.put(name, .{ .fields = fields }) catch {
            fields.deinit();
        };
    }

    fn collectFunctions(self: *Checker, module: ast.Module, functions: *std.StringHashMap(FunctionInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl, .extern_fn => |fn_decl| {
                    if (!functions.contains(fn_decl.name.text)) functions.put(fn_decl.name.text, .{
                        .params = fn_decl.params,
                        .return_ty = fn_decl.return_type,
                        .no_lang_trap = hasNoLangTrap(decl.attrs),
                        .is_const = fn_decl.is_const,
                    }) catch {
                        self.oom = true;
                    };
                },
                .struct_decl, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectEnums(self: *Checker, module: ast.Module, enums: *std.StringHashMap(EnumInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .enum_decl => |enum_decl| self.collectEnum(enum_decl, enums),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectEnum(self: *Checker, enum_decl: ast.EnumDecl, enums: *std.StringHashMap(EnumInfo)) void {
        if (enums.contains(enum_decl.name.text)) return;
        var cases = std.StringHashMap(void).init(self.reporter.allocator);
        for (enum_decl.cases) |case| {
            if (!cases.contains(case.name.text)) cases.put(case.name.text, {}) catch {
                self.oom = true;
            };
        }
        enums.put(enum_decl.name.text, .{ .cases = cases, .is_open = enum_decl.is_open, .repr = enum_decl.repr }) catch {
            cases.deinit();
        };
    }

    fn collectGlobals(self: *Checker, module: ast.Module, globals: *std.StringHashMap(GlobalInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .global_decl => |global| if (global.ty) |ty| {
                    if (!globals.contains(global.name.text)) globals.put(global.name.text, .{ .ty = ty }) catch {
                        self.oom = true;
                    };
                },
                .fn_decl, .extern_fn, .struct_decl, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl => {},
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
                names.put(name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDecl(self: *Checker, decl: ast.Decl, mmio_structs: *const std.StringHashMap(MmioStruct), structs: *const std.StringHashMap(StructInfo), packed_bits: *const std.StringHashMap(LayoutFieldInfo), overlay_unions: *const std.StringHashMap(LayoutFieldInfo), tagged_unions: *const std.StringHashMap(UnionInfo), enums: *const std.StringHashMap(EnumInfo), functions: *const std.StringHashMap(FunctionInfo), globals: *const std.StringHashMap(GlobalInfo), type_aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        const no_lang_trap = hasNoLangTrap(decl.attrs);
        const type_ctx = Context{ .mmio_structs = mmio_structs, .structs = structs, .packed_bits = packed_bits, .overlay_unions = overlay_unions, .tagged_unions = tagged_unions, .enums = enums, .type_aliases = type_aliases };
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| self.checkFn(fn_decl, no_lang_trap, mmio_structs, structs, packed_bits, overlay_unions, tagged_unions, enums, functions, globals, type_aliases),
            .struct_decl => |struct_decl| {
                var struct_ctx = type_ctx;
                if (struct_decl.abi) |abi| {
                    struct_ctx.allow_mmio_register_type = std.mem.eql(u8, abi, "mmio");
                }
                self.checkStruct(struct_decl, struct_ctx);
            },
            .enum_decl => |enum_decl| self.checkEnum(enum_decl, type_ctx),
            .union_decl => |union_decl| self.checkTaggedUnion(union_decl, type_ctx),
            .packed_bits_decl => |packed_bits_decl| self.checkPackedBits(packed_bits_decl, type_ctx),
            .overlay_union_decl => |overlay_union_decl| self.checkOverlayUnion(overlay_union_decl, type_ctx),
            .type_alias => |alias| self.checkType(alias.ty, .normal, type_ctx),
            .opaque_decl => {},
            .global_decl => |global| {
                const type_error_count = self.reporter.diagnostics.items.len;
                if (global.ty) |ty| {
                    self.checkType(ty, .storage, type_ctx);
                } else {
                    self.errorCode(global.name.span, "E_GLOBAL_REQUIRES_TYPE", "global declarations require an explicit storage type");
                    return;
                }
                const type_valid = self.reporter.diagnostics.items.len == type_error_count;
                if (global.init) |initializer| self.checkGlobalInitializer(global, initializer, type_valid, .{ .structs = structs, .packed_bits = packed_bits, .overlay_unions = overlay_unions, .tagged_unions = tagged_unions, .enums = enums, .functions = functions, .globals = globals, .type_aliases = type_aliases });
            },
        }
    }

    fn checkEnum(self: *Checker, enum_decl: ast.EnumDecl, ctx: Context) void {
        const repr_class = if (enum_decl.repr) |repr| classifyTypeCtx(repr, ctx) else .checked_isize;
        const repr_bounds = checkedIntBounds(repr_class);
        if (enum_decl.repr) |repr| {
            self.checkType(repr, .normal, ctx);
            if (!isCheckedInt(repr_class)) {
                self.errorCode(repr.span, "E_ENUM_REPR_NOT_INTEGER", "enum representation type must be an integer type");
            }
        }

        var cases = std.StringHashMap(void).init(self.reporter.allocator);
        defer cases.deinit();
        var values = std.AutoHashMap(EnumValueKey, void).init(self.reporter.allocator);
        defer values.deinit();

        for (enum_decl.cases) |case| {
            if (cases.contains(case.name.text)) {
                self.errorCode(case.name.span, "E_DUPLICATE_ENUM_CASE", "enum case names must be unique");
            } else {
                cases.put(case.name.text, {}) catch {
                    self.oom = true;
                };
            }
            if (case.value) |value| self.checkEnumCaseValue(value, repr_bounds, &values);
        }
    }

    fn checkEnumCaseValue(self: *Checker, value: ast.Expr, repr_bounds: ?IntBounds, values: *std.AutoHashMap(EnumValueKey, void)) void {
        _ = self.checkExpr(value, .{});
        const literal = integerLiteralValue(value) orelse {
            self.errorCode(value.span, "E_ENUM_CASE_VALUE_NOT_INTEGER", "enum representation values must be integer literals");
            return;
        };
        const key = enumValueKey(literal);
        if (repr_bounds) |bounds| {
            if (!enumValueFits(key, bounds)) {
                self.errorCode(value.span, "E_ENUM_CASE_VALUE_OUT_OF_RANGE", "enum case value is outside the representation type range");
            }
        }
        if (values.contains(key)) {
            self.errorCode(value.span, "E_DUPLICATE_ENUM_VALUE", "enum case representation values must be unique");
        } else {
            values.put(key, {}) catch {
                self.oom = true;
            };
        }
    }

    fn checkStruct(self: *Checker, struct_decl: ast.StructDecl, ctx_in: Context) void {
        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        defer fields.deinit();

        // A generic struct's type parameters are valid type names in its fields.
        var type_params = std.StringHashMap(void).init(self.reporter.allocator);
        defer type_params.deinit();
        for (struct_decl.type_params) |tp| type_params.put(tp.text, {}) catch {
            self.oom = true;
        };
        var ctx = ctx_in;
        if (struct_decl.type_params.len > 0) ctx.type_params = &type_params;

        for (struct_decl.fields) |field| {
            self.checkType(field.ty, .storage, ctx);
            if (fields.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_STRUCT_FIELD", "struct field names must be unique");
            } else {
                fields.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    // ----- Linear `move`/liveness pass (section 18.1, annex D.7) -----
    //
    // Tracks each `move`-typed binding (params + locals) and enforces that it is
    // used linearly: consumed (moved) exactly once. A by-value use moves it; a
    // borrow (`&x`, `x.field`) does not. Using a moved value is E_USE_AFTER_MOVE;
    // a live binding reaching the end of the function is E_RESOURCE_LEAK. Not a
    // borrow checker — there are no lifetimes or aliasing analysis.

    fn isMoveTypeName(self: *Checker, ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        const move_types = self.move_types orelse return false;
        var cur = ty;
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            switch (cur.kind) {
                .name => |n| {
                    if (move_types.contains(n.text)) return true;
                    if (aliases.get(n.text)) |target| {
                        cur = target;
                        continue;
                    }
                    return false;
                },
                .generic => |g| return move_types.contains(g.base.text),
                else => return false,
            }
        }
        return false;
    }

    fn checkMoveLinearity(self: *Checker, fn_decl: ast.FnDecl, aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        const body = fn_decl.body orelse return;
        var state = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
        defer state.deinit();
        for (fn_decl.params) |param| {
            if (self.isMoveTypeName(param.ty, aliases)) {
                state.put(param.name.text, .{ .live = true, .span = param.name.span }) catch {
                    self.oom = true;
                };
            }
        }
        self.moveBlock(body, &state, aliases);
        // Function exit: any still-live (and not deferred-for-consumption) move
        // binding was never consumed — a leak.
        var it = state.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value is never consumed (must be moved, returned, or freed)");
            }
        }
    }

    fn moveBlock(self: *Checker, block: ast.Block, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        for (block.items) |stmt| self.moveStmt(stmt, state, aliases);
    }

    fn moveStmt(self: *Checker, stmt: ast.Stmt, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |decl| {
                if (decl.init) |init_expr| self.moveConsume(init_expr, state, aliases);
                if (decl.ty) |ty| {
                    if (self.isMoveTypeName(ty, aliases) and decl.names.len > 0) {
                        state.put(decl.names[0].text, .{ .live = true, .span = decl.names[0].span }) catch {
                            self.oom = true;
                        };
                    }
                }
            },
            .@"return" => |maybe| if (maybe) |v| self.moveConsume(v, state, aliases),
            .expr => |e| self.moveConsume(e, state, aliases),
            .assignment => |a| {
                self.moveConsume(a.value, state, aliases);
                if (a.target.kind == .ident) {
                    if (state.getPtr(a.target.kind.ident.text)) |slot| slot.live = true;
                }
            },
            // `defer <expr>` runs at scope end: it reserves (does not immediately
            // move) the values it will consume, so they neither leak nor remain
            // movable.
            .@"defer" => |e| self.moveDefer(e, state),
            .assert => |e| self.moveBorrow(e, state),
            .block, .unsafe_block, .comptime_block => |b| self.moveBlock(b, state, aliases),
            .contract_block => |c| self.moveBlock(c.block, state, aliases),
            .loop => |l| {
                if (l.iterable) |iter| self.moveBorrow(iter, state);
                self.moveBlock(l.body, state, aliases);
            },
            .if_let => |n| {
                // The condition/scrutinee is evaluated, so by-value `move` operands in
                // it are consumed (borrow operands `&x` stay borrows inside moveConsume).
                self.moveConsume(n.value, state, aliases);
                self.moveBlock(n.then_block, state, aliases);
                if (n.else_block) |eb| self.moveBlock(eb, state, aliases);
            },
            .@"switch" => |sw| {
                // The subject is evaluated, so by-value `move` operands in it are
                // consumed (a plain `if cond` desugars to a switch on `cond`; borrow
                // operands `&x` and non-move subjects stay no-ops in moveConsume).
                self.moveConsume(sw.subject, state, aliases);
                // Infer the subject's type so a pattern binding (`ok(p)`) that names a `move`
                // value is tracked inside the arm — otherwise use-after-move / a leak through a
                // switch arm goes undetected.
                const subject_ty: ?ast.TypeExpr = if (self.move_ctx) |ctx| exprResultType(sw.subject, ctx.*) else null;
                for (sw.arms) |arm| {
                    var bound_name: ?[]const u8 = null;
                    for (arm.patterns) |pat| {
                        const payload_ty: ?ast.TypeExpr = switch (pat.kind) {
                            .bind => subject_ty, // binds the whole value
                            .tag_bind => |tb| if (subject_ty) |sty| resultPayloadType(sty, tb.tag.text) else null,
                            else => null,
                        };
                        const name: ?ast.Ident = switch (pat.kind) {
                            .bind => |id| id,
                            .tag_bind => |tb| tb.binding,
                            else => null,
                        };
                        if (name) |id| {
                            if (payload_ty) |pty| {
                                if (self.isMoveTypeName(pty, aliases)) {
                                    state.put(id.text, .{ .live = true, .span = id.span }) catch {
                                        self.oom = true;
                                    };
                                    bound_name = id.text;
                                }
                            }
                        }
                    }
                    switch (arm.body) {
                        .block => |b| self.moveBlock(b, state, aliases),
                        .expr => |e| self.moveConsume(e, state, aliases),
                    }
                    // A `move` value bound by this arm must be consumed within it; then it leaves
                    // scope (remove it so a later arm's same-named binding starts fresh).
                    if (bound_name) |bn| {
                        if (state.getPtr(bn)) |slot| {
                            if (slot.live and !slot.deferred) {
                                self.errorCode(slot.span, "E_RESOURCE_LEAK", "linear `move` value bound in a switch arm is never consumed (must be moved, returned, or freed)");
                            }
                        }
                        _ = state.remove(bn);
                    }
                }
            },
            .@"break", .@"continue", .asm_stmt => {},
        }
    }

    // Consume the move bindings used by-value in `expr` (checking liveness).
    fn moveConsume(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        switch (expr.kind) {
            .ident => |id| {
                if (state.getPtr(id.text)) |slot| {
                    if (!slot.live) {
                        self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` value after it was moved");
                    } else if (slot.deferred) {
                        self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be moved");
                    } else {
                        slot.live = false;
                    }
                }
            },
            .grouped => |inner| self.moveConsume(inner.*, state, aliases),
            .try_expr => |inner| self.moveConsume(inner.operand.*, state, aliases),
            .cast => |c| self.moveConsume(c.value.*, state, aliases),
            .address_of => |inner| self.moveBorrow(inner.*, state),
            .member => |m| self.moveBorrow(m.base.*, state),
            .deref => |inner| self.moveBorrow(inner.*, state),
            .index => |ix| {
                self.moveBorrow(ix.base.*, state);
                self.moveConsume(ix.index.*, state, aliases);
            },
            .call => |c| for (c.args) |arg| self.moveConsume(arg, state, aliases),
            .binary => |b| {
                self.moveConsume(b.left.*, state, aliases);
                self.moveConsume(b.right.*, state, aliases);
            },
            .unary => |u| self.moveConsume(u.expr.*, state, aliases),
            .struct_literal => |fields| for (fields) |f| self.moveConsume(f.value, state, aliases),
            .array_literal => |items| for (items) |item| self.moveConsume(item, state, aliases),
            else => {},
        }
    }

    // Borrow: check the move bindings referenced are live, without consuming.
    fn moveBorrow(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot)) void {
        switch (expr.kind) {
            .ident => |id| {
                if (state.getPtr(id.text)) |slot| {
                    if (!slot.live) self.errorCode(expr.span, "E_USE_AFTER_MOVE", "borrow of linear `move` value after it was moved");
                }
            },
            .grouped, .address_of, .deref => |inner| self.moveBorrow(inner.*, state),
            .try_expr => |inner| self.moveBorrow(inner.operand.*, state),
            .member => |m| self.moveBorrow(m.base.*, state),
            .index => |ix| self.moveBorrow(ix.base.*, state),
            .cast => |c| self.moveBorrow(c.value.*, state),
            .call => |c| for (c.args) |arg| self.moveBorrow(arg, state),
            else => {},
        }
    }

    // `defer <expr>`: reserve the move bindings the deferred expr will consume.
    fn moveDefer(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot)) void {
        switch (expr.kind) {
            .ident => |id| {
                if (state.getPtr(id.text)) |slot| {
                    if (!slot.live) {
                        self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer consumes a linear `move` value already moved");
                    } else {
                        slot.deferred = true;
                    }
                }
            },
            .grouped => |inner| self.moveDefer(inner.*, state),
            .call => |c| for (c.args) |arg| self.moveDefer(arg, state),
            .member => |m| self.moveBorrow(m.base.*, state),
            else => {},
        }
    }

    fn checkTaggedUnion(self: *Checker, union_decl: ast.UnionDecl, ctx: Context) void {
        var cases = std.StringHashMap(void).init(self.reporter.allocator);
        defer cases.deinit();

        for (union_decl.cases) |case| {
            if (case.ty) |ty| self.checkType(ty, .storage, ctx);
            if (cases.contains(case.name.text)) {
                self.errorCode(case.name.span, "E_DUPLICATE_UNION_CASE", "safe tagged union case names must be unique");
            } else {
                cases.put(case.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkPackedBits(self: *Checker, packed_bits: ast.PackedBitsDecl, ctx: Context) void {
        self.checkType(packed_bits.repr, .normal, ctx);
        if (!isCheckedInt(classifyTypeCtx(packed_bits.repr, ctx))) {
            self.errorCode(packed_bits.repr.span, "E_PACKED_BITS_REPR_NOT_INTEGER", "packed bits representation type must be an integer type");
        }

        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        defer fields.deinit();
        for (packed_bits.fields) |field| {
            self.checkType(field.ty, .storage, ctx);
            if (!isTypeName(field.ty, "bool")) {
                self.errorCode(field.ty.span, "E_PACKED_BITS_FIELD_NOT_BOOL", "packed bits fields must be bool");
            }
            if (fields.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_PACKED_BITS_FIELD", "packed bits field names must be unique");
            } else {
                fields.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkOverlayUnion(self: *Checker, overlay_union: ast.OverlayUnionDecl, ctx: Context) void {
        var fields = std.StringHashMap(void).init(self.reporter.allocator);
        defer fields.deinit();
        for (overlay_union.fields) |field| {
            self.checkType(field.ty, .storage, ctx);
            if (fields.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_OVERLAY_FIELD", "overlay union field names must be unique");
            } else {
                fields.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkGlobalInitializer(self: *Checker, global: ast.GlobalDecl, initializer: ast.Expr, type_valid: bool, ctx: Context) void {
        const errors_before = self.reporter.diagnostics.items.len;
        const source = self.checkExpr(initializer, ctx);
        const ty = global.ty orelse {
            if (isNullLiteral(initializer)) {
                self.errorCode(initializer.span, "E_NULL_REQUIRES_TARGET", "null requires an explicit nullable pointer target type");
            }
            _ = self.checkTargetlessLiteralInitializer(initializer);
            return;
        };
        const target = classifyTypeCtx(ty, ctx);
        if (isUninitLiteral(initializer)) {
            self.errorCode(initializer.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
            return;
        }
        const literal_checked = self.checkIntegerLiteralInitializer(target, ty, initializer, ctx);
        const null_checked = self.checkNullPointerInitializer(target, initializer);
        const array_literal_checked = self.checkArrayLiteralInitializer(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const struct_literal_checked = self.checkStructLiteralInitializer(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const array_decay_checked = self.checkArrayDecayInitializer(target, source, initializer);
        const pointer_conversion_checked = self.checkPointerViewInitializer(ty, initializer, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(ty, initializer, ctx);
        const address_checked = self.checkAddressOfInitializer(target, ty, initializer, ctx);
        const address_class_checked = checkAddressClassConversion(self, initializer.span, target, source);
        const enum_checked = self.checkEnumValueCompatibility(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion") else false;
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(target, source)) {
            self.errorCode(initializer.span, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        }
        // A `const` global's initializer is a compile-time constant by
        // definition (section 22): accept any expression that folds, including
        // named references to earlier const globals (e.g. `MAX * 2`).
        const folds_const = global.is_const and self.comptimeConstantFolds(initializer);
        if (type_valid and self.reporter.diagnostics.items.len == errors_before and !isStaticGlobalInitializer(initializer, ctx) and !folds_const) {
            self.errorCode(initializer.span, "E_GLOBAL_INITIALIZER_NOT_STATIC", "global initializer must be a compile-time static value for M0 C emission");
        }
    }

    fn comptimeConstantFolds(self: *Checker, expr: ast.Expr) bool {
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var scope = eval.ComptimeScope.init(fba.allocator());
        scope.funcs = self.const_fns;
        scope.globals = self.const_globals;
        return switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => true,
            else => false,
        };
    }

    fn checkFn(self: *Checker, fn_decl: ast.FnDecl, no_lang_trap: bool, mmio_structs: *const std.StringHashMap(MmioStruct), structs: *const std.StringHashMap(StructInfo), packed_bits: *const std.StringHashMap(LayoutFieldInfo), overlay_unions: *const std.StringHashMap(LayoutFieldInfo), tagged_unions: *const std.StringHashMap(UnionInfo), enums: *const std.StringHashMap(EnumInfo), functions: *const std.StringHashMap(FunctionInfo), globals: *const std.StringHashMap(GlobalInfo), type_aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        var scope = Scope.init(self.reporter.allocator);
        defer scope.deinit();
        var mmio_params = std.StringHashMap([]const u8).init(self.reporter.allocator);
        defer mmio_params.deinit();

        // Collect `comptime T: type` type parameters first, so the rest of the
        // signature and body may use them as type names (user-defined generics).
        var type_params = std.StringHashMap(void).init(self.reporter.allocator);
        defer type_params.deinit();
        for (fn_decl.params) |param| {
            if (param.is_comptime and isTypeName(param.ty, "type")) {
                type_params.put(param.name.text, {}) catch {
                    self.oom = true;
                };
            }
        }
        const sig_ctx = Context{ .mmio_structs = mmio_structs, .structs = structs, .packed_bits = packed_bits, .overlay_unions = overlay_unions, .tagged_unions = tagged_unions, .enums = enums, .type_aliases = type_aliases, .type_params = &type_params };

        for (fn_decl.params) |param| {
            self.checkType(param.ty, .storage, sig_ctx);
            if (scope.contains(param.name.text)) {
                self.errorCode(param.name.span, "E_DUPLICATE_PARAMETER", "function parameter names must be unique");
            } else {
                scope.put(param.name.text, .{ .class = classifyTypeCtx(param.ty, sig_ctx), .mutable = false, .ty = param.ty, .origin = .param }) catch {
                    self.oom = true;
                };
                if (mmioPointee(param.ty)) |struct_name| mmio_params.put(param.name.text, struct_name) catch {
                    self.oom = true;
                };
            }
        }
        const return_kind = if (fn_decl.return_type) |ty| classifyTypeCtx(ty, sig_ctx) else TypeClass.void;
        const returns_never = if (fn_decl.return_type) |ty| blk: {
            self.checkType(ty, .return_type, sig_ctx);
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
                .packed_bits = packed_bits,
                .overlay_unions = overlay_unions,
                .tagged_unions = tagged_unions,
                .enums = enums,
                .type_aliases = type_aliases,
                .functions = functions,
                .globals = globals,
                .const_fns = self.const_fns,
                .const_globals = self.const_globals,
                .type_params = &type_params,
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
        self.checkUnhandledResultLocals(block, ctx);
    }

    // Section 22: const-fold the scalar subset of a comptime block. Binds
    // comptime `let`/`var` constants and evaluates `assert(...)` conditions,
    // reporting E_COMPTIME_TRAP when an assertion is provably false or the
    // const evaluation itself traps (divide-by-zero, invalid shift). Statements
    // outside the constant subset are skipped — they are not provably wrong, so
    // they produce no diagnostic here (effect rules are enforced by checkBlock).
    fn foldComptimeBlock(self: *Checker, block: ast.Block, scope: *eval.ComptimeScope) void {
        self.foldComptimeBlockAt(block, scope, null);
    }

    // `report_span`, when set, redirects E_COMPTIME_TRAP to that span — used when
    // re-checking a callee's comptime assertions at a call site (section 22
    // comptime parameters), so the failure points at the call, not the callee.
    fn foldComptimeBlockAt(self: *Checker, block: ast.Block, scope: *eval.ComptimeScope, report_span: ?diagnostics.Span) void {
        for (block.items) |stmt| {
            const span = report_span orelse stmt.span;
            switch (stmt.kind) {
                .let_decl, .var_decl => |local| {
                    if (local.names.len != 1) continue;
                    const init_expr = local.init orelse continue;
                    switch (eval.foldComptimeExpr(scope, init_expr)) {
                        .value => |value| {
                            scope.bind(local.names[0].text, value) catch {};
                            if (local.ty) |lty| if (eval.comptimeTypeBitWidth(lty)) |bits| scope.bindWidth(local.names[0].text, bits);
                        },
                        .trap => self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error"),
                        .unknown => {},
                    }
                },
                .assert => |expr| {
                    switch (eval.foldComptimeExpr(scope, expr)) {
                        .value => |value| {
                            if (value == .boolean and !value.boolean) {
                                self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error");
                            }
                        },
                        .trap => self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error"),
                        .unknown => {},
                    }
                },
                // A comptime block may nest plain/unsafe blocks; recurse so their
                // constants and assertions fold in the same scope.
                .block, .unsafe_block, .comptime_block => |inner| self.foldComptimeBlockAt(inner, scope, report_span),
                else => {},
            }
        }
    }

    // --- Comptime reflection layout model (section 22) ----------------------
    //
    // Folds `sizeof(T)` / `alignof(T)` to a constant ONLY where the result is
    // provably the same as the C-ABI value clang computes for the lowered type:
    // scalars, pointers, fixed arrays, closed enums (by repr), and plain structs
    // whose fields all share one alignment (so there is no order-dependent
    // padding — the field HashMap has no order). Anything else returns null, so
    // the assertion simply does not fold (no false positive/negative).

    // eval.ReflectFn thunk: `self` is passed as the opaque context.
    fn comptimeReflectThunk(ctx: ?*anyopaque, call: ast.Expr) ?i128 {
        const self: *Checker = @ptrCast(@alignCast(ctx orelse return null));
        return self.comptimeReflect(call);
    }

    fn comptimeReflect(self: *Checker, call: ast.Expr) ?i128 {
        const node = switch (call.kind) {
            .call => |n| n,
            else => return null,
        };
        const kind = reflectionKind(node.callee.*) orelse return null;
        const ty = reflectionTypeFromCall(node) orelse return null;
        return switch (kind) {
            .size => self.comptimeSizeOf(ty, 0),
            .alignment => self.comptimeAlignOf(ty, 0),
            else => null, // field/bit offsets need field order; not modeled
        };
    }

    fn comptimeSizeOf(self: *Checker, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (depth > 32) return null;
        switch (ty.kind) {
            .name => |name| {
                if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
                if (self.reflect_env) |env| {
                    if (env.aliases.get(name.text)) |aliased| return self.comptimeSizeOf(aliased, depth + 1);
                    if (env.structs.get(name.text)) |info| return self.comptimeStructSize(info, depth);
                    if (env.enums.get(name.text)) |info| return if (info.repr) |repr| self.comptimeSizeOf(repr, depth + 1) else null;
                }
                return null;
            },
            .pointer, .raw_many_pointer, .slice => return 8,
            .generic => |g| {
                if (isPointerLikeGeneric(g.base.text)) return 8;
                return null;
            },
            .array => |node| {
                const len = parseArrayLen(node.len, self.const_fns, self.const_globals) orelse return null;
                const elem = self.comptimeSizeOf(node.child.*, depth + 1) orelse return null;
                return @as(i128, @intCast(len)) * elem;
            },
            .qualified => |node| return self.comptimeSizeOf(node.child.*, depth + 1),
            else => return null,
        }
    }

    fn comptimeAlignOf(self: *Checker, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (depth > 32) return null;
        switch (ty.kind) {
            .name => |name| {
                if (scalarLayout(name.text)) |layout| return @intCast(layout.alignment);
                if (self.reflect_env) |env| {
                    if (env.aliases.get(name.text)) |aliased| return self.comptimeAlignOf(aliased, depth + 1);
                    if (env.structs.get(name.text)) |info| return self.comptimeStructAlign(info, depth);
                    if (env.enums.get(name.text)) |info| return if (info.repr) |repr| self.comptimeAlignOf(repr, depth + 1) else null;
                }
                return null;
            },
            .pointer, .raw_many_pointer, .slice => return 8,
            .generic => |g| {
                if (isPointerLikeGeneric(g.base.text)) return 8;
                return null;
            },
            .array => |node| return self.comptimeAlignOf(node.child.*, depth + 1),
            .qualified => |node| return self.comptimeAlignOf(node.child.*, depth + 1),
            else => return null,
        }
    }

    // Size of a plain struct, but only when all fields share one alignment (so
    // there is no order-dependent padding) — otherwise null. Tail padding is a
    // no-op in that case (every field size is a multiple of the common align).
    fn comptimeStructSize(self: *Checker, info: StructInfo, depth: usize) ?i128 {
        var total: i128 = 0;
        var common_align: ?i128 = null;
        var it = info.fields.valueIterator();
        while (it.next()) |field_ty| {
            const size = self.comptimeSizeOf(field_ty.*, depth + 1) orelse return null;
            const alignment = self.comptimeAlignOf(field_ty.*, depth + 1) orelse return null;
            if (common_align) |a| {
                if (a != alignment) return null; // mixed alignment: order matters
            } else common_align = alignment;
            if (alignment == 0 or @rem(size, alignment) != 0) return null;
            total += size;
        }
        return total;
    }

    fn comptimeStructAlign(self: *Checker, info: StructInfo, depth: usize) ?i128 {
        var max_align: i128 = 1;
        var it = info.fields.valueIterator();
        while (it.next()) |field_ty| {
            const alignment = self.comptimeAlignOf(field_ty.*, depth + 1) orelse return null;
            if (alignment > max_align) max_align = alignment;
        }
        return max_align;
    }

    // Returns the folded comptime value of `expr`, or null if it is not a
    // compile-time constant (section 22).
    fn comptimeFoldValue(self: *Checker, expr: ast.Expr) ?eval.ComptimeValue {
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var scope = eval.ComptimeScope.init(fba.allocator());
        scope.funcs = self.const_fns;
        scope.globals = self.const_globals;
        return switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => |v| v,
            else => null,
        };
    }

    // Re-check a called function's comptime assertions with its `comptime`
    // parameters bound to the call's constant arguments (section 22). Failures
    // are reported at the call site.
    fn checkComptimeCallAsserts(self: *Checker, fn_decl: ast.FnDecl, args: []const ast.Expr, call_span: diagnostics.Span) void {
        const body = fn_decl.body orelse return;
        if (args.len != fn_decl.params.len) return;
        var arena = std.heap.ArenaAllocator.init(self.reporter.allocator);
        defer arena.deinit();
        var scope = eval.ComptimeScope.init(arena.allocator());
        scope.funcs = self.const_fns;
        scope.globals = self.const_globals;
        for (fn_decl.params, args) |param, arg| {
            if (!param.is_comptime) continue;
            const value = self.comptimeFoldValue(arg) orelse return; // non-const arg already diagnosed
            scope.bind(param.name.text, value) catch return;
        }
        self.foldComptimeCallBody(body, &scope, call_span);
    }

    // Walk a callee body for `comptime { … }` blocks and fold their assertions
    // with `scope` (which carries the bound comptime parameters), reporting at
    // the call site.
    fn foldComptimeCallBody(self: *Checker, block: ast.Block, scope: *eval.ComptimeScope, call_span: diagnostics.Span) void {
        for (block.items) |stmt| {
            switch (stmt.kind) {
                .comptime_block => |inner| self.foldComptimeBlockAt(inner, scope, call_span),
                .block, .unsafe_block => |inner| self.foldComptimeCallBody(inner, scope, call_span),
                else => {},
            }
        }
    }

    fn checkUnhandledResultLocals(self: *Checker, block: ast.Block, ctx: Context) void {
        for (block.items, 0..) |stmt, i| {
            const local = switch (stmt.kind) {
                .let_decl, .var_decl => |local| local,
                else => continue,
            };
            if (local.init == null) continue;
            const local_ty = local.ty orelse exprResultType(local.init.?, ctx);
            const ty = local_ty orelse continue;
            if (classifyTypeCtx(ty, ctx) != .result) continue;
            for (local.names) |name| {
                if (!resultLocalHandledLater(name.text, block.items[i + 1 ..])) {
                    self.errorCode(name.span, "E_UNHANDLED_RESULT", "Result local must be handled or propagated");
                }
            }
        }

        for (block.items, 0..) |stmt, i| {
            const assignment = switch (stmt.kind) {
                .assignment => |assignment| assignment,
                else => continue,
            };
            const target_name = assignmentResultLocalName(assignment.target, ctx) orelse continue;
            const value_ty = exprResultType(assignment.value, ctx) orelse continue;
            if (classifyTypeCtx(value_ty, ctx) != .result) continue;

            if (resultLocalHasPendingValueBefore(target_name.text, block.items[0..i], ctx)) {
                self.errorCode(assignment.target.span, "E_UNHANDLED_RESULT", "Result local must be handled before reassignment");
            }
            if (!resultLocalHandledLater(target_name.text, block.items[i + 1 ..])) {
                self.errorCode(assignment.value.span, "E_UNHANDLED_RESULT", "assigned Result must be handled or propagated");
            }
        }
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
                const pattern_error_count = self.reporter.diagnostics.items.len;
                self.checkIfLetPattern(node.pattern, value_class);
                const pattern_is_valid = self.reporter.diagnostics.items.len == pattern_error_count;
                var then_scope = Scope.init(self.reporter.allocator);
                defer then_scope.deinit();
                var then_ctx = ctx;
                if (ctx.scope) |scope| {
                    copyScope(scope, &then_scope) catch {
                        self.oom = true;
                    };
                    if (pattern_is_valid) self.addIfLetBinding(node.pattern, node.value, value_class, &then_scope, ctx);
                    then_ctx.scope = &then_scope;
                }
                if (pattern_is_valid) self.checkBlock(node.then_block, then_ctx);
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
            .comptime_block => |block| {
                var next = ctx;
                next.in_comptime = true;
                self.checkBlock(block, next);
                // Fold the constant subset of the block: bind comptime `let`
                // constants and evaluate `assert(...)` conditions, reporting
                // E_COMPTIME_TRAP for a provably-false assertion or a const-eval
                // trap (section 22: "Trap during const eval is a compile error").
                // An arena backs the fold scope so comptime array temporaries
                // are reclaimed together when the block is done.
                var arena = std.heap.ArenaAllocator.init(self.reporter.allocator);
                defer arena.deinit();
                var scope = eval.ComptimeScope.init(arena.allocator());
                scope.funcs = self.const_fns;
                scope.globals = self.const_globals;
                scope.reflect = comptimeReflectThunk;
                scope.reflect_ctx = self;
                self.foldComptimeBlock(block, &scope);
            },
            .block => |block| self.checkBlock(block, ctx),
            .asm_stmt => |asm_stmt| {
                if (!ctx.in_unsafe) {
                    self.errorCode(stmt.span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
                }
                if (ctx.in_comptime) {
                    self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                if (asm_stmt.form == .precise and !ctx.unsafe_contracts.has(.precise_asm)) {
                    self.errorCode(stmt.span, "E_PRECISE_ASM_CONTRACT", "precise asm requires #[unsafe_contract(precise_asm)]");
                }
                if (asm_stmt.form == .precise) {
                    // Each output names an assignable local that receives the
                    // result; the contract trusts the declared register/type.
                    for (asm_stmt.outputs) |output| {
                        self.checkType(output.ty, .storage, ctx);
                        const binding = if (ctx.scope) |scope| scope.get(output.name.text) else null;
                        if (binding) |entry| {
                            if (!entry.mutable) {
                                self.errorCode(output.name.span, "E_ASSIGN_TO_IMMUTABLE_LOCAL", "cannot assign to immutable local binding");
                            }
                        } else {
                            self.errorCode(output.name.span, "E_UNKNOWN_IDENTIFIER", "asm output names an unknown local");
                        }
                    }
                    // Each input feeds a value of the declared type into a register.
                    for (asm_stmt.inputs) |input| {
                        self.checkType(input.ty, .storage, ctx);
                        _ = self.checkExpr(input.value, ctx);
                    }
                }
            },
            .contract_block => |contract| {
                var next = ctx;
                next.unsafe_contracts = next.unsafe_contracts.with(contract.attr);
                self.checkBlock(contract.block, next);
            },
            .@"return" => |maybe| {
                if (ctx.in_comptime) {
                    self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot alter runtime control flow");
                }
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
                if (ctx.in_comptime) {
                    self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot alter runtime control flow");
                }
                if (ctx.loop_depth == 0) {
                    self.errorCode(stmt.span, "E_BREAK_OUTSIDE_LOOP", "break is valid only inside a loop");
                }
            },
            .@"continue" => {
                if (ctx.in_comptime) {
                    self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot alter runtime control flow");
                }
                if (ctx.loop_depth == 0) {
                    self.errorCode(stmt.span, "E_CONTINUE_OUTSIDE_LOOP", "continue is valid only inside a loop");
                }
            },
            .@"defer" => |expr| {
                const cleanup = self.checkExpr(expr, ctx);
                if (cleanup == .result) {
                    self.errorCode(expr.span, "E_UNHANDLED_RESULT", "Result defer cleanup must be handled or propagated");
                }
                if (cleanup == .never or exprContainsDeferControlFlow(expr, ctx)) {
                    self.errorCode(stmt.span, "E_DEFER_CONTROL_FLOW", "defer is lexical cleanup and must not alter control flow");
                }
            },
            .expr => |expr| {
                const value = self.checkExpr(expr, ctx);
                if (value == .result) {
                    self.errorCode(expr.span, "E_UNHANDLED_RESULT", "Result expression statements must be handled or propagated");
                }
            },
            .assert => |expr| {
                if (ctx.no_lang_trap) {
                    self.errorCode(stmt.span, "E_NO_LANG_TRAP_EDGE", "assert may emit a language trap in #[no_lang_trap]");
                }
                const condition = self.checkExpr(expr, ctx);
                if (!isConditionType(condition)) {
                    self.errorCode(expr.span, "E_CONDITION_NOT_BOOL", "condition must be bool");
                }
                // Comptime assert folding is handled by foldComptimeBlock once
                // the whole comptime block (and its constant bindings) is known.
            },
            .assignment => |node| {
                if (!isAssignableTarget(node.target)) {
                    self.errorCode(node.target.span, "E_INVALID_ASSIGNMENT_TARGET", "assignment target must be assignable storage");
                }
                if (isMmioRegisterTarget(node.target, ctx)) {
                    if (ctx.in_comptime) {
                        self.errorCode(stmt.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                    } else {
                        self.errorCode(stmt.span, "E_MMIO_DIRECT_ASSIGN", "MMIO registers must be accessed through typed read/write methods");
                    }
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
        var inferred_ty: ?ast.TypeExpr = local.ty;
        if (inferred_ty == null) {
            if (local.init) |expr| inferred_ty = exprResultType(expr, ctx);
        }
        const kind = if (inferred_ty) |ty| classifyTypeCtx(ty, ctx) else TypeClass.unknown;
        var address_origin: AddressOrigin = .none;
        if (local.ty) |ty| self.checkType(ty, .storage, ctx);
        if (local.init) |expr| {
            const initializer = self.checkExpr(expr, ctx);
            address_origin = addressOrigin(expr, ctx);
            if (isUninitLiteral(expr)) {
                if (!mutable or local.ty == null) {
                    self.errorCode(expr.span, "E_UNINIT_REQUIRES_STORAGE", "uninit is valid only for explicit typed mutable storage initialization");
                }
            } else {
                const literal_checked = if (local.ty) |ty| self.checkIntegerLiteralInitializer(kind, ty, expr, ctx) else false;
                const null_checked = if (local.ty != null) self.checkNullPointerInitializer(kind, expr) else false;
                const null_target_checked = if (local.ty == null and isNullLiteral(expr)) blk: {
                    self.errorCode(expr.span, "E_NULL_REQUIRES_TARGET", "null requires an explicit nullable pointer target type");
                    break :blk true;
                } else false;
                const targetless_literal_checked = if (local.ty == null) self.checkTargetlessLiteralInitializer(expr) else false;
                const array_literal_checked = if (local.ty) |ty| self.checkArrayLiteralInitializer(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else blk: {
                    if (isArrayLiteral(expr)) {
                        self.errorCode(expr.span, "E_ARRAY_LITERAL_REQUIRES_TARGET", "array literal requires an explicit array target type");
                        break :blk true;
                    }
                    break :blk false;
                };
                const struct_literal_checked = if (local.ty) |ty| self.checkStructLiteralInitializer(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else blk: {
                    if (isStructLiteral(expr)) {
                        self.errorCode(expr.span, "E_STRUCT_LITERAL_REQUIRES_TARGET", "struct literal requires an explicit struct target type");
                        break :blk true;
                    }
                    break :blk false;
                };
                const packed_bits_literal_checked = if (local.ty) |ty| self.checkPackedBitsLiteralInitializer(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const array_decay_checked = if (local.ty != null) self.checkArrayDecayInitializer(kind, initializer, expr) else false;
                const pointer_conversion_checked = if (local.ty) |ty| self.checkPointerViewInitializer(ty, expr, ctx) else false;
                const c_void_conversion_checked = if (local.ty) |ty| self.checkCVoidPointerConversion(ty, expr, ctx) else false;
                const address_checked = if (local.ty) |ty| self.checkAddressOfInitializer(kind, ty, expr, ctx) else false;
                const address_class_checked = if (local.ty != null) checkAddressClassConversion(self, expr.span, kind, initializer) else false;
                const enum_checked = if (local.ty) |ty| self.checkEnumValueCompatibility(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const union_checked = if (local.ty) |ty| self.checkTaggedUnionConstructorCompatibility(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                if (local.ty == null and untargeted_union_checked) {
                    // The diagnostic was emitted above; constructor calls need an explicit union target.
                } else if (local.ty != null and !literal_checked and !null_checked and !null_target_checked and !targetless_literal_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(kind, initializer)) {
                    self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion");
                }
            }
        } else {
            self.errorCode(local.names[0].span, "E_LOCAL_REQUIRES_INITIALIZER", "ordinary local variables must be initialized; use '= uninit' for explicit uninitialized storage");
        }
        if (ctx.scope) |scope| {
            for (local.names) |name| {
                self.addLocalBinding(scope, name, .{ .class = kind, .mutable = mutable, .ty = inferred_ty, .origin = .local, .address_origin = address_origin });
            }
        }
    }

    fn addLocalBinding(self: *Checker, scope: *Scope, name: ast.Ident, info: LocalInfo) void {
        if (scope.contains(name.text)) {
            self.errorCode(name.span, "E_DUPLICATE_LOCAL", "local bindings must have unique names in the current scope");
            return;
        }
        scope.put(name.text, info) catch {
            self.oom = true;
        };
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
                if (immutableIndexedValueStorageBase(node.base.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_TO_IMMUTABLE_LOCAL", "cannot assign to immutable local binding");
                }
            },
            .member => |node| {
                if (constStorageBase(node.base.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_THROUGH_CONST_VIEW", "cannot assign through a const pointer or view");
                }
                if (!isMmioRegisterTarget(target, ctx) and immutableValueStorageBase(node.base.*, ctx)) {
                    self.errorCode(target.span, "E_ASSIGN_TO_IMMUTABLE_LOCAL", "cannot assign to immutable local binding");
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
        const target_class = classifyTypeCtx(target_ty, ctx);
        const literal_checked = self.checkIntegerLiteralInitializer(target_class, target_ty, value, ctx);
        const null_checked = self.checkNullPointerInitializer(target_class, value);
        const array_literal_checked = self.checkArrayLiteralInitializer(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const struct_literal_checked = self.checkStructLiteralInitializer(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const array_decay_checked = self.checkArrayDecayInitializer(target_class, value_class, value);
        const pointer_conversion_checked = self.checkPointerViewInitializer(target_ty, value, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, value, ctx);
        const address_checked = self.checkAddressOfInitializer(target_class, target_ty, value, ctx);
        const address_class_checked = checkAddressClassConversion(self, value.span, target_class, value_class);
        const enum_checked = self.checkEnumValueCompatibility(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion") else false;
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(target_class, value_class)) {
            self.errorCode(value.span, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        }
    }

    fn checkExpr(self: *Checker, expr: ast.Expr, ctx: Context) TypeClass {
        return switch (expr.kind) {
            .ident => |ident| self.checkIdentExpr(ident, ctx),
            .int_literal => .int_literal,
            .float_literal => .float_literal,
            .void_literal => .void,
            .bool_literal => .bool,
            .null_literal => .null_literal,
            .array_literal => |items| {
                for (items) |item| _ = self.checkExpr(item, ctx);
                return .unknown;
            },
            .struct_literal => |fields| {
                for (fields) |field| _ = self.checkExpr(field.value, ctx);
                return .unknown;
            },
            .string_literal, .char_literal, .uninit_literal, .enum_literal => .unknown,
            .unreachable_expr => {
                if (ctx.no_lang_trap) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "reachable unreachable emits a language trap in #[no_lang_trap]");
                }
                if (ctx.in_comptime) {
                    self.errorCode(expr.span, "E_COMPTIME_TRAP", "trap during const eval is a compile error");
                }
                return .never;
            },
            .grouped, .address_of => |inner| self.checkExpr(inner.*, ctx),
            .try_expr => |inner| {
                if (ctx.no_lang_trap) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "unwrap may emit a language trap in #[no_lang_trap]");
                }
                const operand = self.checkExpr(inner.operand.*, ctx);
                if (!isTryOperand(operand)) {
                    self.errorCode(expr.span, "E_TRY_REQUIRES_RESULT_OR_NULLABLE", "postfix '?' requires a Result or nullable operand");
                }
                if (tryPayloadType(inner.operand.*, ctx)) |payload_ty| return classifyTypeCtx(payload_ty, ctx);
                return tryResultType(operand);
            },
            .block => |block| {
                self.checkBlock(block, ctx);
                return .unknown;
            },
            .unary => |node| {
                const inner = self.checkExpr(node.expr.*, ctx);
                if (ctx.no_lang_trap and node.op == .neg and isCheckedSigned(inner)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "checked unary negation may trap in #[no_lang_trap]");
                }
                if (node.op == .neg and isCheckedUnsigned(inner)) {
                    self.errorCode(expr.span, "E_UNSIGNED_NEGATION", "unsigned checked integers do not support unary '-'");
                }
                if (node.op == .neg) {
                    self.checkUnaryNegOperand(expr.span, inner);
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
                if (node.op == .bit_not and isAddressClass(inner)) {
                    self.errorCode(expr.span, "E_ADDRESS_CLASS_OPERATION", "opaque address classes do not support this operator");
                }
                if (node.op == .bit_not and isForbiddenBitwisePolicy(inner)) {
                    self.errorCode(expr.span, "E_BITWISE_ARITH_DOMAIN_OPERAND", "bitwise operations are not defined on this arithmetic domain");
                }
                if (node.op == .bit_not) {
                    self.checkUnaryBitwiseOperand(expr.span, inner);
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
                const left = self.checkExpr(node.left.*, ctx);
                const right = self.checkExpr(node.right.*, ctx);
                if (ctx.no_lang_trap and isTrapBinary(node.op) and !isNoTrapArithmeticDomainOp(node.op, left, right) and !isNonTrappingFloatOp(node.op, left, right)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "checked operation may trap in #[no_lang_trap]");
                }
                if (isArithmeticBinary(node.op) and arithmeticDomainsImplicitlyMix(left, right)) {
                    self.errorCode(expr.span, "E_ARITH_POLICY_MIX", "arithmetic domains do not implicitly mix");
                }
                if (isArithmeticBinary(node.op)) {
                    self.checkArithmeticOperatorOperands(expr.span, left, right);
                }
                if ((isArithmeticBinary(node.op) or isComparisonBinary(node.op))) {
                    self.checkFloatBinaryOperands(expr.span, left, right);
                }
                if (node.op == .mod and (isFloat(left) or isFloat(right))) {
                    self.errorCode(expr.span, "E_OPERATOR_OPERAND", "remainder is not defined on floating-point operands");
                }
                if ((node.op == .div or node.op == .mod) and (isArithmeticDomain(left) or isArithmeticDomain(right))) {
                    self.errorCode(expr.span, "E_ARITH_DOMAIN_DIVISION", "division and remainder are defined only on checked integers, not arithmetic domains");
                }
                if ((isArithmeticBinary(node.op) or isBitwiseBinary(node.op) or isComparisonBinary(node.op) or isLogicalBinary(node.op)) and (isAddressClass(left) or isAddressClass(right))) {
                    self.errorCode(expr.span, "E_ADDRESS_CLASS_OPERATION", "opaque address classes do not support this operator");
                }
                if (isArithmeticBinary(node.op) or isComparisonBinary(node.op) or
                    node.op == .bit_and or node.op == .bit_or or node.op == .bit_xor)
                {
                    // `& | ^` must width-match their operands like `+ - * /` do; otherwise a
                    // narrow target plus a narrow left operand lets `mergeArithmetic` pick the
                    // narrow type and silently drop the wide operand's high bits. Shifts are
                    // excluded: a shift count is not width-matched to the shifted value.
                    self.checkCheckedIntegerBinaryOperands(expr.span, left, right);
                }
                // `& | ^` (but not the shifts) also adapt a literal operand to the other
                // operand's width, so range-check there too. Shift counts are not width-matched.
                if (isArithmeticBinary(node.op) or isComparisonBinary(node.op) or
                    node.op == .bit_and or node.op == .bit_or or node.op == .bit_xor)
                {
                    self.checkBinaryLiteralOperandRange(node.left.*, left, node.right.*, right);
                }
                if (isComparisonBinary(node.op)) {
                    self.checkPointerComparison(expr.span, node.op, node.left.*, left, node.right.*, right, ctx);
                    self.checkComparisonOperatorOperands(expr.span, node.op, left, right);
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
                if (isBitwiseBinary(node.op)) {
                    self.checkBitwiseOperatorOperands(expr.span, left, right);
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
                self.checkType(node.ty.*, .normal, ctx);
                const target = classifyTypeCtx(node.ty.*, ctx);
                if ((source == .c_void_pointer) != (target == .c_void_pointer)) {
                    self.errorCode(expr.span, "E_C_VOID_CONVERSION", "c_void pointer conversions require an explicit FFI boundary operation");
                }
                self.checkEnumCast(expr.span, node.value.*, source, node.ty.*, target, ctx);
                return target;
            },
            .call => |node| {
                const trap_call = isTrapCall(node.callee.*);
                if (ctx.no_lang_trap and isTrapCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "explicit trap emits a language trap in #[no_lang_trap]");
                }
                if (ctx.in_comptime and trap_call) {
                    self.errorCode(expr.span, "E_COMPTIME_TRAP", "trap during const eval is a compile error");
                }
                if (ctx.no_lang_trap and isUnwrapCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "unwrap may emit a language trap in #[no_lang_trap]");
                }
                if (ctx.no_lang_trap and isTrappingConversionCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "trap_from may emit a range trap in #[no_lang_trap]");
                }
                if (uncheckedRequirement(node.callee.*)) |required| {
                    if (!ctx.unsafe_contracts.has(required)) {
                        self.errorCode(expr.span, "E_UNCHECKED_OUTSIDE_CONTRACT", "unchecked operation requires matching #[unsafe_contract]");
                    }
                }
                if (isUnsafeOperationCall(node.callee.*) and !ctx.in_unsafe) {
                    self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
                }
                if (ctx.in_comptime and isComptimeForbiddenCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                if (ctx.in_comptime and isMmioRegisterAccessCall(node.callee.*, ctx)) {
                    self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                self.checkMmioRegisterAccessCall(expr.span, node.callee.*, node.args, ctx);
                self.checkAtomicCall(expr.span, node.callee.*, node.args, ctx);
                self.checkDmaCall(expr.span, node.callee.*, node.args, ctx);
                self.checkMmioMapCall(expr.span, node, ctx);
                self.checkTypeStaticCall(expr.span, node.callee.*, node.args, ctx);
                self.checkResidueCall(expr.span, node.callee.*, node.args, ctx);
                self.checkReduceCall(expr.span, node, ctx);
                const bitcast_class = self.checkBitcastCall(expr.span, node, ctx);
                const raw_many_offset_class = self.checkRawManyOffsetCall(expr.span, node, ctx);
                const reflection_class = self.checkReflectionCall(expr.span, node, ctx);
                if (reflection_class) |class| return class;
                const const_get_class = self.checkConstGetCall(expr.span, node, ctx);
                if (const_get_class) |class| return class;
                if (trap_call) self.checkTrapKind(expr.span, node.args);
                self.checkCallCallee(node.callee.*, ctx);
                for (node.type_args) |ty| self.checkType(ty, .normal, ctx);
                const direct_function = if (!trap_call and node.type_args.len == 0) directCallFunction(node.callee.*, ctx) else null;
                // Calling a value of function-pointer type (callback, vtable
                // field, local): check the call against the pointer's signature.
                const fnptr_ty: ?ast.TypeExpr = if (!trap_call and direct_function == null) calleeFnPointerType(node.callee.*, ctx) else null;
                if (fnptr_ty) |fpty| {
                    const sig = fpty.kind.fn_pointer;
                    if (node.args.len != sig.params.len) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match function-pointer signature");
                    }
                }
                if (direct_function) |function| {
                    // A `const fn` is evaluable at comptime (section 22); only
                    // non-const (runtime) functions are a forbidden effect.
                    if (ctx.in_comptime and !function.is_const) {
                        self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot call runtime functions");
                    }
                    if (ctx.no_lang_trap and !function.no_lang_trap) {
                        self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "call target is not proven #[no_lang_trap]");
                    }
                    if (node.args.len != function.params.len) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match function declaration");
                    } else {
                        // section 22: a `comptime` value parameter's argument must
                        // be a compile-time constant; a `comptime T: type`
                        // parameter's argument must name a type (user generics).
                        for (function.params, node.args) |param, arg| {
                            if (!param.is_comptime) continue;
                            if (isTypeName(param.ty, "type")) {
                                if (typeArgName(arg)) |tn| {
                                    if (!isKnownTypeName(tn, ctx)) self.errorCode(arg.span, "E_TYPE_ARG_REQUIRED", "type parameter requires a known type argument");
                                } else {
                                    self.errorCode(arg.span, "E_TYPE_ARG_REQUIRED", "type parameter requires a type argument");
                                }
                            } else if (!self.comptimeConstantFolds(arg)) {
                                self.errorCode(arg.span, "E_COMPTIME_ARG_REQUIRED", "comptime parameter requires a compile-time constant argument");
                            }
                        }
                        // Re-check the callee's comptime assertions with its
                        // comptime parameters bound to these constant arguments.
                        if (directCallName(node.callee.*)) |callee_name| {
                            if (self.comptime_fns) |registry| {
                                if (registry.get(callee_name)) |callee| {
                                    self.checkComptimeCallAsserts(callee, node.args, expr.span);
                                }
                            }
                        }
                    }
                }
                for (node.args, 0..) |arg, index| {
                    // A `comptime T: type` argument is a type, not a value — do
                    // not type-check it as an expression.
                    if (direct_function) |function| {
                        if (index < function.params.len and function.params[index].is_comptime and isTypeName(function.params[index].ty, "type")) continue;
                    }
                    const source = self.checkExpr(arg, ctx);
                    if (direct_function) |function| {
                        if (index < function.params.len) self.checkCallArgument(function.params[index].ty, arg, source, ctx);
                    }
                    if (fnptr_ty) |fpty| {
                        const sig = fpty.kind.fn_pointer;
                        if (index < sig.params.len) self.checkCallArgument(sig.params[index], arg, source, ctx);
                    }
                }
                if (trap_call) return .never;
                // `drop(x)` consumes a linear `move` value (or is a no-op for a
                // plain value) and yields void. The move/liveness pass consumes
                // the argument via the ordinary call-argument path.
                if (isDropCall(node.callee.*)) {
                    if (node.args.len != 1) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "drop takes exactly one argument");
                    }
                    return .void;
                }
                if (rawLoadCallReturnType(node)) |ty| return classifyTypeCtx(ty, ctx);
                if (isRawPtrCall(node.callee.*) and node.type_args.len == 1) {
                    const ptr_ty = ast.TypeExpr{ .span = node.type_args[0].span, .kind = .{ .pointer = .{ .mutability = .mut, .child = @constCast(&node.type_args[0]) } } };
                    return classifyTypeCtx(ptr_ty, ctx);
                }
                if (self.checkEnumRawCall(expr.span, node.callee.*, node.args, ctx)) |class| return class;
                if (atomicCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (self.dmaCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (mmioMapCallPayloadType(node)) |_| return .nullable_pointer;
                if (typeStaticCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (residueCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (reduceCallReturnClass(node.callee.*)) |class| return class;
                if (bitcast_class) |class| return class;
                if (raw_many_offset_class) |class| return class;
                if (directCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (fnptr_ty) |fpty| return classifyTypeCtx(fpty.kind.fn_pointer.ret.*, ctx);
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
                if (indexResultType(node, ctx)) |ty| return classifyTypeCtx(ty, ctx);
                return .unknown;
            },
            .deref => |inner| {
                const inner_class = self.checkExpr(inner.*, ctx);
                if (ctx.in_comptime and isRuntimePointerDerefClass(inner_class)) {
                    self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                if (inner_class == .raw_many_pointer and !ctx.in_unsafe) {
                    self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
                }
                if (inner_class == .c_void_pointer) {
                    self.errorCode(expr.span, "E_C_VOID_DEREF", "c_void pointer cannot be dereferenced");
                }
                if (isOpaqueAddressClass(inner_class)) {
                    self.errorCode(expr.span, addressDerefDiagnostic(inner_class), addressDerefMessage(inner_class));
                }
                if (derefResultType(inner.*, ctx)) |ty| return classifyTypeCtx(ty, ctx);
                return .unknown;
            },
            .member => |node| {
                if (isBuiltinNamespaceMember(node)) return .unknown;
                const base_class = self.checkExpr(node.base.*, ctx);
                if (base_class == .c_void_pointer) {
                    self.errorCode(expr.span, "E_C_VOID_NO_LAYOUT", "c_void has no fields in MC");
                }
                self.checkKnownStructField(expr.span, node.base.*, node.name.text, ctx);
                if (memberResultFieldType(node, ctx)) |field_ty| return classifyTypeCtx(field_ty, ctx);
                return .unknown;
            },
        };
    }

    fn checkIdentExpr(self: *Checker, ident: ast.Ident, ctx: Context) TypeClass {
        if (ctx.scope) |scope| {
            if (scope.get(ident.text)) |binding| return binding.class;
        }
        if (globalClass(ident.text, ctx)) |class| return class;
        // A top-level function name used as a value is a function pointer.
        if (ctx.functions) |fns| {
            if (fns.contains(ident.text)) return .fn_pointer;
        }
        self.errorCode(ident.span, "E_UNKNOWN_IDENTIFIER", "unknown identifier");
        return .unknown;
    }

    fn checkCallCallee(self: *Checker, callee: ast.Expr, ctx: Context) void {
        switch (callee.kind) {
            .ident => |ident| {
                if (isBuiltinFunctionName(ident.text)) return;
                if (isKnownTaggedUnionConstructorName(ident.text, ctx)) return;
                if (ctx.functions != null and ctx.functions.?.contains(ident.text)) return;
                if (ctx.scope != null and ctx.scope.?.contains(ident.text)) return;
                self.errorCode(ident.span, "E_UNKNOWN_FUNCTION", "unknown function");
            },
            .member => |node| {
                if (isAtomicOperationMember(node, ctx)) return;
                if (isDmaOperationMember(node, ctx)) return;
                if (isTypeStaticMember(node, ctx)) return;
                if (isBuiltinNamespaceMember(node)) return;
                _ = self.checkExpr(callee, ctx);
            },
            .grouped => |inner| self.checkCallCallee(inner.*, ctx),
            else => _ = self.checkExpr(callee, ctx),
        }
    }

    fn checkType(self: *Checker, ty: ast.TypeExpr, mode: TypeMode, ctx: Context) void {
        switch (ty.kind) {
            .name => |name| {
                if (mode == .ffi_opaque_pointer and std.mem.eql(u8, name.text, "void")) {
                    self.errorCode(name.span, "E_MC_VOID_POINTER_FFI", "use c_void for C opaque object pointers, not MC void");
                } else if (mode != .ffi_opaque_pointer and std.mem.eql(u8, name.text, "c_void")) {
                    self.errorCode(name.span, "E_C_VOID_NO_LAYOUT", "c_void has no size or layout in MC; use pointers to c_void at FFI boundaries");
                } else if (mode == .storage and std.mem.eql(u8, name.text, "void")) {
                    self.errorCode(name.span, "E_VOID_STORAGE", "void is only valid as a function return type or generic marker");
                } else if (mode == .storage and std.mem.eql(u8, name.text, "never")) {
                    self.errorCode(name.span, "E_NEVER_STORAGE", "never is a control-flow type and cannot be used for storage");
                } else if (!isKnownTypeName(name.text, ctx)) {
                    self.errorCode(name.span, "E_UNKNOWN_TYPE", "unknown type name");
                }
            },
            .enum_literal => {},
            .member => |node| self.checkType(node.base.*, .normal, ctx),
            .nullable => |child| self.checkType(child.*, mode, ctx),
            .qualified => |node| self.checkType(node.child.*, mode, ctx),
            .pointer => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode, ctx);
            },
            .raw_many_pointer => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode, ctx);
            },
            .slice => |node| {
                const child_mode: TypeMode = if (isCAbiOpaqueBoundary(node.child.*)) .ffi_opaque_pointer else .normal;
                self.checkType(node.child.*, child_mode, ctx);
            },
            .array => |node| {
                // A length that folds to a comptime constant — literal
                // arithmetic or a `const fn` result (section 22 comptime↔type) —
                // is a valid compile-time array length and need not type-check
                // as a runtime usize expression.
                if (comptimeUsizeValue(node.len, self.const_fns, self.const_globals) == null) {
                    const len_class = self.checkExpr(node.len, .{});
                    if (!isIndexType(len_class)) {
                        self.errorCode(node.len.span, "E_ARRAY_LENGTH_TYPE", "array length must be a compile-time checked usize integer expression");
                    }
                }
                self.checkType(node.child.*, if (mode == .storage) .storage else .normal, ctx);
            },
            .generic => |node| {
                if (!isKnownGenericTypeName(node.base.text)) {
                    self.errorCode(node.base.span, "E_UNKNOWN_TYPE", "unknown generic type name");
                } else if (genericTypeExpectedArgs(node.base.text)) |expected| {
                    if (node.args.len != expected) {
                        self.errorCode(node.base.span, "E_GENERIC_TYPE_ARG_COUNT", "generic type has the wrong number of type arguments");
                    }
                }
                for (node.args) |arg| self.checkType(arg, .normal, ctx);
                self.checkGenericTypeArgs(node, ctx);
                if (isArithmeticDomainTypeName(node.base.text) and node.args.len == 1) {
                    if (!isCheckedUnsigned(classifyTypeCtx(node.args[0], ctx))) {
                        self.errorCode(node.args[0].span, "E_ARITH_DOMAIN_UNSIGNED", "MC-C0 arithmetic domains require an unsigned integer type argument");
                    }
                }
            },
            .fn_pointer => |node| {
                // Parameter and return types must themselves be valid storage
                // types (a function-pointer parameter/return cannot be `void`
                // except as the return position).
                for (node.params) |param| self.checkType(param, .storage, ctx);
                self.checkType(node.ret.*, .normal, ctx);
            },
            .closure_type => |node| {
                // Same validity rule as a function pointer: parameters are storage
                // types, the return is a normal type.
                for (node.params) |param| self.checkType(param, .storage, ctx);
                self.checkType(node.ret.*, .normal, ctx);
            },
        }
    }

    fn checkGenericTypeArgs(self: *Checker, node: anytype, ctx: Context) void {
        if (std.mem.eql(u8, node.base.text, "Reg")) {
            if (node.args.len != 2) return;
            self.checkMmioRegisterPosition(node.base.span, ctx);
            self.checkMmioRegisterWidth(node.args[0]);
            self.checkMmioAccessMode(node.args[1]);
        } else if (std.mem.eql(u8, node.base.text, "RegBits")) {
            if (node.args.len != 3) return;
            self.checkMmioRegisterPosition(node.base.span, ctx);
            self.checkMmioRegisterWidth(node.args[0]);
            if (!isPackedBitsTypeName(node.args[1], ctx)) {
                self.errorCode(node.args[1].span, "E_MMIO_REGBITS_TYPE", "RegBits value type must be a known packed bits type");
            }
            self.checkMmioAccessMode(node.args[2]);
        } else if (std.mem.eql(u8, node.base.text, "DmaBuf")) {
            if (node.args.len != 2) return;
            self.checkStoragePayloadType(node.args[0]);
            self.checkDmaBufMode(node.args[1]);
        } else if (std.mem.eql(u8, node.base.text, "atomic")) {
            if (node.args.len != 1) return;
            self.checkStoragePayloadType(node.args[0]);
        } else if (std.mem.eql(u8, node.base.text, "MmioPtr")) {
            if (node.args.len != 1) return;
            self.checkStoragePayloadType(node.args[0]);
            self.checkMmioPtrTarget(node.args[0], ctx);
        } else if (genericHasStoragePayload(node.base.text)) {
            if (node.args.len == 0) return;
            self.checkStoragePayloadType(node.args[0]);
        }
    }

    fn checkMmioRegisterPosition(self: *Checker, span: diagnostics.Span, ctx: Context) void {
        if (!ctx.allow_mmio_register_type) {
            self.errorCode(span, "E_MMIO_REGISTER_POSITION", "Reg and RegBits types are valid only as extern mmio struct fields");
        }
    }

    fn checkMmioPtrTarget(self: *Checker, ty: ast.TypeExpr, ctx: Context) void {
        const name = typeName(ty) orelse {
            self.errorCode(ty.span, "E_MMIO_PTR_TARGET", "MmioPtr target must be an extern mmio struct type");
            return;
        };
        if (!isKnownTypeName(name, ctx)) return;
        if (!knownMmioStructName(name, ctx)) {
            self.errorCode(ty.span, "E_MMIO_PTR_TARGET", "MmioPtr target must be an extern mmio struct type");
        }
    }

    fn checkStoragePayloadType(self: *Checker, ty: ast.TypeExpr) void {
        switch (ty.kind) {
            .name => |name| {
                if (std.mem.eql(u8, name.text, "void")) {
                    self.errorCode(name.span, "E_VOID_STORAGE", "void is only valid as a function return type or generic marker");
                } else if (std.mem.eql(u8, name.text, "never")) {
                    self.errorCode(name.span, "E_NEVER_STORAGE", "never is a control-flow type and cannot be used for storage");
                }
            },
            .qualified => |node| self.checkStoragePayloadType(node.child.*),
            .array => |node| self.checkStoragePayloadType(node.child.*),
            else => {},
        }
    }

    fn checkDmaBufMode(self: *Checker, ty: ast.TypeExpr) void {
        const mode = switch (ty.kind) {
            .enum_literal => |literal| literal.text,
            else => {
                self.errorCode(ty.span, "E_DMA_BUF_MODE", "DmaBuf mode must be .coherent or .noncoherent");
                return;
            },
        };
        if (!isDmaBufMode(mode)) {
            self.errorCode(ty.span, "E_DMA_BUF_MODE", "DmaBuf mode must be .coherent or .noncoherent");
        }
    }

    fn checkMmioRegisterWidth(self: *Checker, ty: ast.TypeExpr) void {
        if (!isFixedUnsignedMmioWidth(ty)) {
            self.errorCode(ty.span, "E_MMIO_REGISTER_WIDTH", "MMIO register width must be u8, u16, u32, or u64");
        }
    }

    fn checkMmioAccessMode(self: *Checker, ty: ast.TypeExpr) void {
        const mode = switch (ty.kind) {
            .enum_literal => |literal| literal.text,
            else => {
                self.errorCode(ty.span, "E_MMIO_ACCESS_MODE", "MMIO register access mode must be .read, .write, or .read_write");
                return;
            },
        };
        if (!isMmioAccessMode(mode)) {
            self.errorCode(ty.span, "E_MMIO_ACCESS_MODE", "MMIO register access mode must be .read, .write, or .read_write");
        }
    }

    fn checkMmioRegisterAccessCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| {
                self.checkMmioRegisterAccessCall(span, inner.*, args, ctx);
                return;
            },
            else => return,
        };
        if (!std.mem.eql(u8, member.name.text, "read") and !std.mem.eql(u8, member.name.text, "write")) return;
        const info = mmioRegisterMemberInfo(member.base.*, ctx) orelse return;
        if (std.mem.eql(u8, member.name.text, "read")) {
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "MMIO read expects exactly one ordering argument");
                return;
            }
            self.checkMmioReadOrdering(args[0]);
            if (!info.access.allowsRead()) {
                self.errorCode(member.name.span, "E_MMIO_ACCESS_FORBIDDEN", "MMIO register access mode does not allow read");
            }
        }
        if (std.mem.eql(u8, member.name.text, "write")) {
            if (args.len != 2) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "MMIO write expects a value and one ordering argument");
                return;
            }
            self.checkMmioWriteOrdering(args[1]);
            if (!info.access.allowsWrite()) {
                self.errorCode(member.name.span, "E_MMIO_ACCESS_FORBIDDEN", "MMIO register access mode does not allow write");
            }
        }
    }

    fn checkAtomicCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| {
                self.checkAtomicCall(span, inner.*, args, ctx);
                return;
            },
            else => return,
        };

        if (isIdentNamed(member.base.*, "atomic") and std.mem.eql(u8, member.name.text, "init")) {
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "atomic.init expects exactly one initializer argument");
            }
            return;
        }

        const payload_ty = atomicPayloadTypeForValue(member.base.*, ctx) orelse return;
        const payload_class = classifyTypeCtx(payload_ty, ctx);
        if (std.mem.eql(u8, member.name.text, "load")) {
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "atomic load expects exactly one memory ordering argument");
                return;
            }
            self.checkAtomicLoadOrdering(args[0]);
            return;
        }
        if (std.mem.eql(u8, member.name.text, "store")) {
            if (args.len != 2) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "atomic store expects a value and one memory ordering argument");
                return;
            }
            const source = self.checkExpr(args[0], ctx);
            self.checkCallArgument(payload_ty, args[0], source, ctx);
            self.checkAtomicStoreOrdering(args[1]);
            return;
        }
        if (std.mem.eql(u8, member.name.text, "fetch_add") or std.mem.eql(u8, member.name.text, "fetch_sub")) {
            if (args.len != 2) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "atomic fetch_add/fetch_sub expects a value and one memory ordering argument");
                return;
            }
            if (!isCheckedInt(payload_class)) {
                self.errorCode(member.name.span, "E_ATOMIC_OPERATION", "atomic fetch_add/fetch_sub requires an integer payload type");
            }
            const source = self.checkExpr(args[0], ctx);
            self.checkCallArgument(payload_ty, args[0], source, ctx);
            self.checkAtomicReadModifyWriteOrdering(args[1]);
            return;
        }
        self.errorCode(member.name.span, "E_ATOMIC_OPERATION", "unknown atomic operation");
    }

    fn checkAtomicLoadOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = atomicOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic load ordering must be .relaxed, .acquire, or .seq_cst");
            return;
        };
        if (!isAtomicLoadOrdering(ordering)) {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic load ordering must be .relaxed, .acquire, or .seq_cst");
        }
    }

    fn checkAtomicStoreOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = atomicOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic store ordering must be .relaxed, .release, or .seq_cst");
            return;
        };
        if (!isAtomicStoreOrdering(ordering)) {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic store ordering must be .relaxed, .release, or .seq_cst");
        }
    }

    fn checkAtomicReadModifyWriteOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = atomicOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic read-modify-write ordering must be a valid atomic memory order");
            return;
        };
        if (!isAtomicOrdering(ordering)) {
            self.errorCode(expr.span, "E_ATOMIC_ORDERING", "atomic read-modify-write ordering must be a valid atomic memory order");
        }
    }

    fn checkDmaCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| {
                self.checkDmaCall(span, inner.*, args, ctx);
                return;
            },
            else => return,
        };

        if (isIdentNamed(member.base.*, "cache")) {
            if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return;
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "cache DMA operation expects exactly one DmaBuf argument");
                return;
            }
            const info = dmaBufInfoForValue(args[0], ctx) orelse {
                self.errorCode(args[0].span, "E_DMA_OPERATION", "cache DMA operation requires a DmaBuf argument");
                _ = self.checkExpr(args[0], ctx);
                return;
            };
            if (!std.mem.eql(u8, info.mode, "noncoherent")) {
                self.errorCode(args[0].span, "E_DMA_CACHE_MODE", "cache clean/invalidate are required only for noncoherent DmaBuf values");
            }
            return;
        }

        const info = dmaBufInfoForValue(member.base.*, ctx) orelse return;
        if (std.mem.eql(u8, member.name.text, "dma_addr") or std.mem.eql(u8, member.name.text, "as_slice")) {
            if (args.len != 0) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "DmaBuf operation does not take arguments");
            }
            _ = info;
            return;
        }
        self.errorCode(member.name.span, "E_DMA_OPERATION", "unknown DmaBuf operation");
    }

    fn checkTypeStaticCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| {
                self.checkTypeStaticCall(span, inner.*, args, ctx);
                return;
            },
            else => return,
        };
        const class = staticTypeBaseClass(member.base.*, ctx) orelse return;
        const op = member.name.text;

        // Explicit scalar/domain conversions (section 3, section 5).
        if (isConversionName(op)) {
            if (std.mem.eql(u8, op, "from_mod") and class != .wrap) {
                self.errorCode(member.name.span, "E_CONVERSION_OPERATION", "from_mod is defined only on wrap<T> targets");
                return;
            }
            if (isNarrowingConversionName(op) and !isCheckedInt(class)) {
                self.errorCode(member.name.span, "E_CONVERSION_OPERATION", "try_from/trap_from/wrap_from/sat_from are defined only on scalar integer targets");
                return;
            }
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "conversion expects exactly one source argument");
            }
            return;
        }

        // Two-operand domain operations (section 5.4, section 5.5).
        if (class == .serial or class == .counter) {
            const code = if (class == .serial) "E_SERIAL_OPERATION" else "E_COUNTER_OPERATION";
            const known = if (class == .serial) isSerialOperationName(op) else isCounterOperationName(op);
            if (!known) {
                self.errorCode(member.name.span, code, if (class == .serial) "unknown serial number operation" else "unknown free-running counter operation");
                return;
            }
            const expected = domainOperationArgCount(op);
            if (args.len != expected) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "domain operation has the wrong number of arguments");
                return;
            }
            // The first two operands must share the domain type; a third argument
            // (an external interval bound) is checked only for arity.
            for (args[0..@min(@as(usize, 2), args.len)]) |arg| {
                const arg_ty = exprResultType(arg, ctx) orelse exprStorageType(arg, ctx) orelse continue;
                const arg_class = classifyTypeCtx(arg_ty, ctx);
                if (arg_class != .unknown and arg_class != class) {
                    self.errorCode(arg.span, code, "domain operation operands must have the same arithmetic-domain type");
                }
            }
            return;
        }

        // Scalar/wrap/sat targets only define the conversion constructors above.
        self.errorCode(member.name.span, "E_CONVERSION_OPERATION", "unknown type-level operation");
    }

    fn checkResidueCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| {
                self.checkResidueCall(span, inner.*, args, ctx);
                return;
            },
            else => return,
        };
        if (!std.mem.eql(u8, member.name.text, "residue")) return;
        const ty = exprResultType(member.base.*, ctx) orelse exprStorageType(member.base.*, ctx) orelse return;
        const class = classifyTypeCtx(ty, ctx);
        if (!isArithmeticDomain(class)) return;
        if (class != .wrap) {
            self.errorCode(member.name.span, "E_CONVERSION_OPERATION", "residue() is defined only on wrap<T> values");
            return;
        }
        if (args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "residue expects no arguments");
        }
    }

    fn checkReduceCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) void {
        if (!isReduceSumCheckedCallee(call.callee.*)) return;
        // reduce.sum_checked<T>(xs: []const T) -> Result<T, Overflow>
        if (call.type_args.len != 1) {
            self.errorCode(span, "E_REDUCE_REQUIRES_INTEGER", "reduce.sum_checked requires exactly one integer type argument");
            return;
        }
        const t = call.type_args[0];
        const t_name = typeName(t) orelse {
            self.errorCode(t.span, "E_REDUCE_REQUIRES_INTEGER", "reduce.sum_checked is restricted to integer types");
            return;
        };
        if (!isIntegerScalarName(t_name)) {
            self.errorCode(t.span, "E_REDUCE_REQUIRES_INTEGER", "reduce.sum_checked is restricted to integer types");
        }
        if (call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "reduce.sum_checked expects exactly one slice argument");
            return;
        }
        // The argument is type-checked by the enclosing call arm; here we only
        // confirm it is a slice of the element type (§8.2: `xs: []const T`).
        const arg_ty = exprResultType(call.args[0], ctx) orelse exprStorageType(call.args[0], ctx) orelse return;
        const arg_class = classifyTypeCtx(arg_ty, ctx);
        if (arg_class != .slice) {
            self.errorCode(call.args[0].span, "E_REDUCE_ARG_NOT_SLICE", "reduce.sum_checked expects a slice (`[]const T`) of the element type");
        }
    }

    fn checkConstGetCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        const member = constGetMember(call.callee.*) orelse return null;
        if (call.args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "const_get expects no runtime arguments");
        }
        const index = if (call.type_args.len == 1) constGetIndexArg(call.type_args[0]) else null;
        if (call.type_args.len != 1 or index == null) {
            self.errorCode(span, "E_CONST_GET_INDEX", "const_get requires exactly one compile-time usize index");
        }
        const base_class = self.checkExpr(member.base.*, ctx);
        if (base_class != .array and base_class != .unknown and base_class != .never) {
            self.errorCode(member.base.span, "E_CONST_GET_BASE", "const_get is defined only for fixed-length arrays");
        }
        const base_ty = exprResultType(member.base.*, ctx) orelse exprStorageType(member.base.*, ctx) orelse return .unknown;
        const array = fixedArrayType(resolveAliasType(base_ty, ctx), ctx.const_fns, ctx.const_globals) orelse {
            self.errorCode(member.base.span, "E_CONST_GET_BASE", "const_get is defined only for fixed-length arrays");
            return .unknown;
        };
        if (index) |idx| {
            if (idx >= array.len) {
                self.errorCode(call.type_args[0].span, "E_CONST_GET_BOUNDS", "const_get index is out of bounds for the fixed-length array");
            }
        }
        return classifyTypeCtx(array.child, ctx);
    }

    fn dmaCallReturnClass(self: *Checker, callee: ast.Expr, ctx: Context) ?TypeClass {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| return self.dmaCallReturnClass(inner.*, ctx),
            else => return null,
        };
        _ = dmaBufInfoForValue(member.base.*, ctx) orelse return null;
        if (std.mem.eql(u8, member.name.text, "dma_addr")) return .dma_addr;
        if (std.mem.eql(u8, member.name.text, "as_slice")) return .slice;
        return null;
    }

    fn checkMmioMapCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) void {
        if (!isMmioMapCallName(call.callee.*)) return;
        if (call.type_args.len != 1 or call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "mmio.map requires exactly one target type and one physical address argument");
            return;
        }
        self.checkMmioPtrTarget(call.type_args[0], ctx);
        const source_ty = exprResultType(call.args[0], ctx) orelse exprStorageType(call.args[0], ctx) orelse return;
        const source = classifyTypeCtx(source_ty, ctx);
        if (source != .paddr and source != .unknown and source != .never) {
            self.errorCode(call.args[0].span, "E_ADDRESS_CLASS_MISMATCH", "mmio.map requires a PAddr argument");
        }
    }

    fn checkBitcastCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        if (!isBitcastCallName(call.callee.*)) return null;

        const target_ty = if (call.type_args.len == 1) call.type_args[0] else null;
        if (call.type_args.len != 1 or call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "bitcast requires exactly one target type and one value argument");
        }

        const target = if (target_ty) |ty| classifyTypeCtx(ty, ctx) else TypeClass.unknown;
        if (target_ty) |ty| {
            if (!isBitcastLayoutClass(target) or !isBitcastLayoutType(ty, ctx)) {
                self.errorCode(ty.span, "E_BITCAST_TYPE", "bitcast target must have a fixed scalar, pointer, or address-class layout");
            }
        }

        if (call.args.len == 1) {
            const source_ty = exprResultType(call.args[0], ctx) orelse exprStorageType(call.args[0], ctx);
            if (source_ty) |ty| {
                const source = classifyTypeCtx(ty, ctx);
                if (!isBitcastLayoutClass(source) or !isBitcastLayoutType(ty, ctx)) {
                    self.errorCode(call.args[0].span, "E_BITCAST_TYPE", "bitcast source must have a fixed scalar, pointer, or address-class layout");
                }
            } else {
                self.errorCode(call.args[0].span, "E_BITCAST_TYPE", "bitcast source type must be known");
            }
        }

        return target;
    }

    fn checkMmioReadOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = mmioOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_MMIO_ORDERING", "MMIO read ordering must be .relaxed or .acquire");
            return;
        };
        if (!isMmioReadOrdering(ordering)) {
            self.errorCode(expr.span, "E_MMIO_ORDERING", "MMIO read ordering must be .relaxed or .acquire");
        }
    }

    fn checkMmioWriteOrdering(self: *Checker, expr: ast.Expr) void {
        const ordering = mmioOrderingName(expr) orelse {
            self.errorCode(expr.span, "E_MMIO_ORDERING", "MMIO write ordering must be .relaxed or .release");
            return;
        };
        if (!isMmioWriteOrdering(ordering)) {
            self.errorCode(expr.span, "E_MMIO_ORDERING", "MMIO write ordering must be .relaxed or .release");
        }
    }

    fn mmioOrderingName(expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .enum_literal => |literal| literal.text,
            else => null,
        };
    }

    fn atomicOrderingName(expr: ast.Expr) ?[]const u8 {
        return switch (expr.kind) {
            .enum_literal => |literal| literal.text,
            else => null,
        };
    }

    fn isAtomicOrdering(ordering: []const u8) bool {
        return std.mem.eql(u8, ordering, "relaxed") or
            std.mem.eql(u8, ordering, "acquire") or
            std.mem.eql(u8, ordering, "release") or
            std.mem.eql(u8, ordering, "acq_rel") or
            std.mem.eql(u8, ordering, "seq_cst");
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

    fn isMmioReadOrdering(ordering: []const u8) bool {
        return std.mem.eql(u8, ordering, "relaxed") or std.mem.eql(u8, ordering, "acquire");
    }

    fn isMmioWriteOrdering(ordering: []const u8) bool {
        return std.mem.eql(u8, ordering, "relaxed") or std.mem.eql(u8, ordering, "release");
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

    fn checkReflectionCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        const kind = reflectionKind(call.callee.*) orelse return null;
        const target = self.reflectionTarget(span, call) orelse return reflectionReturnClass(kind);
        const reflected_ty = target.ty;
        if (isTypeName(reflected_ty, "c_void")) {
            self.errorCode(span, "E_C_VOID_NO_LAYOUT", "c_void has no size or alignment in MC");
            return reflectionReturnClass(kind);
        }
        self.checkReflectedType(reflected_ty, ctx);

        if (reflectionRequiresField(kind)) {
            if (target.args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "field reflection requires exactly one enum-literal field name");
                return reflectionReturnClass(kind);
            }
            const field = enumLiteralName(target.args[0]) orelse {
                self.errorCode(target.args[0].span, "E_REFLECTION_FIELD_LITERAL", "field reflection requires an enum-literal field name");
                return reflectionReturnClass(kind);
            };
            self.checkReflectedField(reflected_ty, field, ctx);
        } else if (target.args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "type reflection builtin does not take runtime arguments");
        }

        return reflectionReturnClass(kind);
    }

    fn reflectionTarget(self: *Checker, span: diagnostics.Span, call: anytype) ?ReflectionTarget {
        if (call.type_args.len > 0) {
            if (call.type_args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "reflection builtin requires exactly one reflected type");
                return null;
            }
            return .{ .ty = call.type_args[0], .args = call.args };
        }
        if (call.args.len == 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "reflection builtin requires a reflected type");
            return null;
        }
        const ty = reflectionTypeExprFromArg(call.args[0]) orelse {
            self.errorCode(call.args[0].span, "E_REFLECTION_TYPE_ARG", "reflection type argument must be a type name");
            return null;
        };
        return .{ .ty = ty, .args = call.args[1..] };
    }

    fn checkReflectedType(self: *Checker, ty: ast.TypeExpr, ctx: Context) void {
        self.checkReflectedGenericTypeArgs(ty, ctx);
        if (reflectionGenericHasWrongArity(ty)) {
            self.errorCode(ty.span, "E_REFLECTION_GENERIC_ARG_COUNT", "reflection generic type has the wrong number of type arguments");
            return;
        }
        if (isKnownLayoutType(ty, ctx)) return;
        self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "reflection requires a known layout-capable type");
    }

    fn checkReflectedGenericTypeArgs(self: *Checker, ty: ast.TypeExpr, ctx: Context) void {
        switch (ty.kind) {
            .generic => |node| {
                self.checkGenericTypeArgs(node, ctx);
                for (node.args) |arg| self.checkReflectedGenericTypeArgs(arg, ctx);
            },
            .qualified => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .nullable => |child| self.checkReflectedGenericTypeArgs(child.*, ctx),
            .pointer => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .raw_many_pointer => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .slice => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .array => |node| self.checkReflectedGenericTypeArgs(node.child.*, ctx),
            .fn_pointer => |node| {
                for (node.params) |param| self.checkReflectedGenericTypeArgs(param, ctx);
                self.checkReflectedGenericTypeArgs(node.ret.*, ctx);
            },
            .closure_type => |node| {
                for (node.params) |param| self.checkReflectedGenericTypeArgs(param, ctx);
                self.checkReflectedGenericTypeArgs(node.ret.*, ctx);
            },
            .member, .name, .enum_literal => {},
        }
    }

    fn checkReflectedField(self: *Checker, ty: ast.TypeExpr, field: ast.Ident, ctx: Context) void {
        const name = typeName(ty) orelse {
            self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
            return;
        };
        if (layoutFieldInfo(name, ctx)) |info| {
            if (!info.fields.contains(field.text)) {
                self.errorCode(field.span, "E_UNKNOWN_STRUCT_FIELD", "layout type has no field with this name");
            }
        } else {
            self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
        }
    }

    fn checkIntegerLiteralInitializer(self: *Checker, target: TypeClass, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const value = integerLiteralValue(expr) orelse return false;
        if (target == .wrap or target == .sat) {
            const bounds = arithmeticDomainInnerBounds(resolveAliasType(target_ty, ctx), if (target == .wrap) "wrap" else "sat", ctx) orelse return false;
            if (value.negative or value.magnitude > bounds.max) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
                return true;
            }
            return true;
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

    fn checkArrayLiteralInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const items = arrayLiteralItems(expr) orelse return false;
        const resolved_target_ty = resolveAliasType(target_ty, ctx);
        const array = switch (resolved_target_ty.kind) {
            .array => |node| node,
            .qualified => |node| switch (node.child.kind) {
                .array => |array_node| array_node,
                else => {
                    self.errorCode(expr.span, code, message);
                    return true;
                },
            },
            else => {
                self.errorCode(expr.span, code, message);
                return true;
            },
        };
        const expected_len = parseArrayLen(array.len, ctx.const_fns, ctx.const_globals) orelse {
            self.errorCode(array.len.span, "E_ARRAY_LITERAL_LENGTH", "array literal target must have a known constant length");
            return true;
        };
        if (items.len != expected_len) {
            self.errorCode(expr.span, "E_ARRAY_LITERAL_LENGTH", "array literal element count must match the target array length");
        }
        const element_ty = array.child.*;
        const element_class = classifyTypeCtx(element_ty, ctx);
        for (items) |item| {
            const item_class = self.checkExpr(item, ctx);
            const literal_checked = self.checkIntegerLiteralInitializer(element_class, element_ty, item, ctx);
            const null_checked = self.checkNullPointerInitializer(element_class, item);
            const array_literal_checked = self.checkArrayLiteralInitializer(element_ty, item, ctx, code, message);
            const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(element_ty, item, ctx, code, message);
            const pointer_conversion_checked = self.checkPointerViewInitializer(element_ty, item, ctx);
            const c_void_conversion_checked = self.checkCVoidPointerConversion(element_ty, item, ctx);
            const address_checked = self.checkAddressOfInitializer(element_class, element_ty, item, ctx);
            const address_class_checked = checkAddressClassConversion(self, item.span, element_class, item_class);
            const enum_checked = self.checkEnumValueCompatibility(element_ty, item, ctx, code, message);
            const union_checked = self.checkTaggedUnionConstructorCompatibility(element_ty, item, ctx, code, message);
            const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(item, ctx, code, message) else false;
            if (!literal_checked and !null_checked and !array_literal_checked and !packed_bits_literal_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(element_class, item_class)) {
                self.errorCode(item.span, code, message);
            }
        }
        return true;
    }

    fn checkStructLiteralInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const literal_fields = structLiteralFields(expr) orelse return false;
        const resolved_target_ty = resolveAliasType(target_ty, ctx);
        if (packedBitsInfoForType(resolved_target_ty, ctx) != null) return false;
        const struct_name = structTypeName(resolved_target_ty) orelse {
            self.errorCode(expr.span, code, message);
            return true;
        };
        const structs = ctx.structs orelse {
            self.errorCode(expr.span, code, message);
            return true;
        };
        const struct_info = structs.get(struct_name) orelse {
            self.errorCode(expr.span, code, message);
            return true;
        };

        var seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer seen.deinit();
        for (literal_fields) |field| {
            if (seen.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_STRUCT_LITERAL_FIELD", "struct literal field names must be unique");
            } else {
                seen.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
            const field_ty = struct_info.fields.get(field.name.text) orelse {
                self.errorCode(field.name.span, "E_UNKNOWN_STRUCT_FIELD", "struct has no field with this name");
                _ = self.checkExpr(field.value, ctx);
                continue;
            };
            const value_class = self.checkExpr(field.value, ctx);
            const field_class = classifyTypeCtx(field_ty, ctx);
            const literal_checked = self.checkIntegerLiteralInitializer(field_class, field_ty, field.value, ctx);
            const null_checked = self.checkNullPointerInitializer(field_class, field.value);
            const array_literal_checked = self.checkArrayLiteralInitializer(field_ty, field.value, ctx, code, message);
            const struct_literal_checked = self.checkStructLiteralInitializer(field_ty, field.value, ctx, code, message);
            const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(field_ty, field.value, ctx, code, message);
            const pointer_conversion_checked = self.checkPointerViewInitializer(field_ty, field.value, ctx);
            const c_void_conversion_checked = self.checkCVoidPointerConversion(field_ty, field.value, ctx);
            const address_checked = self.checkAddressOfInitializer(field_class, field_ty, field.value, ctx);
            const address_class_checked = checkAddressClassConversion(self, field.value.span, field_class, value_class);
            const enum_checked = self.checkEnumValueCompatibility(field_ty, field.value, ctx, code, message);
            const union_checked = self.checkTaggedUnionConstructorCompatibility(field_ty, field.value, ctx, code, message);
            const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(field.value, ctx, code, message) else false;
            if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(field_class, value_class)) {
                self.errorCode(field.value.span, code, message);
            }
        }

        var required = struct_info.fields.iterator();
        while (required.next()) |entry| {
            if (!seen.contains(entry.key_ptr.*)) {
                self.errorCode(expr.span, "E_STRUCT_LITERAL_MISSING_FIELD", "struct literal must initialize every field");
            }
        }
        return true;
    }

    fn checkPackedBitsLiteralInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const literal_fields = structLiteralFields(expr) orelse return false;
        const packed_info = packedBitsInfoForType(resolveAliasType(target_ty, ctx), ctx) orelse return false;

        var seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer seen.deinit();
        var has_unknown_field = false;
        for (literal_fields) |field| {
            if (seen.contains(field.name.text)) {
                self.errorCode(field.name.span, "E_DUPLICATE_STRUCT_LITERAL_FIELD", "struct literal field names must be unique");
            } else {
                seen.put(field.name.text, {}) catch {
                    self.oom = true;
                };
            }
            const field_ty = packed_info.fields.get(field.name.text) orelse {
                self.errorCode(field.name.span, "E_UNKNOWN_STRUCT_FIELD", "packed bits type has no field with this name");
                has_unknown_field = true;
                _ = self.checkExpr(field.value, ctx);
                continue;
            };
            const value_class = self.checkExpr(field.value, ctx);
            const field_class = classifyTypeCtx(field_ty, ctx);
            if (!canInitialize(field_class, value_class)) {
                self.errorCode(field.value.span, code, message);
            }
        }

        if (!has_unknown_field) {
            var required = packed_info.fields.iterator();
            while (required.next()) |entry| {
                if (!seen.contains(entry.key_ptr.*)) {
                    self.errorCode(expr.span, "E_STRUCT_LITERAL_MISSING_FIELD", "packed bits literal must initialize every field");
                }
            }
        }
        return true;
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
        if (nullablePointerWideningCtx(target, source, ctx)) return true;
        if (implicitPointerViewConversionCtx(target, source, ctx)) {
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
        const literal_checked = self.checkIntegerLiteralInitializer(target, target_ty, expr, ctx);
        const null_checked = self.checkNullPointerInitializer(target, expr);
        const array_literal_checked = self.checkArrayLiteralInitializer(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const struct_literal_checked = self.checkStructLiteralInitializer(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const array_decay_checked = self.checkArrayDecayInitializer(target, returned, expr);
        const pointer_conversion_checked = self.checkPointerViewReturn(target_ty, expr, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, expr, ctx);
        const address_checked = self.checkAddressOfInitializer(target, target_ty, expr, ctx);
        const address_class_checked = checkAddressClassConversion(self, expr.span, target, returned);
        const local_escape_checked = self.checkLocalAddressReturn(target, expr, ctx);
        const enum_checked = self.checkEnumValueCompatibility(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type") else false;
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !address_class_checked and !local_escape_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(target, returned)) {
            self.errorCode(expr.span, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        }
    }

    fn checkPointerViewReturn(self: *Checker, target: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const source = exprResultType(expr, ctx) orelse return false;
        if (nullablePointerWideningCtx(target, source, ctx)) return true;
        if (implicitPointerViewConversionCtx(target, source, ctx)) {
            self.errorCode(expr.span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer and view conversions must be explicit");
            return true;
        }
        return false;
    }

    fn checkCVoidPointerConversion(self: *Checker, target: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const source = exprResultType(expr, ctx) orelse return false;
        if (implicitCVoidPointerConversionCtx(target, source, ctx)) {
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
        // A function-pointer parameter: the argument is either a named function
        // (check its signature) or another function-pointer value (check the
        // signatures match structurally).
        if (classifyTypeCtx(target_ty, ctx) == .fn_pointer) {
            if (directCallName(arg)) |name| {
                if (ctx.functions != null and ctx.functions.?.contains(name)) {
                    if (!functionMatchesFnPointer(name, target_ty, ctx)) {
                        self.errorCode(arg.span, "E_FN_POINTER_SIGNATURE_MISMATCH", "function signature does not match the expected function-pointer type");
                    }
                    return;
                }
            }
            if (exprDeclaredType(arg, ctx)) |arg_ty| {
                if (classifyTypeCtx(arg_ty, ctx) == .fn_pointer) {
                    if (!sameTypeSyntaxCtx(arg_ty, target_ty, ctx)) {
                        self.errorCode(arg.span, "E_FN_POINTER_SIGNATURE_MISMATCH", "function-pointer signature does not match the expected type");
                    }
                    return;
                }
            }
        }
        const target = classifyTypeCtx(target_ty, ctx);
        const literal_checked = self.checkIntegerLiteralInitializer(target, target_ty, arg, ctx);
        const null_checked = self.checkNullPointerInitializer(target, arg);
        const array_literal_checked = self.checkArrayLiteralInitializer(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const struct_literal_checked = self.checkStructLiteralInitializer(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const packed_bits_literal_checked = self.checkPackedBitsLiteralInitializer(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const array_decay_checked = self.checkArrayDecayInitializer(target, source, arg);
        const pointer_conversion_checked = self.checkPointerViewInitializer(target_ty, arg, ctx);
        const c_void_conversion_checked = self.checkCVoidPointerConversion(target_ty, arg, ctx);
        const address_checked = self.checkAddressOfInitializer(target, target_ty, arg, ctx);
        const address_class_checked = checkAddressClassConversion(self, arg.span, target, source);
        const enum_checked = self.checkEnumValueCompatibility(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(target_ty, arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(arg, ctx, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion") else false;
        // A struct value passed where a *different* named struct is expected is a
        // type error: distinct struct types (e.g. the move typestates CpuBuffer
        // vs DeviceBuffer) are not interchangeable just because they classify the
        // same. (Struct literals are target-typed and handled above.)
        if (self.checkNamedStructMismatch(target_ty, arg, ctx)) return;
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(target, source)) {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "call argument requires an explicit conversion");
        }
    }

    // True (and reports) when `arg` is a value of one named struct passed where a
    // different named struct is expected.
    fn checkNamedStructMismatch(self: *Checker, target_ty: ast.TypeExpr, arg: ast.Expr, ctx: Context) bool {
        const tname = structNameOfType(target_ty, ctx) orelse return false;
        const arg_ty = exprDeclaredType(arg, ctx) orelse return false;
        const aname = structNameOfType(arg_ty, ctx) orelse return false;
        if (!std.mem.eql(u8, tname, aname)) {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "call argument struct type does not match the parameter type");
            return true;
        }
        return false;
    }

    fn checkTaggedUnionConstructorCompatibility(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const union_info = unionInfoForType(target_ty, ctx) orelse return false;
        const call = taggedUnionConstructorCall(expr) orelse return false;
        if (taggedUnionConstructorIsFunction(call.name.text, ctx)) return false;
        const case_payload = union_info.cases.get(call.name.text) orelse {
            self.errorCode(call.name.span, "E_UNKNOWN_UNION_CASE", "union has no case with this name");
            return true;
        };
        if (case_payload) |payload_ty| {
            if (call.args.len != 1) {
                self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match union case payload");
                return true;
            }
            const source = self.checkExpr(call.args[0], ctx);
            self.checkCallArgument(payload_ty, call.args[0], source, ctx);
        } else if (call.args.len != 0) {
            self.errorCode(expr.span, "E_CALL_ARG_COUNT", "call argument count does not match union case payload");
        }
        _ = code;
        _ = message;
        return true;
    }

    fn checkTaggedUnionConstructorRequiresUnionTarget(self: *Checker, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const call = taggedUnionConstructorCall(expr) orelse return false;
        if (!isKnownTaggedUnionConstructorName(call.name.text, ctx)) return false;
        if (taggedUnionConstructorIsFunction(call.name.text, ctx)) return false;
        self.errorCode(expr.span, code, message);
        return true;
    }

    fn checkEnumValueCompatibility(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const target_enum = enumInfoForType(target_ty, ctx);
        if (enumLiteralName(expr)) |literal| {
            const enum_info = target_enum orelse {
                self.errorCode(expr.span, code, message);
                return true;
            };
            if (!enum_info.cases.contains(literal.text)) {
                self.errorCode(literal.span, "E_UNKNOWN_ENUM_CASE", "enum has no case with this name");
            }
            return true;
        }
        if (exprResultType(expr, ctx)) |source_ty| {
            const source_is_enum = enumInfoForType(source_ty, ctx) != null;
            if (target_enum != null or source_is_enum) {
                if (sameTypeSyntaxCtx(target_ty, source_ty, ctx)) return true;
                self.errorCode(expr.span, code, message);
                return true;
            }
        }
        if (target_enum != null) {
            self.errorCode(expr.span, code, message);
            return true;
        }
        return false;
    }

    fn checkEnumCast(self: *Checker, span: diagnostics.Span, value: ast.Expr, source_class: TypeClass, target_ty: ast.TypeExpr, target_class: TypeClass, ctx: Context) void {
        if (enumInfoForType(target_ty, ctx)) |target_enum| {
            if (isIntegerLike(source_class)) {
                if (!target_enum.is_open) {
                    self.errorCode(span, "E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION", "integer-to-closed-enum conversion must use a checked conversion path");
                }
                return;
            }
        }

        const source_ty = exprResultType(value, ctx) orelse return;
        if (enumInfoForType(source_ty, ctx) != null and isCheckedInt(target_class)) {
            self.errorCode(span, "E_ENUM_RAW_REQUIRES_OPEN_ENUM", "use .raw() to extract the representation value of an open enum");
        }
    }

    fn checkEnumRawCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []const ast.Expr, ctx: Context) ?TypeClass {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| return self.checkEnumRawCall(span, inner.*, args, ctx),
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "raw")) return null;
        const base_ty = exprResultType(member.base.*, ctx) orelse return null;
        const enum_info = enumInfoForType(base_ty, ctx) orelse return null;
        if (args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "call argument count does not match function declaration");
        }
        if (!enum_info.is_open) {
            self.errorCode(member.name.span, "E_ENUM_RAW_REQUIRES_OPEN_ENUM", "raw enum representation access is valid only on open enums");
            return .unknown;
        }
        const repr = enum_info.repr orelse return .unknown;
        return classifyTypeCtx(repr, ctx);
    }

    fn checkRawManyOffsetCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        const base_ty = rawManyOffsetReturnType(call, ctx) orelse return null;
        if (!ctx.in_unsafe) {
            self.errorCode(span, "E_UNSAFE_REQUIRED", "operation requires unsafe context");
        }
        if (call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "call argument count does not match function declaration");
            return classifyTypeCtx(base_ty, ctx);
        }
        const index_class = self.checkExpr(call.args[0], ctx);
        if (!isIndexType(index_class)) {
            self.errorCode(call.args[0].span, "E_INDEX_NOT_USIZE", "array and slice indices must be checked usize");
        }
        return classifyTypeCtx(base_ty, ctx);
    }

    fn checkLocalAddressReturn(self: *Checker, target: TypeClass, expr: ast.Expr, ctx: Context) bool {
        if (!isNonNullPointerLike(target) and !isNullablePointerLike(target)) return false;
        if (localAddressRoot(expr, ctx) != null) {
            self.errorCode(expr.span, "E_LOCAL_ADDRESS_ESCAPE", "cannot return the address of local storage");
            return true;
        }
        return false;
    }

    fn checkTargetlessLiteralInitializer(self: *Checker, expr: ast.Expr) bool {
        switch (expr.kind) {
            .enum_literal => {
                self.errorCode(expr.span, "E_ENUM_LITERAL_REQUIRES_TARGET", "enum literal requires an explicit enum target type");
                return true;
            },
            .string_literal, .char_literal => {
                self.errorCode(expr.span, "E_LITERAL_REQUIRES_TARGET", "literal requires an explicit target type");
                return true;
            },
            .grouped => |inner| return self.checkTargetlessLiteralInitializer(inner.*),
            else => return false,
        }
    }

    // An integer literal used as a binary operand adapts to the other operand's type and is
    // emitted as a temporary of that width *before* the checked operation runs, so an
    // out-of-range literal is silently truncated by the C compiler, defeating the overflow
    // check (e.g. `x * 300` with `x: u8` stores `uint8_t = 300` -> 44, then checks `5 * 44`).
    // Range-check each literal operand against the other operand's checked-integer bounds, the
    // same way an initializer is checked by checkIntegerLiteralInitializer.
    fn checkBinaryLiteralOperandRange(self: *Checker, left_expr: ast.Expr, left: TypeClass, right_expr: ast.Expr, right: TypeClass) void {
        self.checkLiteralOperandAgainstClass(left_expr, right);
        self.checkLiteralOperandAgainstClass(right_expr, left);
    }

    fn checkLiteralOperandAgainstClass(self: *Checker, expr: ast.Expr, target: TypeClass) void {
        const value = integerLiteralValue(expr) orelse return;
        const bounds = checkedIntBounds(target) orelse return;
        if (value.negative) {
            if (!bounds.signed or value.magnitude > bounds.min_abs) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
            }
            return;
        }
        if (value.magnitude > bounds.max) {
            self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
        }
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

    fn checkUnaryNegOperand(self: *Checker, span: diagnostics.Span, operand: TypeClass) void {
        if (isCheckedUnsigned(operand)) return;
        if (isDiagnosticNeutralOperand(operand) or isCheckedSigned(operand) or isArithmeticDomain(operand) or isFloatish(operand) or operand == .int_literal) return;
        self.errorCode(span, "E_OPERATOR_OPERAND", "unary '-' requires a signed integer, floating-point, or arithmetic-domain operand");
    }

    fn checkUnaryBitwiseOperand(self: *Checker, span: diagnostics.Span, operand: TypeClass) void {
        if (isAddressClass(operand)) return;
        if (isCheckedSigned(operand) or operand == .bool or isPointerLike(operand) or isForbiddenBitwisePolicy(operand)) return;
        if (isBitwiseOperand(operand)) return;
        self.errorCode(span, "E_OPERATOR_OPERAND", "bitwise operators require unsigned integer or wrapping operands");
    }

    fn checkFloatBinaryOperands(self: *Checker, span: diagnostics.Span, left: TypeClass, right: TypeClass) void {
        if (!isFloatish(left) and !isFloatish(right)) return;
        if (isDiagnosticNeutralOperand(left) or isDiagnosticNeutralOperand(right)) return;
        if (isFloatish(left) and isFloatish(right)) {
            if (isFloat(left) and isFloat(right) and left != right) {
                self.errorCode(span, "E_NO_IMPLICIT_CONVERSION", "f32 and f64 do not implicitly convert; use an explicit conversion");
            }
            return;
        }
        self.errorCode(span, "E_NO_IMPLICIT_CONVERSION", "floating-point and non-floating-point operands do not implicitly mix");
    }

    fn checkArithmeticOperatorOperands(self: *Checker, span: diagnostics.Span, left: TypeClass, right: TypeClass) void {
        if (isAddressClass(left) or isAddressClass(right)) return;
        if (isSingleObjectPointerLike(left) or isSingleObjectPointerLike(right)) return;
        if (!isArithmeticOperand(left) or !isArithmeticOperand(right)) {
            self.errorCode(span, "E_OPERATOR_OPERAND", "arithmetic operators require integer or arithmetic-domain operands");
        }
    }

    fn checkBitwiseOperatorOperands(self: *Checker, span: diagnostics.Span, left: TypeClass, right: TypeClass) void {
        if (isAddressClass(left) or isAddressClass(right)) return;
        if (isCheckedSigned(left) or isCheckedSigned(right)) return;
        if (left == .bool or right == .bool) return;
        if (isPointerLike(left) or isPointerLike(right)) return;
        if (isForbiddenBitwisePolicy(left) or isForbiddenBitwisePolicy(right)) return;
        if (!isBitwiseOperand(left) or !isBitwiseOperand(right)) {
            self.errorCode(span, "E_OPERATOR_OPERAND", "bitwise operators require unsigned integer or wrapping operands");
        }
    }

    fn checkComparisonOperatorOperands(self: *Checker, span: diagnostics.Span, op: ast.BinaryOp, left: TypeClass, right: TypeClass) void {
        if (isAddressClass(left) or isAddressClass(right)) return;
        if (op == .eq or op == .ne) {
            if (equalityOperandsCompatible(left, right)) return;
            self.errorCode(span, "E_OPERATOR_OPERAND", "equality operators require comparable operands");
            return;
        }
        if (isPointerLike(left) or isPointerLike(right) or left == .null_literal or right == .null_literal) return;
        if (isDiagnosticNeutralOperand(left) or isDiagnosticNeutralOperand(right)) return;
        if (isForbiddenOrderingDomain(left) or isForbiddenOrderingDomain(right)) {
            self.errorCode(span, "E_ORDERED_ARITH_DOMAIN_OPERAND", "ordered comparisons are not defined on wrap, serial, or counter arithmetic domains");
            return;
        }
        if (isOrderedComparisonOperand(left) and isOrderedComparisonOperand(right)) return;
        self.errorCode(span, "E_OPERATOR_OPERAND", "ordered comparisons require integer or arithmetic-domain operands");
    }

    fn checkPointerComparison(
        self: *Checker,
        span: diagnostics.Span,
        op: ast.BinaryOp,
        left_expr: ast.Expr,
        left: TypeClass,
        right_expr: ast.Expr,
        right: TypeClass,
        ctx: Context,
    ) void {
        if (isAddressClass(left) or isAddressClass(right)) return;

        const left_is_null = left == .null_literal;
        const right_is_null = right == .null_literal;
        const left_ty = exprResultType(left_expr, ctx) orelse exprStorageType(left_expr, ctx);
        const right_ty = exprResultType(right_expr, ctx) orelse exprStorageType(right_expr, ctx);
        const left_is_view = if (left_ty) |ty| viewType(ty) != null else false;
        const right_is_view = if (right_ty) |ty| viewType(ty) != null else false;

        if (!left_is_null and !right_is_null and !left_is_view and !right_is_view) return;

        if (op != .eq and op != .ne) {
            self.errorCode(span, "E_POINTER_ORDERING", "pointer and view values support only equality comparisons");
            return;
        }

        if (left_is_null or right_is_null) {
            if ((left_is_null and right_is_view) or (right_is_null and left_is_view)) return;
            self.errorCode(span, "E_NO_IMPLICIT_CONVERSION", "null comparisons require a pointer or view operand");
            return;
        }

        if (!left_is_view or !right_is_view) {
            self.errorCode(span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer comparisons require compatible pointer or view operands");
            return;
        }

        if (!pointerComparableTypesCtx(left_ty.?, right_ty.?, ctx)) {
            self.errorCode(span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer comparisons require compatible pointer or view operands");
        }
    }

    fn checkKnownStructField(self: *Checker, span: diagnostics.Span, base: ast.Expr, field_name: []const u8, ctx: Context) void {
        const base_ty = exprResultType(base, ctx) orelse return;
        const layout_name = structTypeName(base_ty) orelse return;
        const layout_info = layoutFieldInfo(layout_name, ctx) orelse return;
        if (!layout_info.fields.contains(field_name)) {
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
                    if (value_class == .result) {
                        self.errorCode(node.tag.span, "E_IF_LET_RESULT_TAG", "if let result narrowing supports only ok(...) or err(...)");
                    } else {
                        self.errorCode(pattern.span, "E_IF_LET_NARROW_PATTERN", "if let supports only optional bindings and Result ok(...) or err(...) bindings");
                    }
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
        var binding_ctx = ctx;
        binding_ctx.scope = scope;
        switch (pattern.kind) {
            .bind => |ident| {
                if (!isNullableValue(value_class)) return;
                const narrowed_ty = if (exprResultType(value, binding_ctx)) |ty| nullableInnerType(ty) else null;
                self.addLocalBinding(scope, ident, .{
                    .class = tryResultType(value_class),
                    .mutable = false,
                    .ty = narrowed_ty,
                    .origin = .local,
                });
            },
            .tag_bind => |node| {
                if (!isResultNarrowingTag(node.tag.text) or value_class != .result) return;
                const narrowed_ty = if (exprResultType(value, binding_ctx)) |ty| resultPayloadType(ty, node.tag.text) else null;
                self.addLocalBinding(scope, node.binding, .{
                    .class = if (narrowed_ty) |ty| classifyTypeCtx(ty, ctx) else .unknown,
                    .mutable = false,
                    .ty = narrowed_ty,
                    .origin = .local,
                });
            },
            .wildcard, .tag, .literal => {},
        }
    }

    fn addForBinding(self: *Checker, loop: ast.Loop, ctx: Context, scope: *Scope) void {
        const label = loop.label orelse return;
        const iterable = loop.iterable orelse return;
        const element_ty = if (exprResultType(iterable, ctx)) |ty| iterableElementType(ty) else null;
        self.addLocalBinding(scope, label, .{
            .class = if (element_ty) |ty| classifyTypeCtx(ty, ctx) else .unknown,
            .mutable = false,
            .ty = element_ty,
            .origin = .local,
        });
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
            scope.put(label.text, entry) catch {
                self.oom = true;
            };
        } else {
            _ = scope.remove(label.text);
        }
    }

    fn checkSwitch(self: *Checker, node: ast.Switch, ctx: Context) void {
        const subject_class = self.checkExpr(node.subject, ctx);
        const subject_ty = exprResultType(node.subject, ctx);
        const subject_enum = if (subject_ty) |ty| enumInfoForType(ty, ctx) else null;
        const subject_union = if (subject_ty) |ty| unionInfoForType(ty, ctx) else null;
        var enum_cases_seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer enum_cases_seen.deinit();
        var union_cases_seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer union_cases_seen.deinit();
        var result_cases_seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer result_cases_seen.deinit();
        var bool_cases_seen = std.StringHashMap(void).init(self.reporter.allocator);
        defer bool_cases_seen.deinit();
        var literal_cases_seen = std.AutoHashMap(EnumValueKey, void).init(self.reporter.allocator);
        defer literal_cases_seen.deinit();
        self.checkSwitchWildcardOrdering(node);
        for (node.arms) |arm| {
            self.checkSwitchArmPatterns(arm.patterns, subject_class, subject_ty, ctx);
            if (subject_enum) |enum_info| {
                self.checkDuplicateSwitchEnumCases(arm.patterns, enum_info, &enum_cases_seen);
            }
            if (subject_union) |union_info| {
                self.checkDuplicateSwitchUnionCases(arm.patterns, union_info, &union_cases_seen);
            }
            if (subject_class == .result) {
                self.checkDuplicateSwitchResultCases(arm.patterns, &result_cases_seen);
            }
            if (subject_class == .bool) {
                self.checkDuplicateSwitchBoolCases(arm.patterns, &bool_cases_seen);
            }
            if (isIntegerLike(subject_class)) {
                self.checkDuplicateSwitchIntegerLiteralCases(arm.patterns, &literal_cases_seen);
            }
            var arm_scope = Scope.init(self.reporter.allocator);
            defer arm_scope.deinit();
            var arm_ctx = ctx;
            if (ctx.scope) |scope| {
                copyScope(scope, &arm_scope) catch {
                    self.oom = true;
                };
                self.addSwitchArmBindings(arm.patterns, node.subject, subject_class, &arm_scope, ctx);
                arm_ctx.scope = &arm_scope;
            }
            switch (arm.body) {
                .block => |block| self.checkBlock(block, arm_ctx),
                .expr => |expr| _ = self.checkExpr(expr, arm_ctx),
            }
        }
        if (subject_ty) |ty| {
            if (closedEnumInfoForType(ty, ctx)) |enum_info| {
                if (!switchCoversAllEnumCases(node, enum_info)) {
                    self.errorCode(node.subject.span, "E_CLOSED_ENUM_SWITCH_EXHAUSTIVE", "switch over closed enum must cover every case or use '_'");
                }
            }
        }
    }

    fn checkDuplicateSwitchEnumCases(self: *Checker, patterns: []const ast.Pattern, enum_info: EnumInfo, seen: *std.StringHashMap(void)) void {
        for (patterns) |pattern| {
            const tag = switch (pattern.kind) {
                .tag => |tag| tag,
                else => continue,
            };
            if (!enum_info.cases.contains(tag.text)) continue;
            if (seen.contains(tag.text)) {
                self.errorCode(tag.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(tag.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDuplicateSwitchUnionCases(self: *Checker, patterns: []const ast.Pattern, union_info: UnionInfo, seen: *std.StringHashMap(void)) void {
        for (patterns) |pattern| {
            const tag = switch (pattern.kind) {
                .tag => |tag| tag,
                .tag_bind => |node| node.tag,
                else => continue,
            };
            if (!union_info.cases.contains(tag.text)) continue;
            if (seen.contains(tag.text)) {
                self.errorCode(tag.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(tag.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDuplicateSwitchResultCases(self: *Checker, patterns: []const ast.Pattern, seen: *std.StringHashMap(void)) void {
        for (patterns) |pattern| {
            const tag = switch (pattern.kind) {
                .tag => |tag| tag,
                .tag_bind => |node| node.tag,
                else => continue,
            };
            if (!isResultNarrowingTag(tag.text)) continue;
            if (seen.contains(tag.text)) {
                self.errorCode(tag.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(tag.text, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDuplicateSwitchBoolCases(self: *Checker, patterns: []const ast.Pattern, seen: *std.StringHashMap(void)) void {
        for (patterns) |pattern| {
            const value = switchBoolLiteralValue(pattern) orelse continue;
            const key = if (value) "true" else "false";
            if (seen.contains(key)) {
                self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(key, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkDuplicateSwitchIntegerLiteralCases(self: *Checker, patterns: []const ast.Pattern, seen: *std.AutoHashMap(EnumValueKey, void)) void {
        for (patterns) |pattern| {
            const key = switch (pattern.kind) {
                .literal => |expr| if (integerLiteralValue(expr)) |value| enumValueKey(value) else continue,
                else => continue,
            };
            if (seen.contains(key)) {
                self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
            } else {
                seen.put(key, {}) catch {
                    self.oom = true;
                };
            }
        }
    }

    fn checkSwitchWildcardOrdering(self: *Checker, node: ast.Switch) void {
        var wildcard_seen = false;
        for (node.arms) |arm| {
            var arm_has_wildcard = false;
            for (arm.patterns) |pattern| {
                if (wildcard_seen) {
                    self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
                    continue;
                }
                if (pattern.kind == .wildcard) {
                    if (arm_has_wildcard) {
                        self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
                    }
                    arm_has_wildcard = true;
                } else if (arm_has_wildcard) {
                    self.errorCode(pattern.span, "E_DUPLICATE_SWITCH_CASE", "switch case pattern is already covered");
                }
            }
            if (arm_has_wildcard) wildcard_seen = true;
        }
    }

    fn checkSwitchArmPatterns(self: *Checker, patterns: []const ast.Pattern, subject_class: TypeClass, subject_ty: ?ast.TypeExpr, ctx: Context) void {
        var binding_pattern_count: usize = 0;
        const subject_enum = if (subject_ty) |ty| enumInfoForType(ty, ctx) else null;
        const subject_union = if (subject_ty) |ty| unionInfoForType(ty, ctx) else null;
        for (patterns) |pattern| {
            switch (pattern.kind) {
                .tag => |tag| {
                    if (subject_enum) |enum_info| {
                        if (!enum_info.cases.contains(tag.text)) {
                            self.errorCode(tag.span, "E_UNKNOWN_ENUM_CASE", "enum has no case with this name");
                        }
                    } else if (subject_union) |union_info| {
                        if (!union_info.cases.contains(tag.text)) {
                            self.errorCode(tag.span, "E_UNKNOWN_UNION_CASE", "union has no case with this name");
                        }
                    } else if (subject_class == .result and !isResultNarrowingTag(tag.text)) {
                        self.errorCode(tag.span, "E_SWITCH_RESULT_TAG", "switch result patterns support only ok or err tags");
                    } else if (subject_class != .result and isResultNarrowingTag(tag.text)) {
                        self.errorCode(tag.span, "E_SWITCH_RESULT_REQUIRED", "switch ok or err patterns require a Result value");
                    }
                },
                .tag_bind => |node| {
                    binding_pattern_count += 1;
                    if (subject_union) |union_info| {
                        if (!union_info.cases.contains(node.tag.text)) {
                            self.errorCode(node.tag.span, "E_UNKNOWN_UNION_CASE", "union has no case with this name");
                        } else if (unionCasePayloadType(union_info, node.tag.text) == null) {
                            self.errorCode(pattern.span, "E_UNION_CASE_HAS_NO_PAYLOAD", "union case binding requires a payload case");
                        }
                    } else if (!isResultNarrowingTag(node.tag.text)) {
                        self.errorCode(node.tag.span, "E_SWITCH_RESULT_TAG", "switch result binding supports only ok(...) or err(...)");
                    } else if (subject_class != .result) {
                        self.errorCode(pattern.span, "E_SWITCH_RESULT_REQUIRED", "switch ok(...) or err(...) binding requires a Result value");
                    }
                },
                .bind => {
                    binding_pattern_count += 1;
                },
                .literal => |expr| self.checkSwitchLiteralPattern(pattern, expr, subject_class),
                .wildcard => {},
            }
        }
        if (binding_pattern_count > 1) {
            self.errorCode(patterns[0].span, "E_SWITCH_MULTI_BINDING_ARM", "switch arms with multiple patterns cannot introduce bindings");
        }
    }

    fn checkSwitchLiteralPattern(self: *Checker, pattern: ast.Pattern, expr: ast.Expr, subject_class: TypeClass) void {
        if (subject_class == .unknown) return;
        if (subject_class == .bool) {
            if (switchBoolLiteralValue(pattern) == null) {
                self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
            }
            return;
        }
        if (isIntegerLike(subject_class)) {
            if (integerLiteralValue(expr) == null) {
                self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
            }
            return;
        }
        self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
    }

    fn addSwitchArmBindings(self: *Checker, patterns: []const ast.Pattern, subject: ast.Expr, subject_class: TypeClass, scope: *Scope, ctx: Context) void {
        if (patterns.len != 1) return;
        var binding_ctx = ctx;
        binding_ctx.scope = scope;
        const subject_ty = exprResultType(subject, binding_ctx) orelse return;
        const subject_union = unionInfoForType(subject_ty, binding_ctx);
        for (patterns) |pattern| {
            switch (pattern.kind) {
                .tag_bind => |node| {
                    const narrowed_ty = if (subject_class == .result and isResultNarrowingTag(node.tag.text))
                        resultPayloadType(subject_ty, node.tag.text)
                    else if (subject_union) |union_info|
                        unionCasePayloadType(union_info, node.tag.text)
                    else
                        null;
                    const ty = narrowed_ty orelse continue;
                    self.addLocalBinding(scope, node.binding, .{
                        .class = classifyTypeCtx(ty, ctx),
                        .mutable = false,
                        .ty = ty,
                        .origin = .local,
                    });
                },
                .bind => |ident| {
                    if (!isNullableValue(subject_class)) continue;
                    const narrowed_ty = nullableInnerType(subject_ty) orelse continue;
                    self.addLocalBinding(scope, ident, .{
                        .class = classifyTypeCtx(narrowed_ty, ctx),
                        .mutable = false,
                        .ty = narrowed_ty,
                        .origin = .local,
                    });
                },
                .wildcard, .tag, .literal => {},
            }
        }
    }
};

const Context = struct {
    no_lang_trap: bool = false,
    in_unsafe: bool = false,
    in_comptime: bool = false,
    returns_never: bool = false,
    returns_void: bool = false,
    return_ty: ?ast.TypeExpr = null,
    return_kind: TypeClass = .void,
    loop_depth: usize = 0,
    unsafe_contracts: UnsafeContracts = .{},
    scope: ?*Scope = null,
    allow_mmio_register_type: bool = false,
    mmio_structs: ?*const std.StringHashMap(MmioStruct) = null,
    mmio_params: ?*const std.StringHashMap([]const u8) = null,
    structs: ?*const std.StringHashMap(StructInfo) = null,
    packed_bits: ?*const std.StringHashMap(LayoutFieldInfo) = null,
    overlay_unions: ?*const std.StringHashMap(LayoutFieldInfo) = null,
    tagged_unions: ?*const std.StringHashMap(UnionInfo) = null,
    enums: ?*const std.StringHashMap(EnumInfo) = null,
    type_aliases: ?*const std.StringHashMap(ast.TypeExpr) = null,
    functions: ?*const std.StringHashMap(FunctionInfo) = null,
    globals: ?*const std.StringHashMap(GlobalInfo) = null,
    // `const fn` bodies, for evaluating comptime const-fn calls (e.g. when a
    // const-fn result drives a fixed-array length — section 22 comptime↔type).
    const_fns: ?*const std.StringHashMap(ast.FnDecl) = null,
    // Folded `const NAME: T = …` global values, for resolving named compile-time
    // constants in comptime contexts and array lengths.
    const_globals: ?*const std.StringHashMap(eval.ComptimeValue) = null,
    // Names of the current function's `comptime T: type` type parameters
    // (user-defined generics, section 22); valid as type names in its body.
    type_params: ?*const std.StringHashMap(void) = null,
};

const MmioStruct = struct {
    fields: std.StringHashMap(MmioFieldInfo),
};

const MmioFieldInfo = struct {
    access: MmioRegisterAccess,
};

const MmioRegisterAccess = enum {
    read,
    write,
    read_write,

    fn allowsRead(self: MmioRegisterAccess) bool {
        return self == .read or self == .read_write;
    }

    fn allowsWrite(self: MmioRegisterAccess) bool {
        return self == .write or self == .read_write;
    }
};

const StructInfo = struct {
    fields: std.StringHashMap(ast.TypeExpr),
};

// Liveness slot for a linear `move` binding (section 18.1 / annex D.7).
const MoveSlot = struct {
    live: bool,
    span: diagnostics.Span,
    // Reserved by a `defer` to be consumed at scope end: not a leak, not movable.
    deferred: bool = false,
};

const LayoutFieldInfo = struct {
    fields: std.StringHashMap(ast.TypeExpr),
};

const EnumInfo = struct {
    cases: std.StringHashMap(void),
    is_open: bool,
    repr: ?ast.TypeExpr,
};

const UnionInfo = struct {
    cases: std.StringHashMap(?ast.TypeExpr),
};

const FunctionInfo = struct {
    params: []const ast.Param,
    return_ty: ?ast.TypeExpr,
    no_lang_trap: bool = false,
    is_const: bool = false,
};

const GlobalInfo = struct {
    ty: ast.TypeExpr,
};

const UnsafeContracts = struct {
    no_overflow: bool = false,
    noalias_contract: bool = false,
    precise_asm: bool = false,

    fn with(self: UnsafeContracts, attr: ast.Attr) UnsafeContracts {
        var next = self;
        switch (attr.kind) {
            .unsafe_contract => |contract| {
                if (std.mem.eql(u8, contract.name.text, "no_overflow")) next.no_overflow = true;
                if (std.mem.eql(u8, contract.name.text, "noalias")) next.noalias_contract = true;
                if (std.mem.eql(u8, contract.name.text, "precise_asm")) next.precise_asm = true;
            },
            .no_lang_trap, .named => {},
        }
        return next;
    }

    fn has(self: UnsafeContracts, required: ContractKind) bool {
        return switch (required) {
            .no_overflow => self.no_overflow,
            .noalias_contract => self.noalias_contract,
            .precise_asm => self.precise_asm,
        };
    }
};

const ContractKind = enum {
    no_overflow,
    noalias_contract,
    precise_asm,
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
        .struct_decl => |struct_decl| struct_decl.name,
        .enum_decl => |enum_decl| enum_decl.name,
        .union_decl => |union_decl| union_decl.name,
        .packed_bits_decl => |packed_bits| packed_bits.name,
        .overlay_union_decl => |overlay_union| overlay_union.name,
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
    vaddr,
    dma_addr,
    user_ptr,
    mmio_ptr,
    phys_ptr,
    atomic,
    dma_buf,
    result,
    fn_pointer,
    never,
    void,
    bool,
    null_literal,
    int_literal,
    f32,
    f64,
    float_literal,
    duration,
    order,
};

const TypeMode = enum {
    normal,
    storage,
    return_type,
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

fn isIntegerLike(kind: TypeClass) bool {
    return isCheckedInt(kind) or kind == .int_literal;
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

fn isRuntimePointerDerefClass(kind: TypeClass) bool {
    return switch (kind) {
        .pointer, .raw_many_pointer, .c_void_pointer, .nullable_pointer, .nullable_c_void_pointer, .paddr, .vaddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr => true,
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

fn isForbiddenOrderingDomain(kind: TypeClass) bool {
    return switch (kind) {
        .wrap, .serial, .counter => true,
        else => false,
    };
}

fn isArithmeticDomain(kind: TypeClass) bool {
    return switch (kind) {
        .wrap, .sat, .serial, .counter => true,
        else => false,
    };
}

fn isFloat(kind: TypeClass) bool {
    return kind == .f32 or kind == .f64;
}

fn isFloatish(kind: TypeClass) bool {
    return isFloat(kind) or kind == .float_literal;
}

// IEEE floating-point arithmetic never raises a language trap: division by zero
// and overflow yield infinities or NaN rather than `.DivideByZero`/`.IntegerOverflow`.
fn isNonTrappingFloatOp(op: ast.BinaryOp, left: TypeClass, right: TypeClass) bool {
    if (!isFloatish(left) or !isFloatish(right)) return false;
    if (!isFloat(left) and !isFloat(right)) return false;
    return switch (op) {
        .add, .sub, .mul, .div => true,
        else => false,
    };
}

fn isDiagnosticNeutralOperand(kind: TypeClass) bool {
    return kind == .unknown or kind == .never;
}

fn isArithmeticOperand(kind: TypeClass) bool {
    return isDiagnosticNeutralOperand(kind) or isIntegerLike(kind) or isArithmeticDomain(kind) or isFloatish(kind);
}

fn isBitwiseOperand(kind: TypeClass) bool {
    return isDiagnosticNeutralOperand(kind) or isCheckedUnsigned(kind) or kind == .int_literal or kind == .wrap;
}

fn isOrderedComparisonOperand(kind: TypeClass) bool {
    return isArithmeticOperand(kind);
}

fn isEqualityOperand(kind: TypeClass) bool {
    return isDiagnosticNeutralOperand(kind) or
        isIntegerLike(kind) or
        isArithmeticDomain(kind) or
        isFloatish(kind) or
        kind == .bool or
        isPointerLike(kind) or
        kind == .null_literal;
}

fn equalityOperandsCompatible(left: TypeClass, right: TypeClass) bool {
    if (!isEqualityOperand(left) or !isEqualityOperand(right)) return false;
    if (isDiagnosticNeutralOperand(left) or isDiagnosticNeutralOperand(right)) return true;
    if (left == .null_literal or right == .null_literal) return isPointerLike(left) or isPointerLike(right);
    if (left == .bool or right == .bool) return left == .bool and right == .bool;
    if (isPointerLike(left) or isPointerLike(right)) return isPointerLike(left) and isPointerLike(right);
    if (isArithmeticDomain(left) or isArithmeticDomain(right)) return left == right;
    if (isFloatish(left) or isFloatish(right)) return floatOperandsCompatible(left, right);
    return isIntegerLike(left) and isIntegerLike(right);
}

fn floatOperandsCompatible(left: TypeClass, right: TypeClass) bool {
    if (!isFloatish(left) or !isFloatish(right)) return false;
    if (isFloat(left) and isFloat(right)) return left == right;
    return true; // at least one operand is an adaptable float literal
}

fn arithmeticDomainsImplicitlyMix(left: TypeClass, right: TypeClass) bool {
    if (left == .unknown or right == .unknown or left == .never or right == .never) return false;
    if (isArithmeticDomain(left) or isArithmeticDomain(right)) return left != right;
    return false;
}

fn isNoTrapArithmeticDomainOp(op: ast.BinaryOp, left: TypeClass, right: TypeClass) bool {
    if (left != right) return false;
    return switch (left) {
        .wrap => switch (op) {
            .add, .sub, .mul => true,
            else => false,
        },
        .sat => switch (op) {
            .add, .sub, .mul => true,
            else => false,
        },
        else => false,
    };
}

fn mergeArithmetic(left: TypeClass, right: TypeClass) TypeClass {
    if (left == .f64 or right == .f64) return .f64;
    if (left == .f32 or right == .f32) return .f32;
    if (left == .float_literal or right == .float_literal) return .float_literal;
    if (left == .wrap or right == .wrap) return .wrap;
    if (left == .sat or right == .sat) return .sat;
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
        .fn_pointer => .fn_pointer,
        else => .unknown,
    };
}

fn classifyTypeCtx(ty: ast.TypeExpr, ctx: Context) TypeClass {
    return classifyType(resolveAliasType(ty, ctx));
}

fn resolveAliasType(ty: ast.TypeExpr, ctx: Context) ast.TypeExpr {
    return resolveAliasTypeDepth(ty, ctx, 0);
}

fn resolveAliasTypeDepth(ty: ast.TypeExpr, ctx: Context, depth: usize) ast.TypeExpr {
    if (depth > 64) return ty;
    return switch (ty.kind) {
        .name => |name| {
            const aliases = ctx.type_aliases orelse return ty;
            const target = aliases.get(name.text) orelse return ty;
            if (typeName(target)) |target_name| {
                if (std.mem.eql(u8, target_name, name.text)) return ty;
            }
            return resolveAliasTypeDepth(target, ctx, depth + 1);
        },
        .qualified => |node| resolveAliasTypeDepth(node.child.*, ctx, depth),
        else => ty,
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

fn atomicPayloadType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "atomic") or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| atomicPayloadType(node.child.*),
        else => null,
    };
}

fn atomicPayloadTypeForValue(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    return atomicPayloadType(resolveAliasType(ty, ctx));
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

fn dmaBufInfoForValue(expr: ast.Expr, ctx: Context) ?DmaBufInfo {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    return dmaBufInfo(resolveAliasType(ty, ctx));
}

// Resolves a member base that names a scalar integer or arithmetic-domain type
// (directly or through a type alias), for static operations like `TcpSeq.before(a, b)`
// or `u8.try_from(x)`. Returns null when the base is a value binding or does not
// name such a type.
fn staticTypeBaseClass(base: ast.Expr, ctx: Context) ?TypeClass {
    const ident = switch (base.kind) {
        .ident => |id| id,
        .grouped => |inner| return staticTypeBaseClass(inner.*, ctx),
        else => return null,
    };
    if (ctx.scope) |scope| {
        if (scope.get(ident.text) != null) return null;
    }
    const resolved = resolveAliasType(simpleNameType(ident.text, ident.span), ctx);
    const class = classifyType(resolved);
    if (isCheckedInt(class) or isArithmeticDomain(class)) return class;
    return null;
}

fn isConversionName(name: []const u8) bool {
    return std.mem.eql(u8, name, "from") or
        std.mem.eql(u8, name, "try_from") or
        std.mem.eql(u8, name, "trap_from") or
        std.mem.eql(u8, name, "wrap_from") or
        std.mem.eql(u8, name, "sat_from") or
        std.mem.eql(u8, name, "from_mod");
}

fn isNarrowingConversionName(name: []const u8) bool {
    return std.mem.eql(u8, name, "try_from") or
        std.mem.eql(u8, name, "trap_from") or
        std.mem.eql(u8, name, "wrap_from") or
        std.mem.eql(u8, name, "sat_from");
}

fn isSerialOperationName(name: []const u8) bool {
    return std.mem.eql(u8, name, "before") or
        std.mem.eql(u8, name, "after") or
        std.mem.eql(u8, name, "distance") or
        std.mem.eql(u8, name, "compare");
}

fn isCounterOperationName(name: []const u8) bool {
    return std.mem.eql(u8, name, "delta_mod") or
        std.mem.eql(u8, name, "elapsed_assume_within") or
        std.mem.eql(u8, name, "elapsed_bounded");
}

// Number of arguments a serial/counter domain operation takes. The first two are
// always the domain operands; a third (where present) is an external interval.
fn domainOperationArgCount(op: []const u8) usize {
    if (std.mem.eql(u8, op, "elapsed_assume_within") or std.mem.eql(u8, op, "elapsed_bounded")) return 3;
    return 2;
}

fn isTypeStaticMember(member: anytype, ctx: Context) bool {
    return staticTypeBaseClass(member.base.*, ctx) != null;
}

fn isIntegerScalarName(name: []const u8) bool {
    return switch (classifyTypeName(name)) {
        .checked_u8, .checked_u16, .checked_u32, .checked_u64, .checked_usize, .checked_i8, .checked_i16, .checked_i32, .checked_i64, .checked_isize => true,
        else => false,
    };
}

fn isReduceSumCheckedCallee(callee: ast.Expr) bool {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return isReduceSumCheckedCallee(inner.*),
        else => return false,
    };
    return isIdentNamed(member.base.*, "reduce") and std.mem.eql(u8, member.name.text, "sum_checked");
}

fn reduceCallReturnClass(callee: ast.Expr) ?TypeClass {
    return if (isReduceSumCheckedCallee(callee)) .result else null;
}

fn typeStaticCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return typeStaticCallReturnClass(inner.*, ctx),
        else => return null,
    };
    const class = staticTypeBaseClass(member.base.*, ctx) orelse return null;
    const op = member.name.text;
    if (std.mem.eql(u8, op, "try_from")) return .result;
    if (std.mem.eql(u8, op, "from_mod")) return if (class == .wrap) .wrap else null;
    if (std.mem.eql(u8, op, "from") or
        std.mem.eql(u8, op, "trap_from") or
        std.mem.eql(u8, op, "wrap_from") or
        std.mem.eql(u8, op, "sat_from")) return class;
    if (class == .serial) {
        if (std.mem.eql(u8, op, "before") or std.mem.eql(u8, op, "after")) return .bool;
        if (std.mem.eql(u8, op, "distance")) return .wrap;
        if (std.mem.eql(u8, op, "compare")) return .result;
    } else if (class == .counter) {
        if (std.mem.eql(u8, op, "delta_mod")) return .wrap;
        if (std.mem.eql(u8, op, "elapsed_assume_within")) return .duration;
        if (std.mem.eql(u8, op, "elapsed_bounded")) return .result;
    }
    return null;
}

fn wrapValueInnerType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    const resolved = resolveAliasType(ty, ctx);
    return switch (resolved.kind) {
        .generic => |node| if (std.mem.eql(u8, node.base.text, "wrap") and node.args.len == 1) node.args[0] else null,
        else => null,
    };
}

// `.residue()` exposes the raw modulo representative of a wrap<T> value (section 5.2).
fn residueCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return residueCallReturnClass(inner.*, ctx),
        else => return null,
    };
    if (!std.mem.eql(u8, member.name.text, "residue")) return null;
    const inner = wrapValueInnerType(member.base.*, ctx) orelse return null;
    return classifyTypeCtx(inner, ctx);
}

fn atomicCallReturnType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return atomicCallReturnType(inner.*, ctx),
        else => return null,
    };
    if (std.mem.eql(u8, member.name.text, "load") or std.mem.eql(u8, member.name.text, "fetch_add") or std.mem.eql(u8, member.name.text, "fetch_sub")) {
        return atomicPayloadTypeForValue(member.base.*, ctx);
    }
    return null;
}

fn atomicCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const ty = atomicCallReturnType(callee, ctx) orelse return null;
    return classifyTypeCtx(ty, ctx);
}

fn bitcastCallReturnType(call: anytype) ?ast.TypeExpr {
    if (!isBitcastCallName(call.callee.*) or call.type_args.len != 1) return null;
    return call.type_args[0];
}

// `raw.load<T>(addr)` reads a `T` from a raw address (the dual of `raw.store`).
fn isRawLoadCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |m| isIdentNamed(m.base.*, "raw") and std.mem.eql(u8, m.name.text, "load"),
        .grouped => |inner| isRawLoadCall(inner.*),
        else => false,
    };
}

fn rawLoadCallReturnType(call: anytype) ?ast.TypeExpr {
    if (!isRawLoadCall(call.callee.*) or call.type_args.len != 1) return null;
    return call.type_args[0];
}

fn isMmioMapCallName(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |m| isIdentNamed(m.base.*, "mmio") and std.mem.eql(u8, m.name.text, "map"),
        .grouped => |inner| isMmioMapCallName(inner.*),
        else => false,
    };
}

fn mmioMapCallPayloadType(call: anytype) ?ast.TypeExpr {
    if (!isMmioMapCallName(call.callee.*) or call.type_args.len != 1) return null;
    return .{
        .span = call.type_args[0].span,
        .kind = .{ .generic = .{
            .base = .{ .text = "MmioPtr", .span = call.type_args[0].span },
            .args = call.type_args[0..1],
        } },
    };
}

// `raw.ptr<T>(addr)` mints a `*mut T` from a raw address — the typed-pointer companion
// of raw.load/store (used to view an allocation as a typed object: Arc blocks, etc.).
fn isRawPtrCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |m| isIdentNamed(m.base.*, "raw") and std.mem.eql(u8, m.name.text, "ptr"),
        .grouped => |inner| isRawPtrCall(inner.*),
        else => false,
    };
}

fn tryPayloadType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    switch (expr.kind) {
        .call => |node| if (mmioMapCallPayloadType(node)) |ty| return ty,
        .grouped => |inner| return tryPayloadType(inner.*, ctx),
        else => {},
    }
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
        .raw_many_pointer => |node| node.child.*,
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
        // Member access auto-dereferences a pointer (`p.field` == `(*p).field`), so
        // the field-type lookup must see through a pointer to the struct too.
        .pointer => |node| structTypeName(node.child.*),
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

fn unionTypeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| unionTypeName(node.child.*),
        else => null,
    };
}

fn unionInfoForType(ty: ast.TypeExpr, ctx: Context) ?UnionInfo {
    const name = unionTypeName(ty) orelse return null;
    const tagged_unions = ctx.tagged_unions orelse return null;
    return tagged_unions.get(name);
}

fn unionCasePayloadType(union_info: UnionInfo, case_name: []const u8) ?ast.TypeExpr {
    return union_info.cases.get(case_name) orelse null;
}

const TaggedUnionConstructorCall = struct {
    name: ast.Ident,
    args: []const ast.Expr,
};

fn taggedUnionConstructorCall(expr: ast.Expr) ?TaggedUnionConstructorCall {
    return switch (expr.kind) {
        .call => |node| blk: {
            const ident = switch (node.callee.kind) {
                .ident => |ident| ident,
                .grouped => |inner| switch (inner.kind) {
                    .ident => |ident| ident,
                    else => break :blk null,
                },
                else => break :blk null,
            };
            break :blk .{ .name = ident, .args = node.args };
        },
        .grouped => |inner| taggedUnionConstructorCall(inner.*),
        else => null,
    };
}

fn isKnownTaggedUnionConstructorName(name: []const u8, ctx: Context) bool {
    const tagged_unions = ctx.tagged_unions orelse return false;
    var values = tagged_unions.valueIterator();
    while (values.next()) |union_info| {
        if (union_info.cases.contains(name)) return true;
    }
    return false;
}

fn taggedUnionConstructorIsFunction(name: []const u8, ctx: Context) bool {
    const functions = ctx.functions orelse return false;
    return functions.contains(name);
}

fn classifyGenericTypeName(name: []const u8) TypeClass {
    if (std.mem.eql(u8, name, "Result")) return .result;
    if (std.mem.eql(u8, name, "atomic")) return .atomic;
    if (std.mem.eql(u8, name, "DmaBuf")) return .dma_buf;
    if (std.mem.eql(u8, name, "UserPtr")) return .user_ptr;
    if (std.mem.eql(u8, name, "MmioPtr")) return .mmio_ptr;
    if (std.mem.eql(u8, name, "PhysPtr")) return .phys_ptr;
    if (std.mem.eql(u8, name, "wrap")) return .wrap;
    if (std.mem.eql(u8, name, "sat")) return .sat;
    if (std.mem.eql(u8, name, "serial")) return .serial;
    if (std.mem.eql(u8, name, "counter")) return .counter;
    if (std.mem.eql(u8, name, "Duration")) return .duration;
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
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "Order")) return .order;
    if (std.mem.eql(u8, name, "never")) return .never;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "PAddr")) return .paddr;
    if (std.mem.eql(u8, name, "VAddr")) return .vaddr;
    if (std.mem.eql(u8, name, "DmaAddr")) return .dma_addr;
    return .unknown;
}

fn canInitialize(target: TypeClass, initializer: TypeClass) bool {
    if (target == .unknown or initializer == .unknown) return true;
    if (initializer == .never) return true;
    if (target == initializer) return true;
    if (isNullablePointerLike(target) and initializer == .null_literal) return true;
    if (isCheckedInt(target) and initializer == .int_literal) return true;
    if (isFloat(target) and initializer == .float_literal) return true;
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

fn arithmeticDomainInnerBounds(ty: ast.TypeExpr, domain: []const u8, ctx: Context) ?IntBounds {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        .qualified => |node| return arithmeticDomainInnerBounds(resolveAliasType(node.child.*, ctx), domain, ctx),
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, domain) or generic.args.len != 1) return null;
    return checkedIntBounds(classifyTypeCtx(generic.args[0], ctx));
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

const EnumValueKey = struct {
    negative: bool,
    magnitude: u128,
};

fn enumValueKey(value: LiteralValue) EnumValueKey {
    return .{
        .negative = value.negative and value.magnitude != 0,
        .magnitude = value.magnitude,
    };
}

fn enumValueFits(value: EnumValueKey, bounds: IntBounds) bool {
    if (value.negative) {
        return bounds.signed and value.magnitude <= bounds.min_abs;
    }
    return value.magnitude <= bounds.max;
}

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

fn parseArrayLen(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?usize {
    return switch (expr.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .grouped => |inner| parseArrayLen(inner.*, funcs, globals),
        .binary => |node| {
            const left = parseArrayLen(node.left.*, funcs, globals) orelse return null;
            const right = parseArrayLen(node.right.*, funcs, globals) orelse return null;
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
        // Section 22 comptime↔type feedback: a `const fn` result or a named
        // `const` global can drive a fixed-array length, e.g. `[align_up(3, 4)]u8`
        // or `[CAP]u8`.
        .call, .ident => comptimeUsizeValue(expr, funcs, globals),
        else => null,
    };
}

// Fold a comptime expression to a usize using the const-fn evaluator. A
// stack buffer backs the evaluator's scopes so this stays a free function
// (callable from the type-level array-length helpers without a Checker).
fn comptimeUsizeValue(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?usize {
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

fn parseUsizeLiteral(literal: []const u8) ?usize {
    var cleaned: [128]u8 = undefined;
    if (literal.len > cleaned.len) return null;
    var len: usize = 0;
    for (literal) |ch| {
        if (ch != '_') {
            cleaned[len] = ch;
            len += 1;
        }
    }
    return std.fmt.parseInt(usize, cleaned[0..len], 0) catch null;
}

fn isArrayLiteral(expr: ast.Expr) bool {
    return arrayLiteralItems(expr) != null;
}

fn arrayLiteralItems(expr: ast.Expr) ?[]const ast.Expr {
    return switch (expr.kind) {
        .array_literal => |items| items,
        .grouped => |inner| arrayLiteralItems(inner.*),
        else => null,
    };
}

fn isStructLiteral(expr: ast.Expr) bool {
    return structLiteralFields(expr) != null;
}

fn structLiteralFields(expr: ast.Expr) ?[]const ast.StructLiteralField {
    return switch (expr.kind) {
        .struct_literal => |fields| fields,
        .grouped => |inner| structLiteralFields(inner.*),
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

fn isStaticGlobalInitializer(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .int_literal, .bool_literal, .null_literal, .void_literal, .enum_literal => true,
        .ident => |ident| if (ctx.globals) |globals| globals.contains(ident.text) else false,
        .unary => |node| node.op == .neg and integerLiteralValue(node.expr.*) != null,
        // An explicit conversion of a static operand (`0 as u32`) is itself static;
        // the comptime folder applies the cast, and the C backend emits it inline.
        .cast => |node| isStaticGlobalInitializer(node.value.*, ctx),
        .grouped => |inner| isStaticGlobalInitializer(inner.*, ctx),
        .address_of => |inner| isStaticGlobalAddressTarget(inner.*, ctx),
        .array_literal => |items| allStaticGlobalInitializerItems(items, ctx),
        .struct_literal => |fields| allStaticGlobalInitializerFields(fields, ctx),
        // `atomic.init(<static>)` lowers to a plain `= value` initializer, so a
        // global atomic with a static seed (e.g. an interrupt-shared counter) is a
        // valid static global.
        .call => |node| isAtomicInitCallee(node.callee.*) and node.args.len == 1 and isStaticGlobalInitializer(node.args[0], ctx),
        else => false,
    };
}

fn isAtomicInitCallee(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |m| isIdentNamed(m.base.*, "atomic") and std.mem.eql(u8, m.name.text, "init"),
        .grouped => |inner| isAtomicInitCallee(inner.*),
        else => false,
    };
}

fn allStaticGlobalInitializerItems(items: []const ast.Expr, ctx: Context) bool {
    for (items) |item| {
        if (!isStaticGlobalInitializer(item, ctx)) return false;
    }
    return true;
}

fn allStaticGlobalInitializerFields(fields: []const ast.StructLiteralField, ctx: Context) bool {
    for (fields) |field| {
        if (!isStaticGlobalInitializer(field.value, ctx)) return false;
    }
    return true;
}

fn isStaticGlobalAddressTarget(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| if (ctx.globals) |globals| globals.contains(ident.text) else false,
        .member => |node| isStaticGlobalAddressTarget(node.base.*, ctx),
        .index => |node| isStaticGlobalAddressTarget(node.base.*, ctx) and isStaticGlobalInitializer(node.index.*, ctx),
        .grouped => |inner| isStaticGlobalAddressTarget(inner.*, ctx),
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
            return sameTypeSyntaxCtx(node.child.*, source_child, ctx);
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
        // A field's assignability is the base's: through a non-const pointer it is mutable
        // even though the pointer binding itself is immutable (a `*mut T` parameter permits
        // `p.field = …`), so `&mut p.field` is allowed too. Mirrors the assignment check.
        .member => |node| !immutableValueStorageBase(node.base.*, ctx) and !constStorageBase(node.base.*, ctx),
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
        .paddr, .vaddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr => true,
        else => false,
    };
}

fn isAddressClass(kind: TypeClass) bool {
    return switch (kind) {
        .paddr, .vaddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr => true,
        else => false,
    };
}

fn isBitcastLayoutClass(kind: TypeClass) bool {
    return isCheckedInt(kind) or isFloat(kind) or kind == .bool or isPointerLike(kind) or isAddressClass(kind);
}

fn isBitcastLayoutType(ty: ast.TypeExpr, ctx: Context) bool {
    return isBitcastLayoutClass(classifyTypeCtx(resolveAliasType(ty, ctx), ctx));
}

fn checkAddressClassConversion(self: *Checker, span: diagnostics.Span, target: TypeClass, source: TypeClass) bool {
    if (!isAddressClass(target) or !isAddressClass(source)) return false;
    if (target == source) return false;
    self.errorCode(span, addressClassMismatchDiagnostic(target, source), addressClassMismatchMessage(target, source));
    return true;
}

fn addressClassMismatchDiagnostic(target: TypeClass, source: TypeClass) []const u8 {
    if (source == .dma_addr and target == .paddr) return "E_DMA_ADDR_NOT_PADDR";
    if (source == .dma_addr and target == .vaddr) return "E_DMA_ADDR_NOT_VADDR";
    return "E_ADDRESS_CLASS_MISMATCH";
}

fn addressClassMismatchMessage(target: TypeClass, source: TypeClass) []const u8 {
    if (source == .dma_addr and target == .paddr) return "DmaAddr is not PAddr";
    if (source == .dma_addr and target == .vaddr) return "DmaAddr is not VAddr";
    return "opaque address classes are not implicitly interchangeable";
}

fn addressDerefDiagnostic(kind: TypeClass) []const u8 {
    return switch (kind) {
        .paddr => "E_PADDR_DEREF",
        .vaddr => "E_VADDR_DEREF",
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
        .vaddr => "cannot dereference VAddr; convert it to a typed virtual pointer first",
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
    // Strip every `_` digit-group separator and parse the full magnitude, matching the C
    // backend (appendCIntLiteral / parseI128Literal) and eval.zig. Do NOT break at `_<letter>`:
    // in a hex literal the letter can be a hex digit (`0xAB_C` == 0xABC), and treating it as a
    // type-suffix boundary truncated the value, letting an out-of-range literal slip past the
    // range check into a narrower, truncating C emission.
    for (raw) |ch| {
        if (ch == '_') continue;
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

fn deinitLayoutFieldInfos(infos: *std.StringHashMap(LayoutFieldInfo)) void {
    var values = infos.valueIterator();
    while (values.next()) |info| info.fields.deinit();
    infos.deinit();
}

fn deinitTaggedUnions(tagged_unions: *std.StringHashMap(UnionInfo)) void {
    var values = tagged_unions.valueIterator();
    while (values.next()) |union_info| union_info.cases.deinit();
    tagged_unions.deinit();
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
    if (mmioRegisterMemberInfo(target, ctx) != null) return true;
    if (isMmioRegisterTarget(member.base.*, ctx)) return true;
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

fn isMmioRegisterAccessCall(callee: ast.Expr, ctx: Context) bool {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return isMmioRegisterAccessCall(inner.*, ctx),
        else => return false,
    };
    if (!std.mem.eql(u8, member.name.text, "read") and !std.mem.eql(u8, member.name.text, "write")) return false;
    return mmioRegisterMemberInfo(member.base.*, ctx) != null;
}

fn isAtomicOperationMember(member: anytype, ctx: Context) bool {
    if (isIdentNamed(member.base.*, "atomic")) return std.mem.eql(u8, member.name.text, "init");
    _ = atomicPayloadTypeForValue(member.base.*, ctx) orelse return false;
    return true;
}

fn isDmaOperationMember(member: anytype, ctx: Context) bool {
    if (isIdentNamed(member.base.*, "cache")) {
        return std.mem.eql(u8, member.name.text, "clean") or
            std.mem.eql(u8, member.name.text, "invalidate");
    }
    _ = dmaBufInfoForValue(member.base.*, ctx) orelse return false;
    return true;
}

fn mmioRegisterMemberInfo(expr: ast.Expr, ctx: Context) ?MmioFieldInfo {
    const member = switch (expr.kind) {
        .member => |node| node,
        .grouped => |inner| return mmioRegisterMemberInfo(inner.*, ctx),
        else => return null,
    };
    const base_name = switch (member.base.kind) {
        .ident => |ident| ident.text,
        else => return null,
    };
    const mmio_params = ctx.mmio_params orelse return null;
    const struct_name = mmio_params.get(base_name) orelse return null;
    const mmio_structs = ctx.mmio_structs orelse return null;
    const mmio_struct = mmio_structs.get(struct_name) orelse return null;
    return mmio_struct.fields.get(member.name.text);
}

fn isAssignableTarget(target: ast.Expr) bool {
    return switch (target.kind) {
        .ident => true,
        .deref => |inner| isAssignableDerefOperand(inner.*),
        .index => |node| isAssignableTarget(node.base.*),
        .member => |node| isAssignableTarget(node.base.*),
        .grouped => |inner| isAssignableTarget(inner.*),
        else => false,
    };
}

fn isAssignableDerefOperand(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |node| isRawManyOffsetCallSyntax(node),
        .grouped => |inner| isAssignableDerefOperand(inner.*),
        else => isAssignableTarget(expr),
    };
}

fn isRawManyOffsetCallSyntax(call: anytype) bool {
    if (call.type_args.len != 0 or call.args.len != 1) return false;
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return false,
        },
        else => return false,
    };
    return std.mem.eql(u8, member.name.text, "offset");
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
        .deref => |inner| constStorageBase(inner.*, ctx),
        .index => |node| constStorageBase(node.base.*, ctx),
        .member => |node| constStorageBase(node.base.*, ctx),
        .call => |node| if (rawManyOffsetReturnType(node, ctx)) |ty| isConstStorageType(ty) else false,
        .grouped => |inner| constStorageBase(inner.*, ctx),
        else => false,
    };
}

fn immutableValueStorageBase(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                // A field reached through a pointer auto-derefs; its
                // assignability is the *pointer's* mutability (a const pointer is
                // caught separately by constStorageBase), not the binding's. So a
                // `*mut T` parameter permits `p.field = …` even though `p` itself
                // is an immutable binding.
                if (entry.ty) |ty| {
                    if (ty.kind == .pointer) return false;
                }
                return !entry.mutable;
            }
            return false;
        },
        // A deref (`(*p).field`) is likewise governed by the pointer's const-ness.
        .deref => false,
        .member => |node| immutableValueStorageBase(node.base.*, ctx),
        .grouped => |inner| immutableValueStorageBase(inner.*, ctx),
        else => false,
    };
}

fn immutableIndexedValueStorageBase(expr: ast.Expr, ctx: Context) bool {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return false;
    if (!isArrayType(ty)) return false;
    return immutableValueStorageBase(expr, ctx);
}

fn isArrayType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .array => true,
        .qualified => |node| isArrayType(node.child.*),
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
        .call => |node| rawManyOffsetReturnType(node, ctx),
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
    return classifyTypeCtx(ty, ctx);
}

fn exprResultType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |node| constGetReturnType(node, ctx) orelse rawManyOffsetReturnType(node, ctx) orelse atomicCallReturnType(node.callee.*, ctx) orelse bitcastCallReturnType(node) orelse if (node.type_args.len == 0) directCallReturnType(node.callee.*, ctx) else null,
        .try_expr => |inner| tryPayloadType(inner.operand.*, ctx),
        .cast => |node| node.ty.*,
        .deref => |inner| derefResultType(inner.*, ctx),
        .index => |node| indexResultType(node, ctx),
        .member => |node| memberResultFieldType(node, ctx),
        .grouped => |inner| exprResultType(inner.*, ctx),
        // Comparison and logical operators yield `bool`; surfacing that lets a
        // `switch a < b { true => …, false => … }` count as exhaustive.
        .binary => |node| if (isComparisonBinary(node.op) or isLogicalBinary(node.op))
            boolTypeExpr(expr.span)
        else
            exprStorageType(expr, ctx),
        .unary => |node| if (node.op == .logical_not) boolTypeExpr(expr.span) else exprStorageType(expr, ctx),
        else => exprStorageType(expr, ctx),
    };
}

fn boolTypeExpr(span: diagnostics.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = "bool", .span = span } } };
}

fn constGetMember(callee: ast.Expr) ?struct { base: *ast.Expr, name: ast.Ident } {
    return switch (callee.kind) {
        .member => |node| if (std.mem.eql(u8, node.name.text, "const_get")) .{ .base = node.base, .name = node.name } else null,
        .grouped => |inner| constGetMember(inner.*),
        else => null,
    };
}

const ConstGetInfo = struct {
    base: *ast.Expr,
    index: ?usize,
    len: usize,
    element_ty: ast.TypeExpr,
};

fn constGetInfo(call: anytype, ctx: Context) ?ConstGetInfo {
    const member = constGetMember(call.callee.*) orelse return null;
    const base_ty = exprResultType(member.base.*, ctx) orelse exprStorageType(member.base.*, ctx) orelse return null;
    const array = fixedArrayType(resolveAliasType(base_ty, ctx), ctx.const_fns, ctx.const_globals) orelse return null;
    return .{
        .base = member.base,
        .index = if (call.type_args.len == 1) constGetIndexArg(call.type_args[0]) else null,
        .len = array.len,
        .element_ty = array.child,
    };
}

fn constGetReturnType(call: anytype, ctx: Context) ?ast.TypeExpr {
    const info = constGetInfo(call, ctx) orelse return null;
    return info.element_ty;
}

const FixedArrayInfo = struct {
    len: usize,
    child: ast.TypeExpr,
};

fn fixedArrayType(ty: ast.TypeExpr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?FixedArrayInfo {
    return switch (ty.kind) {
        .array => |node| .{ .len = parseArrayLen(node.len, funcs, globals) orelse return null, .child = node.child.* },
        .qualified => |node| fixedArrayType(node.child.*, funcs, globals),
        else => null,
    };
}

fn constGetIndexArg(ty: ast.TypeExpr) ?usize {
    return switch (ty.kind) {
        .name => |name| parseUsizeLiteral(name.text),
        else => null,
    };
}

fn rawManyOffsetReturnType(call: anytype, ctx: Context) ?ast.TypeExpr {
    if (call.type_args.len != 0) return null;
    const member = switch (call.callee.kind) {
        .member => |node| node,
        .grouped => |inner| switch (inner.kind) {
            .member => |node| node,
            else => return null,
        },
        else => return null,
    };
    if (!std.mem.eql(u8, member.name.text, "offset")) return null;
    const base_ty = exprResultType(member.base.*, ctx) orelse return null;
    return if (isRawManyPointerTypeCtx(base_ty, ctx)) base_ty else null;
}

fn isRawManyPointerType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .raw_many_pointer => true,
        .qualified => |node| isRawManyPointerType(node.child.*),
        else => false,
    };
}

fn isRawManyPointerTypeCtx(ty: ast.TypeExpr, ctx: Context) bool {
    return isRawManyPointerType(resolveAliasType(ty, ctx));
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
    const layout_name = structTypeName(base_ty) orelse return null;
    const layout_info = layoutFieldInfo(layout_name, ctx) orelse return null;
    return layout_info.fields.get(field_name);
}

fn directCallReturnClass(callee: ast.Expr, ctx: Context) ?TypeClass {
    const function = directCallFunction(callee, ctx) orelse return null;
    const return_ty = function.return_ty orelse return .void;
    return classifyTypeCtx(return_ty, ctx);
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

// The type name of a type-parameter argument (a bare type-name ident).
fn typeArgName(arg: ast.Expr) ?[]const u8 {
    return switch (arg.kind) {
        .ident => |id| id.text,
        .grouped => |inner| typeArgName(inner.*),
        else => null,
    };
}

// The struct name a type expression directly names (a known struct/move type),
// or null if it isn't a plain named struct.
fn structNameOfType(ty: ast.TypeExpr, ctx: Context) ?[]const u8 {
    const structs = ctx.structs orelse return null;
    return switch (ty.kind) {
        .name => |n| if (structs.contains(n.text)) n.text else null,
        else => null,
    };
}

// The declared type of an expression usable for struct-name comparison: a local
// or global binding's type, or a direct call's return type.
fn exprDeclaredType(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| blk: {
            if (ctx.scope) |scope| {
                if (scope.get(ident.text)) |entry| break :blk entry.ty;
            }
            break :blk globalType(ident.text, ctx);
        },
        .call => |node| blk: {
            const name = directCallName(node.callee.*) orelse break :blk null;
            const fns = ctx.functions orelse break :blk null;
            const info = fns.get(name) orelse break :blk null;
            break :blk info.return_ty;
        },
        .member => |node| memberFieldType(node, ctx),
        .grouped => |inner| exprDeclaredType(inner.*, ctx),
        else => null,
    };
}

// If `callee` is a value of function-pointer type (a local, global, parameter, or
// struct field), return its signature type; otherwise null.
fn calleeFnPointerType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprDeclaredType(callee, ctx) orelse return null;
    const resolved = resolveAliasType(ty, ctx);
    return switch (resolved.kind) {
        .fn_pointer => resolved,
        else => null,
    };
}

// Does the named top-level function's signature match an expected `fn(...) -> R`
// type? Compared structurally, without allocating an intermediate type.
fn functionMatchesFnPointer(fn_name: []const u8, expected: ast.TypeExpr, ctx: Context) bool {
    const node = switch (resolveAliasType(expected, ctx).kind) {
        .fn_pointer => |n| n,
        else => return false,
    };
    const fns = ctx.functions orelse return false;
    const info = fns.get(fn_name) orelse return false;
    if (info.params.len != node.params.len) return false;
    for (info.params, node.params) |param, expected_param| {
        if (!sameTypeSyntaxCtx(param.ty, expected_param, ctx)) return false;
    }
    const void_ty = ast.TypeExpr{ .span = expected.span, .kind = .{ .name = .{ .text = "void", .span = expected.span } } };
    const ret_ty = info.return_ty orelse void_ty;
    return sameTypeSyntaxCtx(ret_ty, node.ret.*, ctx);
}

fn directCallName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| directCallName(inner.*),
        else => null,
    };
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
        .member => |node| localStorageRoot(node.base.*, ctx),
        .index => |node| indexedLocalArrayStorageRoot(node.base.*, ctx),
        .grouped => |inner| localStorageRoot(inner.*, ctx),
        else => null,
    };
}

fn indexedLocalArrayStorageRoot(expr: ast.Expr, ctx: Context) ?diagnostics.Span {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    if (!isArrayType(ty)) return null;
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = if (ctx.scope) |scope| scope.get(ident.text) else null;
            if (binding) |entry| {
                if (entry.origin == .local or entry.origin == .param) return expr.span;
            }
            return null;
        },
        .grouped => |inner| indexedLocalArrayStorageRoot(inner.*, ctx),
        else => localStorageRoot(expr, ctx),
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

fn pointerComparableTypes(left: ast.TypeExpr, right: ast.TypeExpr) bool {
    const left_view = viewType(left) orelse return false;
    const right_view = viewType(right) orelse return false;
    if (left_view.kind != right_view.kind) return false;
    const left_child = viewElementType(left) orelse return false;
    const right_child = viewElementType(right) orelse return false;
    return sameTypeSyntax(left_child, right_child);
}

fn pointerComparableTypesCtx(left: ast.TypeExpr, right: ast.TypeExpr, ctx: Context) bool {
    const resolved_left = resolveAliasType(left, ctx);
    const resolved_right = resolveAliasType(right, ctx);
    const left_view = viewType(resolved_left) orelse return false;
    const right_view = viewType(resolved_right) orelse return false;
    if (left_view.kind != right_view.kind) return false;
    const left_child = viewElementType(resolved_left) orelse return false;
    const right_child = viewElementType(resolved_right) orelse return false;
    return sameTypeSyntaxCtx(left_child, right_child, ctx);
}

fn viewElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        .slice => |node| node.child.*,
        .nullable => |child| viewElementType(child.*),
        .qualified => |node| viewElementType(node.child.*),
        else => null,
    };
}

fn implicitPointerViewConversion(target: ast.TypeExpr, source: ast.TypeExpr) bool {
    _ = viewType(target) orelse return false;
    _ = viewType(source) orelse return false;
    if (nullablePointerWidening(target, source)) return false;
    const target_is_c_void = isCVoidPointerClass(classifyType(target));
    const source_is_c_void = isCVoidPointerClass(classifyType(source));
    if (target_is_c_void != source_is_c_void) return false;
    return !sameTypeSyntax(target, source);
}

fn implicitPointerViewConversionCtx(target: ast.TypeExpr, source: ast.TypeExpr, ctx: Context) bool {
    const resolved_target = resolveAliasType(target, ctx);
    const resolved_source = resolveAliasType(source, ctx);
    _ = viewType(resolved_target) orelse return false;
    _ = viewType(resolved_source) orelse return false;
    if (nullablePointerWideningCtx(resolved_target, resolved_source, ctx)) return false;
    const target_is_c_void = isCVoidPointerClass(classifyTypeCtx(resolved_target, ctx));
    const source_is_c_void = isCVoidPointerClass(classifyTypeCtx(resolved_source, ctx));
    if (target_is_c_void != source_is_c_void) return false;
    return !sameTypeSyntaxCtx(resolved_target, resolved_source, ctx);
}

fn nullablePointerWidening(target: ast.TypeExpr, source: ast.TypeExpr) bool {
    const target_view = viewType(target) orelse return false;
    const source_view = viewType(source) orelse return false;
    if (!target_view.nullable or source_view.nullable) return false;
    if (target_view.kind != source_view.kind or target_view.mutability != source_view.mutability) return false;
    const target_child = nullableInnerType(target) orelse return false;
    return sameTypeSyntax(target_child, source);
}

fn nullablePointerWideningCtx(target: ast.TypeExpr, source: ast.TypeExpr, ctx: Context) bool {
    const resolved_target = resolveAliasType(target, ctx);
    const resolved_source = resolveAliasType(source, ctx);
    const target_view = viewType(resolved_target) orelse return false;
    const source_view = viewType(resolved_source) orelse return false;
    if (!target_view.nullable or source_view.nullable) return false;
    if (target_view.kind != source_view.kind or target_view.mutability != source_view.mutability) return false;
    const target_child = nullableInnerType(resolved_target) orelse return false;
    return sameTypeSyntaxCtx(target_child, resolved_source, ctx);
}

fn implicitCVoidPointerConversion(target: ast.TypeExpr, source: ast.TypeExpr) bool {
    _ = viewType(target) orelse return false;
    _ = viewType(source) orelse return false;
    const target_is_c_void = isCVoidPointerClass(classifyType(target));
    const source_is_c_void = isCVoidPointerClass(classifyType(source));
    return target_is_c_void != source_is_c_void;
}

fn implicitCVoidPointerConversionCtx(target: ast.TypeExpr, source: ast.TypeExpr, ctx: Context) bool {
    const resolved_target = resolveAliasType(target, ctx);
    const resolved_source = resolveAliasType(source, ctx);
    _ = viewType(resolved_target) orelse return false;
    _ = viewType(resolved_source) orelse return false;
    const target_is_c_void = isCVoidPointerClass(classifyTypeCtx(resolved_target, ctx));
    const source_is_c_void = isCVoidPointerClass(classifyTypeCtx(resolved_source, ctx));
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
        .fn_pointer => |left_node| blk: {
            const right_node = switch (right.kind) {
                .fn_pointer => |node| node,
                else => unreachable,
            };
            if (left_node.params.len != right_node.params.len) break :blk false;
            for (left_node.params, right_node.params) |left_param, right_param| {
                if (!sameTypeSyntax(left_param, right_param)) break :blk false;
            }
            break :blk sameTypeSyntax(left_node.ret.*, right_node.ret.*);
        },
        .closure_type => |left_node| blk: {
            const right_node = switch (right.kind) {
                .closure_type => |node| node,
                else => unreachable,
            };
            if (left_node.params.len != right_node.params.len) break :blk false;
            for (left_node.params, right_node.params) |left_param, right_param| {
                if (!sameTypeSyntax(left_param, right_param)) break :blk false;
            }
            break :blk sameTypeSyntax(left_node.ret.*, right_node.ret.*);
        },
    };
}

fn sameTypeSyntaxCtx(left: ast.TypeExpr, right: ast.TypeExpr, ctx: Context) bool {
    return sameTypeSyntax(resolveAliasType(left, ctx), resolveAliasType(right, ctx));
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

fn mmioFieldInfoFromType(ty: ast.TypeExpr) ?MmioFieldInfo {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    const access_arg: ast.TypeExpr = if (std.mem.eql(u8, generic.base.text, "Reg") and generic.args.len == 2)
        generic.args[1]
    else if (std.mem.eql(u8, generic.base.text, "RegBits") and generic.args.len == 3)
        generic.args[2]
    else
        return null;
    const access = mmioRegisterAccessFromType(access_arg) orelse return null;
    return .{ .access = access };
}

fn mmioRegisterAccessFromType(ty: ast.TypeExpr) ?MmioRegisterAccess {
    const name = switch (ty.kind) {
        .enum_literal => |literal| literal.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "write")) return .write;
    if (std.mem.eql(u8, name, "read_write")) return .read_write;
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

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

fn simpleNameType(name: []const u8, span: diagnostics.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = name, .span = span } } };
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
            if (isIdentNamed(node.base.*, "raw") and (std.mem.eql(u8, node.name.text, "store") or std.mem.eql(u8, node.name.text, "load"))) return true;
            // raw.ptr mints a typed pointer from an address (like phys() makes a PAddr);
            // it needs no unsafe block — dereferencing the result is the checked part.
            if (isIdentNamed(node.base.*, "mmio") and std.mem.eql(u8, node.name.text, "map")) return true;
            return false;
        },
        .grouped => |inner| isUnsafeOperationCall(inner.*),
        else => false,
    };
}

fn isBuiltinNamespaceMember(member: anytype) bool {
    const base = switch (member.base.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident.text,
            else => return false,
        },
        else => return false,
    };
    if (std.mem.eql(u8, base, "raw")) return std.mem.eql(u8, member.name.text, "store") or std.mem.eql(u8, member.name.text, "load") or std.mem.eql(u8, member.name.text, "ptr");
    if (std.mem.eql(u8, base, "fence")) return std.mem.eql(u8, member.name.text, "full") or std.mem.eql(u8, member.name.text, "acquire") or std.mem.eql(u8, member.name.text, "release");
    if (std.mem.eql(u8, base, "mmio")) return std.mem.eql(u8, member.name.text, "map");
    if (std.mem.eql(u8, base, "unchecked")) return isUncheckedNoOverflowMember(member.name.text);
    if (std.mem.eql(u8, base, "wrapping")) return std.mem.eql(u8, member.name.text, "add");
    if (std.mem.eql(u8, base, "reduce")) return std.mem.eql(u8, member.name.text, "sum_checked");
    if (std.mem.eql(u8, base, "compiler")) return std.mem.eql(u8, member.name.text, "assume_noalias_unchecked");
    if (std.mem.eql(u8, base, "cpu")) return std.mem.eql(u8, member.name.text, "pause");
    if (std.mem.eql(u8, base, "atomic")) return std.mem.eql(u8, member.name.text, "init");
    if (std.mem.eql(u8, base, "cache")) return std.mem.eql(u8, member.name.text, "clean") or std.mem.eql(u8, member.name.text, "invalidate");
    if (std.mem.eql(u8, base, "lock")) return std.mem.eql(u8, member.name.text, "acquire");
    if (std.mem.eql(u8, base, "heap")) return std.mem.eql(u8, member.name.text, "alloc");
    if (std.mem.eql(u8, base, "device")) return std.mem.eql(u8, member.name.text, "wait_irq");
    if (std.mem.eql(u8, base, "fs")) return std.mem.eql(u8, member.name.text, "read");
    return false;
}

fn isUncheckedNoOverflowMember(name: []const u8) bool {
    return std.mem.eql(u8, name, "add") or
        std.mem.eql(u8, name, "sub") or
        std.mem.eql(u8, name, "mul");
}

fn isBuiltinFunctionName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "trap")) return true;
    if (std.mem.eql(u8, name, "drop")) return true;
    if (std.mem.eql(u8, name, "bind")) return true; // closure construction
    if (std.mem.eql(u8, name, "unwrap")) return true;
    if (std.mem.eql(u8, name, "bitcast")) return true;
    if (std.mem.eql(u8, name, "phys")) return true;
    if (std.mem.eql(u8, name, "ok")) return true;
    if (std.mem.eql(u8, name, "err")) return true;
    if (std.mem.eql(u8, name, "size_of")) return true;
    if (std.mem.eql(u8, name, "sizeof")) return true;
    if (std.mem.eql(u8, name, "alignof")) return true;
    if (std.mem.eql(u8, name, "field_offset")) return true;
    if (std.mem.eql(u8, name, "field_type")) return true;
    if (std.mem.eql(u8, name, "bit_offset")) return true;
    if (std.mem.eql(u8, name, "repr_of")) return true;
    return false;
}

fn isBitcastCallName(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "bitcast"),
        .grouped => |inner| isBitcastCallName(inner.*),
        else => false,
    };
}

fn isComptimeForbiddenCall(callee: ast.Expr) bool {
    return isUnsafeOperationCall(callee) or isCpuPauseCall(callee) or isFenceCall(callee);
}

fn isFenceCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| isIdentNamed(node.base.*, "fence") and
            (std.mem.eql(u8, node.name.text, "full") or std.mem.eql(u8, node.name.text, "acquire") or std.mem.eql(u8, node.name.text, "release")),
        .grouped => |inner| isFenceCall(inner.*),
        else => false,
    };
}

fn isCpuPauseCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| isIdentNamed(node.base.*, "cpu") and std.mem.eql(u8, node.name.text, "pause"),
        .grouped => |inner| isCpuPauseCall(inner.*),
        else => false,
    };
}

const ReflectionKind = enum {
    size,
    alignment,
    field_offset,
    field_type,
    bit_offset,
    repr,
};

const ReflectionTarget = struct {
    ty: ast.TypeExpr,
    args: []const ast.Expr,
};

fn reflectionKind(callee: ast.Expr) ?ReflectionKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            if (std.mem.eql(u8, ident.text, "field_type")) return .field_type;
            if (std.mem.eql(u8, ident.text, "bit_offset")) return .bit_offset;
            if (std.mem.eql(u8, ident.text, "repr_of")) return .repr;
            return null;
        },
        .grouped => |inner| return reflectionKind(inner.*),
        else => null,
    };
}

fn reflectionTypeExprFromArg(expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| .{ .span = ident.span, .kind = .{ .name = ident } },
        .grouped => |inner| reflectionTypeExprFromArg(inner.*),
        else => null,
    };
}

// Type registries used by the comptime reflection layout model.
const ReflectEnv = struct {
    structs: *const std.StringHashMap(StructInfo),
    enums: *const std.StringHashMap(EnumInfo),
    aliases: *const std.StringHashMap(ast.TypeExpr),
};

const ScalarLayout = struct { size: u32, alignment: u32 };

// Sizes/alignments that are identical across the supported LP64 C ABIs, so a
// comptime fold agrees with clang's runtime `sizeof`/`alignof`.
fn scalarLayout(name: []const u8) ?ScalarLayout {
    const table = [_]struct { n: []const u8, s: u32 }{
        .{ .n = "u8", .s = 1 },   .{ .n = "i8", .s = 1 },   .{ .n = "bool", .s = 1 },
        .{ .n = "u16", .s = 2 },  .{ .n = "i16", .s = 2 },
        .{ .n = "u32", .s = 4 },  .{ .n = "i32", .s = 4 },  .{ .n = "f32", .s = 4 },
        .{ .n = "u64", .s = 8 },  .{ .n = "i64", .s = 8 },  .{ .n = "f64", .s = 8 },
        .{ .n = "usize", .s = 8 }, .{ .n = "isize", .s = 8 },
        // Opaque address classes lower to pointer-width integers.
        .{ .n = "PAddr", .s = 8 }, .{ .n = "VAddr", .s = 8 }, .{ .n = "DmaAddr", .s = 8 },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e.n)) return .{ .size = e.s, .alignment = e.s };
    }
    return null;
}

fn isPointerLikeGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "MmioPtr") or std.mem.eql(u8, name, "UserPtr");
}

// Extract the reflected type from a reflection call's `type_args` or first arg.
fn reflectionTypeFromCall(node: anytype) ?ast.TypeExpr {
    if (node.type_args.len == 1) return node.type_args[0];
    if (node.args.len >= 1) return reflectionTypeExprFromArg(node.args[0]);
    return null;
}

fn reflectionRequiresField(kind: ReflectionKind) bool {
    return switch (kind) {
        .field_offset, .field_type, .bit_offset => true,
        .size, .alignment, .repr => false,
    };
}

fn reflectionReturnClass(kind: ReflectionKind) TypeClass {
    return switch (kind) {
        .size, .alignment, .field_offset, .bit_offset => .checked_usize,
        .field_type, .repr => .unknown,
    };
}

fn isKnownLayoutType(ty: ast.TypeExpr, ctx: Context) bool {
    return switch (ty.kind) {
        .name => |name| isPrimitiveLayoutType(name.text) or
            knownStructName(name.text, ctx) or
            knownPackedBitsName(name.text, ctx) or
            knownOverlayUnionName(name.text, ctx) or
            knownTaggedUnionName(name.text, ctx) or
            knownEnumName(name.text, ctx) or
            // A `comptime T: type` parameter is layout-capable once monomorphized;
            // `sizeof(T)`/`alignof(T)` in a generic body resolve per instantiation.
            (if (ctx.type_params) |tp| tp.contains(name.text) else false),
        .pointer, .raw_many_pointer, .slice, .array, .nullable => true,
        .fn_pointer => true, // a function pointer has pointer layout
        .closure_type => true, // a closure is a fixed {code, env} aggregate
        .qualified => |node| isKnownLayoutType(node.child.*, ctx),
        .generic => |node| isKnownLayoutGeneric(node, ctx),
        .member, .enum_literal => false,
    };
}

fn isPrimitiveLayoutType(name: []const u8) bool {
    return classifyTypeName(name) != .unknown;
}

fn isKnownTypeName(name: []const u8, ctx: Context) bool {
    if (classifyTypeName(name) != .unknown) return true;
    if (std.mem.eql(u8, name, "Error")) return true;
    if (std.mem.eql(u8, name, "AmbiguousSerialOrder")) return true;
    if (std.mem.eql(u8, name, "AmbiguousCounterInterval")) return true;
    if (std.mem.eql(u8, name, "ConversionError")) return true;
    if (std.mem.eql(u8, name, "Overflow")) return true;
    // `type` is the meta-type of a `comptime T: type` parameter; `T` and friends
    // are valid type names inside the generic function (section 22).
    if (std.mem.eql(u8, name, "type")) return true;
    if (ctx.type_params) |tps| {
        if (tps.contains(name)) return true;
    }
    // IrqOff (§19.1): a capability type witnessing that interrupts are disabled.
    // A function requiring a disabled-interrupt critical section takes a
    // `cs: IrqOff` parameter, so the operation cannot be written without one.
    if (std.mem.eql(u8, name, "IrqOff")) return true;
    if (std.mem.eql(u8, name, "c_void")) return true;
    if (knownStructName(name, ctx)) return true;
    if (knownPackedBitsName(name, ctx)) return true;
    if (knownOverlayUnionName(name, ctx)) return true;
    if (knownTaggedUnionName(name, ctx)) return true;
    if (knownEnumName(name, ctx)) return true;
    if (ctx.type_aliases) |type_aliases| {
        if (type_aliases.contains(name)) return true;
    }
    return false;
}

fn isKnownGenericTypeName(name: []const u8) bool {
    if (classifyGenericTypeName(name) != .unknown) return true;
    if (std.mem.eql(u8, name, "Reg")) return true;
    if (std.mem.eql(u8, name, "RegBits")) return true;
    if (std.mem.eql(u8, name, "DmaBuf")) return true;
    if (std.mem.eql(u8, name, "MaybeUninit")) return true;
    if (std.mem.eql(u8, name, "atomic")) return true;
    return false;
}

fn isArithmeticDomainTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter");
}

fn genericHasStoragePayload(name: []const u8) bool {
    return std.mem.eql(u8, name, "MaybeUninit") or
        std.mem.eql(u8, name, "atomic") or
        std.mem.eql(u8, name, "UserPtr") or
        std.mem.eql(u8, name, "MmioPtr") or
        std.mem.eql(u8, name, "PhysPtr") or
        std.mem.eql(u8, name, "DmaBuf");
}

fn isFixedUnsignedMmioWidth(ty: ast.TypeExpr) bool {
    const name = typeName(ty) orelse return false;
    return std.mem.eql(u8, name, "u8") or
        std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or
        std.mem.eql(u8, name, "u64");
}

fn isPackedBitsTypeName(ty: ast.TypeExpr, ctx: Context) bool {
    const name = typeName(ty) orelse return false;
    return knownPackedBitsName(name, ctx);
}

fn isMmioAccessMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "read") or
        std.mem.eql(u8, mode, "write") or
        std.mem.eql(u8, mode, "read_write");
}

fn isDmaBufMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "coherent") or
        std.mem.eql(u8, mode, "noncoherent");
}

fn knownMmioStructName(name: []const u8, ctx: Context) bool {
    const mmio_structs = ctx.mmio_structs orelse return false;
    return mmio_structs.contains(name);
}

fn knownStructName(name: []const u8, ctx: Context) bool {
    const structs = ctx.structs orelse return false;
    return structs.contains(name);
}

fn knownPackedBitsName(name: []const u8, ctx: Context) bool {
    const packed_bits = ctx.packed_bits orelse return false;
    return packed_bits.contains(name);
}

fn packedBitsInfoForType(ty: ast.TypeExpr, ctx: Context) ?LayoutFieldInfo {
    const name = typeName(ty) orelse return null;
    const packed_bits = ctx.packed_bits orelse return null;
    return packed_bits.get(name);
}

fn knownOverlayUnionName(name: []const u8, ctx: Context) bool {
    const overlay_unions = ctx.overlay_unions orelse return false;
    return overlay_unions.contains(name);
}

fn knownTaggedUnionName(name: []const u8, ctx: Context) bool {
    const tagged_unions = ctx.tagged_unions orelse return false;
    return tagged_unions.contains(name);
}

fn layoutFieldInfo(name: []const u8, ctx: Context) ?LayoutFieldInfo {
    if (ctx.structs) |structs| {
        if (structs.get(name)) |info| return .{ .fields = info.fields };
    }
    if (ctx.packed_bits) |packed_bits| {
        if (packed_bits.get(name)) |info| return info;
    }
    if (ctx.overlay_unions) |overlay_unions| {
        if (overlay_unions.get(name)) |info| return info;
    }
    return null;
}

fn knownEnumName(name: []const u8, ctx: Context) bool {
    const enums = ctx.enums orelse return false;
    return enums.contains(name);
}

fn isKnownLayoutGeneric(node: anytype, ctx: Context) bool {
    const expected = genericTypeExpectedArgs(node.base.text) orelse return false;
    if (node.args.len != expected) return false;
    for (node.args) |arg| {
        if (arg.kind == .enum_literal) continue;
        if (!isKnownLayoutType(arg, ctx)) return false;
    }
    return true;
}

fn reflectionGenericHasWrongArity(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| if (genericTypeExpectedArgs(node.base.text)) |expected| node.args.len != expected else false,
        .qualified => |node| reflectionGenericHasWrongArity(node.child.*),
        else => false,
    };
}

fn genericTypeExpectedArgs(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "Reg")) return 2;
    if (std.mem.eql(u8, name, "RegBits")) return 3;
    if (std.mem.eql(u8, name, "MmioPtr")) return 1;
    if (std.mem.eql(u8, name, "UserPtr")) return 1;
    if (std.mem.eql(u8, name, "PhysPtr")) return 1;
    if (std.mem.eql(u8, name, "DmaBuf")) return 2;
    if (std.mem.eql(u8, name, "MaybeUninit")) return 1;
    if (std.mem.eql(u8, name, "atomic")) return 1;
    if (std.mem.eql(u8, name, "Result")) return 2;
    if (std.mem.eql(u8, name, "wrap")) return 1;
    if (std.mem.eql(u8, name, "sat")) return 1;
    if (std.mem.eql(u8, name, "serial")) return 1;
    if (std.mem.eql(u8, name, "counter")) return 1;
    if (std.mem.eql(u8, name, "Duration")) return 1;
    return null;
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

fn isDropCall(callee: ast.Expr) bool {
    return isIdentNamed(callee, "drop");
}

// `trap_from` is the only conversion builtin that raises a language (range) trap;
// the other conversions/domain ops are pure casts/clamps/Result and never trap.
fn isTrappingConversionCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| std.mem.eql(u8, node.name.text, "trap_from"),
        .grouped => |inner| isTrappingConversionCall(inner.*),
        else => false,
    };
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
        .block, .unsafe_block, .comptime_block => |block| fallthroughSpan(block, ctx) != null,
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
    var has_bool_true = false;
    var has_bool_false = false;
    const subject_is_result = if (exprResultType(node.subject, ctx)) |ty| classifyTypeCtx(ty, ctx) == .result else false;
    const subject_is_bool = if (exprResultType(node.subject, ctx)) |ty| classifyTypeCtx(ty, ctx) == .bool else false;
    const closed_enum = if (exprResultType(node.subject, ctx)) |ty| closedEnumInfoForType(ty, ctx) else null;
    const tagged_union = if (exprResultType(node.subject, ctx)) |ty| unionInfoForType(ty, ctx) else null;
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
                .literal => {
                    if (subject_is_bool) {
                        if (switchBoolLiteralValue(pattern)) |value| {
                            if (value) {
                                has_bool_true = true;
                            } else {
                                has_bool_false = true;
                            }
                        }
                    }
                },
                .bind => {},
            }
        }
        if (switchBodyMayFallThrough(arm.body, ctx)) return true;
    }
    if (closed_enum) |enum_info| {
        return !has_wildcard and !switchCoversAllEnumCases(node, enum_info);
    }
    if (tagged_union) |union_info| {
        return !has_wildcard and !switchCoversAllUnionCases(node, union_info);
    }
    if (subject_is_bool) {
        return !has_wildcard and !(has_bool_true and has_bool_false);
    }
    return !has_wildcard and !(has_result_ok and has_result_err);
}

fn switchBoolLiteralValue(pattern: ast.Pattern) ?bool {
    return switch (pattern.kind) {
        .literal => |expr| boolLiteralValue(expr),
        else => null,
    };
}

fn boolLiteralValue(expr: ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_literal => |value| value,
        .grouped => |inner| boolLiteralValue(inner.*),
        else => null,
    };
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

fn switchCoversAllUnionCases(node: ast.Switch, union_info: UnionInfo) bool {
    var cases = union_info.cases.keyIterator();
    while (cases.next()) |case_name| {
        if (!switchCoversUnionCase(node, case_name.*)) return false;
    }
    return true;
}

fn switchCoversUnionCase(switch_node: ast.Switch, case_name: []const u8) bool {
    for (switch_node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .tag => |tag| if (std.mem.eql(u8, tag.text, case_name)) return true,
                .tag_bind => |tag_bind| if (std.mem.eql(u8, tag_bind.tag.text, case_name)) return true,
                .wildcard => return true,
                .literal, .bind => {},
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
        .unsafe_block, .comptime_block, .block => |block| blockContainsTry(block),
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

fn resultLocalHandledLater(name: []const u8, stmts: []const ast.Stmt) bool {
    for (stmts) |stmt| {
        if (stmtHandlesResultLocal(name, stmt)) return true;
    }
    return false;
}

fn resultLocalHasPendingValueBefore(name: []const u8, stmts: []const ast.Stmt, ctx: Context) bool {
    var pending = false;
    for (stmts) |stmt| {
        if (stmtHandlesResultLocal(name, stmt)) {
            pending = false;
            continue;
        }
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                if (!localDeclaresName(local, name)) continue;
                const local_ty = local.ty orelse if (local.init) |expr| exprResultType(expr, ctx) else null;
                const ty = local_ty orelse continue;
                if (classifyTypeCtx(ty, ctx) == .result and local.init != null) pending = true;
            },
            .assignment => |assignment| {
                if (!exprIsIdentNamed(assignment.target, name)) continue;
                const value_ty = exprResultType(assignment.value, ctx) orelse continue;
                pending = classifyTypeCtx(value_ty, ctx) == .result;
            },
            else => {},
        }
    }
    return pending;
}

fn assignmentResultLocalName(target: ast.Expr, ctx: Context) ?ast.Ident {
    return switch (target.kind) {
        .ident => |ident| {
            const scope = ctx.scope orelse return null;
            const binding = scope.get(ident.text) orelse return null;
            if (binding.origin != .local or !binding.mutable) return null;
            const ty = binding.ty orelse return null;
            if (classifyTypeCtx(ty, ctx) != .result) return null;
            return ident;
        },
        .grouped => |inner| assignmentResultLocalName(inner.*, ctx),
        else => null,
    };
}

fn localDeclaresName(local: ast.LocalDecl, name: []const u8) bool {
    for (local.names) |ident| {
        if (std.mem.eql(u8, ident.text, name)) return true;
    }
    return false;
}

fn stmtHandlesResultLocal(name: []const u8, stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .let_decl, .var_decl => |local| if (local.init) |expr| exprHandlesResultLocal(name, expr) else false,
        .loop => |node| if (node.iterable) |iterable| exprHandlesResultLocal(name, iterable) else false,
        .if_let => |node| resultIfLetHandlesLocal(name, node) or exprHandlesResultLocal(name, node.value),
        .@"switch" => |node| resultSwitchHandlesLocal(name, node) or exprHandlesResultLocal(name, node.subject),
        .unsafe_block, .comptime_block, .block => |block| blockHandlesResultLocal(name, block),
        .contract_block => |contract| blockHandlesResultLocal(name, contract.block),
        .@"return" => |maybe| if (maybe) |expr| exprHandlesResultLocal(name, expr) else false,
        .@"break", .@"continue", .asm_stmt => false,
        .@"defer", .expr, .assert => |expr| exprHandlesResultLocal(name, expr),
        .assignment => |node| exprHandlesResultLocal(name, node.target) or exprHandlesResultLocal(name, node.value),
    };
}

fn blockHandlesResultLocal(name: []const u8, block: ast.Block) bool {
    for (block.items) |stmt| {
        if (stmtHandlesResultLocal(name, stmt)) return true;
    }
    return false;
}

fn stmtTerminatesNormally(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .@"return", .@"break", .@"continue", .asm_stmt => true,
        .expr => |expr| exprTerminatesNormally(expr),
        .block, .unsafe_block, .comptime_block => |block| blockTerminatesNormally(block),
        .contract_block => |contract| blockTerminatesNormally(contract.block),
        .if_let => |node| node.else_block != null and
            blockTerminatesNormally(node.then_block) and
            blockTerminatesNormally(node.else_block.?),
        .@"switch" => |node| switchTerminatesNormally(node),
        else => false,
    };
}

fn blockTerminatesNormally(block: ast.Block) bool {
    for (block.items) |stmt| {
        if (stmtTerminatesNormally(stmt)) return true;
    }
    return false;
}

fn switchTerminatesNormally(node: ast.Switch) bool {
    var has_wildcard = false;
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            if (pattern.kind == .wildcard) has_wildcard = true;
        }
        const body_terminates = switch (arm.body) {
            .block => |block| blockTerminatesNormally(block),
            .expr => |expr| exprTerminatesNormally(expr),
        };
        if (!body_terminates) return false;
    }
    return has_wildcard;
}

fn exprTerminatesNormally(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unreachable_expr => true,
        .grouped => |inner| exprTerminatesNormally(inner.*),
        .call => |node| isTrapCall(node.callee.*),
        .block => |block| blockTerminatesNormally(block),
        else => false,
    };
}

fn resultIfLetHandlesLocal(name: []const u8, node: ast.IfLet) bool {
    if (node.else_block == null or !exprIsIdentNamed(node.value, name)) return false;
    return switch (node.pattern.kind) {
        .tag_bind => |tag_bind| isResultNarrowingTag(tag_bind.tag.text),
        else => false,
    };
}

fn resultSwitchHandlesLocal(name: []const u8, node: ast.Switch) bool {
    if (!exprIsIdentNamed(node.subject, name)) return false;
    var has_wildcard = false;
    var has_ok = false;
    var has_err = false;
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .wildcard => has_wildcard = true,
                .tag => |tag| {
                    if (std.mem.eql(u8, tag.text, "ok")) has_ok = true;
                    if (std.mem.eql(u8, tag.text, "err")) has_err = true;
                },
                .tag_bind => |tag_bind| {
                    if (std.mem.eql(u8, tag_bind.tag.text, "ok")) has_ok = true;
                    if (std.mem.eql(u8, tag_bind.tag.text, "err")) has_err = true;
                },
                .literal, .bind => {},
            }
        }
    }
    return has_wildcard or (has_ok and has_err);
}

fn exprHandlesResultLocal(name: []const u8, expr: ast.Expr) bool {
    return switch (expr.kind) {
        .try_expr => |inner| exprIsIdentNamed(inner.operand.*, name) or exprHandlesResultLocal(name, inner.operand.*),
        .grouped, .address_of, .deref => |inner| exprHandlesResultLocal(name, inner.*),
        .block => |block| blockHandlesResultLocal(name, block),
        .unary => |node| exprHandlesResultLocal(name, node.expr.*),
        .binary => |node| exprHandlesResultLocal(name, node.left.*) or exprHandlesResultLocal(name, node.right.*),
        .cast => |node| exprHandlesResultLocal(name, node.value.*),
        .call => |node| callHandlesResultLocal(name, node),
        .index => |node| exprHandlesResultLocal(name, node.base.*) or exprHandlesResultLocal(name, node.index.*),
        .member => |node| exprHandlesResultLocal(name, node.base.*),
        else => false,
    };
}

fn callHandlesResultLocal(name: []const u8, node: anytype) bool {
    if (exprHandlesResultLocal(name, node.callee.*)) return true;
    for (node.args) |arg| {
        if (exprHandlesResultLocal(name, arg)) return true;
    }
    return false;
}

fn exprIsIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| exprIsIdentNamed(inner.*, name),
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
        .unsafe_block, .comptime_block, .block => |block| blockContainsDeferControlFlow(block, ctx),
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
        else => if (exprResultType(expr, ctx)) |ty| classifyTypeCtx(ty, ctx) == .never else false,
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

test "rejects nested MMIO register field assignment" {
    const source =
        \\packed bits UartLsr: u8 {
        \\    data_ready: bool,
        \\    tx_empty: bool,
        \\}
        \\
        \\extern mmio struct Uart16550 {
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn set_lsr(uart: MmioPtr<Uart16550>, flag: bool) -> void {
        \\    uart.lsr.tx_empty = flag;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nested_mmio_register_field_assignment.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var checker = Checker.init(&reporter);
    checker.checkModule(module);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_MMIO_DIRECT_ASSIGN"));
}

test "type checks packed bits fields as bool" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\fn read_ready(status: Status) -> bool {
        \\    return status.ready;
        \\}
        \\
        \\fn write_ready(status: Status, flag: bool) -> Status {
        \\    var next: Status = status;
        \\    next.ready = flag;
        \\    return next;
        \\}
        \\
        \\fn reject_read_ready_as_u32(status: Status) -> u32 {
        \\    return status.ready;
        \\}
        \\
        \\fn reject_unknown(status: Status) -> bool {
        \\    return status.missing;
        \\}
        \\
        \\fn reject_write_u32(status: Status, value: u32) -> Status {
        \\    var next: Status = status;
        \\    next.ready = value;
        \\    return next;
        \\}
        \\
        \\fn reject_write_literal(status: Status) -> Status {
        \\    var next: Status = status;
        \\    next.ready = 1;
        \\    return next;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "packed_bits_field_typing.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var checker = Checker.init(&reporter);
    checker.checkModule(module);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_RETURN_TYPE_MISMATCH"));
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_UNKNOWN_STRUCT_FIELD"));
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_NO_IMPLICIT_CONVERSION"));
}

test "const_get requires in-bounds fixed array index" {
    const source =
        \\fn accept(xs: [2]u32) -> u32 {
        \\    return xs.const_get<1>();
        \\}
        \\
        \\fn reject_oob(xs: [2]u32) -> u32 {
        \\    return xs.const_get<2>();
        \\}
        \\
        \\fn reject_base(xs: []const u32) -> u32 {
        \\    return xs.const_get<0>();
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "const_get.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var checker = Checker.init(&reporter);
    checker.checkModule(module);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_CONST_GET_BOUNDS"));
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_CONST_GET_BASE"));
    try std.testing.expect(!hasDiagnosticCode(&reporter, "E_UNKNOWN_FUNCTION"));
}

fn hasDiagnosticCode(reporter: *const diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, code) != null) return true;
    }
    return false;
}
