//! Human-readable MIR dumps and verification-fact listings.
//!
//! These back `mcc inspect-mir` style output and the golden dump fixtures.
//! They are presentation only: nothing here is an authority for lowering.
//!
//! Split out of `mir.zig` with no behavior change; `mir.zig` re-exports the
//! public entry points so existing `mir.X` call sites compile unchanged.

const std = @import("std");

const ast = @import("ast.zig");
const mir_facade = @import("mir.zig");
const mir_cleanup_cfg = @import("mir_cleanup_cfg.zig");
const mir_model = @import("mir_model.zig");
const mir_verify_util = @import("mir_verify_util.zig");

const BuildOptions = mir_model.BuildOptions;
const Function = mir_model.Function;
const Module = mir_model.Module;

const buildFromDecls = mir_facade.buildFromDecls;
const buildOptFromDecls = mir_facade.buildOptFromDecls;
const cfgHasStructuralError = mir_facade.cfgHasStructuralError;
const floatFactTargetType = mir_facade.floatFactTargetType;
const functionFallsThrough = mir_facade.functionFallsThrough;
const instructionSourcePoint = mir_cleanup_cfg.instructionSourcePoint;
const integerFactTargetType = mir_facade.integerFactTargetType;
const irqContextCallFinding = mir_facade.irqContextCallFinding;
const irqContextFindingName = mir_verify_util.irqContextFindingName;
const moduleSymbolSpelling = mir_cleanup_cfg.moduleSymbolSpelling;
const sourcePointForSpanId = mir_cleanup_cfg.sourcePointForSpanId;
const targetOwnerSpelling = mir_cleanup_cfg.targetOwnerSpelling;
const valueSpelling = mir_facade.valueSpelling;

pub fn appendDumpFromDecls(allocator: std.mem.Allocator, decls: []ast.Decl, out: *std.ArrayList(u8)) !void {
    return appendDumpOptFromDecls(allocator, decls, out, .{});
}
pub fn appendDumpOptFromDecls(allocator: std.mem.Allocator, decls: []ast.Decl, out: *std.ArrayList(u8), options: BuildOptions) !void {
    var module_mir = try buildOptFromDecls(allocator, decls, options);
    defer module_mir.deinit();
    try appendDumpFromMir(allocator, module_mir, out);
}

