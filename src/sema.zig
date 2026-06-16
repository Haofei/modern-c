const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const diagnostics = @import("diagnostics.zig");
const type_layout = @import("layout.zig");
const numeric = @import("numeric.zig");
const parser = @import("parser.zig");
const eval = @import("eval.zig");

// Scalar type layout shared across the passes (see `layout.zig`).
const scalarLayout = type_layout.scalarLayout;

// Pure AST-shape queries shared with `mir.zig`/`lower_c.zig` (see `ast_query.zig`). The shared
// `isIdentNamed` is grouping-transparent (was not, here, before consolidation).
const isIdentNamed = ast_query.isIdentNamed;
const MmioRegisterAccess = ast_query.MmioRegisterAccess;
const mmioRegisterAccessFromModeType = ast_query.mmioRegisterAccessFromModeType;
const simpleNameType = ast_query.simpleNameType;
const isMmioMapCallName = ast_query.isMmioMapCallName;
const mmioMapCallPayloadType = ast_query.mmioMapCallPayloadType;
const exprIsIdentNamed = ast_query.exprIsIdentNamed;
const isResultNarrowingTag = ast_query.isResultNarrowingTag;
const localDeclaresName = ast_query.localDeclaresName;
const resultIfLetHandlesLocal = ast_query.resultIfLetHandlesLocal;
const resultSwitchHandlesLocal = ast_query.resultSwitchHandlesLocal;
const boolLiteralValue = ast_query.boolLiteralValue;
const isUninitLiteral = ast_query.isUninitLiteral;
const typeName = ast_query.typeName;
const isRawManyPointerType = ast_query.isRawManyPointerType;
const isPointerLikeGeneric = ast_query.isPointerLikeGeneric;
const isArithmeticLayoutGeneric = ast_query.isArithmeticLayoutGeneric;
const mmioPointee = ast_query.mmioPointee;
const reduceCallKind = ast_query.reduceCallKind;
const constU8SliceType = ast_query.constU8SliceType;
const byteViewCallKind = ast_query.byteViewCallKind;
const DmaBufInfo = ast_query.DmaBufInfo;
const dmaBufInfo = ast_query.dmaBufInfo;

// Numeric-literal and integer-bounds primitives shared with `mir.zig` and `lower_c.zig`
// (see `numeric.zig`); aliased here so the existing call sites read unchanged.
const LiteralValue = numeric.LiteralValue;
const IntBounds = numeric.IntBounds;
const maxUnsigned = numeric.maxUnsigned;
const signedBounds = numeric.signedBounds;
const parseUsizeLiteral = numeric.parseUsizeLiteral;
const parseCharLiteral = numeric.parseCharLiteral;
const integerLiteralValue = numeric.integerLiteralValue;
const alignForward = numeric.alignForward;

