//! Inspection-only C metadata emitter.
//!
//! This module is intentionally outside the executable C backend.  It may
//! inspect frontend syntax to produce human-readable compatibility metadata;
//! `lower_c.zig` consumes only verified executable MIR.

const std = @import("std");

const ast = @import("ast.zig");
const builtin_syntax = @import("builtin_syntax.zig");
const expr_syntax = @import("expr_syntax.zig");
const lower_c_atomic = @import("lower_c_atomic.zig");
const lower_c_model = @import("lower_c_model.zig");
const lower_c_op = @import("lower_c_op.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_c_type = @import("lower_c_type.zig");
const type_bridge = @import("type_bridge.zig");

const GlobalAccess = lower_c_model.GlobalAccess;
const GlobalInfo = lower_c_model.GlobalInfo;
const MmioAccess = lower_c_model.MmioAccess;
const MmioField = lower_c_model.MmioField;
const MmioSequenceState = lower_c_model.MmioSequenceState;
const MmioStruct = lower_c_model.MmioStruct;
const CheckedOp = lower_c_op.CheckedOp;
const TrapKind = lower_c_op.TrapKind;
const arithmeticDomainOpName = lower_c_op.arithmeticDomainOpName;
const checkedOpForBinary = lower_c_op.checkedOpForBinary;
const checkedOpName = lower_c_op.checkedOpName;
const floatCTypeName = lower_c_type.floatCTypeName;
const genericChildType = lower_c_shape.genericChildType;
const globalInfoFromType = lower_c_shape.globalInfoFromType;
const isOverflowOp = lower_c_op.isOverflowOp;
const mmioFieldFromType = lower_c_shape.mmioFieldFromType;
const orderingArg = lower_c_atomic.orderingArg;
const widthBits = lower_c_op.widthBits;
const asmHasMemoryClobber = lower_c_atomic.asmHasMemoryClobber;
const atomicOrderCConstant = lower_c_atomic.atomicOrderCConstant;
const atomicOrderSynchronizes = lower_c_atomic.atomicOrderSynchronizes;
const calleeIdentName = expr_syntax.calleeIdentName;
const contractMatchesCallee = builtin_syntax.contractMatchesCallee;
const contractName = expr_syntax.contractName;
const dmaBufInfo = type_bridge.dmaBufInfo;
const isIdentNamed = expr_syntax.isIdentNamed;
const memberCallee = expr_syntax.memberCallee;
const memberExpr = expr_syntax.memberExpr;
const isRawStoreCall = expr_syntax.isRawStoreCall;
const knownContractCalleeName = builtin_syntax.knownContractCalleeName;
const mmioPointee = type_bridge.mmioPointee;
const typeName = type_bridge.typeName;

pub fn appendInspectionFromDecls(allocator: std.mem.Allocator, decls: []const ast.Decl, out: *std.ArrayList(u8)) anyerror!void {
    var inspector = Inspector.init(allocator, out);
    try inspector.inspectDecls(decls);
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

    fn inspectDecls(self: *Inspector, decls: []const ast.Decl) anyerror!void {
        defer self.deinit();
        try self.collectDeclFacts(decls);
        for (decls) |decl| {
            switch (decl.kind) {
                .fn_decl, .extern_fn => |fn_decl| if (fn_decl.body) |body| try self.inspectFn(fn_decl, body),
                .type_alias, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectDeclFacts(self: *Inspector, decls: []const ast.Decl) !void {
        for (decls) |decl| {
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
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .union_decl, .opaque_decl, .trait_decl, .impl_trait => {},
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
            // The async transform eliminates every `await_expr` pre-sema.
            .await_expr => unreachable,
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
            .grouped, .move_expr, .address_of, .deref => |inner| try self.inspectExpr(inner.*, ctx),
            .borrow_expr => |node| try self.inspectExpr(node.value.*, ctx),
            .try_expr => |inner| try self.inspectExpr(inner.operand.*, ctx),
            .block => |body| try self.inspectBlock(body, ctx),
            .slice => |node| {
                try self.inspectExpr(node.base.*, ctx);
                try self.inspectExpr(node.start.*, ctx);
                try self.inspectExpr(node.end.*, ctx);
            },
            .unary => |node| {
                if (node.op == .neg) {
                    if (exprType(node.expr.*, ctx)) |ty| {
                        try self.writeCheckedArithmetic(ctx, .neg, ty, .integer_overflow);
                    }
                }
                try self.inspectExpr(node.expr.*, ctx);
            },
            .binary => |node| {
                const op = checkedOpForBinary(node.op);
                if (arithmeticDomainForBinary(node, ctx)) |domain| {
                    try self.writeArithmeticDomainLowering(ctx, domain, node.op);
                } else if (node.op == .shl) {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, op.?, ty, .invalid_shift);
                    try self.writeCheckedArithmetic(ctx, op.?, ty, .integer_overflow);
                } else if (node.op == .shr) {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, op.?, ty, .invalid_shift);
                } else if (op) |checked_op| {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, checked_op, ty, trapKindForBinary(node, ty));
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
                try self.writeFloatReduceMetadata(node, ctx);
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

    fn writeFloatReduceMetadata(self: *Inspector, call: anytype, ctx: *FnContext) !void {
        const kind = expr_syntax.reduceCallKind(call.callee.*) orelse return;
        const member = memberCallee(call.callee.*) orelse return;
        const is_left = kind == .sum_left;
        const is_fast = kind == .sum_fast;
        if (!is_left and !is_fast) return;
        if (call.type_args.len != 1) return;

        const mc_type = typeName(call.type_args[0]) orelse return;
        const c_type = floatCTypeName(call.type_args[0]) orelse return;
        try self.out.print(
            self.allocator,
            "lower float_reduce fn={s} op={s} type={s} c_type={s} strict_left_fold={} reassociate={} vectorize={} target_dependent={}\n",
            .{ ctx.name, member.name.text, mc_type, c_type, is_left, is_fast, is_fast, is_fast },
        );
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
        if (!isBitcastCall(call)) return;
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
        const member = memberExpr(callee) orelse return null;
        const kind: []const u8 = if (std.mem.eql(u8, member.name.text, "read"))
            "read"
        else if (std.mem.eql(u8, member.name.text, "write"))
            "write"
        else
            return null;

        const reg_member = memberExpr(member.base.*) orelse return null;
        const param = calleeIdentName(reg_member.base.*) orelse return null;
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

// These classifiers intentionally live with inspection. They recover readable
// metadata from parsed declarations and are not part of executable lowering.
fn atomicAccess(callee: anytype, args: anytype, ctx: anytype) ?lower_c_model.AtomicAccess {
    const member = memberExpr(callee) orelse return null;
    const object = calleeIdentName(member.base.*) orelse return null;
    const payload = ctx.local_atomic_payloads.get(object) orelse return null;
    if (std.mem.eql(u8, member.name.text, "load")) {
        const ordering = lower_c_atomic.atomicOrderingArg(args, 0);
        if (!lower_c_atomic.isAtomicLoadOrdering(ordering)) return null;
        return .{ .op = "load", .object = object, .payload_type = payload, .ordering = ordering };
    }
    if (std.mem.eql(u8, member.name.text, "store")) {
        const ordering = lower_c_atomic.atomicOrderingArg(args, 1);
        if (!lower_c_atomic.isAtomicStoreOrdering(ordering)) return null;
        return .{ .op = "store", .object = object, .payload_type = payload, .ordering = ordering };
    }
    if (std.mem.eql(u8, member.name.text, "fetch_add") or std.mem.eql(u8, member.name.text, "fetch_sub")) {
        if (!lower_c_atomic.isAtomicIntegerPayload(payload)) return null;
        const ordering = lower_c_atomic.atomicOrderingArg(args, 1);
        if (atomicOrderCConstant(ordering) == null) return null;
        return .{ .op = member.name.text, .object = object, .payload_type = payload, .ordering = ordering };
    }
    return null;
}

fn dmaOperation(callee: anytype, args: anytype, ctx: anytype) ?lower_c_model.DmaOperation {
    const member = memberExpr(callee) orelse return null;
    if (isIdentNamed(member.base.*, "cache")) {
        if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return null;
        if (args.len != 1) return null;
        const object = calleeIdentName(args[0]) orelse return null;
        const payload = ctx.local_dma_payloads.get(object) orelse return null;
        const mode = ctx.local_dma_modes.get(object) orelse return null;
        if (!std.mem.eql(u8, mode, "noncoherent")) return null;
        return .{ .kind = member.name.text, .object = object, .payload = payload, .mode = mode };
    }
    const object = calleeIdentName(member.base.*) orelse return null;
    const payload = ctx.local_dma_payloads.get(object) orelse return null;
    const mode = ctx.local_dma_modes.get(object) orelse return null;
    if (std.mem.eql(u8, member.name.text, "dma_addr") and args.len == 0)
        return .{ .kind = "dma_addr", .object = object, .payload = payload, .mode = mode };
    if (std.mem.eql(u8, member.name.text, "as_slice") and args.len == 0)
        return .{ .kind = "as_slice", .object = object, .payload = payload, .mode = mode };
    return null;
}

fn dmaAddrHandoffObject(value: anytype, ctx: anytype) ?[]const u8 {
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

fn exprType(expr: anytype, ctx: anytype) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ctx.local_types.get(ident.text),
        .grouped => |inner| exprType(inner.*, ctx),
        .unary => |node| exprType(node.expr.*, ctx),
        else => null,
    };
}

fn arithmeticDomainForBinary(node: anytype, ctx: anytype) ?[]const u8 {
    if (lower_c_op.isWrapPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, "wrap") and exprHasArithmeticDomain(node.right.*, ctx, "wrap")) return "wrap";
    if (expr_syntax.isSatPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, "sat") and exprHasArithmeticDomain(node.right.*, ctx, "sat")) return "sat";
    return null;
}

fn exprHasArithmeticDomain(expr: anytype, ctx: anytype, domain: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| if (ctx.local_domains.get(ident.text)) |found| std.mem.eql(u8, found, domain) else false,
        .grouped => |inner| exprHasArithmeticDomain(inner.*, ctx, domain),
        .binary => |node| if (std.mem.eql(u8, domain, "wrap"))
            lower_c_op.isWrapPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, domain) and exprHasArithmeticDomain(node.right.*, ctx, domain)
        else if (std.mem.eql(u8, domain, "sat"))
            expr_syntax.isSatPreservingBinary(node.op) and exprHasArithmeticDomain(node.left.*, ctx, domain) and exprHasArithmeticDomain(node.right.*, ctx, domain)
        else
            false,
        else => false,
    };
}

fn ordinaryGlobalTarget(allocator: std.mem.Allocator, target: anytype, ctx: anytype, globals: std.StringHashMap(GlobalInfo), structs: anytype) ?GlobalAccess {
    return switch (target.kind) {
        .ident => |ident| if (!ctx.locals.contains(ident.text)) if (globals.get(ident.text)) |global| .{ .name = ident.text, .info = global } else null else null,
        .index => |index| ordinaryGlobalArrayTarget(allocator, index, ctx, globals),
        .member => |member| ordinaryGlobalMemberTarget(allocator, member, ctx, globals, structs),
        .grouped => |inner| ordinaryGlobalTarget(allocator, inner.*, ctx, globals, structs),
        else => null,
    };
}

fn ordinaryGlobalArrayTarget(allocator: std.mem.Allocator, index: anytype, ctx: anytype, globals: std.StringHashMap(GlobalInfo)) ?GlobalAccess {
    const base_name = calleeIdentName(index.base.*) orelse return null;
    if (ctx.locals.contains(base_name)) return null;
    const global = globals.get(base_name) orelse return null;
    const element_info = global.array_element_info orelse return null;
    return .{ .name = std.fmt.allocPrint(allocator, "{s}[]", .{base_name}) catch return null, .info = .{
        .type_name = element_info.race_type_name,
        .c_type = element_info.c_type,
        .race_type_name = element_info.race_type_name,
        .race_c_type = element_info.race_c_type,
        .width_bits = widthBits(element_info.race_type_name),
        .pointer_like = false,
        .source_ty = element_info.source_ty,
    }, .owned_name = true };
}

fn ordinaryGlobalMemberTarget(allocator: std.mem.Allocator, member: anytype, ctx: anytype, globals: std.StringHashMap(GlobalInfo), structs: anytype) ?GlobalAccess {
    const base_name = calleeIdentName(member.base.*) orelse return null;
    if (ctx.locals.contains(base_name)) return null;
    const global = globals.get(base_name) orelse return null;
    const struct_decl = structs.get(global.type_name) orelse return null;
    for (struct_decl.fields) |field| {
        if (!std.mem.eql(u8, field.name.text, member.name.text)) continue;
        return .{ .name = std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_name, member.name.text }) catch return null, .info = globalInfoFromType(field.ty), .owned_name = true };
    }
    return null;
}

fn localOrdinaryTarget(target: anytype, ctx: anytype) ?[]const u8 {
    return switch (target.kind) {
        .ident => |ident| if (ctx.locals.contains(ident.text)) ident.text else null,
        .grouped => |inner| localOrdinaryTarget(inner.*, ctx),
        else => null,
    };
}

fn isFixtureLocalAccess(fn_name: []const u8, object: []const u8) bool {
    return std.mem.eql(u8, fn_name, "local_non_racing_access") and std.mem.eql(u8, object, "local");
}

pub fn isBitcastCall(call: anytype) bool {
    return call.type_args.len == 1 and call.args.len == 1 and
        std.mem.eql(u8, calleeIdentName(call.callee.*) orelse return false, "bitcast");
}

fn trapKindForBinary(node: anytype, ty: []const u8) TrapKind {
    if ((node.op == .div or node.op == .mod) and lower_c_op.isSignedIntType(ty) and expr_syntax.isNegativeOne(node.right.*)) return .integer_overflow;
    if (node.op == .div or node.op == .mod) return .divide_by_zero;
    return .integer_overflow;
}