pub fn appendDumpFromMir(allocator: std.mem.Allocator, module_mir: Module, out: *std.ArrayList(u8)) !void {
    for (module_mir.symbol_identities) |identity| {
        try out.print(
            allocator,
            "mir symbol_identity id={} spelling={s}\n",
            .{ identity.id.index(), identity.spelling },
        );
    }
    for (module_mir.drop_glue_facts) |fact| {
        const resource_type = moduleSymbolSpelling(module_mir, fact.typed_resource_symbol_id) orelse return error.InvalidMirDropGlueFacts;
        const release_fn = moduleSymbolSpelling(module_mir, fact.typed_release_symbol_id) orelse return error.InvalidMirDropGlueFacts;
        try out.print(
            allocator,
            "mir drop_glue_fact resource_type={s} resource_symbol={} release_fn={s} release_symbol={} recorded=true line={} column={}\n",
            .{ resource_type, fact.typed_resource_symbol_id.index(), release_fn, fact.typed_release_symbol_id.index(), fact.source.line, fact.source.column },
        );
    }
    for (module_mir.type_ownership_facts) |fact| {
        const type_name = moduleSymbolSpelling(module_mir, fact.typed_type_symbol_id) orelse return error.InvalidMirTypeOwnershipFacts;
        try out.print(
            allocator,
            "mir type_ownership type={s} symbol={} kind={s} drop_glue_symbol={} thread_move={} line={} column={}\n",
            .{
                type_name,
                fact.typed_type_symbol_id.index(),
                @tagName(fact.kind),
                if (fact.drop_glue_symbol_id.isValid()) fact.drop_glue_symbol_id.index() else std.math.maxInt(usize),
                fact.thread_move,
                fact.source.line,
                fact.source.column,
            },
        );
    }
    for (module_mir.checked_callables) |callable| {
        try out.print(
            allocator,
            "checked callable symbol_id={} source_id={} body_id={} kind={s} return={s} params={} c_abi={} no_lang_trap={} irq_context={}\n",
            .{
                callable.symbol_id.index(),
                if (callable.source_id.isValid()) callable.source_id.index() else std.math.maxInt(usize),
                if (callable.body_id.isValid()) callable.body_id.index() else std.math.maxInt(usize),
                @tagName(callable.kind),
                callable.return_ty.name(),
                callable.param_count,
                callable.c_abi,
                callable.no_lang_trap,
                callable.irq_context,
            },
        );
    }
    for (module_mir.functions) |function| {
        try out.print(
            allocator,
            "mir function name={s} symbol_id={} return={s} no_lang_trap={} irq_context={} extern={} c_abi={} params={} blocks={} trap_edges={} contract_regions={} range_facts={} bounds_facts={} integer_facts={} float_facts={} const_get_facts={} call_target_facts={} target_type_facts={} pointer_provenance_facts={} representation_facts={} elided_bounds={}\n",
            .{ function.name, if (function.typed_symbol_id.isValid()) function.typed_symbol_id.index() else std.math.maxInt(usize), function.return_ty.name(), function.no_lang_trap, function.irq_context, function.is_extern, function.c_abi, function.param_count, function.blocks.len, function.trap_edges.len, function.contract_regions.len, function.range_facts.len, function.bounds_facts.len, function.integer_facts.len, function.float_facts.len, function.const_get_facts.len, function.call_target_facts.len, function.target_type_facts.len, function.pointer_provenance_facts.len, function.representation_facts.len, function.elided_bounds.len },
        );
        for (function.type_identities) |identity| {
            try out.print(
                allocator,
                "mir type_identity fn={s} id={} spelling={s}\n",
                .{ function.name, identity.id.index(), identity.spelling },
            );
        }
        for (function.span_identities) |identity| {
            try out.print(
                allocator,
                "mir span_identity fn={s} id={} line={} column={} offset={} len={}\n",
                .{ function.name, identity.id.index(), identity.source.line, identity.source.column, identity.source.offset, identity.source.len },
            );
        }
        for (function.value_identities) |identity| {
            try out.print(
                allocator,
                "mir value_identity fn={s} id={} spelling={s}\n",
                .{ function.name, identity.id.index(), identity.spelling },
            );
        }
        for (function.target_owner_identities) |identity| {
            try out.print(
                allocator,
                "mir target_owner_identity fn={s} id={} spelling={s}\n",
                .{ function.name, identity.id.index(), identity.spelling },
            );
        }
        for (function.ownership_events) |event| {
            try out.print(
                allocator,
                "mir ownership_event fn={s} kind={s} block={} generation={} root_value={} root_symbol={} root_type_symbol={} projections={} loan_id={} loan_kind={s} drop_glue_symbol={} line={} column={}\n",
                .{
                    function.name,
                    @tagName(event.kind),
                    if (event.block_id.isValid()) event.block_id.index() else std.math.maxInt(usize),
                    event.generation,
                    if (event.place.root_value_id.isValid()) event.place.root_value_id.index() else std.math.maxInt(usize),
                    if (event.place.root_symbol_id.isValid()) event.place.root_symbol_id.index() else std.math.maxInt(usize),
                    if (event.place.root_type_symbol_id.isValid()) event.place.root_type_symbol_id.index() else std.math.maxInt(usize),
                    event.place.projection_count,
                    event.loan_id,
                    if (event.loan_kind) |loan_kind| @tagName(loan_kind) else "none",
                    if (event.drop_glue_symbol_id.isValid()) event.drop_glue_symbol_id.index() else std.math.maxInt(usize),
                    event.source.line,
                    event.source.column,
                },
            );
        }
        for (function.ffi_param_contracts) |fact| {
            if (fact.kind == .address) {
                const address_class = switch (fact.address_class.?) {
                    .dma_addr => "dma",
                    .paddr => "physical",
                    .vaddr => "virtual",
                    else => unreachable,
                };
                try out.print(allocator, "mir ffi_param_contract fn={s} index={} name={s} kind=address address_class={s} conversion=explicit\n", .{ function.name, fact.index, fact.name, address_class });
            } else {
                const nonnull = switch (fact.nullability) {
                    .nonnull => "true",
                    .nullable => "false",
                    .when_nonempty => "when_nonempty",
                    .not_applicable => unreachable,
                };
                try out.print(allocator, "mir ffi_param_contract fn={s} index={} name={s} kind={s} nonnull={s} access={s} extent={s} alignment=type provenance=extern_unknown stable_until=call_return\n", .{ function.name, fact.index, fact.name, @tagName(fact.kind), nonnull, @tagName(fact.access), @tagName(fact.extent) });
            }
        }
        for (function.contract_regions) |region| {
            try out.print(
                allocator,
                "mir contract_region fn={s} id={} kind={s} begin_line={} end_line={}\n",
                .{ function.name, region.id, region.kind, region.begin_line, region.end_line },
            );
        }
        for (function.blocks) |block| {
            try out.print(
                allocator,
                "mir block fn={s} id={} kind={s} terminator={s} successors=",
                .{ function.name, block.id.index(), block.kind, block.terminator.name() },
            );
            for (block.successors, 0..) |successor, i| {
                if (i != 0) try out.append(allocator, ',');
                try out.print(allocator, "{}", .{successor.index()});
            }
            try out.append(allocator, '\n');
            if (typedBodyIsDumpable(&function.executable_body)) continue;
            for (block.instructions) |instruction| {
                const source = instructionSourcePoint(function, instruction) orelse return error.InvalidSpanReference;
                const value_id = if (instruction.typed_value_id) |id| valueSpelling(function, id) orelse "none" else "none";
                if (instruction.target_index) |index| {
                    const target_owner = if (instruction.typed_target_owner_id) |owner_id| targetOwnerSpelling(function, owner_id) orelse "<invalid>" else "none";
                    try out.print(
                        allocator,
                        "mir instr fn={s} block={} kind={s} detail={s} type={s} target_owner={s} target_index={} value_id={s} contract_region_id=none line={} column={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), instruction.detail, instruction.result_ty.name(), target_owner, index, value_id, source.line, source.column },
                    );
                } else if (instruction.typed_target_owner_id) |owner_id| {
                    const owner = targetOwnerSpelling(function, owner_id) orelse "<invalid>";
                    try out.print(
                        allocator,
                        "mir instr fn={s} block={} kind={s} detail={s} type={s} target_owner={s} target_index=none value_id={s} contract_region_id=none line={} column={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), instruction.detail, instruction.result_ty.name(), owner, value_id, source.line, source.column },
                    );
                } else if (instruction.const_index) |index| {
                    try out.print(
                        allocator,
                        "mir instr fn={s} block={} kind={s} detail={s} type={s} const_index={} value_id={s} contract_region_id=none line={} column={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), instruction.detail, instruction.result_ty.name(), index, value_id, source.line, source.column },
                    );
                } else if (instruction.contract_region_id) |region_id| {
                    try out.print(
                        allocator,
                        "mir instr fn={s} block={} kind={s} detail={s} type={s} value_id={s} contract_region_id={} line={} column={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), instruction.detail, instruction.result_ty.name(), value_id, region_id, source.line, source.column },
                    );
                } else {
                    try out.print(
                        allocator,
                        "mir instr fn={s} block={} kind={s} detail={s} type={s} value_id={s} contract_region_id=none line={} column={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), instruction.detail, instruction.result_ty.name(), value_id, source.line, source.column },
                    );
                }
                if (instruction.typed_callee_span_id.isValid()) {
                    try out.print(
                        allocator,
                        "mir call_identity fn={s} block={} kind={s} detail={s} callee_span_id={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), instruction.detail, instruction.typed_callee_span_id.index() },
                    );
                }
                if (instruction.typed_left_operand_span_id.isValid()) {
                    const right_id = if (instruction.typed_right_operand_span_id.isValid())
                        instruction.typed_right_operand_span_id.index()
                    else
                        std.math.maxInt(usize);
                    try out.print(
                        allocator,
                        "mir operand_identity fn={s} block={} kind={s} detail={s} left_span_id={} right_span_id={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), instruction.detail, instruction.typed_left_operand_span_id.index(), right_id },
                    );
                }
                if (instruction.typed_switch_pattern_count != 0) {
                    for (instruction.typed_switch_patterns[0..instruction.typed_switch_pattern_count], 0..) |pattern, pattern_index| {
                        switch (pattern) {
                            .unused => unreachable,
                            .wildcard => try out.print(
                                allocator,
                                "mir switch_pattern fn={s} block={} index={} kind=wildcard\n",
                                .{ function.name, block.id.index(), pattern_index },
                            ),
                            .scalar => |scalar| try out.print(
                                allocator,
                                "mir switch_pattern fn={s} block={} index={} kind=scalar negative={} magnitude={}\n",
                                .{ function.name, block.id.index(), pattern_index, scalar.negative, scalar.magnitude },
                            ),
                        }
                    }
                }
                if (instruction.typed_aggregate_operand_count != 0) {
                    for (instruction.typed_aggregate_operand_span_ids[0..instruction.typed_aggregate_operand_count], 0..) |operand_span_id, operand_index| {
                        try out.print(
                            allocator,
                            "mir aggregate_operand fn={s} block={} index={} span_id={} field_index={}\n",
                            .{
                                function.name,
                                block.id.index(),
                                operand_index,
                                operand_span_id.index(),
                                instruction.typed_aggregate_field_indices[operand_index],
                            },
                        );
                    }
                }
                if (instruction.typed_base_operand_span_id.isValid() and instruction.member_field_index != null) {
                    try out.print(
                        allocator,
                        "mir place_identity fn={s} block={} kind={s} detail={s} base_span_id={} field_index={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), instruction.detail, instruction.typed_base_operand_span_id.index(), instruction.member_field_index.? },
                    );
                }
                if (instruction.typed_index_operand_span_id.isValid()) {
                    try out.print(
                        allocator,
                        "mir index_identity fn={s} block={} base_span_id={} index_span_id={} constant_index={} static_bound={}\n",
                        .{
                            function.name,
                            block.id.index(),
                            instruction.typed_base_operand_span_id.index(),
                            instruction.typed_index_operand_span_id.index(),
                            instruction.constant_index_value orelse std.math.maxInt(usize),
                            instruction.static_index_bound orelse std.math.maxInt(usize),
                        },
                    );
                }
                if (instruction.typed_target_operand_span_id.isValid() or instruction.typed_value_operand_span_id.isValid()) {
                    const target_id = if (instruction.typed_target_operand_span_id.isValid()) instruction.typed_target_operand_span_id.index() else std.math.maxInt(usize);
                    const value_id_index = if (instruction.typed_value_operand_span_id.isValid()) instruction.typed_value_operand_span_id.index() else std.math.maxInt(usize);
                    try out.print(
                        allocator,
                        "mir statement_operand_identity fn={s} block={} kind={s} target_span_id={} value_span_id={}\n",
                        .{ function.name, block.id.index(), @tagName(instruction.kind), target_id, value_id_index },
                    );
                }
                if (instruction.typed_callee_root_value_id.isValid()) {
                    const field_index = if (instruction.callee_field_index) |index| try std.fmt.allocPrint(allocator, "{}", .{index}) else "none";
                    defer if (instruction.callee_field_index != null) allocator.free(field_index);
                    try out.print(
                        allocator,
                        "mir indirect_callee_place fn={s} block={} root_value_id={} root_span_id={} owner_id={} field_index={s}\n",
                        .{ function.name, block.id.index(), instruction.typed_callee_root_value_id.index(), instruction.typed_callee_root_span_id.index(), instruction.typed_target_owner_id.?.index(), field_index },
                    );
                }
            }
        }
        try appendExecutableBodyDump(allocator, function, out);
        for (function.trap_edges) |edge| {
            const source = sourcePointForSpanId(function, edge.typed_span_id) orelse return error.InvalidTrapEdge;
            try out.print(
                allocator,
                "mir trap_edge fn={s} from={} trap_block={} kind={s} source={s} explicit=true line={} column={} typed_span_id={}\n",
                .{ function.name, edge.from_block.index(), edge.trap_block.index(), @tagName(edge.kind), @tagName(edge.source), source.line, source.column, if (edge.typed_span_id.isValid()) edge.typed_span_id.index() else std.math.maxInt(usize) },
            );
        }
        for (function.representation_facts) |fact| {
            const source = sourcePointForSpanId(function, fact.typed_span_id) orelse return error.InvalidMirRepresentationFacts;
            try out.print(
                allocator,
                "mir representation_fact fn={s} kind={s} detail={s} type={s} value_id={s} recorded=true line={} column={} typed_result_ty_id={} typed_value_id={} typed_span_id={}\n",
                .{
                    function.name,
                    @tagName(fact.kind),
                    fact.detail,
                    fact.result_ty.name(),
                    valueSpelling(function, fact.typed_value_id) orelse "none",
                    source.line,
                    source.column,
                    if (fact.typed_result_ty.isValid()) fact.typed_result_ty.index() else std.math.maxInt(usize),
                    if (fact.typed_value_id.isValid()) fact.typed_value_id.index() else std.math.maxInt(usize),
                    if (fact.typed_span_id.isValid()) fact.typed_span_id.index() else std.math.maxInt(usize),
                },
            );
        }
        for (function.range_facts) |fact| {
            const source = sourcePointForSpanId(function, fact.typed_span_id) orelse return error.InvalidMirRangeFacts;
            try out.print(
                allocator,
                "mir range_fact fn={s} region_id={} target={s} op={s} left={s} right={s} result_type={s} assumption=no_overflow recorded=true line={} column={} typed_span_id={}\n",
                .{ function.name, fact.region_id, fact.target, fact.op, fact.left, fact.right, fact.result_ty.name(), source.line, source.column, fact.typed_span_id.index() },
            );
        }
        for (function.bounds_facts) |fact| {
            const source = sourcePointForSpanId(function, fact.typed_span_id) orelse return error.InvalidMirBoundsFacts;
            try out.print(
                allocator,
                "mir bounds_fact fn={s} kind={s} recorded=true line={} column={} typed_span_id={}\n",
                .{ function.name, @tagName(fact.kind), source.line, source.column, fact.typed_span_id.index() },
            );
        }
        for (function.integer_facts) |fact| {
            const target_name = if (integerFactTargetType(&function, fact)) |target_ty| target_ty.name() else "invalid";
            const source = sourcePointForSpanId(function, fact.typed_span_id);
            try out.print(
                allocator,
                "mir integer_fact fn={s} literal={s} target_type={s} target_type_id={} typed_span_id={} recorded=true line={} column={}\n",
                .{ function.name, fact.literal, target_name, if (fact.target_type_id.isValid()) fact.target_type_id.index() else std.math.maxInt(usize), if (fact.typed_span_id.isValid()) fact.typed_span_id.index() else std.math.maxInt(usize), if (source) |point| point.line else std.math.maxInt(usize), if (source) |point| point.column else std.math.maxInt(usize) },
            );
        }
        for (function.float_facts) |fact| {
            const target_name = if (floatFactTargetType(&function, fact)) |target_ty| target_ty.name() else "invalid";
            const source = sourcePointForSpanId(function, fact.typed_span_id);
            try out.print(
                allocator,
                "mir float_fact fn={s} literal={s} target_type={s} target_type_id={} typed_span_id={} recorded=true line={} column={}\n",
                .{ function.name, fact.literal, target_name, if (fact.target_type_id.isValid()) fact.target_type_id.index() else std.math.maxInt(usize), if (fact.typed_span_id.isValid()) fact.typed_span_id.index() else std.math.maxInt(usize), if (source) |point| point.line else std.math.maxInt(usize), if (source) |point| point.column else std.math.maxInt(usize) },
            );
        }
        for (function.const_get_facts) |fact| {
            const source = sourcePointForSpanId(function, fact.typed_span_id) orelse return error.InvalidMirConstGetFacts;
            try out.print(
                allocator,
                "mir const_get_fact fn={s} index={} typed_span_id={} recorded=true line={} column={}\n",
                .{ function.name, fact.index, fact.typed_span_id.index(), source.line, source.column },
            );
        }
        for (function.call_target_facts) |fact| {
            const source = sourcePointForSpanId(function, fact.typed_span_id) orelse return error.InvalidMirCallTargetFacts;
            try out.print(
                allocator,
                "mir call_target_fact fn={s} kind={s} result_type={s} recorded=true line={} column={} typed_span_id={}\n",
                .{ function.name, @tagName(fact.kind), fact.result_ty.name(), source.line, source.column, if (fact.typed_span_id.isValid()) fact.typed_span_id.index() else std.math.maxInt(usize) },
            );
        }
        for (function.target_type_facts) |fact| {
            const source = sourcePointForSpanId(function, fact.typed_span_id) orelse return error.InvalidMirTargetTypeFacts;
            const target_index = if (fact.target_index) |index| try std.fmt.allocPrint(allocator, "{}", .{index}) else "none";
            defer if (fact.target_index != null) allocator.free(target_index);
            const target_owner = targetOwnerSpelling(function, fact.typed_target_owner_id) orelse "none";
            const aggregate_construction = if (fact.aggregate_construction) |kind| @tagName(kind) else "none";
            try out.print(
                allocator,
                "mir target_type_fact fn={s} kind={s} target_type_id={} result_type={s} aggregate_construction={s} target_owner={s} target_index={s} recorded=true line={} column={} typed_result_ty_id={} typed_span_id={} typed_callee_span_id={} typed_operand_value_id={} typed_target_owner_id={}\n",
                .{
                    function.name,
                    @tagName(fact.kind),
                    if (fact.target_type_id.isValid()) fact.target_type_id.index() else std.math.maxInt(usize),
                    fact.result_ty.name(),
                    aggregate_construction,
                    target_owner,
                    target_index,
                    source.line,
                    source.column,
                    if (fact.typed_result_ty.isValid()) fact.typed_result_ty.index() else std.math.maxInt(usize),
                    if (fact.typed_span_id.isValid()) fact.typed_span_id.index() else std.math.maxInt(usize),
                    if (fact.typed_callee_span_id.isValid()) fact.typed_callee_span_id.index() else std.math.maxInt(usize),
                    if (fact.typed_operand_value_id.isValid()) fact.typed_operand_value_id.index() else std.math.maxInt(usize),
                    if (fact.typed_target_owner_id.isValid()) fact.typed_target_owner_id.index() else std.math.maxInt(usize),
                },
            );
        }
        for (function.pointer_provenance_facts) |fact| {
            const element = if (fact.element_index) |index| try std.fmt.allocPrint(allocator, "{}", .{index}) else "none";
            defer if (fact.element_index != null) allocator.free(element);
            try out.print(
                allocator,
                "mir pointer_provenance_fact fn={s} subject={s} element={s} provenance={s} storage={s} pointer_kind={s} mutability={s} child={s} field={s} invalidation_reason={s} invalidation_policy={s} line={} column={}\n",
                .{
                    function.name,
                    fact.subject,
                    element,
                    @tagName(fact.provenance),
                    fact.storage orelse "none",
                    @tagName(fact.pointer_shape.kind),
                    @tagName(fact.pointer_shape.mutability),
                    fact.pointer_shape.child,
                    fact.field_path orelse "none",
                    @tagName(fact.invalidation_reason),
                    @tagName(fact.invalidation_policy),
                    fact.source.line,
                    fact.source.column,
                },
            );
        }
        for (function.elided_bounds) |span_id| {
            const source = sourcePointForSpanId(function, span_id) orelse return error.InvalidMirElidedBounds;
            try out.print(
                allocator,
                "mir elided_bounds_fact fn={s} check=bounds_elided recorded=true line={} column={} typed_span_id={}\n",
                .{ function.name, source.line, source.column, span_id.index() },
            );
        }
    }
    for (module_mir.aggregate_return_summaries) |summary| {
        try out.print(
            allocator,
            "mir aggregate_return_summary_fact callee={s} recorded=true line={} column={}\n",
            .{ summary.callee, summary.source.line, summary.source.column },
        );
    }
    for (module_mir.aggregate_return_pointer_facts) |fact| {
        try out.print(
            allocator,
            "mir aggregate_return_pointer_fact callee={s} field={s} provenance={s} pointer_kind={s} mutability={s} child={s} recorded=true line={} column={}\n",
            .{
                fact.callee,
                fact.field_path,
                @tagName(fact.provenance),
                @tagName(fact.pointer_shape.kind),
                @tagName(fact.pointer_shape.mutability),
                fact.pointer_shape.child,
                fact.source.line,
                fact.source.column,
            },
        );
    }
}