pub const Checker = struct {
    reporter: *diagnostics.Reporter,
    // Set when building a symbol table runs out of memory. Surfaced as a fatal
    // diagnostic so an incomplete table never silently passes checking.
    oom: bool = false,
    // Names that own a qualified namespace (`module`/`impl`); a local binding may not shadow
    // one, or `Owner.member` access would silently bind to the qualified symbol instead of the
    // local. Set for the duration of checkModule.
    qualified_owners: [][]const u8 = &.{},
    // The (possibly mangled) name of the function currently being checked, used to
    // decide whether code may name an `opaque struct`'s private fields: only the
    // struct's own associated functions (`Struct__member`, from `impl Struct`) may.
    // Null at module scope (globals/initializers), where no private field is in reach.
    current_fn_name: ?[]const u8 = null,
    // Fact-gated MIR optimizer toggle (annex E), set by the caller for `verify --optimize`.
    // When on, a provably-in-range constant index is treated as non-trapping so it is
    // allowed inside `#[no_lang_trap]` (mirrors the MIR-level bounds-check elision). Off by
    // default, so `check` and the standard pipeline are unchanged.
    optimize: bool = false,
    // Registry of `const fn` declarations, populated for the duration of
    // checkModule so comptime folding can evaluate const-fn calls (section 22).
    const_fns: ?*const std.StringHashMap(ast.FnDecl) = null,
    // Folded values of `const NAME: T = …` globals (section 22), so comptime
    // folding can resolve named compile-time constants.
    const_globals: ?*const std.StringHashMap(eval.ComptimeValue) = null,
    // Declared integer widths of named const globals, used by width-sensitive
    // comptime folds such as `~CONST_U32`.
    const_global_widths: ?*const std.StringHashMap(u16) = null,
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
    // A stack of "names live at loop entry", one frame per enclosing loop, maintained
    // during the move pass. A `break`/`continue` exits the current iteration, so any
    // loop-body-local `move` value live at that edge (a name not in the top frame) is a
    // leak — the same check `return` does at function exit, but scoped to the loop body.
    move_loop_stack: std.ArrayListUnmanaged(std.StringHashMap(void)) = .empty,
    // Owns the synthetic place-key strings (`binding.field`) the move pass inserts into
    // its state to track a `move` field that has been moved out of its aggregate. Freed at
    // the end of each function's analysis.
    move_place_keys: std.ArrayListUnmanaged([]const u8) = .empty,

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
        self.qualified_owners = module.qualified_owners;
        self.checkTopLevelNames(module);
        self.checkBackendNameUniqueness(module);
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

        var reflect_env = ReflectEnv{
            .structs = &structs,
            .packed_bits = &packed_bits,
            .overlay_unions = &overlay_unions,
            .tagged_unions = &tagged_unions,
            .enums = &enums,
            .aliases = &type_aliases,
        };
        self.reflect_env = &reflect_env;
        defer self.reflect_env = null;

        var const_globals = std.StringHashMap(eval.ComptimeValue).init(self.reporter.allocator);
        defer eval.deinitConstGlobals(self.reporter.allocator, &const_globals);
        eval.collectConstGlobalsWithOptions(self.reporter.allocator, module, &const_fns, &const_globals, .{
            .reflect = comptimeReflectThunk,
            .reflect_ctx = self,
        }) catch {
            self.oom = true;
        };
        self.const_globals = &const_globals;
        defer self.const_globals = null;

        var const_global_widths = std.StringHashMap(u16).init(self.reporter.allocator);
        defer const_global_widths.deinit();
        self.collectConstGlobalWidths(module, &const_global_widths);
        self.const_global_widths = &const_global_widths;
        defer self.const_global_widths = null;

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

        // Definite-initialization pass (S0.1). A scalar `var x: T = uninit;`
        // must be definitely assigned on every control-flow path before it is
        // read; a read-before-assign is E_USE_BEFORE_INIT. Runs over every
        // function body (the `uninit` idiom is pervasive, but the analysis is
        // precise enough to accept it — see checkDefiniteInit).
        {
            const di_ctx = Context{
                .functions = &functions,
                .globals = &globals,
                .type_aliases = &type_aliases,
                .structs = &structs,
                .enums = &enums,
                .tagged_unions = &tagged_unions,
            };
            for (module.decls) |decl| {
                if (decl.kind == .fn_decl) self.checkDefiniteInit(decl.kind.fn_decl, di_ctx);
            }
        }

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
            defer self.move_loop_stack.deinit(self.reporter.allocator); // free the loop-entry snapshot stack
            defer self.move_place_keys.deinit(self.reporter.allocator); // free the field-move place-key list
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
        structs.put(struct_decl.name.text, .{ .fields = fields, .ordered = struct_decl.fields, .is_opaque = struct_decl.is_opaque }) catch {
            fields.deinit();
        };
    }

    fn collectPackedBits(self: *Checker, module: ast.Module, packed_bits: *std.StringHashMap(LayoutFieldInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .packed_bits_decl => |packed_bits_decl| self.collectLayoutFields(packed_bits_decl.name.text, packed_bits_decl.fields, packed_bits_decl.repr, packed_bits),
                .fn_decl, .extern_fn, .type_alias, .struct_decl, .enum_decl, .union_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
            }
        }
    }

    fn collectOverlayUnions(self: *Checker, module: ast.Module, overlay_unions: *std.StringHashMap(LayoutFieldInfo)) void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .overlay_union_decl => |overlay_union_decl| self.collectLayoutFields(overlay_union_decl.name.text, overlay_union_decl.fields, null, overlay_unions),
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

    fn collectLayoutFields(self: *Checker, name: []const u8, fields_in: []const ast.Field, repr: ?ast.TypeExpr, infos: *std.StringHashMap(LayoutFieldInfo)) void {
        if (infos.contains(name)) return;
        var fields = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        for (fields_in) |field| {
            if (!fields.contains(field.name.text)) fields.put(field.name.text, field.ty) catch {
                self.oom = true;
            };
        }
        infos.put(name, .{ .fields = fields, .ordered = fields_in, .repr = repr }) catch {
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
                        .may_sleep = hasMaySleep(decl.attrs),
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

    fn collectConstGlobalWidths(self: *Checker, module: ast.Module, widths: *std.StringHashMap(u16)) void {
        for (module.decls) |decl| {
            const global = switch (decl.kind) {
                .global_decl => |g| g,
                else => continue,
            };
            if (!global.is_const) continue;
            const ty = global.ty orelse continue;
            const bits = eval.comptimeTypeBitWidth(ty) orelse continue;
            widths.put(global.name.text, bits) catch {
                self.oom = true;
            };
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
            // A value-level top-level declaration (function or global) may not shadow a
            // module/impl owner name, or `Owner.member` would bind to the qualified symbol
            // instead of this value. Type declarations are exempt: an `impl T` owner IS the
            // type `T`. (Locals and parameters are reserved at their binding sites.)
            if (isValueLevelDecl(decl.kind) and self.isQualifiedOwner(name.text)) {
                self.errorCode(name.span, "E_RESERVED_QUALIFIED_NAME", "a top-level value may not shadow a module/impl name");
            }
        }
    }

    fn checkDecl(self: *Checker, decl: ast.Decl, mmio_structs: *const std.StringHashMap(MmioStruct), structs: *const std.StringHashMap(StructInfo), packed_bits: *const std.StringHashMap(LayoutFieldInfo), overlay_unions: *const std.StringHashMap(LayoutFieldInfo), tagged_unions: *const std.StringHashMap(UnionInfo), enums: *const std.StringHashMap(EnumInfo), functions: *const std.StringHashMap(FunctionInfo), globals: *const std.StringHashMap(GlobalInfo), type_aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        const no_lang_trap = hasNoLangTrap(decl.attrs);
        const irq_context = hasIrqContext(decl.attrs);
        const type_ctx = Context{ .mmio_structs = mmio_structs, .structs = structs, .packed_bits = packed_bits, .overlay_unions = overlay_unions, .tagged_unions = tagged_unions, .enums = enums, .type_aliases = type_aliases };
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| {
                self.checkFn(fn_decl, no_lang_trap, irq_context, mmio_structs, structs, packed_bits, overlay_unions, tagged_unions, enums, functions, globals, type_aliases);
                // T(term)1: bounded-loop / no-unbounded-recursion check for IRQ/atomic
                // and `#[bounded]` functions (opt-in; existing code is unaffected).
                if (hasBoundedContext(decl.attrs)) {
                    if (fn_decl.body) |body| self.checkTermination(fn_decl.name.text, body);
                }
            },
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

        var empty_aliases = std.StringHashMap(ast.TypeExpr).init(self.reporter.allocator);
        defer empty_aliases.deinit();
        const aliases = ctx.type_aliases orelse &empty_aliases;

        for (struct_decl.fields) |field| {
            self.checkType(field.ty, .storage, ctx);
            // A linear `move` resource stored by value in a non-`move` struct escapes
            // linear tracking: the aggregate is copyable/leakable, so the resource could be
            // duplicated or dropped without being consumed. This also closes the generic
            // container hole — `Pool<Token, N>`, `Arc<Token>`, etc. monomorphize to a
            // non-move struct with a move-typed field and are rejected here. Hold a move
            // resource in another `move` type, or store it behind a pointer.
            if (self.typeIsMoveArray(field.ty, aliases)) {
                // An array of a `move` type as a field is not yet trackable — element moves need
                // the indexed-place model the checker does not have. Reject it in *any* struct,
                // including a `move` struct: otherwise `s.items[i]` could be moved out twice with
                // no use-after-move diagnostic (a double free). Hold the resources behind
                // pointers, or in a `move` container, until indexed move places exist.
                self.errorCode(field.ty.span, "E_MOVE_ARRAY_UNSUPPORTED", "an array of a linear `move` type is not yet trackable as a struct field (element moves need place analysis); hold the resources behind pointers or in a `move` container instead");
            } else if (!struct_decl.is_move and self.typeEmbedsMoveByValue(field.ty, aliases)) {
                self.errorCode(field.ty.span, "E_MOVE_FIELD_IN_NONMOVE", "a linear `move` value cannot be stored by value in a non-`move` struct (it would be duplicated or leaked); make the struct `move`, or store the resource behind a pointer");
            }
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

    // Whether `ty` embeds a linear `move` resource *by value* — directly, in an array, or
    // behind a qualifier/nullable. A pointer or slice to a move type is NOT by-value (it
    // borrows; the resource lives elsewhere). Used to reject storing a move resource inside
    // a non-move aggregate, where it would escape linear tracking (and be duplicated or
    // leaked) — including a generic container monomorphized over a move type, e.g.
    // `Pool<Token, N>`'s `[N]Token` or `Arc<Token>`'s embedded value.
    fn typeEmbedsMoveByValue(self: *Checker, ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        switch (ty.kind) {
            .name => return self.isMoveTypeName(ty, aliases),
            .generic => |g| {
                if (self.isMoveTypeName(ty, aliases)) return true; // a `move` generic (Arc<T>, …)
                // A built-in generic that stores its type arguments by value (e.g. Result<T,E>)
                // embeds a move resource if any argument does. (User generic structs aren't
                // handled here: they monomorphize to a concrete struct whose fields are checked
                // directly, and a move field in a non-`move` struct is rejected there.)
                if (genericHoldsArgsByValue(g.base.text)) {
                    for (g.args) |arg| {
                        if (self.typeEmbedsMoveByValue(arg, aliases)) return true;
                    }
                }
                return false;
            },
            .array => |node| return self.typeEmbedsMoveByValue(node.child.*, aliases),
            .qualified => |node| return self.typeEmbedsMoveByValue(node.child.*, aliases),
            .nullable => |child| return self.typeEmbedsMoveByValue(child.*, aliases),
            else => return false, // pointers, slices, fn/closure types: not by-value
        }
    }

    // Whether the resolved type is an array (possibly under a qualifier/nullable) whose element
    // embeds a `move` resource. Such a binding can't be tracked yet — element moves need the
    // place model — so it is rejected rather than silently allowed to duplicate/leak.
    fn typeIsMoveArray(self: *Checker, ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        switch (ty.kind) {
            .array => |node| return self.typeEmbedsMoveByValue(node.child.*, aliases),
            .qualified => |node| return self.typeIsMoveArray(node.child.*, aliases),
            .nullable => |child| return self.typeIsMoveArray(child.*, aliases),
            else => return false,
        }
    }

    fn checkMoveLinearity(self: *Checker, fn_decl: ast.FnDecl, aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        const body = fn_decl.body orelse return;
        var state = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
        defer state.deinit();
        defer {
            for (self.move_place_keys.items) |k| self.reporter.allocator.free(k);
            self.move_place_keys.clearRetainingCapacity();
        }
        for (fn_decl.params) |param| {
            if (self.typeIsMoveArray(param.ty, aliases)) {
                self.errorCode(param.name.span, "E_MOVE_ARRAY_UNSUPPORTED", "an array of a linear `move` type is not yet trackable (element moves need place analysis); pass the resources behind pointers or in a `move` container instead");
            } else if (self.typeEmbedsMoveByValue(param.ty, aliases)) {
                state.put(param.name.text, .{ .live = true, .span = param.name.span, .ty = param.ty }) catch {
                    self.oom = true;
                };
            }
        }
        const fell_through = !self.moveBlock(body, &state, aliases);
        // Implicit fall-through exit at the end of the body (a `void` return): only a
        // real exit edge if control can actually reach it. If the body diverges on every
        // path (e.g. ends in `return`), each such exit edge was already leak-checked.
        if (fell_through) {
            var it = state.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                    self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value is never consumed (must be moved, returned, or freed)");
                }
            }
        }
    }

    // Analyze the statements of a block in order. Returns `true` if the block diverges
    // (every path through it ends in `return`/`break`/`continue`), in which case the
    // join after the block is unreachable. Statements after a diverging statement are
    // dead code and are not analyzed.
    fn moveBlock(self: *Checker, block: ast.Block, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        for (block.items) |stmt| {
            if (self.moveStmt(stmt, state, aliases)) return true;
        }
        return false;
    }

    // A lexical `{ ... }` sub-scope. Returns whether the block diverges. Block-local
    // `move` bindings are dropped from `state` on the way out; if the block falls through
    // (does not diverge) any still-live local is a leak at the scope's normal exit edge.
    fn moveScopedBlock(self: *Checker, block: ast.Block, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        var before = self.cloneMoveState(state);
        defer before.deinit();
        const diverges = self.moveBlock(block, state, aliases);
        if (!diverges) {
            self.reportMoveLocalsLeavingScope(state, &before, "linear `move` value declared in this block is never consumed (must be moved, returned, or freed before the block ends)");
        }

        var scoped = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
        defer scoped.deinit();
        var it = before.iterator();
        while (it.next()) |entry| {
            const slot = state.get(entry.key_ptr.*) orelse entry.value_ptr.*;
            scoped.put(entry.key_ptr.*, slot) catch {
                self.oom = true;
            };
        }
        self.replaceMoveState(state, &scoped);
        return diverges;
    }

    // Leak-check every `move` binding live at an exit edge. Used both at an explicit
    // `return` (the whole function exits) and at a `?` operator (the function exits on
    // the error branch). A `deferred` binding is scheduled for lexical cleanup that runs
    // on the exit edge, so it is not a leak.
    fn checkMoveExitEdge(self: *Checker, state: *const std.StringHashMap(MoveSlot), message: []const u8) void {
        var it = state.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", message);
            }
        }
    }

    fn checkMoveExit(self: *Checker, state: *const std.StringHashMap(MoveSlot)) void {
        self.checkMoveExitEdge(state, "linear `move` value is still live on this function-exit path (must be moved, returned, or freed)");
    }

    fn reportMoveLocalsLeavingScope(self: *Checker, inner: *const std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), message: []const u8) void {
        var it = inner.iterator();
        while (it.next()) |entry| {
            if (outer.contains(entry.key_ptr.*)) continue;
            if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", message);
            }
        }
    }

    fn addIfLetMoveBinding(self: *Checker, pattern: ast.Pattern, value: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
        const ctx = self.move_ctx orelse return null;
        const value_ty = exprResultType(value, ctx.*) orelse return null;
        switch (pattern.kind) {
            .bind => |ident| {
                const payload_ty = nullableInnerType(value_ty) orelse return null;
                if (!self.typeEmbedsMoveByValue(payload_ty, aliases)) return null;
                state.put(ident.text, .{ .live = true, .span = ident.span, .ty = payload_ty }) catch {
                    self.oom = true;
                };
                return ident.text;
            },
            .tag_bind => |node| {
                const payload_ty = resultPayloadType(value_ty, node.tag.text) orelse return null;
                if (!self.typeEmbedsMoveByValue(payload_ty, aliases)) return null;
                state.put(node.binding.text, .{ .live = true, .span = node.binding.span, .ty = payload_ty }) catch {
                    self.oom = true;
                };
                return node.binding.text;
            },
            .wildcard, .tag, .literal => return null,
        }
    }

    // An expression used only for its side effects (a bare expression statement, or a switch /
    // if-let arm whose body is an expression) discards its result. If that result embeds a
    // linear `move` resource by value — a `move` struct, a `Result<…move…,…>`, or a `?move` —
    // the resource leaks: it was never bound, returned, or passed to a consuming function.
    // (A direct call's return type and a `?` operand's ok payload are resolved here; a generic
    // call with explicit type args is not, but its by-value storage is still caught at
    // monomorphization by E_MOVE_FIELD_IN_NONMOVE.)
    fn checkUnusedMoveResult(self: *Checker, e: ast.Expr, aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        const mctx = self.move_ctx orelse return;
        const rty = exprResultType(e, mctx.*) orelse return;
        if (self.typeEmbedsMoveByValue(rty, aliases)) {
            self.errorCode(e.span, "E_UNUSED_MOVE_RESULT", "the linear `move` result of this expression is discarded; bind it with `let`, return it, or pass it to a consuming function");
        }
    }

    // Analyze one statement. Returns `true` if it diverges — transfers control out of the
    // enclosing block on every path (`return`, `break`, `continue`, or a branch all of
    // whose arms diverge) — so the statements that follow are unreachable and the join
    // after it has no predecessor here.
    fn moveStmt(self: *Checker, stmt: ast.Stmt, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        switch (stmt.kind) {
            .let_decl, .var_decl => |decl| {
                if (decl.init) |init_expr| self.moveConsume(init_expr, state, aliases);
                // The binding's type: an explicit annotation, else inferred from the
                // initializer. An inferred `let b = alloc()` over a `move` type must still be
                // tracked as a live resource, or it leaks undetected.
                var binding_ty: ?ast.TypeExpr = decl.ty;
                if (binding_ty == null) {
                    if (decl.init) |init_expr| {
                        if (self.move_ctx) |mctx| binding_ty = exprResultType(init_expr, mctx.*);
                    }
                }
                if (binding_ty) |ty| {
                    if (decl.names.len > 0) {
                        if (self.typeIsMoveArray(ty, aliases)) {
                            self.errorCode(decl.names[0].span, "E_MOVE_ARRAY_UNSUPPORTED", "an array of a linear `move` type is not yet trackable (element moves need place analysis); hold the resources behind pointers or in a `move` container instead");
                        } else if (self.typeEmbedsMoveByValue(ty, aliases)) {
                            // A binding whose type embeds a `move` resource by value — a `move`
                            // struct, a `Result<…move…, …>`, or a `?move` — must be consumed.
                            state.put(decl.names[0].text, .{ .live = true, .span = decl.names[0].span, .ty = ty }) catch {
                                self.oom = true;
                            };
                        }
                    }
                }
                return false;
            },
            .@"return" => |maybe| {
                if (maybe) |v| self.moveConsume(v, state, aliases);
                self.checkMoveExit(state);
                return true; // the rest of the block is unreachable
            },
            .expr => |e| {
                self.moveConsume(e, state, aliases);
                self.checkUnusedMoveResult(e, aliases);
                // An expression statement that unconditionally aborts or is unreachable
                // (`unreachable`, `trap(...)`, or a call to a `-> never` function) ends
                // this control-flow path. Unlike `return`/`?` it performs no normal exit
                // and reaches no successor, so live resources here do not leak — the
                // program halts or the path is impossible. This is the `Unreachable`
                // lattice state: diverge with no exit-edge leak check, so the post-branch
                // join drops this path instead of merging a stale live set (which would
                // otherwise raise a spurious E_MOVE_BRANCH_MISMATCH / E_RESOURCE_LEAK).
                // (The `-> never` call is recognized here for the move join even though
                // the function-level return-path checker still requires an explicit
                // `return`/`trap`/`unreachable` terminator — both backends need one.)
                if (self.move_ctx) |mctx| {
                    if (!exprMayFallThrough(e, mctx.*) or exprIsNeverCall(e, mctx.*)) return true;
                }
                return false;
            },
            .assignment => |a| {
                switch (a.target.kind) {
                    .ident => |id| {
                        if (state.getPtr(id.text)) |slot| {
                            if (slot.live and !slot.deferred) {
                                self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot overwrite a live linear `move` value; consume it first");
                            } else if (slot.deferred) {
                                self.errorCode(a.target.span, "E_USE_AFTER_MOVE", "linear `move` value is reserved by a `defer` and cannot be reassigned");
                            }
                        }
                        self.moveConsume(a.value, state, aliases);
                        if (state.getPtr(id.text)) |slot| slot.live = true;
                    },
                    .member => |m| {
                        // Assigning through `p.field`: the base must be live, and overwriting a
                        // live `move` field (one not already moved out) would drop the old
                        // resource without consuming it.
                        self.moveBorrow(m.base.*, state);
                        const key_opt = self.moveFieldPlaceKey(a.target, m, state, aliases);
                        if (key_opt) |key| {
                            if (!state.contains(key)) {
                                self.errorCode(a.target.span, "E_RESOURCE_OVERWRITE", "cannot overwrite a live linear `move` field; consume it first");
                            }
                        }
                        self.moveConsume(a.value, state, aliases);
                        if (key_opt) |key| {
                            _ = state.remove(key); // the field now holds a fresh live resource
                        }
                    },
                    else => {
                        self.moveConsume(a.value, state, aliases);
                    },
                }
                return false;
            },
            // `defer <expr>` runs at scope end: it reserves (does not immediately
            // move) the values it will consume, so they neither leak nor remain
            // movable.
            .@"defer" => |e| {
                self.moveDefer(e, state, aliases);
                return false;
            },
            .assert => |e| {
                self.moveBorrow(e, state);
                return false;
            },
            .block, .unsafe_block, .comptime_block => |b| return self.moveScopedBlock(b, state, aliases),
            .contract_block => |c| return self.moveScopedBlock(c.block, state, aliases),
            .loop => |l| {
                if (l.iterable) |iter| self.moveBorrow(iter, state);
                // Snapshot the names live at loop entry so a `break`/`continue` inside
                // the body can tell loop-body locals (which leak on an early exit) from
                // outer resources (handled by the E_MOVE_LOOP_RESOURCE check below).
                var entry_names = std.StringHashMap(void).init(self.reporter.allocator);
                var snap_it = state.iterator();
                while (snap_it.next()) |e| {
                    entry_names.put(e.key_ptr.*, {}) catch {
                        self.oom = true;
                    };
                }
                self.move_loop_stack.append(self.reporter.allocator, entry_names) catch {
                    self.oom = true;
                };
                var body_state = self.cloneMoveState(state);
                defer body_state.deinit();
                _ = self.moveBlock(l.body, &body_state, aliases);
                if (self.move_loop_stack.pop()) |popped| {
                    var p = popped;
                    p.deinit();
                }
                self.reportMoveLocalsLeavingScope(&body_state, state, "linear `move` value declared in a loop body is never consumed (must be moved, returned, or freed before the iteration ends)");
                var it = state.iterator();
                while (it.next()) |entry| {
                    const after = body_state.get(entry.key_ptr.*) orelse continue;
                    const before = entry.value_ptr.*;
                    if (before.live != after.live or before.deferred != after.deferred) {
                        self.errorCode(before.span, "E_MOVE_LOOP_RESOURCE", "cannot consume or reserve an outer linear `move` value inside a loop; the loop may run zero or multiple times");
                        entry.value_ptr.live = false;
                        entry.value_ptr.deferred = false;
                    }
                }
                // A loop may run zero times, so control can always fall through past it.
                return false;
            },
            .if_let => |n| {
                // The condition/scrutinee is evaluated, so by-value `move` operands in
                // it are consumed (borrow operands `&x` stay borrows inside moveConsume).
                self.moveConsume(n.value, state, aliases);
                var then_state = self.cloneMoveState(state);
                defer then_state.deinit();
                var else_state = self.cloneMoveState(state);
                defer else_state.deinit();
                const bound_name = self.addIfLetMoveBinding(n.pattern, n.value, &then_state, aliases);
                const then_div = self.moveBlock(n.then_block, &then_state, aliases);
                if (bound_name) |bn| {
                    // A diverging arm already leak-checked the binding at its exit edge.
                    if (!then_div) {
                        if (then_state.getPtr(bn)) |slot| {
                            if (slot.live and !slot.deferred) {
                                self.errorCode(slot.span, "E_RESOURCE_LEAK", "linear `move` value bound in an if-let branch is never consumed (must be moved, returned, or freed)");
                            }
                        }
                    }
                    _ = then_state.remove(bn);
                }
                var else_div = false;
                if (n.else_block) |eb| {
                    else_div = self.moveBlock(eb, &else_state, aliases);
                }
                self.finalizeBranchLocals(&then_state, state, !then_div);
                self.finalizeBranchLocals(&else_state, state, !else_div);
                self.joinMoveBranches(state, &then_state, then_div, &else_state, else_div);
                // Diverges only when an `else` exists and both arms diverge; a missing
                // `else` arm falls through.
                return then_div and (n.else_block != null) and else_div;
            },
            .@"switch" => |sw| {
                // The subject is evaluated, so by-value `move` operands in it are
                // consumed (a plain `if cond` desugars to a switch on `cond`; borrow
                // operands `&x` and non-move subjects stay no-ops in moveConsume).
                self.moveConsume(sw.subject, state, aliases);
                var joined: ?std.StringHashMap(MoveSlot) = null;
                defer if (joined) |*m| m.deinit();
                // Infer the subject's type so a pattern binding (`ok(p)`) that names a `move`
                // value is tracked inside the arm — otherwise use-after-move / a leak through a
                // switch arm goes undetected.
                const subject_ty: ?ast.TypeExpr = if (self.move_ctx) |ctx| exprResultType(sw.subject, ctx.*) else null;
                var any_arm = false;
                var all_diverge = true;
                for (sw.arms) |arm| {
                    any_arm = true;
                    var arm_state = self.cloneMoveState(state);
                    defer arm_state.deinit();
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
                                // Recursive predicate: a payload that is itself a `?move` or
                                // `Result<…move…,…>` embeds a linear resource and must be tracked
                                // inside the arm too, not only a payload that is a move type name.
                                if (self.typeEmbedsMoveByValue(pty, aliases)) {
                                    arm_state.put(id.text, .{ .live = true, .span = id.span, .ty = pty }) catch {
                                        self.oom = true;
                                    };
                                    bound_name = id.text;
                                }
                            }
                        }
                    }
                    const arm_div = switch (arm.body) {
                        .block => |b| self.moveBlock(b, &arm_state, aliases),
                        .expr => |e| blk: {
                            self.moveConsume(e, &arm_state, aliases);
                            self.checkUnusedMoveResult(e, aliases); // arm body is used for effect; its move result must not be discarded
                            break :blk false;
                        },
                    };
                    // A `move` value bound by this arm must be consumed within it; then it leaves
                    // scope (remove it so a later arm's same-named binding starts fresh). A
                    // diverging arm already leak-checked it at its exit edge.
                    if (bound_name) |bn| {
                        if (!arm_div) {
                            if (arm_state.getPtr(bn)) |slot| {
                                if (slot.live and !slot.deferred) {
                                    self.errorCode(slot.span, "E_RESOURCE_LEAK", "linear `move` value bound in a switch arm is never consumed (must be moved, returned, or freed)");
                                }
                            }
                        }
                        _ = arm_state.remove(bn);
                    }
                    self.finalizeBranchLocals(&arm_state, state, !arm_div);
                    // Only an arm that falls through reaches the join after the switch.
                    if (!arm_div) {
                        all_diverge = false;
                        if (joined) |*m| {
                            self.mergeMoveBranches(m, m, &arm_state);
                        } else {
                            joined = self.cloneMoveState(&arm_state);
                        }
                    }
                }
                if (joined) |*m| self.replaceMoveState(state, m);
                // The switch diverges only if it has arms and every arm diverges.
                return any_arm and all_diverge;
            },
            .@"break", .@"continue" => {
                self.checkLoopExitLeaks(state);
                return true; // the rest of the loop body is unreachable
            },
            .asm_stmt => return false,
        }
    }

    // Drop branch-local `move` bindings (names not present in `outer`) from `branch` on
    // the way out of an if/switch arm. If the arm falls through (`report`), any still-live
    // local is a leak at the arm's normal exit; a diverging arm already leak-checked its
    // locals at the exit edge. Afterwards `branch` holds only outer names, so two arms can
    // be merged by comparing the same keys.
    fn finalizeBranchLocals(self: *Checker, branch: *std.StringHashMap(MoveSlot), outer: *const std.StringHashMap(MoveSlot), report: bool) void {
        var removals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer removals.deinit(self.reporter.allocator);
        var it = branch.iterator();
        while (it.next()) |entry| {
            if (outer.contains(entry.key_ptr.*)) continue;
            if (report and entry.value_ptr.live and !entry.value_ptr.deferred) {
                self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value declared in this branch is never consumed before the branch exits");
            }
            removals.append(self.reporter.allocator, entry.key_ptr.*) catch {
                self.oom = true;
            };
        }
        for (removals.items) |k| _ = branch.remove(k);
    }

    // Join two control-flow arms into `dest`. A diverging arm does not reach the join, so
    // it contributes nothing: the join is the surviving arm's state (or unreachable if
    // both diverge). Only when both arms fall through are they merged — and a `move` value
    // must then have consistent ownership across them (else E_MOVE_BRANCH_MISMATCH).
    fn joinMoveBranches(
        self: *Checker,
        dest: *std.StringHashMap(MoveSlot),
        left: *const std.StringHashMap(MoveSlot),
        left_div: bool,
        right: *const std.StringHashMap(MoveSlot),
        right_div: bool,
    ) void {
        if (left_div and right_div) return; // join is unreachable; leave `dest` as-is
        if (left_div) {
            self.replaceMoveState(dest, right);
            return;
        }
        if (right_div) {
            self.replaceMoveState(dest, left);
            return;
        }
        self.mergeMoveBranches(dest, left, right);
    }

    // At a `break`/`continue`, the current iteration ends. Any loop-body-local `move`
    // value still live (a name not present at loop entry, and not reserved by a defer)
    // leaks on that edge — the iteration exits without consuming it. Mirrors
    // `checkMoveExit` for `return`, but bounded to the innermost loop's body locals.
    fn checkLoopExitLeaks(self: *Checker, state: *std.StringHashMap(MoveSlot)) void {
        if (self.move_loop_stack.items.len == 0) return; // a stray break/continue (parser rejects)
        const entry_names = &self.move_loop_stack.items[self.move_loop_stack.items.len - 1];
        // `break`/`continue` is terminal in its block, so this is the only visit; we do
        // NOT clear the slot, which would corrupt the live state the enclosing branch
        // merges back (producing spurious branch-mismatch / use-after-move downstream).
        var it = state.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.live and !entry.value_ptr.deferred and !entry_names.contains(entry.key_ptr.*)) {
                self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value declared in a loop body is never consumed before this `break`/`continue` exits the iteration");
            }
        }
    }

    fn cloneMoveState(self: *Checker, state: *const std.StringHashMap(MoveSlot)) std.StringHashMap(MoveSlot) {
        var clone = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
        var it = state.iterator();
        while (it.next()) |entry| {
            clone.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
        return clone;
    }

    fn replaceMoveState(self: *Checker, dest: *std.StringHashMap(MoveSlot), src: *const std.StringHashMap(MoveSlot)) void {
        dest.clearRetainingCapacity();
        var it = src.iterator();
        while (it.next()) |entry| {
            dest.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
    }

    fn mergeMoveBranches(
        self: *Checker,
        dest: *std.StringHashMap(MoveSlot),
        left: *const std.StringHashMap(MoveSlot),
        right: *const std.StringHashMap(MoveSlot),
    ) void {
        var merged = std.StringHashMap(MoveSlot).init(self.reporter.allocator);
        defer merged.deinit();

        var it = left.iterator();
        while (it.next()) |entry| {
            const other = right.get(entry.key_ptr.*) orelse {
                if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                    self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value created in only one branch is never consumed before the branch exits");
                }
                continue;
            };
            var slot = entry.value_ptr.*;
            if (slot.live != other.live or slot.deferred != other.deferred) {
                self.errorCode(slot.span, "E_MOVE_BRANCH_MISMATCH", "linear `move` value has inconsistent ownership across control-flow branches");
                slot.live = false;
                slot.deferred = false;
            }
            merged.put(entry.key_ptr.*, slot) catch {
                self.oom = true;
            };
        }

        var right_it = right.iterator();
        while (right_it.next()) |entry| {
            if (left.contains(entry.key_ptr.*)) continue;
            if (entry.value_ptr.live and !entry.value_ptr.deferred) {
                self.errorCode(entry.value_ptr.span, "E_RESOURCE_LEAK", "linear `move` value created in only one branch is never consumed before the branch exits");
            }
        }

        self.replaceMoveState(dest, &merged);
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
                    } else if (hasMovedSubplace(id.text, state)) {
                        // Moving the whole aggregate would also move the field already taken
                        // out of it — a duplicate move. (`forget_unchecked` discards the husk
                        // instead and goes through moveForget, which is allowed.)
                        self.errorCode(expr.span, "E_USE_AFTER_MOVE", "linear `move` value used as a whole after one of its fields was moved out");
                        slot.live = false;
                    } else {
                        slot.live = false;
                    }
                }
            },
            .grouped => |inner| self.moveConsume(inner.*, state, aliases),
            .try_expr => |inner| {
                // `?` is an exit edge: on error it returns from the function. The operand's
                // `ok` payload is consumed and flows on; every *other* live `move` value
                // would leak on the error return unless it is registered with `defer`.
                self.moveConsume(inner.operand.*, state, aliases);
                self.checkMoveExitEdge(state, "linear `move` value is still live where `?` may return on error (consume it before `?`, or register it with `defer`)");
            },
            .cast => |c| self.moveConsume(c.value.*, state, aliases),
            .address_of => |inner| self.moveBorrow(inner.*, state),
            .member => |m| {
                self.moveBorrow(m.base.*, state); // the base must be live to take a field
                // Moving a `move`-typed field out of a tracked aggregate: poison the field
                // so a second move (or a borrow) of it is caught.
                if (self.moveFieldPlaceKey(expr, m, state, aliases)) |key| {
                    if (state.contains(key)) {
                        self.errorCode(expr.span, "E_USE_AFTER_MOVE", "use of linear `move` field after it was moved out");
                    } else {
                        state.put(key, .{ .live = false, .span = expr.span }) catch {
                            self.oom = true;
                        };
                    }
                }
            },
            .deref => |inner| self.moveBorrow(inner.*, state),
            .index => |ix| {
                self.moveBorrow(ix.base.*, state);
                self.moveConsume(ix.index.*, state, aliases);
            },
            .call => |c| {
                // `drop(x)` is a safe discard for plain values, but on a linear `move`
                // value it consumes the binding while freeing nothing — a leak the
                // checker would otherwise bless. Reject it and point at the real options:
                // a release function, or `forget_unchecked` when the contents were already
                // transferred. (The argument is still consumed below so a single mistake
                // does not cascade into use-after-move noise.)
                if (isDropCall(c.callee.*)) {
                    for (c.args) |arg| {
                        if (self.exprIsMoveTyped(arg, state, aliases)) {
                            self.errorCode(arg.span, "E_DROP_LINEAR_RESOURCE", "a linear `move` value cannot be `drop`ped (it frees nothing); release it with its free function, or `forget_unchecked` it in an unsafe block once its contents have been transferred");
                        }
                    }
                    for (c.args) |arg| self.moveConsume(arg, state, aliases);
                } else if (isForgetUncheckedCall(c.callee.*)) {
                    // Discard the husk wholesale — moved-out fields and all — so a partial
                    // move is fine here (the aggregate is being thrown away, not reused).
                    for (c.args) |arg| self.moveForget(arg, state, aliases);
                } else {
                    for (c.args) |arg| self.moveConsume(arg, state, aliases);
                }
            },
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

    // ----- place sensitivity: track a `move` field moved out of its aggregate -----
    //
    // The state is keyed by binding name; a one-level field move is recorded with a
    // synthetic key `binding.field` whose presence means "this field has been moved out".
    // This lets the checker reject a duplicate field move, a borrow of a moved-out field,
    // and a whole-aggregate move after a field was taken (which would duplicate it).

    // If `expr` is `<binding>.<field>` where the field is a `move` type and the base is a
    // tracked move binding, return the place key `binding.field` (allocated once, owned by
    // `move_place_keys`); otherwise null.
    const PlaceKeyTy = struct { key: []const u8, ty: ast.TypeExpr };

    // Build the dotted place key and leaf type for a place expression (`x`, `x.f`, `x.f.g`)
    // whose root is a tracked move binding — so nested fields, not just one level, are
    // distinct places. The key is allocated and owned by `move_place_keys`. Returns null if
    // the root is not a tracked move binding or a field type cannot be resolved.
    fn placeKeyAndType(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) ?PlaceKeyTy {
        switch (expr.kind) {
            .grouped => |inner| return self.placeKeyAndType(inner.*, state),
            .ident => |id| {
                const slot = state.get(id.text) orelse return null;
                const ty = slot.ty orelse return null;
                return .{ .key = id.text, .ty = ty }; // root key = binding name (AST-owned)
            },
            .member => |m| {
                const base = self.placeKeyAndType(m.base.*, state) orelse return null;
                const ctx = self.move_ctx orelse return null;
                const field_ty = structFieldType(base.ty, m.name.text, ctx.*) orelse return null;
                const key = std.fmt.allocPrint(self.reporter.allocator, "{s}.{s}", .{ base.key, m.name.text }) catch {
                    self.oom = true;
                    return null;
                };
                self.move_place_keys.append(self.reporter.allocator, key) catch {
                    self.oom = true;
                };
                return .{ .key = key, .ty = field_ty };
            },
            else => return null,
        }
    }

    // The place key for a `move`-typed field access (at any nesting depth), or null if the
    // accessed place is not a tracked move field.
    fn moveFieldPlaceKey(self: *Checker, expr: ast.Expr, m: anytype, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
        _ = m;
        const pp = self.placeKeyAndType(expr, state) orelse return null;
        // A field is a move place if its type *embeds* a move resource by value — not only a
        // direct move type name, but also a `?move` / `Result<…move…,…>` field. Otherwise moving
        // such a wrapper field out of an aggregate would not poison the place, and a second
        // move of the same field (a double free) would go undetected. (Move-typed array fields
        // are rejected at declaration, so a place leaf is never an untrackable array.)
        if (!self.typeEmbedsMoveByValue(pp.ty, aliases)) return null;
        return pp.key;
    }

    // Whether the place denoted by `expr` (a possibly-nested field access) is recorded as
    // moved out.
    fn placeExprIsMoved(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot)) bool {
        const pp = self.placeKeyAndType(expr, state) orelse return false;
        return state.contains(pp.key);
    }

    // Whether any field of `base` has been moved out (a partial move of the aggregate).
    fn hasMovedSubplace(base: []const u8, state: *const std.StringHashMap(MoveSlot)) bool {
        var it = state.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (k.len > base.len + 1 and std.mem.startsWith(u8, k, base) and k[base.len] == '.') return true;
        }
        return false;
    }

    // Remove every `base.field` place key when the whole aggregate leaves play (consumed or
    // forgotten), so a later same-named binding starts clean.
    fn clearSubplaces(base: []const u8, state: *std.StringHashMap(MoveSlot)) void {
        // Remove every `base.field…` subplace. A HashMap iterator is invalidated by a removal,
        // so rescan from the top after each one until none remain — rather than collecting into
        // a fixed-size batch, which would silently leave stale subplace state behind once an
        // aggregate had more moved-out fields than the batch could hold. The number of tracked
        // subplaces per function is tiny, so the repeated scan is cheap.
        var removed_any = true;
        while (removed_any) {
            removed_any = false;
            var it = state.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (k.len > base.len + 1 and std.mem.startsWith(u8, k, base) and k[base.len] == '.') {
                    _ = state.remove(k);
                    removed_any = true;
                    break; // the iterator is now invalid; rescan with a fresh one
                }
            }
        }
    }

    // `forget_unchecked(x)` discards the whole aggregate husk: consume the binding and drop
    // its field-move records (the husk is being thrown away, moved-out fields and all), so a
    // partial move is fine here — unlike a real whole-aggregate move.
    fn moveForget(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
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
                clearSubplaces(id.text, state);
            },
            .grouped => |inner| self.moveForget(inner.*, state, aliases),
            else => self.moveConsume(expr, state, aliases),
        }
    }

    // Whether `expr` denotes a linear `move` value — a tracked move binding by name, or
    // any expression whose inferred type is a move type. Used to reject `drop` of a
    // resource.
    fn exprIsMoveTyped(self: *Checker, expr: ast.Expr, state: *const std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
        switch (expr.kind) {
            .ident => |id| if (state.contains(id.text)) return true,
            .grouped => |inner| return self.exprIsMoveTyped(inner.*, state, aliases),
            else => {},
        }
        if (self.move_ctx) |mctx| {
            if (exprResultType(expr, mctx.*)) |ty| {
                // Use the recursive predicate, not isMoveTypeName: a `?move`, `Result<…move…,…>`,
                // or array-of-move result also denotes a linear resource (so `drop` of it frees
                // nothing and leaks), even though the wrapper itself is not a move type *name*.
                if (self.typeEmbedsMoveByValue(ty, aliases)) return true;
            }
        }
        return false;
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
            .try_expr => |inner| {
                // `?` is an exit edge even in a borrow position: on error it returns, so any
                // other live `move` value would leak unless registered with `defer`.
                self.moveBorrow(inner.operand.*, state);
                self.checkMoveExitEdge(state, "linear `move` value is still live where `?` may return on error (consume it before `?`, or register it with `defer`)");
            },
            .member => |m| {
                self.moveBorrow(m.base.*, state);
                // Borrowing a field (at any nesting depth) that was already moved out is a
                // use-after-move.
                if (self.placeExprIsMoved(expr, state)) {
                    self.errorCode(expr.span, "E_USE_AFTER_MOVE", "borrow of linear `move` field after it was moved out");
                }
            },
            .index => |ix| self.moveBorrow(ix.base.*, state),
            .cast => |c| self.moveBorrow(c.value.*, state),
            .call => |c| for (c.args) |arg| self.moveBorrow(arg, state),
            else => {},
        }
    }

    // `defer <expr>`: reserve the move bindings the deferred expr will consume.
    fn moveDefer(self: *Checker, expr: ast.Expr, state: *std.StringHashMap(MoveSlot), aliases: *const std.StringHashMap(ast.TypeExpr)) void {
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
            .grouped => |inner| self.moveDefer(inner.*, state, aliases),
            .call => |c| for (c.args) |arg| self.moveDefer(arg, state, aliases),
            .member => |m| {
                self.moveBorrow(m.base.*, state);
                // `defer free(p.field)`: reserve the move field for lexical cleanup so it is
                // neither leaked at exit nor moved out before the defer runs.
                if (self.moveFieldPlaceKey(expr, m, state, aliases)) |key| {
                    if (state.contains(key)) {
                        self.errorCode(expr.span, "E_USE_AFTER_MOVE", "defer reserves a linear `move` field already moved out");
                    } else {
                        state.put(key, .{ .live = true, .span = expr.span, .deferred = true }) catch {
                            self.oom = true;
                        };
                    }
                }
            },
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
        const fn_pointer_checked = self.checkFunctionPointerInitializer(ty, initializer, ctx);
        const address_class_checked = checkAddressClassConversion(self, initializer.span, target, source);
        const enum_checked = self.checkEnumValueCompatibility(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(ty, initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(initializer, ctx, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion") else false;
        const secret_checked = target == .secret and self.checkSecretWrapInitializer(ty, initializer, ctx);
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(target, source)) {
            self.errorCode(initializer.span, "E_NO_IMPLICIT_CONVERSION", "global initializer requires an explicit conversion");
        }
        // A typed global initializer is static when it is either a C static
        // initializer or folds through the section-22 comptime evaluator. The
        // latter admits expressions like `1 + 2` and const-fn aggregate builders
        // while still rejecting runtime calls.
        const folds_static = self.comptimeConstantFolds(initializer);
        if (type_valid and self.reporter.diagnostics.items.len == errors_before and !isStaticGlobalInitializer(initializer, ctx) and !folds_static) {
            self.errorCode(initializer.span, "E_GLOBAL_INITIALIZER_NOT_STATIC", "global initializer must be a compile-time static value for M0 C emission");
        }
    }

    fn comptimeConstantFolds(self: *Checker, expr: ast.Expr) bool {
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var scope = eval.ComptimeScope.init(fba.allocator());
        self.seedComptimeScope(&scope);
        return switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => true,
            else => false,
        };
    }

    fn seedComptimeScope(self: *Checker, scope: *eval.ComptimeScope) void {
        scope.funcs = self.const_fns;
        scope.globals = self.const_globals;
        scope.reflect = comptimeReflectThunk;
        scope.reflect_ctx = self;
        if (self.const_global_widths) |widths| {
            var it = widths.iterator();
            while (it.next()) |entry| scope.bindWidth(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn checkFn(self: *Checker, fn_decl: ast.FnDecl, no_lang_trap: bool, irq_context: bool, mmio_structs: *const std.StringHashMap(MmioStruct), structs: *const std.StringHashMap(StructInfo), packed_bits: *const std.StringHashMap(LayoutFieldInfo), overlay_unions: *const std.StringHashMap(LayoutFieldInfo), tagged_unions: *const std.StringHashMap(UnionInfo), enums: *const std.StringHashMap(EnumInfo), functions: *const std.StringHashMap(FunctionInfo), globals: *const std.StringHashMap(GlobalInfo), type_aliases: *const std.StringHashMap(ast.TypeExpr)) void {
        self.current_fn_name = fn_decl.name.text;
        defer self.current_fn_name = null;
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
            if (self.isQualifiedOwner(param.name.text)) {
                self.errorCode(param.name.span, "E_RESERVED_QUALIFIED_NAME", "a parameter may not shadow a module/impl name");
            } else if (scope.contains(param.name.text)) {
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
                .irq_context = irq_context,
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

    // ----- Definite-initialization pass (S0.1) ---------------------------------
    //
    // A scalar `var x: T = uninit;` declares storage whose bytes are unspecified;
    // reading it before it is definitely assigned on every control-flow path is a
    // compile error (E_USE_BEFORE_INIT), not a runtime hazard. This is the flow-
    // sensitive "definite assignment" check.
    //
    // State is the set of *pending* names: scalar `uninit` vars declared but not yet
    // proven assigned on the current path. A pending name is:
    //   - removed when it is the whole target of an assignment `x = …` (now assigned),
    //   - removed when its address is taken (`&x`) or it is used through a member /
    //     index / deref base — such a use may initialize it, so we conservatively
    //     treat the var as assigned (this is what keeps the pervasive
    //     `var x: T = uninit; init(&x); use(x)` idiom accepted),
    //   - reported (E_USE_BEFORE_INIT) when it is read as a plain value.
    //
    // Only SCALAR vars are tracked. Aggregates (arrays, structs, unions, slices,
    // results, …) are initialized field/element-at-a-time through index/member
    // assignment, which this whole-variable analysis cannot prove — so they are never
    // made pending (no false positives on `var buf: [N]u8 = uninit; buf[i] = …`).
    //
    // Branches (if/else, switch — `if` desugars to a switch on the bool) intersect:
    // a name is assigned after the branch only if assigned on every arm that falls
    // through to the join. A diverging arm (ends in return/break/continue/unreachable)
    // contributes nothing to the join. Loops are conservative: a body assignment is
    // not guaranteed (the loop may run zero times), so the outer pending set is
    // restored after the loop — but reads inside the body are still checked.
    const DefInitState = std.StringHashMap(diagnostics.Span);

    fn checkDefiniteInit(self: *Checker, fn_decl: ast.FnDecl, ctx: Context) void {
        const body = fn_decl.body orelse return;
        var pending = DefInitState.init(self.reporter.allocator);
        defer pending.deinit();
        _ = self.diBlock(body, &pending, ctx);
    }

    fn diCloneState(self: *Checker, state: *const DefInitState) DefInitState {
        var clone = DefInitState.init(self.reporter.allocator);
        var it = state.iterator();
        while (it.next()) |entry| {
            clone.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
        return clone;
    }

    fn diReplaceState(self: *Checker, dest: *DefInitState, src: *const DefInitState) void {
        dest.clearRetainingCapacity();
        var it = src.iterator();
        while (it.next()) |entry| {
            dest.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
    }

    // Analyze a block's statements in order. Returns whether the block diverges
    // (every path through it ends in return/break/continue/unreachable), so the
    // join after it is unreachable.
    fn diBlock(self: *Checker, block: ast.Block, state: *DefInitState, ctx: Context) bool {
        for (block.items) |stmt| {
            if (self.diStmt(stmt, state, ctx)) return true;
        }
        return false;
    }

    // Returns whether the statement diverges.
    fn diStmt(self: *Checker, stmt: ast.Stmt, state: *DefInitState, ctx: Context) bool {
        switch (stmt.kind) {
            .var_decl => |decl| {
                if (decl.init) |init_expr| {
                    if (isUninitLiteral(init_expr)) {
                        // A scalar `var x: T = uninit;` becomes pending until definitely
                        // assigned. Aggregates and untyped/unknown storage are not tracked.
                        if (decl.ty) |ty| {
                            if (diIsScalarType(ty, ctx)) {
                                for (decl.names) |name| {
                                    state.put(name.text, name.span) catch {
                                        self.oom = true;
                                    };
                                }
                            }
                        }
                    } else {
                        self.diRead(init_expr, state, ctx);
                    }
                }
                return false;
            },
            .let_decl => |decl| {
                if (decl.init) |init_expr| self.diRead(init_expr, state, ctx);
                return false;
            },
            .assignment => |a| {
                // The value is read first; then the target may become assigned.
                self.diRead(a.value, state, ctx);
                switch (a.target.kind) {
                    .ident => |id| {
                        // Whole-variable assignment: the pending var is now definitely set.
                        _ = state.remove(id.text);
                    },
                    else => {
                        // Member/index/deref target: the base is used as storage (address-like);
                        // clear any pending root var (a partial write we cannot fully track) and
                        // read the index/base subexpressions.
                        self.diUseTarget(a.target, state, ctx);
                    },
                }
                return false;
            },
            .@"return" => |maybe| {
                if (maybe) |e| self.diRead(e, state, ctx);
                return true;
            },
            .@"break", .@"continue" => return true,
            .expr => |e| {
                self.diRead(e, state, ctx);
                // An expression that cannot fall through (`unreachable`, `trap(...)`, a
                // `-> never` call) ends this path, like `return`.
                if (!exprMayFallThrough(e, ctx) or exprIsNeverCall(e, ctx)) return true;
                return false;
            },
            .assert => |e| {
                self.diRead(e, state, ctx);
                return false;
            },
            .@"defer" => |e| {
                self.diRead(e, state, ctx);
                return false;
            },
            .block, .unsafe_block, .comptime_block => |b| return self.diBlock(b, state, ctx),
            .contract_block => |c| return self.diBlock(c.block, state, ctx),
            .loop => |l| {
                if (l.iterable) |iter| self.diRead(iter, state, ctx);
                // Conservative: a body assignment may not run (zero iterations), so the
                // outer pending set is restored afterwards. Reads inside the body are still
                // checked against the entry state.
                var body_state = self.diCloneState(state);
                defer body_state.deinit();
                _ = self.diBlock(l.body, &body_state, ctx);
                // The loop may run zero times, so control always falls through.
                return false;
            },
            .if_let => |n| {
                self.diRead(n.value, state, ctx);
                var then_state = self.diCloneState(state);
                defer then_state.deinit();
                const then_div = self.diBlock(n.then_block, &then_state, ctx);
                var else_state = self.diCloneState(state);
                defer else_state.deinit();
                var else_div = false;
                if (n.else_block) |eb| {
                    else_div = self.diBlock(eb, &else_state, ctx);
                }
                self.diJoin(state, &then_state, then_div, &else_state, else_div);
                return then_div and (n.else_block != null) and else_div;
            },
            .@"switch" => |sw| {
                self.diRead(sw.subject, state, ctx);
                var joined: ?DefInitState = null;
                defer if (joined) |*m| m.deinit();
                var any_arm = false;
                var all_diverge = true;
                for (sw.arms) |arm| {
                    any_arm = true;
                    var arm_state = self.diCloneState(state);
                    defer arm_state.deinit();
                    const arm_div = switch (arm.body) {
                        .block => |b| self.diBlock(b, &arm_state, ctx),
                        .expr => |e| blk: {
                            self.diRead(e, &arm_state, ctx);
                            break :blk false;
                        },
                    };
                    if (!arm_div) {
                        all_diverge = false;
                        if (joined) |*m| {
                            self.diMerge(m, &arm_state);
                        } else {
                            joined = self.diCloneState(&arm_state);
                        }
                    }
                }
                if (joined) |*m| self.diReplaceState(state, m);
                return any_arm and all_diverge;
            },
            .asm_stmt => return false,
        }
    }

    // Join two arms into `dest`. A diverging arm does not reach the join, so it
    // contributes nothing; only arms that fall through are intersected (a name is
    // assigned after the branch only if assigned on every reaching arm — i.e. it is
    // pending after the branch if it is still pending on any reaching arm).
    fn diJoin(self: *Checker, dest: *DefInitState, left: *const DefInitState, left_div: bool, right: *const DefInitState, right_div: bool) void {
        if (left_div and right_div) return; // join unreachable; leave dest as-is
        if (left_div) {
            self.diReplaceState(dest, right);
            return;
        }
        if (right_div) {
            self.diReplaceState(dest, left);
            return;
        }
        var merged = self.diCloneState(left);
        defer merged.deinit();
        self.diMerge(&merged, right);
        self.diReplaceState(dest, &merged);
    }

    // Merge `other` into `dest` as the union of pending names (a name is pending after
    // the join if it is still pending on EITHER reaching arm — assigned only if
    // assigned on BOTH).
    fn diMerge(self: *Checker, dest: *DefInitState, other: *const DefInitState) void {
        var it = other.iterator();
        while (it.next()) |entry| {
            dest.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                self.oom = true;
            };
        }
    }

    // Walk an expression evaluated for its value, reporting a read of any pending var
    // and clearing vars whose address is taken (an address-of use may initialize them).
    fn diRead(self: *Checker, expr: ast.Expr, state: *DefInitState, ctx: Context) void {
        switch (expr.kind) {
            .ident => |id| {
                if (state.contains(id.text)) {
                    self.errorCode(expr.span, "E_USE_BEFORE_INIT", "scalar variable initialized with `uninit` is read before it is assigned on all paths");
                }
            },
            .address_of => |inner| self.diUseTarget(inner.*, state, ctx),
            .grouped => |inner| self.diRead(inner.*, state, ctx),
            .unary => |u| self.diRead(u.expr.*, state, ctx),
            .binary => |b| {
                self.diRead(b.left.*, state, ctx);
                self.diRead(b.right.*, state, ctx);
            },
            .cast => |c| self.diRead(c.value.*, state, ctx),
            .call => |c| {
                self.diRead(c.callee.*, state, ctx);
                for (c.args) |arg| self.diRead(arg, state, ctx);
            },
            .index => |n| {
                self.diRead(n.base.*, state, ctx);
                self.diRead(n.index.*, state, ctx);
            },
            .slice => |n| {
                self.diRead(n.base.*, state, ctx);
                self.diRead(n.start.*, state, ctx);
                self.diRead(n.end.*, state, ctx);
            },
            .deref => |inner| self.diRead(inner.*, state, ctx),
            .member => |m| self.diRead(m.base.*, state, ctx),
            .array_literal => |items| for (items) |item| self.diRead(item, state, ctx),
            .struct_literal => |fields| for (fields) |field| self.diRead(field.value, state, ctx),
            .block => |b| {
                var inner = self.diCloneState(state);
                defer inner.deinit();
                _ = self.diBlock(b, &inner, ctx);
            },
            .try_expr => |t| {
                self.diRead(t.operand.*, state, ctx);
                if (t.mapped) |m| self.diRead(m.*, state, ctx);
            },
            else => {},
        }
    }

    // An assignment/address-of target (or a base used as storage). A pending var whose
    // address or storage is used this way may be initialized through that reference, so
    // it is cleared (conservatively assigned) rather than reported as a read. Index
    // subexpressions are still read-checked.
    fn diUseTarget(self: *Checker, target: ast.Expr, state: *DefInitState, ctx: Context) void {
        switch (target.kind) {
            .ident => |id| {
                _ = state.remove(id.text);
            },
            .grouped => |inner| self.diUseTarget(inner.*, state, ctx),
            .member => |m| self.diUseTarget(m.base.*, state, ctx),
            .index => |n| {
                self.diUseTarget(n.base.*, state, ctx);
                self.diRead(n.index.*, state, ctx);
            },
            .deref => |inner| self.diRead(inner.*, state, ctx),
            else => self.diRead(target, state, ctx),
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
                    // `var x: T = uninit;` (e.g. an expression-`switch` desugar temp): bind a
                    // void placeholder so a following assignment can fill it.
                    if (init_expr.kind == .uninit_literal) {
                        scope.bind(local.names[0].text, .void) catch {};
                        if (local.ty) |lty| if (eval.comptimeTypeBitWidth(lty)) |bits| scope.bindWidth(local.names[0].text, bits);
                        continue;
                    }
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
                .expr => |expr| {
                    // `comptime_error("message")` as a block statement: a custom compile-time
                    // diagnostic (section 22), better than the generic trap for documenting a
                    // failed generic constraint.
                    if (comptimeErrorMessage(expr)) |msg| {
                        self.errorCode(span, "E_COMPTIME_ERROR", msg);
                        continue;
                    }
                    var single = [_]ast.Stmt{stmt};
                    switch (eval.foldComptimeBlock(scope, .{ .span = stmt.span, .items = &single })) {
                        .ok, .unknown => {},
                        .trap => self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error"),
                    }
                },
                .assignment, .loop, .@"switch" => {
                    var single = [_]ast.Stmt{stmt};
                    switch (eval.foldComptimeBlock(scope, .{ .span = stmt.span, .items = &single })) {
                        .ok, .unknown => {},
                        .trap => self.errorCode(span, "E_COMPTIME_TRAP", "trap during const eval is a compile error"),
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
    // Folds layout reflection to a constant ONLY where the result is provably
    // the same as the C-ABI value clang computes for the lowered type: scalar,
    // pointer, fixed-array, enum/packed repr, and ordered struct/field layouts.
    // Anything else returns null, so the assertion simply does not fold (no
    // false positive/negative).

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
            .field_offset => self.comptimeFieldOffset(ty, reflectionFieldFromCall(node) orelse return null, 0),
            .bit_offset => self.comptimeBitOffset(ty, reflectionFieldFromCall(node) orelse return null, 0),
            .repr => self.comptimeReprOf(ty, 0),
            else => null,
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
                    if (env.tagged_unions.get(name.text)) |info| return self.comptimeTaggedUnionSize(info, depth);
                    if (env.enums.get(name.text)) |info| {
                        const repr = info.repr orelse simpleNameType("isize", ty.span);
                        return self.comptimeSizeOf(repr, depth + 1);
                    }
                }
                return null;
            },
            .pointer, .raw_many_pointer => return 8,
            .slice => return 16,
            .generic => |g| {
                if (isPointerLikeGeneric(g.base.text)) return 8;
                if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
                if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return self.comptimeSizeOf(g.args[0], depth + 1);
                if ((std.mem.eql(u8, g.base.text, "atomic") or std.mem.eql(u8, g.base.text, "MaybeUninit")) and g.args.len == 1) return self.comptimeSizeOf(g.args[0], depth + 1);
                if (isArithmeticLayoutGeneric(g.base.text) and g.args.len == 1) return self.comptimeSizeOf(g.args[0], depth + 1);
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
                    if (env.tagged_unions.get(name.text)) |info| return self.comptimeTaggedUnionAlign(info, depth);
                    if (env.enums.get(name.text)) |info| {
                        const repr = info.repr orelse simpleNameType("isize", ty.span);
                        return self.comptimeAlignOf(repr, depth + 1);
                    }
                }
                return null;
            },
            .pointer, .raw_many_pointer, .slice => return 8,
            .generic => |g| {
                if (isPointerLikeGeneric(g.base.text)) return 8;
                if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
                if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                if ((std.mem.eql(u8, g.base.text, "atomic") or std.mem.eql(u8, g.base.text, "MaybeUninit")) and g.args.len == 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                if (isArithmeticLayoutGeneric(g.base.text) and g.args.len == 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                return null;
            },
            .array => |node| return self.comptimeAlignOf(node.child.*, depth + 1),
            .qualified => |node| return self.comptimeAlignOf(node.child.*, depth + 1),
            else => return null,
        }
    }

    // C-ABI struct layout over the supported reflection subset. Explicit
    // `@offset(N)` fields are honored for MMIO register maps.
    fn comptimeStructSize(self: *Checker, info: StructInfo, depth: usize) ?i128 {
        const layout = self.comptimeStructLayout(info, null, depth) orelse return null;
        return layout.size;
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

    const TaggedUnionPayloadLayout = struct {
        has_payload: bool,
        size: i128,
        alignment: i128,
    };

    fn comptimeTaggedUnionSize(self: *Checker, info: UnionInfo, depth: usize) ?i128 {
        if (depth > 32) return null;
        const payload = self.comptimeTaggedUnionPayloadLayout(info, depth + 1) orelse return null;
        var offset: i128 = c_tagged_union_tag_size;
        var max_align: i128 = c_tagged_union_tag_align;
        if (payload.has_payload) {
            if (payload.alignment > max_align) max_align = payload.alignment;
            offset = alignForward(offset, payload.alignment) orelse return null;
            offset += payload.size;
        }
        return alignForward(offset, max_align);
    }

    fn comptimeTaggedUnionAlign(self: *Checker, info: UnionInfo, depth: usize) ?i128 {
        if (depth > 32) return null;
        const payload = self.comptimeTaggedUnionPayloadLayout(info, depth + 1) orelse return null;
        return if (payload.has_payload and payload.alignment > c_tagged_union_tag_align)
            payload.alignment
        else
            c_tagged_union_tag_align;
    }

    fn comptimeTaggedUnionPayloadLayout(self: *Checker, info: UnionInfo, depth: usize) ?TaggedUnionPayloadLayout {
        var has_payload = false;
        var max_size: i128 = 0;
        var max_align: i128 = 1;
        var it = info.cases.valueIterator();
        while (it.next()) |maybe_payload| {
            const payload_ty = maybe_payload.* orelse continue;
            has_payload = true;
            const size = self.comptimeSizeOf(payload_ty, depth + 1) orelse return null;
            const alignment = self.comptimeAlignOf(payload_ty, depth + 1) orelse return null;
            if (alignment <= 0) return null;
            if (size > max_size) max_size = size;
            if (alignment > max_align) max_align = alignment;
        }
        return .{
            .has_payload = has_payload,
            .size = alignForward(max_size, max_align) orelse return null,
            .alignment = max_align,
        };
    }

    fn comptimeFieldOffset(self: *Checker, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
        if (depth > 32) return null;
        const name = typeName(ty) orelse return null;
        const env = self.reflect_env orelse return null;
        if (env.aliases.get(name)) |aliased| return self.comptimeFieldOffset(aliased, field, depth + 1);
        if (env.structs.get(name)) |info| {
            const layout = self.comptimeStructLayout(info, field, depth + 1) orelse return null;
            return layout.field_offset;
        }
        if (env.overlay_unions.get(name)) |info| {
            if (info.fields.contains(field)) return 0;
        }
        return null;
    }

    fn comptimeBitOffset(self: *Checker, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
        if (depth > 32) return null;
        const name = typeName(ty) orelse return null;
        const env = self.reflect_env orelse return null;
        if (env.aliases.get(name)) |aliased| return self.comptimeBitOffset(aliased, field, depth + 1);
        if (env.packed_bits.get(name)) |info| {
            for (info.ordered, 0..) |packed_field, bit| {
                if (std.mem.eql(u8, packed_field.name.text, field)) return @intCast(bit);
            }
            return null;
        }
        const byte_offset = self.comptimeFieldOffset(ty, field, depth + 1) orelse return null;
        return byte_offset * 8;
    }

    fn comptimeReprOf(self: *Checker, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (depth > 32) return null;
        switch (ty.kind) {
            .name => |name| {
                if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
                const env = self.reflect_env orelse return null;
                if (env.aliases.get(name.text)) |aliased| return self.comptimeReprOf(aliased, depth + 1);
                if (env.enums.get(name.text)) |info| {
                    const repr = info.repr orelse simpleNameType("isize", ty.span);
                    return self.comptimeSizeOf(repr, depth + 1);
                }
                if (env.packed_bits.get(name.text)) |info| {
                    const repr = info.repr orelse return null;
                    return self.comptimeSizeOf(repr, depth + 1);
                }
                if (env.tagged_unions.contains(name.text)) return c_tagged_union_tag_size;
                return self.comptimeSizeOf(ty, depth + 1);
            },
            .pointer, .raw_many_pointer, .slice, .array, .generic => return self.comptimeSizeOf(ty, depth + 1),
            .qualified => |node| return self.comptimeReprOf(node.child.*, depth + 1),
            else => return null,
        }
    }

    const ComptimeStructLayout = struct {
        size: i128,
        field_offset: ?i128 = null,
    };

    fn comptimeStructLayout(self: *Checker, info: StructInfo, want_field: ?[]const u8, depth: usize) ?ComptimeStructLayout {
        var offset: i128 = 0;
        var max_align: i128 = 1;
        var found: ?i128 = null;
        for (info.ordered) |field| {
            const size = self.comptimeSizeOf(field.ty, depth + 1) orelse return null;
            const alignment = self.comptimeAlignOf(field.ty, depth + 1) orelse return null;
            if (alignment <= 0) return null;
            if (alignment > max_align) max_align = alignment;
            if (field.offset) |explicit| {
                const explicit_offset: i128 = @intCast(explicit);
                if (explicit_offset < offset) return null;
                offset = explicit_offset;
            } else {
                offset = alignForward(offset, alignment) orelse return null;
            }
            if (want_field) |wanted| {
                if (std.mem.eql(u8, field.name.text, wanted)) found = offset;
            }
            offset += size;
        }
        return .{
            .size = alignForward(offset, max_align) orelse return null,
            .field_offset = found,
        };
    }

    // Returns the folded comptime value of `expr`, or null if it is not a
    // compile-time constant (section 22).
    fn comptimeFoldValue(self: *Checker, expr: ast.Expr) ?eval.ComptimeValue {
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var scope = eval.ComptimeScope.init(fba.allocator());
        self.seedComptimeScope(&scope);
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
        self.seedComptimeScope(&scope);
        for (fn_decl.params, args) |param, arg| {
            if (!param.is_comptime) continue;
            if (isTypeName(param.ty, "type")) {
                const ty = eval.comptimeTypeArg(&scope, arg) orelse return;
                scope.bindType(param.name.text, ty) catch return;
                continue;
            }
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
                    if (loop.kind == .@"while" and condition == .secret) {
                        self.errorCode(expr.span, "E_SECRET_BRANCH", "secret value cannot drive a loop condition; this would leak it through control-flow timing");
                    } else if (loop.kind == .@"while" and !isConditionType(condition)) {
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
                self.seedComptimeScope(&scope);
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
                // Verify the register/clobber facts the precise-asm contract would
                // otherwise only trust: real registers, one architecture per block,
                // and no register named by two operands or by both an operand and a
                // clobber (an unsupported constraint combination).
                self.checkAsmConstraints(asm_stmt, stmt.span);
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
                const fn_pointer_checked = if (local.ty) |ty| self.checkFunctionPointerInitializer(ty, expr, ctx) else false;
                const address_class_checked = if (local.ty != null) checkAddressClassConversion(self, expr.span, kind, initializer) else false;
                const enum_checked = if (local.ty) |ty| self.checkEnumValueCompatibility(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const union_checked = if (local.ty) |ty| self.checkTaggedUnionConstructorCompatibility(ty, expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(expr, ctx, "E_NO_IMPLICIT_CONVERSION", "annotated local initializer requires an explicit conversion") else false;
                const secret_checked = if (local.ty) |ty| (kind == .secret and self.checkSecretWrapInitializer(ty, expr, ctx)) else false;
                if (local.ty == null and untargeted_union_checked) {
                    // The diagnostic was emitted above; constructor calls need an explicit union target.
                } else if (local.ty != null and !literal_checked and !null_checked and !null_target_checked and !targetless_literal_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(kind, initializer)) {
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
        if (self.isQualifiedOwner(name.text)) {
            self.errorCode(name.span, "E_RESERVED_QUALIFIED_NAME", "a local binding may not shadow a module/impl name");
            return;
        }
        if (scope.contains(name.text)) {
            self.errorCode(name.span, "E_DUPLICATE_LOCAL", "local bindings must have unique names in the current scope");
            return;
        }
        scope.put(name.text, info) catch {
            self.oom = true;
        };
    }

    fn isQualifiedOwner(self: *Checker, name: []const u8) bool {
        for (self.qualified_owners) |owner| {
            if (std.mem.eql(u8, owner, name)) return true;
        }
        return false;
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
        const fn_pointer_checked = self.checkFunctionPointerInitializer(target_ty, value, ctx);
        const address_class_checked = checkAddressClassConversion(self, value.span, target_class, value_class);
        const enum_checked = self.checkEnumValueCompatibility(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(target_ty, value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(value, ctx, "E_NO_IMPLICIT_CONVERSION", "assignment requires an explicit conversion") else false;
        const secret_checked = target_class == .secret and self.checkSecretWrapInitializer(target_ty, value, ctx);
        // T1.1 lexical region/scope borrows: storing the address of local storage into a
        // location that outlives that local (a `*out`/`out.field` written through a pointer
        // parameter) makes the borrow dangle once the function returns. Reject it.
        if ((isNonNullPointerLike(target_class) or isNullablePointerLike(target_class)) and
            localAddressRoot(value, ctx) != null and assignmentTargetEscapesFunction(target, ctx))
        {
            self.errorCode(value.span, "E_BORROW_ESCAPES_SCOPE", "cannot store the address of local storage where it outlives the local's scope (the borrow would dangle)");
        }
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(target_class, value_class)) {
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
                if (ctx.no_lang_trap and isTrapBinary(node.op) and !isNoTrapArithmeticDomainOp(node.op, left, right) and !isNonTrappingFloatOp(node.op, left, right) and !(self.optimize and divModProvablySafe(node.op, left, node.right.*))) {
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
                    self.checkComparisonOperatorOperands(expr.span, node.op, left, right, ctx.in_unsafe);
                }
                if (isPointerArithmeticBinary(node.op) and (isSingleObjectPointerLike(left) or isSingleObjectPointerLike(right))) {
                    self.errorCode(expr.span, "E_POINTER_ARITH_SINGLE_OBJECT", "single-object pointers do not support arithmetic");
                }
                // Constant-time: offsetting a pointer by a secret is a secret-dependent
                // memory address — the same cache leak as a secret array index.
                if (isPointerArithmeticBinary(node.op) and (isPointerLike(left) or isPointerLike(right)) and (left == .secret or right == .secret)) {
                    self.errorCode(expr.span, "E_SECRET_INDEX", "secret value cannot offset a pointer; a secret-dependent memory access leaks it through the cache");
                }
                if (isBitwiseBinary(node.op) and (isCheckedSigned(left) or isCheckedSigned(right))) {
                    self.errorCode(expr.span, "E_BITWISE_SIGNED_OPERAND", "bitwise operations are not defined on signed checked integers");
                }
                // `&`/`|`/`^` on two bools is the bitwise spelling of logical and/or/xor (0/1
                // values). MC normally forbids it, but permits it inside `unsafe` as a C-compat
                // escape hatch (e.g. machine-generated kernel code). A single bool mixed with a
                // non-bool operand is always rejected.
                if (isBitwiseBinary(node.op) and (left == .bool or right == .bool) and
                    !(ctx.in_unsafe and left == .bool and right == .bool))
                {
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
                if (isComparisonBinary(node.op)) {
                    // A comparison touching a secret produces a *secret* bool, not a
                    // plain bool: it must not be usable as a branch/switch condition
                    // (that would leak the secret through control flow). Constant-time
                    // code selects on it via bitmask/CMOV helpers after `declassify`.
                    if (left == .secret or right == .secret) return .secret;
                    return .bool;
                }
                // `bool & bool` (the unsafe C-compat case above) yields a bool.
                if (isBitwiseBinary(node.op) and ctx.in_unsafe and left == .bool and right == .bool) return .bool;
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
                // `arc_get_mut` proves uniqueness only at the instant of its refcount check; the
                // language has no borrow analysis to stop a later `arc_clone` from aliasing the
                // returned `*mut T`. So it requires an unsafe context, where the caller asserts
                // it will not clone or publish the handle while the pointer is live.
                if (isIdentNamed(node.callee.*, "arc_get_mut") and !ctx.in_unsafe) {
                    self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "arc_get_mut yields an aliasable `*mut T` whose uniqueness the checker cannot enforce; it requires an unsafe context (do not arc_clone/publish the handle while the pointer lives)");
                }
                if (ctx.in_comptime and isComptimeForbiddenCall(node.callee.*)) {
                    self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                if (ctx.in_comptime and isMmioRegisterAccessCall(node.callee.*, ctx)) {
                    self.errorCode(expr.span, "E_COMPTIME_FORBIDS_RUNTIME_EFFECT", "comptime code cannot perform runtime hardware or I/O effects");
                }
                self.checkMmioRegisterAccessCall(expr.span, node.callee.*, node.args, ctx);
                self.checkAtomicCall(expr.span, node.callee.*, node.args, ctx);
                self.checkMaybeUninitCall(expr.span, node.callee.*, node.args, ctx);
                self.checkDmaCall(expr.span, node.callee.*, node.args, ctx);
                self.checkMmioMapCall(expr.span, node, ctx);
                self.checkTypeStaticCall(expr.span, node.callee.*, node.args, ctx);
                self.checkResidueCall(expr.span, node.callee.*, node.args, ctx);
                self.checkReduceCall(expr.span, node, ctx);
                self.checkByteViewCall(expr.span, node, ctx);
                const bitcast_class = self.checkBitcastCall(expr.span, node, ctx);
                const raw_many_offset_class = self.checkRawManyOffsetCall(expr.span, node, ctx);
                const reflection_class = self.checkReflectionCall(expr.span, node, ctx);
                if (reflection_class) |class| return class;
                if (self.checkDeclassifyCall(expr.span, node, ctx)) |class| return class;
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
                    // C2: an IRQ/atomic-context function may not call a sleepable op
                    // (heap alloc, mutex/lock acquire, scheduler yield) — that is
                    // "scheduling while atomic" / "sleeping in interrupt".
                    if (ctx.irq_context and function.may_sleep) {
                        self.errorCode(expr.span, "E_SLEEP_IN_ATOMIC", "calling a #[may_sleep] op from an #[irq_context] function (sleeping in interrupt)");
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
                                if (typeArgName(arg, ctx)) |tn| {
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
                // `forget_unchecked(x)`: discard a linear value without releasing it — the
                // explicit, greppable escape hatch for the tail of a destructor / a transfer
                // API that already moved the resource's contents elsewhere. Its deliberately
                // alarming name is the audit signal that no release runs here; unlike `drop`
                // it is the only form legal on a resource.
                if (isForgetUncheckedCall(node.callee.*)) {
                    if (node.args.len != 1) {
                        self.errorCode(expr.span, "E_CALL_ARG_COUNT", "forget_unchecked takes exactly one argument");
                    }
                    // It discards a linear value without releasing it — a leak if misused — so
                    // it is gated behind `unsafe`, not merely a scary name. Only the trusted
                    // tail of a destructor / transfer API (which has already recorded or moved
                    // the resource) should reach for it, and that code is `unsafe`.
                    if (!ctx.in_unsafe) {
                        self.errorCode(expr.span, "E_UNSAFE_REQUIRED", "forget_unchecked discards a linear value without releasing it; it requires an unsafe context");
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
                if (reduceCallReturnClass(node, ctx)) |class| return class;
                if (byteViewCallReturnClass(node)) |class| return class;
                if (bitcast_class) |class| return class;
                if (raw_many_offset_class) |class| return class;
                if (directCallReturnClass(node.callee.*, ctx)) |class| return class;
                if (mathBuiltinCallReturnClass(node.callee.*)) |class| return class;
                if (fnptr_ty) |fpty| return classifyTypeCtx(fpty.kind.fn_pointer.ret.*, ctx);
                return .unknown;
            },
            .index => |node| {
                // OPT (annex E): a provably-in-range constant index never emits a Bounds
                // trap, so under `--optimize` it is allowed in `#[no_lang_trap]` — mirroring
                // the MIR-level bounds-check elision so sema and MIR agree.
                if (ctx.no_lang_trap and !(self.optimize and self.indexProvablyInBounds(node.base.*, node.index.*, ctx))) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "indexing may trap in #[no_lang_trap]");
                }
                const base_class = self.checkExpr(node.base.*, ctx);
                if (!isIndexableBase(base_class)) {
                    self.errorCode(node.base.span, "E_INDEX_BASE_NOT_ARRAY_OR_SLICE", "indexing is defined only for arrays and slices");
                }
                const index_class = self.checkExpr(node.index.*, ctx);
                // Constant-time: a secret value cannot be used as an array/slice
                // index (nor, by the same token, a pointer offset). A secret-dependent
                // memory access reveals the secret through the data-cache footprint.
                if (index_class == .secret) {
                    self.errorCode(node.index.span, "E_SECRET_INDEX", "secret value cannot be used as an array index; a secret-dependent memory access leaks it through the cache — declassify/reveal it first (unsafe) or use a constant-time table scan");
                } else if (!isIndexType(index_class)) {
                    self.errorCode(node.index.span, "E_INDEX_NOT_USIZE", "array and slice indices must be checked usize");
                }
                if (indexResultType(node, ctx)) |ty| return classifyTypeCtx(ty, ctx);
                return .unknown;
            },
            .slice => |node| {
                // A constant range into a fixed array provably never traps, so under `--optimize`
                // it is allowed in `#[no_lang_trap]` — mirroring the const-index elision (annex E).
                if (ctx.no_lang_trap and !(self.optimize and self.sliceProvablyInBounds(node.base.*, node.start.*, node.end.*, ctx))) {
                    self.errorCode(expr.span, "E_NO_LANG_TRAP_EDGE", "range slicing may trap in #[no_lang_trap]");
                }
                const base_class = self.checkExpr(node.base.*, ctx);
                if (!isIndexableBase(base_class)) {
                    self.errorCode(node.base.span, "E_INDEX_BASE_NOT_ARRAY_OR_SLICE", "slicing is defined only for arrays and slices");
                }
                const start_class = self.checkExpr(node.start.*, ctx);
                if (!isIndexType(start_class)) {
                    self.errorCode(node.start.span, "E_INDEX_NOT_USIZE", "slice range bounds must be checked usize");
                }
                const end_class = self.checkExpr(node.end.*, ctx);
                if (!isIndexType(end_class)) {
                    self.errorCode(node.end.span, "E_INDEX_NOT_USIZE", "slice range bounds must be checked usize");
                }
                if (sliceResultType(node, ctx)) |ty| return classifyTypeCtx(ty, ctx);
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
                // A direct `.field` on a UserPtr<T> is a kernel dereference of user memory:
                // reading T's field reaches through the user pointer. Forbid it exactly like
                // `p.*` — the only path to a user value is a checked copy_from_user/copy_to_user.
                if (base_class == .user_ptr) {
                    self.errorCode(expr.span, "E_USER_PTR_DEREF", "cannot directly access a field through UserPtr; copy it in with copy_from_user first");
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
                if (globalType(ident.text, ctx)) |ty| {
                    if (classifyTypeCtx(ty, ctx) == .fn_pointer) return;
                }
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

    fn checkMaybeUninitCall(self: *Checker, span: diagnostics.Span, callee: ast.Expr, args: []ast.Expr, ctx: Context) void {
        const member = switch (callee.kind) {
            .member => |node| node,
            .grouped => |inner| {
                self.checkMaybeUninitCall(span, inner.*, args, ctx);
                return;
            },
            else => return,
        };
        if (!std.mem.eql(u8, member.name.text, "write") and !std.mem.eql(u8, member.name.text, "assume_init")) return;
        const payload_ty = maybeUninitPayloadTypeForValue(member.base.*, ctx) orelse return;
        if (std.mem.eql(u8, member.name.text, "write")) {
            if (args.len != 1) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "MaybeUninit.write expects exactly one payload argument");
                return;
            }
            const source = self.checkExpr(args[0], ctx);
            self.checkCallArgument(payload_ty, args[0], source, ctx);
            self.checkMaybeUninitWritePayload(payload_ty, args[0], ctx);
            return;
        }
        if (args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "MaybeUninit.assume_init does not take arguments");
        }
    }

    fn checkMaybeUninitWritePayload(self: *Checker, payload_ty: ast.TypeExpr, arg: ast.Expr, ctx: Context) void {
        const payload_name = structNameOfType(payload_ty, ctx) orelse return;
        if (isStructLiteral(arg)) return;
        const arg_ty = exprDeclaredType(arg, ctx) orelse {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "MaybeUninit.write payload must match the storage type");
            return;
        };
        const arg_name = structNameOfType(arg_ty, ctx) orelse {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "MaybeUninit.write payload must match the storage type");
            return;
        };
        if (!std.mem.eql(u8, payload_name, arg_name)) {
            self.errorCode(arg.span, "E_NO_IMPLICIT_CONVERSION", "MaybeUninit.write payload must match the storage type");
        }
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

        const is_dma_op = std.mem.eql(u8, member.name.text, "dma_addr") or
            std.mem.eql(u8, member.name.text, "as_slice");
        if (dmaBufInfoForValue(member.base.*, ctx)) |info| {
            if (!is_dma_op) {
                self.errorCode(member.name.span, "E_DMA_OPERATION", "unknown DmaBuf operation");
                return;
            }
            if (args.len != 0) {
                self.errorCode(span, "E_CALL_ARG_COUNT", "DmaBuf operation does not take arguments");
            }
            _ = info;
            return;
        }
        // The base is not a DmaBuf. `dma_addr`/`as_slice` are defined only on DmaBuf values
        // (section 18 — the device-address vs CPU-view bridge), so calling them on anything else
        // is ill-typed. Without this the checker silently accepted e.g. `someArray.as_slice()`
        // (the result still typed as a slice), which no backend can lower — LLVM rejected it with
        // UnsupportedLlvmEmission, a check-vs-backend inconsistency. Any other member call on a
        // non-DmaBuf base is some other construct, so leave it to the remaining checkers.
        if (is_dma_op) {
            self.errorCode(member.name.span, "E_DMA_OPERATION", "dma_addr/as_slice are defined only on DmaBuf values");
            _ = self.checkExpr(member.base.*, ctx);
        }
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
        const kind = reduceCallKind(call.callee.*) orelse return;
        const requires_float = kind != .sum_checked;
        if (call.type_args.len != 1) {
            self.errorCode(span, if (requires_float) "E_REDUCE_REQUIRES_FLOAT" else "E_REDUCE_REQUIRES_INTEGER", if (requires_float) "floating-point reduction requires exactly one f32/f64 type argument" else "reduce.sum_checked requires exactly one integer type argument");
            return;
        }
        const t = call.type_args[0];
        const t_name = typeName(t) orelse {
            self.errorCode(t.span, if (requires_float) "E_REDUCE_REQUIRES_FLOAT" else "E_REDUCE_REQUIRES_INTEGER", if (requires_float) "floating-point reductions are restricted to f32/f64" else "reduce.sum_checked is restricted to integer types");
            return;
        };
        if (!requires_float and !isIntegerScalarName(t_name)) {
            self.errorCode(t.span, "E_REDUCE_REQUIRES_INTEGER", "reduce.sum_checked is restricted to integer types");
        }
        if (requires_float and !isFloatScalarName(t_name)) {
            self.errorCode(t.span, "E_REDUCE_REQUIRES_FLOAT", "floating-point reductions are restricted to f32/f64");
        }
        if (call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "reduction expects exactly one slice argument");
            return;
        }
        // The argument is type-checked by the enclosing call arm; here we only
        // confirm it is a slice (§8.2/§8.3: `xs: []const T`).
        const arg_ty = exprResultType(call.args[0], ctx) orelse exprStorageType(call.args[0], ctx) orelse return;
        const arg_class = classifyTypeCtx(arg_ty, ctx);
        if (arg_class != .slice) {
            self.errorCode(call.args[0].span, "E_REDUCE_ARG_NOT_SLICE", "reduction expects a slice (`[]const T`) of the element type");
            return;
        }
        const elem_ty = storageElementType(resolveAliasType(arg_ty, ctx)) orelse return;
        const elem_class = classifyTypeCtx(elem_ty, ctx);
        const target_class = classifyTypeCtx(t, ctx);
        if (elem_class != target_class) {
            self.errorCode(call.args[0].span, "E_REDUCE_ARG_NOT_SLICE", "reduction slice element type must match the reduction type argument");
        }
    }

    fn checkByteViewCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) void {
        const kind = byteViewCallKind(call.callee.*) orelse return;
        if (call.type_args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "byte-view operations do not take type arguments");
        }
        switch (kind) {
            .as_bytes => {
                if (call.args.len != 1) {
                    self.errorCode(span, "E_CALL_ARG_COUNT", "mem.as_bytes expects exactly one address argument");
                    return;
                }
                const inner = switch (call.args[0].kind) {
                    .address_of => |target| target.*,
                    .grouped => |grouped| switch (grouped.kind) {
                        .address_of => |target| target.*,
                        else => {
                            self.errorCode(call.args[0].span, "E_BYTE_VIEW_ADDRESS", "mem.as_bytes requires an address expression");
                            return;
                        },
                    },
                    else => {
                        self.errorCode(call.args[0].span, "E_BYTE_VIEW_ADDRESS", "mem.as_bytes requires an address expression");
                        return;
                    },
                };
                const source_ty = exprResultType(inner, ctx) orelse exprStorageType(inner, ctx) orelse {
                    self.errorCode(call.args[0].span, "E_BYTE_VIEW_ADDRESS", "mem.as_bytes requires an addressable value with known storage type");
                    return;
                };
                const resolved = resolveAliasType(source_ty, ctx);
                if (isTypeName(resolved, "void") or isTypeName(resolved, "never")) {
                    self.errorCode(call.args[0].span, "E_BYTE_VIEW_ADDRESS", "mem.as_bytes requires byte-addressable storage");
                }
            },
            .bytes_equal => {
                if (call.args.len != 2) {
                    self.errorCode(span, "E_CALL_ARG_COUNT", "mem.bytes_equal expects exactly two byte slices");
                    return;
                }
                for (call.args) |arg| {
                    const arg_ty = exprResultType(arg, ctx) orelse exprStorageType(arg, ctx) orelse continue;
                    if (!isConstU8SliceType(resolveAliasType(arg_ty, ctx))) {
                        self.errorCode(arg.span, "E_BYTE_VIEW_SLICE", "mem.bytes_equal expects []const u8 byte slices");
                    }
                }
            },
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

    // `declassify(secret)` / `reveal(secret)` — the controlled escape from the
    // constant-time discipline. It takes a `Secret<T>` and yields a plain T, so
    // its result is no longer secret-tainted and CAN feed branches/indices. Because
    // that defeats the leak protection, it is only allowed inside `unsafe` (the
    // caller asserts the timing channel is acceptable here). Returns the inner-T
    // class so taint stops propagating; null if this isn't a declassify call.
    fn checkDeclassifyCall(self: *Checker, span: diagnostics.Span, call: anytype, ctx: Context) ?TypeClass {
        if (!isDeclassifyCallName(call.callee.*)) return null;
        if (call.type_args.len != 0 or call.args.len != 1) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "declassify/reveal takes exactly one secret value argument");
            return .unknown;
        }
        if (!ctx.in_unsafe) {
            self.errorCode(span, "E_UNSAFE_REQUIRED", "declassify/reveal escapes the constant-time discipline and requires unsafe");
        }
        const arg = call.args[0];
        const arg_class = self.checkExpr(arg, ctx);
        if (arg_class != .secret) {
            self.errorCode(arg.span, "E_DECLASSIFY_NOT_SECRET", "declassify/reveal applies only to a Secret<T> value");
            return .unknown;
        }
        // Result is the underlying T, classified from Secret<T>'s payload type.
        const arg_ty = exprResultType(arg, ctx) orelse exprStorageType(arg, ctx);
        if (arg_ty) |ty| {
            if (secretPayloadType(resolveAliasType(ty, ctx))) |inner| return classifyTypeCtx(inner, ctx);
        }
        return .unknown;
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

    // ----- T(term)1: bounded-loop / no-unbounded-recursion check ----------------
    //
    // A function in IRQ/atomic context (or marked `#[bounded]`) must terminate:
    // a kernel can't hang inside an interrupt. Static termination is undecidable
    // in general, so we recognize SHAPES (not prove termination):
    //
    //   * `for x in ARR/SLICE` — always accepted (iteration is over a finite,
    //     fixed-extent base; the type checker already enforces the base is an
    //     array or slice via E_FOR_BASE_NOT_ARRAY_OR_SLICE).
    //   * `while COUNTER </<=/>/>= BOUND { …; COUNTER = COUNTER +/- k; … }` —
    //     accepted when the condition is a relational comparison naming a local
    //     `COUNTER`, and the body monotonically advances that same counter toward
    //     the bound (increment with `<`/`<=`, decrement with `>`/`>=`). `BOUND`
    //     may be any expression (constant, length, field) — we bound the trip
    //     count by the counter's monotone progress, not by evaluating the bound.
    //   * any `while`/`for` whose body contains a `break` — accepted (the break
    //     is an escape hatch; we do not prove it is reached).
    //
    // Everything else is rejected with E_UNBOUNDED_LOOP — notably `while true {}`
    // and any `while cond {}` whose counter is not advanced. This is conservative
    // (false positives on genuinely-bounded but unrecognized shapes), which is
    // why the whole check is opt-in via the attribute.
    //
    // Recursion: DIRECT self-recursion (the function calls itself by name) from a
    // bounded-context function is E_UNBOUNDED_RECURSION. Mutual/indirect recursion
    // is NOT covered.
    fn checkTermination(self: *Checker, fn_name: []const u8, body: ast.Block) void {
        self.checkTerminationBlock(fn_name, body);
    }

    fn checkTerminationBlock(self: *Checker, fn_name: []const u8, block: ast.Block) void {
        for (block.items) |stmt| self.checkTerminationStmt(fn_name, stmt);
    }

    fn checkTerminationStmt(self: *Checker, fn_name: []const u8, stmt: ast.Stmt) void {
        switch (stmt.kind) {
            .loop => |loop| {
                if (!loopIsBounded(loop)) {
                    self.errorCode(stmt.span, "E_UNBOUNDED_LOOP", "loop in a bounded/IRQ-context function is not statically bounded (no monotone counter toward a bound, fixed-range for, or break)");
                }
                self.checkTerminationBlock(fn_name, loop.body);
            },
            .if_let => |node| {
                self.checkTerminationBlock(fn_name, node.then_block);
                if (node.else_block) |eb| self.checkTerminationBlock(fn_name, eb);
            },
            .@"switch" => |node| {
                for (node.arms) |arm| switch (arm.body) {
                    .block => |b| self.checkTerminationBlock(fn_name, b),
                    .expr => |e| self.checkTerminationExpr(fn_name, e),
                };
            },
            .unsafe_block, .comptime_block, .block => |b| self.checkTerminationBlock(fn_name, b),
            .contract_block => |cb| self.checkTerminationBlock(fn_name, cb.block),
            .@"return" => |maybe| {
                if (maybe) |e| self.checkTerminationExpr(fn_name, e);
            },
            .@"defer" => |e| self.checkTerminationExpr(fn_name, e),
            .assert => |e| self.checkTerminationExpr(fn_name, e),
            .assignment => |a| {
                self.checkTerminationExpr(fn_name, a.target);
                self.checkTerminationExpr(fn_name, a.value);
            },
            .expr => |e| self.checkTerminationExpr(fn_name, e),
            .let_decl, .var_decl => |local| {
                if (local.init) |e| self.checkTerminationExpr(fn_name, e);
            },
            .asm_stmt, .@"break", .@"continue" => {},
        }
    }

    fn checkTerminationExpr(self: *Checker, fn_name: []const u8, expr: ast.Expr) void {
        switch (expr.kind) {
            .call => |c| {
                // Direct self-recursion: callee is the bare name of this function.
                if (c.callee.kind == .ident and std.mem.eql(u8, c.callee.kind.ident.text, fn_name)) {
                    self.errorCode(expr.span, "E_UNBOUNDED_RECURSION", "direct recursion from a bounded/IRQ-context function (a kernel must not recurse unboundedly in interrupt/atomic context)");
                }
                self.checkTerminationExpr(fn_name, c.callee.*);
                for (c.args) |arg| self.checkTerminationExpr(fn_name, arg);
            },
            .block => |b| self.checkTerminationBlock(fn_name, b),
            .grouped, .address_of, .deref => |inner| self.checkTerminationExpr(fn_name, inner.*),
            .unary => |u| self.checkTerminationExpr(fn_name, u.expr.*),
            .binary => |b| {
                self.checkTerminationExpr(fn_name, b.left.*);
                self.checkTerminationExpr(fn_name, b.right.*);
            },
            .cast => |c| self.checkTerminationExpr(fn_name, c.value.*),
            .index => |i| {
                self.checkTerminationExpr(fn_name, i.base.*);
                self.checkTerminationExpr(fn_name, i.index.*);
            },
            .slice => |s| {
                self.checkTerminationExpr(fn_name, s.base.*);
                self.checkTerminationExpr(fn_name, s.start.*);
                self.checkTerminationExpr(fn_name, s.end.*);
            },
            .member => |m| self.checkTerminationExpr(fn_name, m.base.*),
            .try_expr => |t| {
                self.checkTerminationExpr(fn_name, t.operand.*);
                if (t.mapped) |m| self.checkTerminationExpr(fn_name, m.*);
            },
            .array_literal => |items| for (items) |it| self.checkTerminationExpr(fn_name, it),
            .struct_literal => |fields| for (fields) |f| self.checkTerminationExpr(fn_name, f.value),
            else => {},
        }
    }

    // A loop matches a recognized statically-bounded shape (see checkTermination).
    fn loopIsBounded(loop: ast.Loop) bool {
        if (loop.kind == .@"for") return true; // iterates a finite array/slice
        // `while`: a relational comparison whose counter is advanced monotonically
        // toward the bound, or any loop body carrying a `break`.
        if (blockHasBreak(loop.body)) return true;
        const cond = loop.iterable orelse return false;
        const counter = relationalCounter(cond) orelse return false;
        return bodyAdvancesCounter(loop.body, counter.name, counter.toward_increase);
    }

    const CounterRel = struct { name: []const u8, toward_increase: bool };

    // Recognize `COUNTER < BOUND` / `<=` / `>` / `>=` where one side is a bare
    // identifier. `toward_increase` is true when the counter must grow to reach
    // the bound (`<`, `<=`), false when it must shrink (`>`, `>=`).
    fn relationalCounter(cond: ast.Expr) ?CounterRel {
        const expr = if (cond.kind == .grouped) cond.kind.grouped.* else cond;
        const b = switch (expr.kind) {
            .binary => |bin| bin,
            else => return null,
        };
        const counter_on_left: bool = b.left.kind == .ident;
        const counter_on_right: bool = b.right.kind == .ident;
        if (!counter_on_left and !counter_on_right) return null;
        const name = if (counter_on_left) b.left.kind.ident.text else b.right.kind.ident.text;
        // Direction the counter must move to *stay in* the loop's bound, i.e.
        // toward making the condition false. `i < N`: i increases. `i > 0`: i
        // decreases. When the counter is the right operand, flip.
        const increases: bool = switch (b.op) {
            .lt, .le => true,
            .gt, .ge => false,
            else => return null,
        };
        return .{ .name = name, .toward_increase = if (counter_on_left) increases else !increases };
    }

    fn blockHasBreak(block: ast.Block) bool {
        for (block.items) |stmt| if (stmtHasBreak(stmt)) return true;
        return false;
    }

    // A `break` that escapes *this* loop. Breaks nested inside an inner loop
    // belong to that inner loop, so we do not descend into nested loop bodies.
    fn stmtHasBreak(stmt: ast.Stmt) bool {
        return switch (stmt.kind) {
            .@"break" => true,
            .loop => false,
            .if_let => |n| blockHasBreak(n.then_block) or (if (n.else_block) |eb| blockHasBreak(eb) else false),
            .@"switch" => |n| blk: {
                for (n.arms) |arm| switch (arm.body) {
                    .block => |b| if (blockHasBreak(b)) break :blk true,
                    .expr => {},
                };
                break :blk false;
            },
            .unsafe_block, .comptime_block, .block => |b| blockHasBreak(b),
            .contract_block => |cb| blockHasBreak(cb.block),
            else => false,
        };
    }

    // The loop body assigns `name = name +/- k` (or `name = k +/- name`) in the
    // direction that drives the condition false. Recognizes the common increment
    // (`i = i + 1`) and decrement (`i = i - 1`) shapes; also `i = i + step`.
    fn bodyAdvancesCounter(block: ast.Block, name: []const u8, toward_increase: bool) bool {
        for (block.items) |stmt| if (stmtAdvancesCounter(stmt, name, toward_increase)) return true;
        return false;
    }

    fn stmtAdvancesCounter(stmt: ast.Stmt, name: []const u8, toward_increase: bool) bool {
        return switch (stmt.kind) {
            .assignment => |a| blk: {
                if (a.target.kind != .ident or !std.mem.eql(u8, a.target.kind.ident.text, name)) break :blk false;
                const v = if (a.value.kind == .grouped) a.value.kind.grouped.* else a.value;
                const bin = switch (v.kind) {
                    .binary => |b| b,
                    else => break :blk false,
                };
                const refs_left = bin.left.kind == .ident and std.mem.eql(u8, bin.left.kind.ident.text, name);
                const refs_right = bin.right.kind == .ident and std.mem.eql(u8, bin.right.kind.ident.text, name);
                if (!refs_left and !refs_right) break :blk false;
                // `+` advances the counter up; `-` advances it down. (`k - i`
                // is not a monotone self-update, so require the counter on the
                // left for subtraction.)
                break :blk switch (bin.op) {
                    .add => toward_increase,
                    .sub => !toward_increase and refs_left,
                    else => false,
                };
            },
            // Recurse into nested control flow so the update may sit under a
            // conditional/block — still the same loop body.
            .if_let => |n| blk: {
                if (bodyAdvancesCounter(n.then_block, name, toward_increase)) break :blk true;
                if (n.else_block) |eb| if (bodyAdvancesCounter(eb, name, toward_increase)) break :blk true;
                break :blk false;
            },
            .unsafe_block, .comptime_block, .block => |b| bodyAdvancesCounter(b, name, toward_increase),
            .contract_block => |cb| bodyAdvancesCounter(cb.block, name, toward_increase),
            else => false,
        };
    }

    // ----- inline-asm register/constraint verification (§23.2) ------------------
    //
    // The backends lower precise-asm operands with generic `"r"` constraints and
    // keep the requested registers only as a provenance comment — the contract
    // *trusts* the register facts. These checks *verify* them so a per-architecture
    // precise-asm block is portable-by-construction: each named register is real,
    // the block names registers of a single architecture, and no register is bound
    // to two operands or clobbered while also holding an operand.

    const AsmArch = enum { x86_64, riscv64, aarch64 };

    // Strip the lexeme's surrounding quotes (registers/clobbers are stored as
    // `"rax"`, including the quotes — matching how the lowering emits them).
    fn asmUnquote(reg: []const u8) []const u8 {
        if (reg.len >= 2 and reg[0] == '"' and reg[reg.len - 1] == '"') return reg[1 .. reg.len - 1];
        return reg;
    }

    // `memory` / `cc` are architecture-neutral pseudo-clobbers, valid everywhere.
    fn asmIsPseudoClobber(name: []const u8) bool {
        return std.mem.eql(u8, name, "memory") or std.mem.eql(u8, name, "cc");
    }

    // A generic (machine-independent or register-class) constraint code — a single
    // letter such as `r` (any register), `m` (memory), `i`/`n` (immediate), `f`
    // (float register), or the x86 class letters `a`/`b`/`c`/`d`. These are not
    // physical registers: they are architecture-neutral and may be repeated across
    // operands (two `"r"` operands are two distinct registers), so they are exempt
    // from the per-architecture and register-conflict checks. Named physical
    // registers are always longer than one character (`rax`, `a0`, `x0`, …), so a
    // single alphabetic token is unambiguously a constraint code.
    fn asmIsGenericConstraint(name: []const u8) bool {
        return name.len == 1 and std.ascii.isAlphabetic(name[0]);
    }

    // The architecture a register name unambiguously belongs to, or null when the
    // name is shared across architectures (`x0..x30`, `sp`) — those are accepted
    // but do not pin the block's architecture, so they never cause a false mismatch.
    // Returns error.Unknown for a name that is not a register on any supported arch.
    fn asmRegisterArch(name: []const u8) error{Unknown}!?AsmArch {
        const x86 = [_][]const u8{ "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
        for (x86) |r| if (std.mem.eql(u8, name, r)) return .x86_64;
        // RISC-V ABI names that are unambiguous (excludes `sp`, shared with aarch64).
        const rv = [_][]const u8{ "zero", "ra", "gp", "tp", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7" };
        for (rv) |r| if (std.mem.eql(u8, name, r)) return .riscv64;
        // AArch64 names that are unambiguous (`w0..w30`, `xzr`, `wzr`, `lr`).
        if (std.mem.eql(u8, name, "xzr") or std.mem.eql(u8, name, "wzr") or std.mem.eql(u8, name, "lr")) return .aarch64;
        if (asmNumberedReg(name, "w", 0, 30)) return .aarch64;
        // Shared / ambiguous: `x0..x31` (riscv x-regs ∩ aarch64 x-regs) and `sp`.
        if (std.mem.eql(u8, name, "sp")) return null;
        if (asmNumberedReg(name, "x", 0, 31)) return null;
        // ----- vector / floating-point register files -----
        // x86-64 SSE/AVX/AVX-512: xmm/ymm/zmm 0..31.
        if (asmNumberedReg(name, "xmm", 0, 31) or asmNumberedReg(name, "ymm", 0, 31) or asmNumberedReg(name, "zmm", 0, 31)) return .x86_64;
        // RISC-V floating-point: `f0..f31` plus the ABI names `ft`/`fs`/`fa`.
        if (asmNumberedReg(name, "ft", 0, 11) or asmNumberedReg(name, "fs", 0, 11) or asmNumberedReg(name, "fa", 0, 7) or asmNumberedReg(name, "f", 0, 31)) return .riscv64;
        // AArch64 SIMD/FP register views: q (128b), d (64b), h (16b), b (8b). The `s` (32b)
        // view is intentionally omitted — it collides with the RISC-V saved-GPR ABI names
        // `s1..s11`, so it would be ambiguous.
        if (asmNumberedReg(name, "q", 0, 31) or asmNumberedReg(name, "d", 0, 31) or asmNumberedReg(name, "h", 0, 31) or asmNumberedReg(name, "b", 0, 31)) return .aarch64;
        // The vector register file `v0..v31` is shared (RISC-V vector ∩ AArch64 SIMD) — neutral.
        if (asmNumberedReg(name, "v", 0, 31)) return null;
        return error.Unknown;
    }

    // True when `name` is `prefix` followed by a decimal in [lo, hi] (no leading zeros).
    fn asmNumberedReg(name: []const u8, prefix: []const u8, lo: u32, hi: u32) bool {
        if (!std.mem.startsWith(u8, name, prefix)) return false;
        const digits = name[prefix.len..];
        if (digits.len == 0 or digits.len > 2) return false;
        if (digits.len == 2 and digits[0] == '0') return false;
        const n = std.fmt.parseInt(u32, digits, 10) catch return false;
        return n >= lo and n <= hi;
    }

    fn checkAsmConstraints(self: *Checker, asm_stmt: ast.AsmStmt, span: diagnostics.Span) void {
        var block_arch: ?AsmArch = null;

        // Unify a named register into the block's architecture (or flag a mismatch),
        // reporting an unknown register. Pseudo-clobbers are skipped by the caller.
        const unify = struct {
            fn call(checker: *Checker, sp: diagnostics.Span, arch: *?AsmArch, raw: []const u8) void {
                const name = asmUnquote(raw);
                if (asmIsGenericConstraint(name)) return; // arch-neutral; not a physical register
                const reg_arch = asmRegisterArch(name) catch {
                    checker.errorCode(sp, "E_ASM_UNKNOWN_REGISTER", "inline-asm names a register that is not valid on any supported architecture");
                    return;
                };
                if (reg_arch) |a| {
                    if (arch.* == null) {
                        arch.* = a;
                    } else if (arch.* != a) {
                        checker.errorCode(sp, "E_ASM_ARCH_MIXED", "inline-asm block mixes registers from more than one architecture");
                    }
                }
            }
        }.call;

        // Named operand registers must be unique across outputs+inputs. A generic
        // constraint code (`"r"`, `"m"`, …) is not a physical register and may repeat,
        // so it is exempt from both the conflict and the architecture checks.
        var used = std.StringHashMap(void).init(self.reporter.allocator);
        defer used.deinit();
        for (asm_stmt.outputs) |output| {
            const name = asmUnquote(output.reg);
            unify(self, span, &block_arch, output.reg);
            if (asmIsGenericConstraint(name)) continue;
            if (used.contains(name)) {
                self.errorCode(span, "E_ASM_REGISTER_CONFLICT", "inline-asm binds the same register to more than one operand");
            } else used.put(name, {}) catch {};
        }
        for (asm_stmt.inputs) |input| {
            const name = asmUnquote(input.reg);
            unify(self, span, &block_arch, input.reg);
            if (asmIsGenericConstraint(name)) continue;
            if (used.contains(name)) {
                self.errorCode(span, "E_ASM_REGISTER_CONFLICT", "inline-asm binds the same register to more than one operand");
            } else used.put(name, {}) catch {};
        }
        // A clobber may not name a register an operand already holds, and a non-pseudo,
        // non-generic clobber participates in architecture unification too.
        for (asm_stmt.clobbers) |clobber| {
            const name = asmUnquote(clobber);
            if (asmIsPseudoClobber(name) or asmIsGenericConstraint(name)) continue;
            unify(self, span, &block_arch, clobber);
            if (used.contains(name)) {
                self.errorCode(span, "E_ASM_CLOBBER_CONFLICT", "inline-asm clobbers a register it also binds to an operand");
            }
        }
    }

    // `#[backend_name("Y")]` overrides the object symbol; two declarations may not map to the
    // same backend symbol, or one would silently shadow the other at link time.
    fn checkBackendNameUniqueness(self: *Checker, module: ast.Module) void {
        var seen = std.StringHashMap(ast.Ident).init(self.reporter.allocator);
        defer seen.deinit();
        for (module.decls) |decl| {
            const name_ident: ast.Ident = switch (decl.kind) {
                .fn_decl => |f| f.name,
                .extern_fn => |f| f.name,
                else => continue,
            };
            const override = backendNameAttr(decl.attrs) orelse continue;
            if (seen.get(override)) |prev| {
                self.reporter.err(name_ident.span, "E_DUPLICATE_BACKEND_NAME: backend symbol \"{s}\" is assigned to both `{s}` and `{s}`", .{ override, prev.text, name_ident.text });
            } else {
                seen.put(override, name_ident) catch {};
            }
        }
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
        const errors_before = self.reporter.diagnostics.items.len;
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
            self.checkReflectedField(kind, reflected_ty, field, ctx);
        } else if (target.args.len != 0) {
            self.errorCode(span, "E_CALL_ARG_COUNT", "type reflection builtin does not take runtime arguments");
        }

        if (kind == .field_type and self.reporter.diagnostics.items.len == errors_before) {
            self.errorCode(span, "E_REFLECTION_TYPE_VALUE", "field_type produces a type and is valid only in type position");
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
        var reflection_ctx = ctx;
        reflection_ctx.allow_mmio_register_type = true;
        self.checkReflectedGenericTypeArgs(ty, reflection_ctx);
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

    fn checkReflectedField(self: *Checker, kind: ReflectionKind, ty: ast.TypeExpr, field: ast.Ident, ctx: Context) void {
        const name = typeName(ty) orelse {
            self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
            return;
        };
        if (layoutFieldInfo(name, ctx)) |info| {
            if (!info.fields.contains(field.text)) {
                self.errorCode(field.span, "E_UNKNOWN_STRUCT_FIELD", "layout type has no field with this name");
            }
        } else if (kind == .field_type) {
            const tagged_unions = ctx.tagged_unions orelse {
                self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
                return;
            };
            const union_info = tagged_unions.get(name) orelse {
                self.errorCode(ty.span, "E_REFLECTION_UNKNOWN_TYPE", "field reflection requires a known field-bearing layout type");
                return;
            };
            const payload_ty = union_info.cases.get(field.text) orelse {
                self.errorCode(field.span, "E_UNKNOWN_STRUCT_FIELD", "layout type has no field with this name");
                return;
            };
            if (payload_ty == null) {
                self.errorCode(field.span, "E_UNION_CASE_HAS_NO_PAYLOAD", "union case has no payload type");
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
        // `Secret<intT>` accepts an in-range integer literal, range-checked against
        // the inner integer type (a literal is the natural way to introduce a key
        // byte / constant secret).
        if (target == .secret) {
            const inner = secretPayloadType(resolveAliasType(target_ty, ctx)) orelse return false;
            const bounds = checkedIntBounds(classifyTypeCtx(inner, ctx)) orelse return false;
            if (value.negative) {
                if (!bounds.signed or value.magnitude > bounds.min_abs) {
                    self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
                }
            } else if (value.magnitude > bounds.max) {
                self.errorCode(expr.span, "E_INTEGER_LITERAL_OUT_OF_RANGE", "integer literal is not representable in the annotated type");
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

    // A plain value of T (or another Secret<T>) may initialize/assign a Secret<T>:
    // classifying a value as secret is a non-narrowing tag, range-checked by the
    // inner type's own rules. Returns true if it handled the initializer (so the
    // caller skips the generic E_NO_IMPLICIT_CONVERSION gate).
    fn checkSecretWrapInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        const inner = secretPayloadType(resolveAliasType(target_ty, ctx)) orelse return false;
        const value_class = self.checkExpr(expr, ctx);
        // Already a secret (Secret<T> -> Secret<T>) or the neutral classes: accept.
        if (value_class == .secret or isDiagnosticNeutralOperand(value_class)) return true;
        // An integer literal is handled by checkIntegerLiteralInitializer; defer.
        if (integerLiteralValue(expr) != null) return false;
        const inner_class = classifyTypeCtx(inner, ctx);
        if (value_class == inner_class) return true;
        self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "Secret<T> can only wrap a value of its underlying type T");
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
            const fn_pointer_checked = self.checkFunctionPointerInitializer(element_ty, item, ctx);
            const address_class_checked = checkAddressClassConversion(self, item.span, element_class, item_class);
            const enum_checked = self.checkEnumValueCompatibility(element_ty, item, ctx, code, message);
            const union_checked = self.checkTaggedUnionConstructorCompatibility(element_ty, item, ctx, code, message);
            const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(item, ctx, code, message) else false;
            if (!literal_checked and !null_checked and !array_literal_checked and !packed_bits_literal_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(element_class, item_class)) {
                self.errorCode(item.span, code, message);
            }
        }
        return true;
    }

    fn checkStructLiteralInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context, code: []const u8, message: []const u8) bool {
        const literal_fields = structLiteralFields(expr) orelse return false;
        const resolved_target_ty = resolveAliasType(target_ty, ctx);
        // An `opaque struct` (including a generic one, e.g. `GenRef<T>`, whose name the
        // plain `structTypeName` below does not resolve) may only be constructed by its
        // own associated functions — a struct literal names every field, so building one
        // outside `impl Name { … }` would forge a handle.
        if (opacityStructName(resolved_target_ty)) |sname| {
            if (ctx.structs) |structs| {
                if (structs.get(sname)) |info| {
                    if (info.is_opaque and !self.opaqueAccessAllowed(sname)) {
                        self.errorCode(expr.span, "E_PRIVATE_FIELD", "cannot construct an `opaque struct` outside its associated functions (`impl` block); its fields are private");
                    }
                }
            }
        }
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
            const fn_pointer_checked = self.checkFunctionPointerInitializer(field_ty, field.value, ctx);
            const address_class_checked = checkAddressClassConversion(self, field.value.span, field_class, value_class);
            const enum_checked = self.checkEnumValueCompatibility(field_ty, field.value, ctx, code, message);
            const union_checked = self.checkTaggedUnionConstructorCompatibility(field_ty, field.value, ctx, code, message);
            const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(field.value, ctx, code, message) else false;
            if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !canInitialize(field_class, value_class)) {
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
        if (!isNonNullPointerLike(target) and !isNullablePointerLike(target)) return false;
        const operand = addressOfOperand(expr) orelse return false;
        const source_ty = addressableStorageType(operand.*, ctx) orelse return true;
        if (!addressOfMatchesPointerTarget(target_ty, source_ty, operand.*, ctx)) {
            self.errorCode(expr.span, "E_NO_IMPLICIT_POINTER_CONVERSION", "pointer and view conversions must be explicit");
        }
        return true;
    }

    fn checkFunctionPointerInitializer(self: *Checker, target_ty: ast.TypeExpr, expr: ast.Expr, ctx: Context) bool {
        if (classifyTypeCtx(target_ty, ctx) != .fn_pointer) return false;
        if (directCallName(expr)) |name| {
            if (ctx.functions != null and ctx.functions.?.contains(name)) {
                if (!functionMatchesFnPointer(name, target_ty, ctx)) {
                    self.errorCode(expr.span, "E_FN_POINTER_SIGNATURE_MISMATCH", "function signature does not match the expected function-pointer type");
                }
                return true;
            }
        }
        const source_ty = exprDeclaredType(expr, ctx) orelse return false;
        if (classifyTypeCtx(source_ty, ctx) != .fn_pointer) return false;
        if (!sameTypeSyntaxCtx(source_ty, target_ty, ctx)) {
            self.errorCode(expr.span, "E_FN_POINTER_SIGNATURE_MISMATCH", "function-pointer signature does not match the expected type");
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
        const fn_pointer_checked = self.checkFunctionPointerInitializer(target_ty, expr, ctx);
        const address_class_checked = checkAddressClassConversion(self, expr.span, target, returned);
        const local_escape_checked = self.checkLocalAddressReturn(target, expr, ctx);
        const enum_checked = self.checkEnumValueCompatibility(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const union_checked = self.checkTaggedUnionConstructorCompatibility(target_ty, expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type");
        const untargeted_union_checked = if (!union_checked) self.checkTaggedUnionConstructorRequiresUnionTarget(expr, ctx, "E_RETURN_TYPE_MISMATCH", "return expression must match the declared return type") else false;
        const secret_checked = target == .secret and self.checkSecretWrapInitializer(target_ty, expr, ctx);
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !fn_pointer_checked and !address_class_checked and !local_escape_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(target, returned)) {
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
        const secret_checked = target == .secret and self.checkSecretWrapInitializer(target_ty, arg, ctx);
        if (!literal_checked and !null_checked and !array_literal_checked and !struct_literal_checked and !packed_bits_literal_checked and !array_decay_checked and !pointer_conversion_checked and !c_void_conversion_checked and !address_checked and !address_class_checked and !enum_checked and !union_checked and !untargeted_union_checked and !secret_checked and !canInitialize(target, source)) {
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

    fn checkComparisonOperatorOperands(self: *Checker, span: diagnostics.Span, op: ast.BinaryOp, left: TypeClass, right: TypeClass, in_unsafe: bool) void {
        if (isAddressClass(left) or isAddressClass(right)) return;
        if (op == .eq or op == .ne) {
            if (equalityOperandsCompatible(left, right)) return;
            // Inside `unsafe`, a bool may be compared against a bare integer literal (`b != 0`,
            // `b != 1`) — bool models a 0/1 value. A C-compat escape hatch for generated code.
            if (in_unsafe and ((left == .bool and right == .int_literal) or (left == .int_literal and right == .bool))) return;
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
        // Field of an `opaque struct` (including a generic one) is private outside its
        // associated functions: outside code may hold and pass the value but not read or
        // write its fields. Checked ahead of the plain-struct field-existence path below,
        // which `structTypeName` skips for a generic base.
        if (opacityStructName(base_ty)) |sname| {
            if (ctx.structs) |structs| {
                if (structs.get(sname)) |info| {
                    if (info.is_opaque and !self.opaqueAccessAllowed(sname)) {
                        self.errorCode(span, "E_PRIVATE_FIELD", "field of an `opaque struct` is private to its associated functions (`impl` block)");
                    }
                }
            }
        }
        const layout_name = structTypeName(base_ty) orelse return;
        const layout_info = layoutFieldInfo(layout_name, ctx) orelse return;
        if (!layout_info.fields.contains(field_name)) {
            self.errorCode(span, "E_UNKNOWN_STRUCT_FIELD", "struct has no field with this name");
        }
    }

    // OPT (annex E) proof obligation for const-index bounds-check elision, mirroring the
    // MIR builder's `indexProvablyInBounds`: the index is a non-negative integer literal `k`,
    // the base names a fixed array of statically-known length `N`, and `k < N`. Conservative
    // (false when not provable), so it can never let an out-of-range access pass.
    fn indexProvablyInBounds(self: *Checker, base: ast.Expr, index: ast.Expr, ctx: Context) bool {
        _ = self;
        const k = constIndexLiteral(index) orelse return false;
        const base_ty = exprStorageType(base, ctx) orelse return false;
        const arr = switch (resolveAliasType(base_ty, ctx).kind) {
            .array => |node| node,
            else => return false,
        };
        const n = parseArrayLen(arr.len, ctx.const_fns, ctx.const_globals) orelse return false;
        return k < n;
    }

    // Const-slice analogue of `indexProvablyInBounds`: both ends are non-negative integer literals
    // into a fixed array of known length, with `start <= end <= len`. Conservative — false on any
    // non-literal bound or unknown base length, so an out-of-range slice is never proven safe.
    fn sliceProvablyInBounds(self: *Checker, base: ast.Expr, start: ast.Expr, end: ast.Expr, ctx: Context) bool {
        _ = self;
        const lo = constIndexLiteral(start) orelse return false;
        const hi = constIndexLiteral(end) orelse return false;
        if (lo > hi) return false; // start <= end
        const base_ty = exprStorageType(base, ctx) orelse return false;
        const arr = switch (resolveAliasType(base_ty, ctx).kind) {
            .array => |node| node,
            else => return false,
        };
        const n = parseArrayLen(arr.len, ctx.const_fns, ctx.const_globals) orelse return false;
        return hi <= n; // end <= len
    }

    // An `opaque struct`'s private fields may be named only by the struct's own associated
    // functions — those declared in `impl Name { … }`, which the parser mangles to the free
    // symbol `Name__member`. Membership is decided on the leading owner segment (the text
    // before the first `__`): an associated function `GenRef__resolve` and the struct
    // `GenRef` share owner `GenRef`. This also survives monomorphization, which appends a
    // `__<args>` specialization suffix to both — the specialized struct `GenRef__u32` and the
    // specialized accessor `GenRef__resolve__u32` still share the owner `GenRef`. The check
    // is purely on (mangled) names, so it also survives the loader's textual-inclusion
    // flattening of imported modules.
    fn opaqueAccessAllowed(self: *Checker, struct_name: []const u8) bool {
        const fname = self.current_fn_name orelse return false;
        return std.mem.eql(u8, ownerSegment(fname), ownerSegment(struct_name));
    }

    // The declared struct name a (possibly generic / pointer / qualified) type names, for
    // opacity lookups. Unlike `structTypeName`, this also resolves a generic application
    // `GenRef<T>` to its base name `GenRef`.
    fn opacityStructName(ty: ast.TypeExpr) ?[]const u8 {
        return switch (ty.kind) {
            .name => |n| n.text,
            .generic => |g| g.base.text,
            .qualified => |q| opacityStructName(q.child.*),
            .pointer => |p| opacityStructName(p.child.*),
            else => null,
        };
    }

    // The leading owner segment of a (possibly mangled) symbol: the text before the first
    // `__`. `impl`/`module` members and monomorphization specializations are all named
    // `Owner__…`, so two symbols belong to the same owner namespace iff their owner segments
    // are equal. A plain symbol with no `__` is its own owner.
    fn ownerSegment(name: []const u8) []const u8 {
        if (std.mem.indexOf(u8, name, "__")) |idx| return name[0..idx];
        return name;
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
        // Constant-time: a secret value must never steer control flow. Both `if`
        // (desugared to a bool `switch`) and `switch` route through here, so this
        // one check forbids `if (secret …)` and `switch (secret) { … }` alike —
        // including a secret *bool* produced by `secret == k`. Reveal it first.
        if (subject_class == .secret) {
            self.errorCode(node.subject.span, "E_SECRET_BRANCH", "secret value cannot drive a branch or switch; this would leak it through control-flow timing — use declassify/reveal (unsafe) or a constant-time select");
        }
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
            // A secret subject is already rejected with E_SECRET_BRANCH above;
            // skip per-pattern type checks so the dispositive error isn't buried
            // under spurious pattern/subject mismatches (the bool patterns of a
            // desugared `if secret` would otherwise mismatch the secret class).
            if (subject_class != .secret) self.checkSwitchArmPatterns(arm.patterns, subject_class, subject_ty, ctx);
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
        if (patterns.len > 1 and binding_pattern_count > 0) {
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
            const literal = integerLiteralValue(expr) orelse {
                self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
                return;
            };
            if (checkedIntBounds(subject_class)) |bounds| {
                if (!enumValueFits(enumValueKey(literal), bounds)) {
                    self.errorCode(expr.span, "E_NO_IMPLICIT_CONVERSION", "switch literal pattern must match the subject type");
                }
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
    // C2: the enclosing function runs in IRQ/atomic context (`#[irq_context]`/
    // `#[atomic]`); calling a `#[may_sleep]` op is "sleeping in interrupt".
    irq_context: bool = false,
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


const StructInfo = struct {
    fields: std.StringHashMap(ast.TypeExpr),
    ordered: []const ast.Field,
    // `opaque struct` — fields are private to the struct's associated functions.
    is_opaque: bool = false,
};

// Liveness slot for a linear `move` binding (section 18.1 / annex D.7).
const MoveSlot = struct {
    live: bool,
    span: diagnostics.Span,
    // Reserved by a `defer` to be consumed at scope end: not a leak, not movable.
    deferred: bool = false,
    // The binding's declared/inferred type, when known — used to look up a `move` field's
    // type for place-sensitive field-move tracking. Null for synthetic field place keys.
    ty: ?ast.TypeExpr = null,
};

const LayoutFieldInfo = struct {
    fields: std.StringHashMap(ast.TypeExpr),
    ordered: []const ast.Field,
    repr: ?ast.TypeExpr = null,
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
    // C2: this function is a sleepable op (`#[may_sleep]`) — calling it from an
    // `#[irq_context]`/`#[atomic]` function is a compile error.
    may_sleep: bool = false,
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
            .no_lang_trap, .named, .backend_name, .origin => {},
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

// A declaration that introduces a value-level top-level name (function or global), as opposed
// to a type-level name. Used to reserve qualified-owner names against value shadows.
fn isValueLevelDecl(kind: ast.Decl.Kind) bool {
    return switch (kind) {
        .fn_decl, .extern_fn, .global_decl => true,
        else => false,
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
    // `Secret<T>` — a constant-time key/crypto-material tag. Carries T's value
    // and arithmetic but FORBIDS secret-dependent control flow and memory
    // access (branch/switch condition, array index, pointer offset, deref) so a
    // secret value can never steer a timing- or cache-observable decision.
    secret,
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

// C2 (IRQ/atomic-context discipline): bare `#[name]` attributes parse as `.named`.
// `#[irq_context]` marks a function that runs in interrupt/atomic context;
// `#[may_sleep]` marks an op that may block (heap alloc, mutex/lock acquire,
// scheduler yield). An irq-context fn may not call a may_sleep op. (`atomic` is a
// reserved keyword, so the synonym attribute name is `#[atomic_context]`.)
fn hasNamedAttr(attrs: []ast.Attr, name: []const u8) bool {
    for (attrs) |attr| switch (attr.kind) {
        .named => |id| if (std.mem.eql(u8, id.text, name)) return true,
        else => {},
    };
    return false;
}

fn hasIrqContext(attrs: []ast.Attr) bool {
    return hasNamedAttr(attrs, "irq_context") or hasNamedAttr(attrs, "atomic_context");
}

fn hasMaySleep(attrs: []ast.Attr) bool {
    return hasNamedAttr(attrs, "may_sleep");
}

// T(term)1: `#[bounded]` opts a function into the bounded-loop / no-unbounded-
// recursion check (so does `#[irq_context]`/`#[atomic_context]`, since a kernel
// must never hang in an interrupt). Every loop in such a function must match a
// recognized statically-bounded shape (or carry a `break`), and the function may
// not recurse into itself. See `checkTermination`.
fn hasBoundedContext(attrs: []ast.Attr) bool {
    return hasIrqContext(attrs) or hasNamedAttr(attrs, "bounded");
}

fn backendNameAttr(attrs: []ast.Attr) ?[]const u8 {
    for (attrs) |attr| switch (attr.kind) {
        .backend_name => |name| return name,
        else => {},
    };
    return null;
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

// Sema mirror of the MIR builder's `divModProvablySafe` (annex E): a `div`/`mod` by a
// non-zero integer-literal divisor cannot divide by zero, and for a signed dividend it
// cannot hit the only checked overflow (`INT_MIN / -1`) unless the divisor is `-1`. So
// under `--optimize` such an operation is non-trapping and allowed in `#[no_lang_trap]`.
// Conservative (false unless provable), so it can never admit a real trap.
fn divModProvablySafe(op: ast.BinaryOp, left: TypeClass, divisor: ast.Expr) bool {
    if (op != .div and op != .mod) return false;
    const d = integerLiteralValue(divisor) orelse return false;
    if (d.magnitude == 0) return false;
    if (isCheckedSigned(left)) return !(d.negative and d.magnitude == 1);
    return !d.negative;
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
    return isDiagnosticNeutralOperand(kind) or isIntegerLike(kind) or isArithmeticDomain(kind) or isFloatish(kind) or kind == .secret;
}

fn isBitwiseOperand(kind: TypeClass) bool {
    return isDiagnosticNeutralOperand(kind) or isCheckedUnsigned(kind) or kind == .int_literal or kind == .wrap or kind == .secret;
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
        kind == .secret or
        isPointerLike(kind) or
        kind == .null_literal;
}

fn equalityOperandsCompatible(left: TypeClass, right: TypeClass) bool {
    if (!isEqualityOperand(left) or !isEqualityOperand(right)) return false;
    if (isDiagnosticNeutralOperand(left) or isDiagnosticNeutralOperand(right)) return true;
    // A secret may be compared against another secret or an integer literal; the
    // result is itself secret (see checkExpr) so it cannot reach a branch.
    if (left == .secret or right == .secret) {
        return (left == .secret or isIntegerLike(left)) and (right == .secret or isIntegerLike(right));
    }
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
    // Secret taint propagates: any operation involving a secret yields a secret,
    // so derived values stay constant-time-constrained (no declassification by
    // arithmetic). `declassify`/`reveal` (behind unsafe) is the only escape.
    if (left == .secret or right == .secret) return .secret;
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

// Definite-init (S0.1) tracks only single-storage SCALAR vars: a whole-variable
// assignment definitely initializes them, and a plain read is a use of the whole
// value. Aggregates (arrays, structs, unions, slices, results, …) are filled
// element/field-at-a-time and are not whole-variable trackable here, so they are
// never made pending (avoids false positives on the `buf[i] = …` / `s.f = …` idiom).
fn diIsScalarType(ty: ast.TypeExpr, ctx: Context) bool {
    return switch (classifyTypeCtx(ty, ctx)) {
        .checked_u8, .checked_u16, .checked_u32, .checked_u64, .checked_usize, .checked_i8, .checked_i16, .checked_i32, .checked_i64, .checked_isize, .wrap, .sat, .serial, .counter, .pointer, .raw_many_pointer, .c_void_pointer, .nullable_pointer, .nullable_c_void_pointer, .paddr, .vaddr, .dma_addr, .user_ptr, .mmio_ptr, .phys_ptr, .secret, .fn_pointer, .bool, .f32, .f64, .duration, .order => true,
        // Not tracked: array, slice, atomic, dma_buf, result, void, never, the
        // literal/unknown classes (structs/enums/unions/generics resolve to .unknown).
        else => false,
    };
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

fn maybeUninitPayloadType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "MaybeUninit") or node.args.len != 1) return null;
            return node.args[0];
        },
        .qualified => |node| maybeUninitPayloadType(node.child.*),
        else => null,
    };
}

fn maybeUninitPayloadTypeForValue(expr: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const ty = exprResultType(expr, ctx) orelse exprStorageType(expr, ctx) orelse return null;
    return maybeUninitPayloadType(resolveAliasType(ty, ctx));
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

fn isFloatScalarName(name: []const u8) bool {
    return std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64");
}

fn reduceCallReturnClass(call: anytype, ctx: Context) ?TypeClass {
    const kind = reduceCallKind(call.callee.*) orelse return null;
    return switch (kind) {
        .sum_checked => .result,
        .sum_left, .sum_fast => if (call.type_args.len == 1) classifyTypeCtx(call.type_args[0], ctx) else .unknown,
    };
}


fn byteViewCallReturnClass(call: anytype) ?TypeClass {
    const kind = byteViewCallKind(call.callee.*) orelse return null;
    return switch (kind) {
        .as_bytes => .slice,
        .bytes_equal => .bool,
    };
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

fn maybeUninitCallReturnType(callee: ast.Expr, ctx: Context) ?ast.TypeExpr {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return maybeUninitCallReturnType(inner.*, ctx),
        else => return null,
    };
    if (!std.mem.eql(u8, member.name.text, "assume_init")) return null;
    return maybeUninitPayloadTypeForValue(member.base.*, ctx);
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
    if (std.mem.eql(u8, name, "Secret")) return .secret;
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

// A non-negative integer-literal array index value, or null if the index is not a literal.
fn constIndexLiteral(index: ast.Expr) ?usize {
    return switch (index.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .grouped => |inner| constIndexLiteral(inner.*),
        else => null,
    };
}

fn parseArrayLen(expr: ast.Expr, funcs: ?*const std.StringHashMap(ast.FnDecl), globals: ?*const std.StringHashMap(eval.ComptimeValue)) ?usize {
    return switch (expr.kind) {
        .int_literal => |literal| parseUsizeLiteral(literal),
        .char_literal => |literal| if (parseCharLiteral(literal)) |value|
            if (value <= std.math.maxInt(usize)) @intCast(value) else null
        else
            null,
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
            .void, .boolean, .float, .tag, .bytes, .array, .@"struct" => null,
        },
        else => null,
    };
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


fn isStaticGlobalInitializer(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .int_literal, .float_literal, .bool_literal, .null_literal, .void_literal, .enum_literal, .string_literal, .char_literal => true,
        .ident => |ident| (if (ctx.globals) |globals| globals.contains(ident.text) else false) or
            (if (ctx.functions) |functions| functions.contains(ident.text) else false),
        .unary => |node| node.op == .neg and (integerLiteralValue(node.expr.*) != null or negativeFloatLiteralOperand(node.expr.*)),
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

fn negativeFloatLiteralOperand(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .float_literal => true,
        .grouped => |inner| negativeFloatLiteralOperand(inner.*),
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
        .nullable => |child| addressOfMatchesPointerTarget(child.*, source_child, operand, ctx),
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
        // A struct-field array base (`x.field[k]`): the field's declared type, so a constant
        // index into a fixed-size struct field is provably in bounds too. Mirrors the MIR
        // builder's `baseTypeExpr` member case.
        .member => |node| blk: {
            const base_ty = exprStorageType(node.base.*, ctx) orelse break :blk null;
            const struct_name = structTypeName(base_ty) orelse break :blk null;
            const structs = ctx.structs orelse break :blk null;
            const info = structs.get(struct_name) orelse break :blk null;
            break :blk info.fields.get(node.name.text);
        },
        // An arithmetic/bitwise binary expression has the type of its operands. This lets a
        // `bitcast<f32>((a + b) << c)` learn its source's integer type (the shift/add result
        // is the left operand's type; a literal operand carries none, so prefer the other side).
        .binary => |node| arithmeticBinaryType(node, ctx),
        .unary => |node| if (node.op == .neg) exprStorageType(node.expr.*, ctx) else null,
        else => null,
    };
}

// The result type of an arithmetic/bitwise binary operator: the type of whichever operand
// carries a concrete type (a bare literal operand has none). Comparison/logical operators are
// handled by the caller (they yield bool), so this only sees value-producing operators.
// Operands are resolved via `exprResultType` so a nested call (`bitcast<T>(..)`, a function
// call) contributes its return type, not just storage-typed idents.
fn arithmeticBinaryType(node: anytype, ctx: Context) ?ast.TypeExpr {
    if (isComparisonBinary(node.op) or isLogicalBinary(node.op)) return null;
    // For a shift, the result type is the left (shifted) operand's type.
    if (node.op == .shl or node.op == .shr) return exprResultType(node.left.*, ctx);
    return exprResultType(node.left.*, ctx) orelse exprResultType(node.right.*, ctx);
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
        .call => |node| constGetReturnType(node, ctx) orelse rawManyOffsetReturnType(node, ctx) orelse byteViewCallReturnType(node) orelse atomicCallReturnType(node.callee.*, ctx) orelse maybeUninitCallReturnType(node.callee.*, ctx) orelse bitcastCallReturnType(node) orelse mathBuiltinReturnType(node.callee.*) orelse if (node.type_args.len == 0) directCallReturnType(node.callee.*, ctx) else null,
        .try_expr => |inner| tryPayloadType(inner.operand.*, ctx),
        .cast => |node| node.ty.*,
        .deref => |inner| derefResultType(inner.*, ctx),
        .index => |node| indexResultType(node, ctx),
        .slice => |node| sliceResultType(node, ctx),
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

// The float result type of a pass-through math builtin call (`__builtin_sqrtf` -> f32,
// `__builtin_sqrt` -> f64), so a `let x: f32 = __builtin_sqrtf(..)` typechecks.
fn mathBuiltinReturnType(callee: ast.Expr) ?ast.TypeExpr {
    return switch (callee.kind) {
        .ident => |ident| blk: {
            const name = if (mathBuiltinFloatClass(ident.text)) |class| (if (class == .f32) "f32" else "f64") else break :blk null;
            break :blk ast.TypeExpr{ .span = ident.span, .kind = .{ .name = .{ .text = name, .span = ident.span } } };
        },
        .grouped => |inner| mathBuiltinReturnType(inner.*),
        else => null,
    };
}


fn byteViewCallReturnType(call: anytype) ?ast.TypeExpr {
    const kind = byteViewCallKind(call.callee.*) orelse return null;
    return switch (kind) {
        .as_bytes => constU8SliceType(call.callee.*.span),
        .bytes_equal => boolTypeExpr(call.callee.*.span),
    };
}

fn isConstU8SliceType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .slice => |node| node.mutability == .@"const" and isTypeName(node.child.*, "u8"),
        .qualified => |node| isConstU8SliceType(node.child.*),
        else => false,
    };
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

fn sliceResultType(slice: anytype, ctx: Context) ?ast.TypeExpr {
    const base_ty = exprResultType(slice.base.*, ctx) orelse exprStorageType(slice.base.*, ctx) orelse return null;
    return sliceTypeForBase(base_ty, slice.base.*.span);
}

fn sliceTypeForBase(base_ty: ast.TypeExpr, span: diagnostics.Span) ?ast.TypeExpr {
    return switch (base_ty.kind) {
        .slice => base_ty,
        .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
        .qualified => |node| sliceTypeForBase(node.child.*, span),
        else => null,
    };
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

// A direct call to a function declared `-> never` diverges: control never returns
// to the call site (the callee panics/loops/traps). Used by the control-flow
// fall-through and linear-`move` analyses so a `panic()`-style helper ends a path
// exactly like an inline `trap(...)`/`unreachable` does.
fn callReturnsNever(call: anytype, ctx: Context) bool {
    const info = directCallFunction(call.callee.*, ctx) orelse return false;
    const ty = info.return_ty orelse return false;
    return isTypeName(ty, "never");
}

// Whether an expression statement is a direct call to a `-> never` function. The linear
// `move` join treats such a statement as a diverging (Unreachable) path so a resource
// consumed before it is not spuriously re-merged as live on the falling-through arm.
fn exprIsNeverCall(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .call => |node| callReturnsNever(node, ctx),
        .grouped => |inner| exprIsNeverCall(inner.*, ctx),
        else => false,
    };
}

// The type name of a type-parameter argument: either a bare type-name ident or
// the named field type from `field_type(T, .field)`.
fn typeArgName(arg: ast.Expr, ctx: Context) ?[]const u8 {
    return switch (arg.kind) {
        .ident => |id| id.text,
        .grouped => |inner| typeArgName(inner.*, ctx),
        .call => |node| fieldTypeArgName(node, ctx),
        else => null,
    };
}

fn fieldTypeArgName(call: anytype, ctx: Context) ?[]const u8 {
    const kind = reflectionKind(call.callee.*) orelse return null;
    if (kind != .field_type) return null;
    const ty = reflectionTypeFromCall(call) orelse return null;
    const field = reflectionFieldFromCall(call) orelse return null;
    const field_ty = reflectedFieldType(ty, field, ctx) orelse return null;
    return typeName(field_ty);
}

fn reflectedFieldType(ty: ast.TypeExpr, field: []const u8, ctx: Context) ?ast.TypeExpr {
    const name = typeName(ty) orelse return null;
    if (layoutFieldInfo(name, ctx)) |layout| return layout.fields.get(field);
    const tagged_unions = ctx.tagged_unions orelse return null;
    const union_info = tagged_unions.get(name) orelse return null;
    return union_info.cases.get(field) orelse null;
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

// T1.1 lexical region/scope borrows: does an assignment *target* write to storage
// that OUTLIVES the current function's locals — i.e. it writes *through a pointer
// parameter* (a deref of a param pointer, or a field reached through one)?
//
// This is the sound, no-false-positive slice. A bare-ident target (`p = ...`) is a
// same-function local at the (flat) function scope, so it does NOT outlive a local
// referent and is never reported here (that needs nested-scope/lifetime analysis,
// T1.3). Only writes that reach OUT of the function via a `*out`/`out.field` pointer
// parameter can make a stack borrow dangle, so only those escape.
//
// Passing `&local` DOWN to a callee is unaffected (that is a call argument, never an
// assignment target), so the `init(&x); use(x)` idiom keeps compiling.
fn assignmentTargetEscapesFunction(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        // `*p = ...` / `p.field = ...` escape when `p` resolves to a pointer parameter.
        .deref => |inner| pointerParamRoot(inner.*, ctx),
        .member => |node| pointerParamRoot(node.base.*, ctx),
        .index => |node| pointerParamRoot(node.base.*, ctx),
        .grouped => |inner| assignmentTargetEscapesFunction(inner.*, ctx),
        else => false,
    };
}

// Whether `expr` is (or transitively dereferences) a pointer *parameter* — storage the
// caller owns, which outlives this function's stack frame. A local pointer is NOT a
// param and does not qualify (it cannot outlive the function it lives in).
fn pointerParamRoot(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| {
            const binding = (if (ctx.scope) |scope| scope.get(ident.text) else null) orelse return false;
            if (binding.origin != .param) return false;
            const ty = binding.ty orelse return false;
            const class = classifyTypeCtx(ty, ctx);
            return isNonNullPointerLike(class) or isNullablePointerLike(class);
        },
        // Reaching further through a param pointer (`*out.next`, `out.buf[i]`) still
        // bottoms out at the caller-owned storage.
        .deref => |inner| pointerParamRoot(inner.*, ctx),
        .member => |node| pointerParamRoot(node.base.*, ctx),
        .index => |node| pointerParamRoot(node.base.*, ctx),
        .grouped => |inner| pointerParamRoot(inner.*, ctx),
        else => false,
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
        .call => expr.span,
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
    const access = mmioRegisterAccessFromModeType(access_arg) orelse return null;
    return .{ .access = access };
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
    if (std.mem.eql(u8, base, "reduce")) return std.mem.eql(u8, member.name.text, "sum_checked") or std.mem.eql(u8, member.name.text, "sum_left") or std.mem.eql(u8, member.name.text, "sum_fast");
    if (std.mem.eql(u8, base, "mem")) return std.mem.eql(u8, member.name.text, "as_bytes") or std.mem.eql(u8, member.name.text, "bytes_equal");
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

// The message text of a `comptime_error("…")` call (quotes stripped), or null if `expr` is
// not that form. Used to surface a custom comptime diagnostic.
fn comptimeErrorMessage(expr: ast.Expr) ?[]const u8 {
    const call = switch (expr.kind) {
        .call => |node| node,
        .grouped => |inner| return comptimeErrorMessage(inner.*),
        else => return null,
    };
    if (!isIdentNamed(call.callee.*, "comptime_error") or call.args.len != 1) return null;
    return switch (call.args[0].kind) {
        .string_literal => |lit| if (lit.len >= 2) lit[1 .. lit.len - 1] else lit,
        else => null,
    };
}

fn isBuiltinFunctionName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "trap")) return true;
    if (std.mem.eql(u8, name, "comptime_error")) return true; // section 22: comptime diagnostic
    if (std.mem.eql(u8, name, "drop")) return true;
    if (std.mem.eql(u8, name, "forget_unchecked")) return true;
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
    if (mathBuiltinFloatClass(name) != null) return true;
    return false;
}

// Pass-through clang math builtins MC accepts unchanged: `__builtin_sqrtf` (f32->f32) and
// `__builtin_sqrt` (f64->f64). They typecheck as a single-float-argument call returning the
// matching float class, and the C backend emits them verbatim (clang provides them natively).
fn mathBuiltinFloatClass(name: []const u8) ?TypeClass {
    if (std.mem.eql(u8, name, "__builtin_sqrtf")) return .f32;
    if (std.mem.eql(u8, name, "__builtin_sqrt")) return .f64;
    return null;
}

fn mathBuiltinCallReturnClass(callee: ast.Expr) ?TypeClass {
    return switch (callee.kind) {
        .ident => |ident| mathBuiltinFloatClass(ident.text),
        .grouped => |inner| mathBuiltinCallReturnClass(inner.*),
        else => null,
    };
}

fn isBitcastCallName(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "bitcast"),
        .grouped => |inner| isBitcastCallName(inner.*),
        else => false,
    };
}

fn isDeclassifyCallName(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "declassify") or std.mem.eql(u8, ident.text, "reveal"),
        .grouped => |inner| isDeclassifyCallName(inner.*),
        else => false,
    };
}

// The payload type T of a `Secret<T>` type expression, or null if `ty` is not a
// `Secret<...>`. (`ty` should already be alias-resolved.)
fn secretPayloadType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .generic => |node| if (std.mem.eql(u8, node.base.text, "Secret") and node.args.len == 1) node.args[0] else null,
        .qualified => |node| secretPayloadType(node.child.*),
        else => null,
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
    packed_bits: *const std.StringHashMap(LayoutFieldInfo),
    overlay_unions: *const std.StringHashMap(LayoutFieldInfo),
    tagged_unions: *const std.StringHashMap(UnionInfo),
    enums: *const std.StringHashMap(EnumInfo),
    aliases: *const std.StringHashMap(ast.TypeExpr),
};

// The C backend lowers tagged unions as a C enum tag followed by an optional
// payload union. Clang/GCC use a 32-bit enum for this generated tag on the
// supported LP64 targets.
const c_tagged_union_tag_size: i128 = 4;
const c_tagged_union_tag_align: i128 = 4;

// Extract the reflected type from a reflection call's `type_args` or first arg.
fn reflectionTypeFromCall(node: anytype) ?ast.TypeExpr {
    if (node.type_args.len == 1) return node.type_args[0];
    if (node.args.len >= 1) return reflectionTypeExprFromArg(node.args[0]);
    return null;
}

fn reflectionFieldFromCall(node: anytype) ?[]const u8 {
    const field_expr = if (node.type_args.len == 1) blk: {
        if (node.args.len != 1) return null;
        break :blk node.args[0];
    } else blk: {
        if (node.args.len != 2) return null;
        break :blk node.args[1];
    };
    const field = enumLiteralName(field_expr) orelse return null;
    return field.text;
}

fn reflectionRequiresField(kind: ReflectionKind) bool {
    return switch (kind) {
        .field_offset, .field_type, .bit_offset => true,
        .size, .alignment, .repr => false,
    };
}

fn reflectionReturnClass(kind: ReflectionKind) TypeClass {
    return switch (kind) {
        .size, .alignment, .field_offset, .bit_offset, .repr => .checked_usize,
        .field_type => .unknown,
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

// Built-in generics that store their type arguments by value (so they embed a `move` resource
// when an argument does). `Result<T,E>` carries its ok/err payload inline; nullable `?T` and
// arrays are handled structurally elsewhere.
fn genericHoldsArgsByValue(name: []const u8) bool {
    return std.mem.eql(u8, name, "Result");
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
        if (structs.get(name)) |info| return .{ .fields = info.fields, .ordered = info.ordered, .repr = null };
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

// `forget_unchecked(x)` consumes a linear `move` value WITHOUT running any release —
// the unsafe escape hatch for the tail of a destructor / a transfer API that has already
// moved the resource's contents elsewhere (e.g. recorded a DMA buffer's address before
// discarding the husk). Unlike `drop`, it is legal on a resource, but only in `unsafe`.
fn isForgetUncheckedCall(callee: ast.Expr) bool {
    return isIdentNamed(callee, "forget_unchecked");
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