/// Does this function's typed body carry the whole body, so the dump can
/// show it instead of the instruction stream?
///
/// The same three shapes the verifier exempts are the ones with nothing to
/// show: an incomplete body, an `extern` declaration and an empty body. They
/// keep the legacy `mir instr` rows, because a dump of nothing is not a dump.
fn typedBodyIsDumpable(body: *const mir_model.ExecutableBody) bool {
    if (!body.isComplete()) return false;
    return body.statements.len != 0 or body.expressions.len != 0 or body.terminators.len != 0;
}

fn executableSource(function: mir_model.Function, span_id: mir_model.SpanId) mir_model.SourcePoint {
    return sourcePointForSpanId(function, span_id) orelse .{ .line = 0, .column = 0 };
}

fn appendOptionalIndex(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id: anytype) !void {
    if (id.isValid()) {
        try out.print(allocator, "{}", .{id.index()});
    } else {
        try out.append(allocator, 'x');
    }
}

/// Dump the typed body: what the backends actually render.
///
/// Every row names a node by its own id and its operation by the tag the
/// typed model carries, so a representation change shows up here as a changed
/// operation rather than as a changed `detail` string. That is the whole
/// point of the repoint: the dump used to print a `kind` enum plus a string
/// the front end chose, which is the classification the typed body replaces.
///
/// The obligations each node owns are printed beside it, because they are the
/// join keys the eleven fact families name; a fact table row and the node it
/// names can now be read against each other in one dump.
fn appendExecutableBodyDump(allocator: std.mem.Allocator, function: mir_model.Function, out: *std.ArrayList(u8)) !void {
    const body = &function.executable_body;
    if (!typedBodyIsDumpable(body)) return;
    for (body.parameters) |parameter| {
        try out.print(
            allocator,
            "mir exec_param fn={s} local={} type={s}\n",
            .{ function.name, parameter.local.index(), parameter.ty.name() },
        );
    }
    for (body.locals) |local| {
        const source = executableSource(function, local.declaration_span_id);
        try out.print(
            allocator,
            "mir exec_local fn={s} local={} spelling={s} type={s} line={} column={}\n",
            .{ function.name, local.id.index(), local.spelling, local.ty.name(), source.line, source.column },
        );
    }
    for (body.places, 0..) |place, place_index| {
        const source = executableSource(function, place.span_id);
        try out.print(
            allocator,
            "mir exec_place fn={s} id={} root={s} projections=",
            .{ function.name, place_index, @tagName(std.meta.activeTag(place.root)) },
        );
        if (place.projection_count == 0) try out.append(allocator, '-');
        for (place.projections[0..place.projection_count], 0..) |projection, projection_index| {
            if (projection_index != 0) try out.append(allocator, ',');
            try out.print(allocator, "{s}", .{@tagName(std.meta.activeTag(projection))});
        }
        try out.print(allocator, " line={} column={}\n", .{ source.line, source.column });
    }
    for (body.expressions) |expression| {
        const source = executableSource(function, expression.span_id);
        try out.print(
            allocator,
            "mir exec_expr fn={s} id={} block={} stmt=",
            .{ function.name, expression.id.index(), expression.block_id.index() },
        );
        try appendOptionalIndex(allocator, out, expression.owner_statement);
        try out.print(
            allocator,
            " op={s}",
            .{@tagName(std.meta.activeTag(expression.operation))},
        );
        try appendExecutableOperationDetail(allocator, expression, out);
        try out.print(
            allocator,
            " type={s} line={} column={}\n",
            .{ expression.result_ty.name(), source.line, source.column },
        );
        try appendExecutableObligations(allocator, function, expression, out);
    }
    for (body.statements) |statement| {
        const source = executableSource(function, statement.span_id);
        try out.print(
            allocator,
            "mir exec_stmt fn={s} id={} block={} op={s} line={} column={}\n",
            .{ function.name, statement.id.index(), statement.block_id.index(), @tagName(std.meta.activeTag(statement.operation)), source.line, source.column },
        );
    }
    for (body.terminators) |terminator| {
        const source = executableSource(function, terminator.span_id);
        try out.print(
            allocator,
            "mir exec_terminator fn={s} block={} op={s} line={} column={}\n",
            .{ function.name, terminator.block_id.index(), @tagName(std.meta.activeTag(terminator.operation)), source.line, source.column },
        );
        if (terminator.call_target_obligation) |obligation| {
            try out.print(
                allocator,
                "mir exec_obligation fn={s} owner=terminator{} kind=call_target id={} detail={s}\n",
                .{ function.name, terminator.block_id.index(), obligation.id.index(), @tagName(obligation.kind) },
            );
        }
    }
    for (body.target_type_obligations) |obligation| {
        try out.print(
            allocator,
            "mir exec_obligation fn={s} owner=",
            .{function.name},
        );
        try appendOptionalIndex(allocator, out, obligation.owner);
        try out.print(
            allocator,
            " kind=target_type id={} detail={s}\n",
            .{ obligation.id.index(), @tagName(obligation.kind) },
        );
    }
    for (body.representation_obligations) |obligation| {
        try out.print(
            allocator,
            "mir exec_obligation fn={s} owner=",
            .{function.name},
        );
        try appendOptionalIndex(allocator, out, obligation.owner);
        try out.print(
            allocator,
            " kind=representation id={} detail={s}\n",
            .{ obligation.id.index(), @tagName(obligation.kind) },
        );
    }
}

/// The part of an operation that is the operation's own content: its operator
/// or builtin, and the operand nodes it names.
///
/// The operands are `ExprId`s, and printing them is what makes an operand
/// identity readable in the dump. In the instruction stream the same thing was
/// a `SpanId` on the instruction, printed as `mir operand_identity` -- a
/// source coordinate standing in for a node, because the stream had no node
/// to point at. Here the operand *is* the node.
///
/// Arms not listed carry their operands in a shape with no single reading
/// (an owned operand slice, a call's argument list, a place); they print
/// their operation and their type, which is what the row is for.
fn appendExecutableOperationDetail(
    allocator: std.mem.Allocator,
    expression: mir_model.ExecutableExpression,
    out: *std.ArrayList(u8),
) !void {
    switch (expression.operation) {
        .unary => |unary| try out.print(allocator, " operator={s} operands={}", .{ @tagName(unary.op), unary.operand.index() }),
        .binary => |binary| try out.print(
            allocator,
            " operator={s} operands={},{}",
            .{ @tagName(binary.op), binary.left.index(), binary.right.index() },
        ),
        .cast => |cast| try out.print(allocator, " operator={s} operands={}", .{ @tagName(cast.kind), cast.operand.index() }),
        .deref => |operand| try out.print(allocator, " operands={}", .{operand.index()}),
        .slice_length => |operand| try out.print(allocator, " operands={}", .{operand.index()}),
        .member => |member| try out.print(allocator, " field_index={} operands={}", .{ member.field_index, member.base.index() }),
        .index => |indexed| try out.print(
            allocator,
            " checked={} operands={},{}",
            .{ indexed.checked, indexed.base.index(), indexed.index.index() },
        ),
        .range_slice => |slice| try out.print(
            allocator,
            " checked={} operands={},{},{}",
            .{ slice.checked, slice.base.index(), slice.start.index(), slice.end.index() },
        ),
        .load => |load| try out.print(allocator, " place={}", .{load.place.index()}),
        .address_of => |address| try out.print(allocator, " place={}", .{address.place.index()}),
        .builtin_call => |builtin| {
            try out.print(allocator, " builtin={s}", .{@tagName(builtin.kind)});
            if (builtin.const_index) |const_index| try out.print(allocator, " const_index={}", .{const_index});
        },
        .indirect_call => |call| try out.print(allocator, " callee={} arguments={}", .{ call.callee.index(), call.argument_count }),
        else => {},
    }
}

/// The typed obligations one expression node owns, one row each. Each is a
/// join key an instruction-scoped fact table names.
fn appendExecutableObligations(
    allocator: std.mem.Allocator,
    function: mir_model.Function,
    expression: mir_model.ExecutableExpression,
    out: *std.ArrayList(u8),
) !void {
    if (mir_model.executableExpressionBoundsObligation(expression)) |obligation| {
        try out.print(
            allocator,
            "mir exec_obligation fn={s} owner={} kind=bounds id={} detail={s}\n",
            .{ function.name, expression.id.index(), obligation.id.index(), @tagName(obligation.kind) },
        );
    }
    if (mir_model.executableExpressionAccessObligation(expression)) |obligation| {
        try out.print(
            allocator,
            "mir exec_obligation fn={s} owner={} kind=access id={} detail={s}\n",
            .{ function.name, expression.id.index(), obligation.id.index(), @tagName(std.meta.activeTag(expression.operation)) },
        );
    }
    if (expression.literal_conversion.isValid()) {
        try out.print(
            allocator,
            "mir exec_obligation fn={s} owner={} kind=literal_conversion id={} detail={s}\n",
            .{
                function.name,
                expression.id.index(),
                expression.literal_conversion.id.index(),
                if (mir_model.executableLiteralConversionIsFloat(expression)) "float" else "integer",
            },
        );
    }
    if (expression.call_target_obligation) |obligation| {
        try out.print(
            allocator,
            "mir exec_obligation fn={s} owner={} kind=call_target id={} detail={s}\n",
            .{ function.name, expression.id.index(), obligation.id.index(), @tagName(obligation.kind) },
        );
    }
    if (expression.range_obligation) |obligation| {
        try out.print(
            allocator,
            "mir exec_obligation fn={s} owner={} kind=range id={} detail={s}\n",
            .{ function.name, expression.id.index(), obligation.id.index(), @tagName(obligation.op) },
        );
    }
    if (expression.const_get_obligation.isValid()) {
        try out.print(
            allocator,
            "mir exec_obligation fn={s} owner={} kind=const_get id={} detail=const_get\n",
            .{ function.name, expression.id.index(), expression.const_get_obligation.index() },
        );
    }
}

/// The verification-fact rows for the refusals a function recorded.
///
/// Each row says what the old per-instruction walk said for the `*_check`
/// instruction it replaced, but the finding name is `@tagName` over the typed
/// value rather than the `detail` string it was read out of.
fn appendFindingRows(allocator: std.mem.Allocator, function: Function, out: *std.ArrayList(u8)) !void {
    for (function.findings) |finding| {
        const source = sourcePointForSpanId(function, finding.typed_span_id) orelse return error.InvalidSpanReference;
        switch (finding.kind) {
            .operator => |operator| try out.print(
                allocator,
                "mir verify fn={s} pass=core finding={s} line={} column={}\n",
                .{ function.name, @tagName(operator), source.line, source.column },
            ),
            .arithmetic_domain => |domain| try out.print(
                allocator,
                "mir verify fn={s} pass=core finding={s} line={} column={}\n",
                .{ function.name, @tagName(domain), source.line, source.column },
            ),
            .switch_coverage => |coverage| try out.print(
                allocator,
                "mir verify fn={s} pass=core finding={s} line={} column={}\n",
                .{ function.name, @tagName(coverage), source.line, source.column },
            ),
            .assignment => |assignment| try out.print(
                allocator,
                "mir verify fn={s} pass=core finding={s} line={} column={}\n",
                .{ function.name, @tagName(assignment), source.line, source.column },
            ),
        }
    }
}

pub fn appendVerificationFactsFromDecls(allocator: std.mem.Allocator, decls: []ast.Decl, out: *std.ArrayList(u8)) !void {
    var mir = try buildFromDecls(allocator, decls);
    defer mir.deinit();
    try appendVerificationFactsFromMir(allocator, mir, out);
}

pub fn appendVerificationFactsFromMir(allocator: std.mem.Allocator, mir: Module, out: *std.ArrayList(u8)) !void {
    for (mir.functions) |function| {
        if (functionFallsThrough(function)) |point| {
            try out.print(
                allocator,
                "mir verify fn={s} pass=core finding=fallthrough line={} column={}\n",
                .{ function.name, point.line, point.column },
            );
        }
        if (cfgHasStructuralError(function)) |point| {
            try out.print(
                allocator,
                "mir verify fn={s} pass=cfg finding=malformed_cfg line={} column={}\n",
                .{ function.name, point.line, point.column },
            );
        }
        for (function.trap_edges) |edge| {
            const source = sourcePointForSpanId(function, edge.typed_span_id) orelse return error.InvalidTrapEdge;
            try out.print(
                allocator,
                "mir verify fn={s} pass=trap finding=trap_edge detail={s} source={s} no_lang_trap={} line={} column={}\n",
                .{ function.name, @tagName(edge.kind), @tagName(edge.source), function.no_lang_trap, source.line, source.column },
            );
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                const source = instructionSourcePoint(function, instruction) orelse return error.InvalidSpanReference;
                if (instruction.kind != .unchecked_assume) continue;
                try out.print(
                    allocator,
                    "mir verify fn={s} pass=unsafe finding=unchecked_assume detail={s} contract_region_id={s} line={} column={}\n",
                    .{ function.name, instruction.detail, if (instruction.contract_region_id == null) "none" else "some", source.line, source.column },
                );
            }
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                const source = instructionSourcePoint(function, instruction) orelse return error.InvalidSpanReference;
                if (instruction.kind != .unsafe_check) continue;
                try out.print(
                    allocator,
                    "mir verify fn={s} pass=unsafe finding=unsafe_required detail={s} line={} column={}\n",
                    .{ function.name, instruction.detail, source.line, source.column },
                );
            }
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                const source = instructionSourcePoint(function, instruction) orelse return error.InvalidSpanReference;
                if (instruction.kind == .address_deref) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=address finding=direct_deref class={s} line={} column={}\n",
                        .{ function.name, instruction.detail, source.line, source.column },
                    );
                }
                if (instruction.kind == .address_conversion) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=address finding=address_class_mismatch source={s} target={s} line={} column={}\n",
                        .{ function.name, instruction.result_ty.name(), instruction.detail, source.line, source.column },
                    );
                }
                if (instruction.kind == .address_operation) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=address finding=opaque_operation detail={s} line={} column={}\n",
                        .{ function.name, instruction.detail, source.line, source.column },
                    );
                }
                if (instruction.kind == .mmio_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=mmio finding=access_forbidden op={s} line={} column={}\n",
                        .{ function.name, instruction.detail, source.line, source.column },
                    );
                }
                if (instruction.kind == .nullability_conversion) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=nullability finding={s} line={} column={}\n",
                        .{ function.name, instruction.detail, source.line, source.column },
                    );
                }
                if (instruction.kind == .conversion_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=conversion finding={s} source_type={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.result_ty.name(), source.line, source.column },
                    );
                }
                if (instruction.kind == .aggregate_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=aggregate finding={s} type={s} line={} column={}\n",
                        .{ function.name, instruction.detail, instruction.result_ty.name(), source.line, source.column },
                    );
                }
                if (instruction.kind == .result_check) {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=result finding={s} line={} column={}\n",
                        .{ function.name, instruction.detail, source.line, source.column },
                    );
                }
                if (irqContextCallFinding(mir, function, instruction)) |finding| {
                    try out.print(
                        allocator,
                        "mir verify fn={s} pass=context finding={s} detail={s} line={} column={}\n",
                        .{ function.name, irqContextFindingName(finding), instruction.detail, source.line, source.column },
                    );
                }
            }
        }
        try appendFindingRows(allocator, function, out);
        for (function.representation_facts) |fact| {
            const source = sourcePointForSpanId(function, fact.typed_span_id) orelse return error.InvalidMirRepresentationFacts;
            switch (fact.kind) {
                .representation_check => try out.print(
                    allocator,
                    "mir verify fn={s} pass=representation finding=representation_check type={s} line={} column={}\n",
                    .{ function.name, fact.detail, source.line, source.column },
                ),
                .representation_use => try out.print(
                    allocator,
                    "mir verify fn={s} pass=representation finding=representation_use detail={s} type={s} line={} column={}\n",
                    .{ function.name, fact.detail, fact.result_ty.name(), source.line, source.column },
                ),
                .typed_load => try out.print(
                    allocator,
                    "mir verify fn={s} pass=representation finding=typed_load detail={s} type={s} line={} column={}\n",
                    .{ function.name, fact.detail, fact.result_ty.name(), source.line, source.column },
                ),
                else => {},
            }
        }
        for (function.range_facts) |fact| {
            const source = sourcePointForSpanId(function, fact.typed_span_id) orelse return error.InvalidMirRangeFacts;
            try out.print(
                allocator,
                "mir verify fn={s} pass=range finding=no_overflow_range target={s} op={s} left={s} right={s} region_id={} recorded=true line={} column={} typed_span_id={}\n",
                .{ function.name, fact.target, fact.op, fact.left, fact.right, fact.region_id, source.line, source.column, fact.typed_span_id.index() },
            );
        }
    }
}
