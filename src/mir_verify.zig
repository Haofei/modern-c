//! MIR verification: the diagnostic verifier over built MIR and the
//! fail-closed `validate*ForLowering` admission checks the backends run
//! before they may consume a module.
//!
//! Split out of `mir.zig` with no behavior change; `mir.zig` re-exports the
//! public entry points so existing `mir.X` call sites compile unchanged.

const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const mir_cleanup_cfg = @import("mir_cleanup_cfg.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const mir_facade = @import("mir.zig");
const mir_model = @import("mir_model.zig");
const mir_representation = @import("mir_representation.zig");
const mir_type = @import("mir_type.zig");
const mir_verify_util = @import("mir_verify_util.zig");

const AccessFact = mir_model.AccessFact;
const BindThunkFact = mir_model.BindThunkFact;
const BoundsFact = mir_model.BoundsFact;
const BuildOptions = mir_model.BuildOptions;
const CallTargetFact = mir_model.CallTargetFact;
const CallTargetKind = mir_model.CallTargetKind;
const CallableKind = mir_model.CallableKind;
const ConstGetFact = mir_model.ConstGetFact;
const CheckedCallableFact = mir_model.CheckedCallableFact;
const EnumCaseFact = mir_model.EnumCaseFact;
const EnumFact = mir_model.EnumFact;
const ExecutableCastKind = mir_model.ExecutableCastKind;
const FloatFact = mir_model.FloatFact;
const Function = mir_model.Function;
const Instruction = mir_model.Instruction;
const IntegerFact = mir_model.IntegerFact;
const LocalId = mir_model.LocalId;
const Module = mir_model.Module;
const PackedBitsFact = mir_model.PackedBitsFact;
const RangeFact = mir_model.RangeFact;
const RepresentationFact = mir_model.RepresentationFact;
const SignatureTypeId = mir_model.SignatureTypeId;
const SignatureTypeTable = mir_model.SignatureTypeTable;
const SourceId = mir_model.SourceId;
const SourceMapDeclarationFact = mir_model.SourceMapDeclarationFact;
const SourceMapDeclarationKind = mir_model.SourceMapDeclarationKind;
const SourcePoint = mir_model.SourcePoint;
const SpanId = mir_model.SpanId;
const SymbolId = mir_model.SymbolId;
const TargetTypeFact = mir_model.TargetTypeFact;
const TargetTypeKind = mir_model.TargetTypeKind;
const TypeId = mir_model.TypeId;
const ValueId = mir_model.ValueId;
const ValueType = mir_model.ValueType;
const addressClassFromName = mir_type.addressClassFromName;
const addressClassMismatchDiagnostic = mir_verify_util.addressClassMismatchDiagnostic;
const addressDerefDiagnostic = mir_verify_util.addressDerefDiagnostic;
const aggregateDiagnostic = mir_verify_util.aggregateDiagnostic;
const alignOverlayStorage = mir_facade.alignOverlayStorage;
const arithmeticDomainDiagnostic = mir_verify_util.arithmeticDomainDiagnostic;
const assignmentFindingDiagnostic = mir_verify_util.assignmentFindingDiagnostic;
const buildFromDecls = mir_facade.buildFromDecls;
const buildOptFromDecls = mir_facade.buildOptFromDecls;
const checkedIntBoundsByName = mir_type.checkedIntBoundsByName;
const conversionDiagnostic = mir_verify_util.conversionDiagnostic;
const ffiFindingDiagnostic = mir_verify_util.ffiFindingDiagnostic;
const functionFallsThrough = mir_facade.functionFallsThrough;
const instructionMatchesSpanId = mir_cleanup_cfg.instructionMatchesSpanId;
const instructionSourcePoint = mir_cleanup_cfg.instructionSourcePoint;
const irqContextCallFinding = mir_facade.irqContextCallFinding;
const irqContextDiagnostic = mir_verify_util.irqContextDiagnostic;
const isRepresentationSensitiveProducer = mir_representation.isSensitiveProducer;
const isRepresentationSensitiveUse = mir_representation.isSensitiveUse;
const isVoidLike = mir_type.isVoidLike;
const moduleSymbolIdentityValid = mir_cleanup_cfg.moduleSymbolIdentityValid;
const noOverflowUncheckedOp = mir_verify_util.noOverflowUncheckedOp;
const nullabilityDiagnostic = mir_verify_util.nullabilityDiagnostic;
const operatorDiagnostic = mir_verify_util.operatorDiagnostic;
const producerHasDominatingRepresentationCheck = mir_representation.producerHasDominatingCheck;
const representationFactKind = mir_facade.representationFactKind;
const resultFindingDiagnostic = mir_verify_util.resultFindingDiagnostic;
const sourcePointForSpanId = mir_cleanup_cfg.sourcePointForSpanId;
const sourcePointSpan = mir_cleanup_cfg.sourcePointSpan;
const switchFindingDiagnostic = mir_verify_util.switchFindingDiagnostic;
const targetOwnerSpelling = mir_cleanup_cfg.targetOwnerSpelling;
const uncheckedAssumeHasMatchingContract = mir_facade.uncheckedAssumeHasMatchingContract;
const usageFindingDiagnostic = mir_verify_util.usageFindingDiagnostic;
const useHasDominatingRepresentationCheck = mir_representation.useHasDominatingCheck;
const validateDropGlueFactsForLowering = mir_cleanup_cfg.validateDropGlueFactsForLowering;
const validateOwnershipEventsForLowering = mir_cleanup_cfg.validateOwnershipEventsForLowering;
const validateTypeOwnershipFactsForLowering = mir_cleanup_cfg.validateTypeOwnershipFactsForLowering;
const verifyFunctionCfg = mir_facade.verifyFunctionCfg;
const verifyFunctionOwnershipEvents = mir_cleanup_cfg.verifyFunctionOwnershipEvents;

pub fn verifyFromDecls(allocator: std.mem.Allocator, decls: []ast.Decl, reporter: *diagnostics.Reporter) !void {
    return verifyOptFromDecls(allocator, decls, reporter, .{});
}

pub fn verifyOptFromDecls(allocator: std.mem.Allocator, decls: []ast.Decl, reporter: *diagnostics.Reporter, options: BuildOptions) !void {
    var mir = try buildOptFromDecls(allocator, decls, options);
    defer mir.deinit();
    try verifyBuiltMir(mir, reporter);
}

pub fn verifyBuiltMir(mir: Module, reporter: *diagnostics.Reporter) !void {
    verifyModuleSymbolIdentities(mir, reporter);
    verifyModuleSourceIdentities(mir, reporter);
    for (mir.functions) |function| {
        verifyFunctionCfg(function, reporter);
        verifyFunctionInstructionIdentities(function, reporter);
        verifyFunctionAccessFacts(mir, function, reporter);
        verifyFunctionOwnershipEvents(mir, function, reporter);

        if (!isVoidLike(function.return_ty)) {
            if (functionFallsThrough(function)) |point| {
                const code = if (function.return_ty == .never) "E_NEVER_FALLTHROUGH" else "E_RETURN_MISSING";
                reporter.err(sourcePointSpan(point), "{s}: MIR verifier found function fallthrough before backend lowering", .{code});
            }
        }

        if (function.no_lang_trap) {
            for (function.trap_edges) |edge| {
                const source: SourcePoint = sourcePointForSpanId(function, edge.typed_span_id) orelse .{ .line = 1, .column = 1 };
                reporter.err(
                    sourcePointSpan(source),
                    "E_NO_LANG_TRAP_EDGE: MIR verifier found language trap edge {s}",
                    .{@tagName(edge.kind)},
                );
            }
        }

        for (function.blocks, 0..) |block, block_index| {
            for (block.instructions, 0..) |instruction, instruction_index| {
                const source: SourcePoint = instructionSourcePoint(function, instruction) orelse .{ .line = 1, .column = 1 };
                if (instruction.kind == .unchecked_assume and !uncheckedAssumeHasMatchingContract(function, instruction)) {
                    reporter.err(
                        sourcePointSpan(source),
                        "E_UNCHECKED_OUTSIDE_CONTRACT: MIR verifier found unchecked optimizer assumption outside matching contract region",
                        .{},
                    );
                }
                if (instruction.kind == .unsafe_check) {
                    reporter.err(
                        sourcePointSpan(source),
                        "E_UNSAFE_REQUIRED: MIR verifier found unsafe machine effect outside unsafe context",
                        .{},
                    );
                }
                if (instruction.kind == .address_deref) {
                    const address_class = addressClassFromName(instruction.detail) orelse .paddr;
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found illegal direct dereference of {s}",
                        .{ addressDerefDiagnostic(address_class), instruction.detail },
                    );
                }
                if (instruction.kind == .address_conversion) {
                    const source_class = switch (instruction.result_ty) {
                        .address => |kind| kind,
                        else => .paddr,
                    };
                    const target_class = addressClassFromName(instruction.detail) orelse .paddr;
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found invalid address-class conversion",
                        .{addressClassMismatchDiagnostic(target_class, source_class)},
                    );
                }
                if (instruction.kind == .address_operation) {
                    reporter.err(
                        sourcePointSpan(source),
                        "E_ADDRESS_CLASS_OPERATION: MIR verifier found illegal operation on opaque address class",
                        .{},
                    );
                }
                if (instruction.kind == .ffi_check) {
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found illegal c_void FFI operation",
                        .{ffiFindingDiagnostic(instruction.detail)},
                    );
                }
                if (instruction.kind == .usage_check) {
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found invalid typed-resource operation",
                        .{usageFindingDiagnostic(instruction.detail)},
                    );
                }
                if (instruction.kind == .mmio_check) {
                    if (std.mem.eql(u8, instruction.detail, "direct_assign")) {
                        reporter.err(
                            sourcePointSpan(source),
                            "E_MMIO_DIRECT_ASSIGN: MIR verifier found direct assignment to an MMIO register",
                            .{},
                        );
                    } else {
                        reporter.err(
                            sourcePointSpan(source),
                            "E_MMIO_ACCESS_FORBIDDEN: MIR verifier found MMIO register access disallowed by Reg/RegBits mode",
                            .{},
                        );
                    }
                }
                if (isRepresentationSensitiveProducer(instruction) and !producerHasDominatingRepresentationCheck(block, instruction_index, instruction.result_ty)) {
                    reporter.err(
                        sourcePointSpan(source),
                        "E_REPRESENTATION_CHECK_MISSING: MIR verifier found representation-sensitive value use without dominating check",
                        .{},
                    );
                }
                if (isRepresentationSensitiveUse(instruction) and !try useHasDominatingRepresentationCheck(mir.allocator, function, block_index, instruction_index, instruction.result_ty)) {
                    reporter.err(
                        sourcePointSpan(source),
                        "E_REPRESENTATION_CHECK_MISSING: MIR verifier found representation-sensitive value use without dominating check",
                        .{},
                    );
                }
                if (instruction.kind == .nullability_conversion) {
                    const code = nullabilityDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found invalid nullability conversion",
                        .{code},
                    );
                }
                if (instruction.kind == .conversion_check) {
                    const code = conversionDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found invalid implicit conversion",
                        .{code},
                    );
                }
                if (instruction.kind == .aggregate_check) {
                    const code = aggregateDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found invalid aggregate literal shape",
                        .{code},
                    );
                }
                if (instruction.kind == .result_check) {
                    if (resultFindingDiagnostic(instruction.detail)) |code| {
                        reporter.err(
                            sourcePointSpan(source),
                            "{s}: MIR verifier found invalid Result control-flow handling",
                            .{code},
                        );
                    }
                }
                if (instruction.kind == .switch_check) {
                    const code = switchFindingDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found invalid switch pattern coverage",
                        .{code},
                    );
                }
                if (instruction.kind == .assignment_check) {
                    const code = assignmentFindingDiagnostic(instruction.detail);
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR verifier found invalid assignment target",
                        .{code},
                    );
                }
                if (irqContextCallFinding(mir, function, instruction)) |finding| {
                    const code = irqContextDiagnostic(finding);
                    reporter.err(
                        sourcePointSpan(source),
                        "{s}: MIR context verifier rejected call in #[irq_context]",
                        .{code},
                    );
                }
            }
        }

        reportFindings(function, reporter);
    }
}

/// Render every refusal the builder recorded for this function.
///
/// This is the finding channel after it stopped being an instruction stream.
/// A finding names its diagnostic by its own value: there is no `detail`
/// string to classify, and no family-shaped `eql` chain with a fallback for a
/// spelling nothing emits. What the walk still shares with the one it
/// replaced is the source rule -- a span that does not resolve falls back to
/// line 1, column 1, exactly as `instructionSourcePoint` did.
fn reportFindings(function: Function, reporter: *diagnostics.Reporter) void {
    for (function.findings) |finding| {
        const source: SourcePoint = sourcePointForSpanId(function, finding.typed_span_id) orelse .{ .line = 1, .column = 1 };
        switch (finding.kind) {
            .operator => |operator| reporter.err(
                sourcePointSpan(source),
                "{s}: MIR verifier found invalid operator operand",
                .{operatorDiagnostic(operator)},
            ),
            .arithmetic_domain => |domain| reporter.err(
                sourcePointSpan(source),
                "{s}: MIR verifier found invalid arithmetic-domain operation",
                .{arithmeticDomainDiagnostic(domain)},
            ),
        }
    }
}

fn verifyModuleSymbolIdentities(module: Module, reporter: *diagnostics.Reporter) void {
    var malformed = false;
    for (module.symbol_identities, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) malformed = true;
        for (module.symbol_identities[0..index]) |prior| {
            if (std.mem.eql(u8, prior.spelling, identity.spelling)) malformed = true;
            if (prior.id.eql(identity.id)) malformed = true;
        }
    }
    for (module.functions) |function| {
        if (!function.typed_symbol_id.isValid()) {
            if (module.symbol_identities.len != 0) malformed = true;
            continue;
        }
        const index = function.typed_symbol_id.index();
        if (index >= module.symbol_identities.len) {
            malformed = true;
            continue;
        }
        if (!std.mem.eql(u8, module.symbol_identities[index].spelling, function.name)) malformed = true;
    }
    if (malformed) {
        reporter.err(
            sourcePointSpan(.{ .line = 1, .column = 1 }),
            "E_MIR_SYMBOL_ID: MIR verifier found malformed symbol identity table",
            .{},
        );
    }
}

fn verifyModuleSourceIdentities(module: Module, reporter: *diagnostics.Reporter) void {
    var malformed = false;
    for (module.source_identities, 0..) |identity, index| {
        if (!identity.id.isValid() or identity.id.index() != index) malformed = true;
        for (module.source_identities[0..index]) |prior| {
            if (prior.id.eql(identity.id) or prior.file_id == identity.file_id) malformed = true;
        }
    }
    for (module.functions) |function| {
        if (!function.typed_source_id.isValid()) {
            if (module.source_identities.len != 0) malformed = true;
            continue;
        }
        if (function.typed_source_id.index() >= module.source_identities.len) malformed = true;
    }
    if (malformed) {
        reporter.err(
            sourcePointSpan(.{ .line = 1, .column = 1 }),
            "E_MIR_SOURCE_ID: MIR verifier found malformed per-file source identity",
            .{},
        );
    }
}

fn verifyFunctionInstructionIdentities(function: Function, reporter: *diagnostics.Reporter) void {
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (!instructionTypedIdentitiesValid(function, instruction)) {
                reporter.err(
                    sourcePointSpan(instructionSourcePoint(function, instruction) orelse .{ .line = 1, .column = 1 }),
                    "E_MIR_IDENTITY: MIR verifier found malformed instruction identity",
                    .{},
                );
                return;
            }
        }
    }
}

/// A resolved access joins the typed node that realizes it, by the `AccessId`
/// the fact and the node's `ExecutableAccessObligation` share.
///
/// The exactly-one rule is stated over `ExecutableBody` in both directions: a
/// fact names exactly one typed obligation, and an obligation is named by
/// exactly one fact. That replaces two stream walks and the two `detail`
/// tests that stood in for identities the stream did not have -- a
/// `startsWith("range_slice")` to tell a slice from an element read, and an
/// `eql("const_get")` to excuse a comptime projection. The typed body says
/// which shape a node is, so a `const_get` is not an index node at all and
/// needs no exception, and an element access is separated from a range slice
/// by its operation rather than by a string.
///
/// The instruction walk remains only for a body the typed form does not
/// represent: an incomplete body, an `extern` declaration, and a global
/// initializer's pseudo-callable.
fn verifyFunctionAccessFacts(module: Module, function: Function, reporter: *diagnostics.Reporter) void {
    const typed = typedObligationsRepresented(module, function);
    for (function.access_facts, 0..) |fact, fact_index| {
        if (!accessFactValid(module, function, fact)) {
            reporter.err(
                sourcePointSpan(sourcePointForSpanId(function, accessFactSpanId(fact)) orelse .{ .line = 1, .column = 1 }),
                "E_MIR_ACCESS_FACT: MIR verifier found malformed resolved access fact",
                .{},
            );
            return;
        }
        for (function.access_facts[0..fact_index]) |prior| {
            // One access, one fact. Checked on the access identity: two
            // synthesized accesses in a generated body share a span but are
            // not the same access, while a copied fact carries a copied
            // identity and is still caught.
            if (prior.accessId().eql(fact.accessId())) {
                reporter.err(
                    sourcePointSpan(sourcePointForSpanId(function, accessFactSpanId(fact)) orelse .{ .line = 1, .column = 1 }),
                    "E_MIR_ACCESS_FACT: MIR verifier found duplicate resolved access fact",
                    .{},
                );
                return;
            }
        }
    }
    if (typed) {
        const body = &function.executable_body;
        for (body.expressions) |expression| {
            const obligation = mir_model.executableExpressionAccessObligation(expression) orelse continue;
            if (countAccessFactsForObligation(function, obligation.id) == 1) continue;
            reporter.err(
                sourcePointSpan(sourcePointForSpanId(function, expression.span_id) orelse .{ .line = 1, .column = 1 }),
                "E_MIR_ACCESS_FACT: MIR verifier found typed access without resolved access fact",
                .{},
            );
            return;
        }
        for (body.places) |place| {
            for (place.projections[0..place.projection_count]) |projection| {
                const obligation = mir_model.executablePlaceAccessObligation(projection) orelse continue;
                if (countAccessFactsForObligation(function, obligation.id) == 1) continue;
                reporter.err(
                    sourcePointSpan(sourcePointForSpanId(function, place.span_id) orelse .{ .line = 1, .column = 1 }),
                    "E_MIR_ACCESS_FACT: MIR verifier found typed access without resolved access fact",
                    .{},
                );
                return;
            }
        }
        return;
    }
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind != .index) continue;
        // `const_get` has its own closed fact family and is not source-level
        // indexing syntax, so it deliberately does not carry AccessFact.
        if (std.mem.eql(u8, instruction.detail, "const_get")) continue;
        const present = if (std.mem.startsWith(u8, instruction.detail, "range_slice"))
            rangeSliceFactForInstruction(function, instruction)
        else
            indexFactForInstruction(function, instruction);
        if (!present) {
            reporter.err(
                sourcePointSpan(instructionSourcePoint(function, instruction) orelse .{ .line = 1, .column = 1 }),
                "E_MIR_ACCESS_FACT: MIR verifier found index instruction without resolved access fact",
                .{},
            );
            return;
        }
    };
}

fn countAccessFactsForObligation(function: Function, id: mir_model.AccessId) usize {
    var count: usize = 0;
    for (function.access_facts) |fact| {
        if (fact.accessId().eql(id)) count += 1;
    }
    return count;
}

/// The typed agreements an element access or range slice makes with its
/// obligation. The operand spans are read off the typed operand *nodes*, so
/// the fact agrees with the operands the body evaluates rather than with a
/// copy the builder stamped on an instruction.
fn accessSiteAgreesWithFact(function: Function, site: mir_model.ExecutableAccessSite, fact: AccessFact) bool {
    return switch (fact) {
        .index => |access| switch (site.kind) {
            .index_expression => site.span_id.eql(access.typed_span_id) and
                site.base_span_id.eql(access.base_span_id) and
                site.index_span_id.eql(access.index_span_id) and
                typeIdMatchesValueType(function, site.result_type_id, access.result_ty),
            // A place projection's base is the place root and the
            // projections before it, not an operand node, so there is no
            // base span to agree about.
            .index_place => site.span_id.eql(access.typed_span_id) and
                site.index_span_id.eql(access.index_span_id) and
                typeIdMatchesValueType(function, site.result_type_id, access.result_ty),
            .range_slice => false,
        },
        .range_slice => |access| site.kind == .range_slice and
            site.span_id.eql(access.typed_span_id) and
            site.base_span_id.eql(access.base_span_id) and
            site.index_span_id.eql(access.start_span_id) and
            site.end_span_id.eql(access.end_span_id) and
            typeIdMatchesValueType(function, site.result_type_id, access.result_ty),
        else => false,
    };
}

fn accessFactValid(module: Module, function: Function, fact: AccessFact) bool {
    if (!fact.accessId().isValid()) return false;
    const primary_span = accessFactSpanId(fact);
    if (!spanIdValid(function, primary_span)) return false;
    const typed = typedObligationsRepresented(module, function);
    switch (fact) {
        .index => |access| {
            if (!accessSpanIdsValid(function, &.{ access.base_span_id, access.index_span_id })) return false;
            if (access.index_ty != .integer) return false;
            if (typed) {
                const site = mir_model.executableAccessSite(&function.executable_body, access.typed_access_id) orelse return false;
                return accessSiteAgreesWithFact(function, site, fact);
            }
            return matchingIndexInstruction(function, access.typed_span_id, access.result_ty, access.base_span_id, access.index_span_id);
        },
        .range_slice => |access| {
            if (!accessSpanIdsValid(function, &.{ access.base_span_id, access.start_span_id, access.end_span_id })) return false;
            if (!accessResultIsSlice(access.result_ty) or access.start_ty != .integer or access.end_ty != .integer) return false;
            if (typed) {
                const site = mir_model.executableAccessSite(&function.executable_body, access.typed_access_id) orelse return false;
                return accessSiteAgreesWithFact(function, site, fact);
            }
            return matchingRangeSliceInstruction(function, access.typed_span_id, access.result_ty, access.base_span_id, access.start_span_id);
        },
        .address_of => |access| {
            if (!accessSpanIdsValid(function, &.{access.operand_span_id})) return false;
            return switch (access.result_ty) {
                // Function addresses are represented as `.value` in the
                // bounded ValueType domain; data addresses retain pointer or
                // address-class shape.
                .pointer, .nullable_pointer, .address, .value => true,
                else => false,
            };
        },
        .deref => |access| {
            if (!accessSpanIdsValid(function, &.{access.operand_span_id})) return false;
            return switch (access.operand_ty) {
                .pointer, .nullable_pointer, .address => true,
                else => false,
            };
        },
    }
}

fn accessSpanIdsValid(function: Function, span_ids: []const SpanId) bool {
    for (span_ids) |span_id| if (!spanIdValid(function, span_id)) return false;
    return true;
}

fn accessResultIsSlice(ty: ValueType) bool {
    return switch (ty) {
        .slice => true,
        .pointer => |shape| shape.kind == .slice,
        else => false,
    };
}

fn matchingIndexInstruction(function: Function, span_id: SpanId, result_ty: ValueType, base_span_id: SpanId, index_span_id: SpanId) bool {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind != .index or !instructionMatchesSpanId(function, instruction, span_id)) continue;
        if (std.meta.eql(instruction.result_ty, result_ty) and instruction.typed_base_operand_span_id.eql(base_span_id) and instruction.typed_index_operand_span_id.eql(index_span_id)) return true;
    };
    return false;
}

fn matchingRangeSliceInstruction(function: Function, span_id: SpanId, result_ty: ValueType, base_span_id: SpanId, start_span_id: SpanId) bool {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind != .index or !instructionMatchesSpanId(function, instruction, span_id)) continue;
        if (!std.mem.startsWith(u8, instruction.detail, "range_slice")) continue;
        if (std.meta.eql(instruction.result_ty, result_ty) and instruction.typed_base_operand_span_id.eql(base_span_id) and instruction.typed_index_operand_span_id.eql(start_span_id)) return true;
    };
    return false;
}

fn indexFactForInstruction(function: Function, instruction: Instruction) bool {
    for (function.access_facts) |fact| switch (fact) {
        .index => |access| if (access.typed_span_id.eql(instruction.typed_span_id) and
            std.meta.eql(access.result_ty, instruction.result_ty) and
            access.base_span_id.eql(instruction.typed_base_operand_span_id) and
            access.index_span_id.eql(instruction.typed_index_operand_span_id)) return true,
        else => {},
    };
    return false;
}

fn rangeSliceFactForInstruction(function: Function, instruction: Instruction) bool {
    for (function.access_facts) |fact| switch (fact) {
        .range_slice => |access| if (access.typed_span_id.eql(instruction.typed_span_id) and
            std.meta.eql(access.result_ty, instruction.result_ty) and
            access.base_span_id.eql(instruction.typed_base_operand_span_id) and
            access.start_span_id.eql(instruction.typed_index_operand_span_id)) return true,
        else => {},
    };
    return false;
}

fn accessFactTag(fact: AccessFact) std.meta.Tag(AccessFact) {
    return std.meta.activeTag(fact);
}

fn accessFactSpanId(fact: AccessFact) SpanId {
    return switch (fact) {
        inline else => |access| access.typed_span_id,
    };
}

fn instructionTypedIdentitiesValid(function: Function, instruction: Instruction) bool {
    if (instruction.typed_result_ty.isValid()) {
        const index = instruction.typed_result_ty.index();
        if (index >= function.type_identities.len) return false;
        if (!function.type_identities[index].matches(instruction.result_ty)) return false;
    }
    if (instruction.typed_span_id.isValid() and instruction.typed_span_id.index() >= function.span_identities.len) return false;
    const requires_operand_identity = (instruction.kind == .unary and std.mem.eql(u8, instruction.detail, "logical_not")) or
        (instruction.kind == .binary and (std.mem.eql(u8, instruction.detail, "logical_and") or std.mem.eql(u8, instruction.detail, "logical_or")));
    if (requires_operand_identity and !instruction.typed_left_operand_span_id.isValid()) return false;
    if (instruction.kind == .binary and requires_operand_identity and !instruction.typed_right_operand_span_id.isValid()) return false;
    if (instruction.typed_left_operand_span_id.isValid()) {
        const is_cast = instruction.kind == .expr and std.mem.eql(u8, instruction.detail, "cast");
        if (instruction.kind != .unary and instruction.kind != .binary and !is_cast) return false;
        if (instruction.typed_left_operand_span_id.index() >= function.span_identities.len) return false;
        if (instruction.kind == .binary) {
            if (!instruction.typed_right_operand_span_id.isValid()) return false;
            if (instruction.typed_right_operand_span_id.index() >= function.span_identities.len) return false;
        } else if (instruction.typed_right_operand_span_id.isValid()) {
            return false;
        }
    } else if (instruction.typed_right_operand_span_id.isValid()) {
        return false;
    }
    if (instruction.typed_base_operand_span_id.isValid()) {
        if (instruction.typed_base_operand_span_id.index() >= function.span_identities.len) return false;
        if (instruction.kind == .expr) {
            if ((instruction.member_field_index == null) == (instruction.builtin_member == null) or
                instruction.typed_index_operand_span_id.isValid()) return false;
        } else if (instruction.kind == .index) {
            if (instruction.member_field_index != null or instruction.builtin_member != null or
                !instruction.typed_index_operand_span_id.isValid()) return false;
        } else return false;
    } else if (instruction.member_field_index != null or instruction.builtin_member != null or instruction.typed_index_operand_span_id.isValid()) {
        return false;
    }
    if (instruction.typed_index_operand_span_id.isValid()) {
        if (instruction.typed_index_operand_span_id.index() >= function.span_identities.len) return false;
        if (instruction.constant_index_value) |constant_index| {
            const operand = instructionAtSpan(function, instruction.typed_index_operand_span_id) orelse return false;
            if (operand.constant_usize_value != constant_index) return false;
        }
    } else if (instruction.constant_index_value != null or instruction.static_index_bound != null) return false;
    if (instruction.constant_usize_value != null and (instruction.kind != .expr or instruction.result_ty != .integer)) return false;
    if (instruction.typed_aggregate_operand_count > Instruction.max_aggregate_operands) return false;
    if (instruction.typed_aggregate_operand_count != 0) {
        const is_array = std.mem.eql(u8, instruction.detail, "array_literal");
        const is_struct = std.mem.eql(u8, instruction.detail, "struct_literal");
        if (instruction.kind != .expr or (!is_array and !is_struct)) return false;
        for (instruction.typed_aggregate_operand_span_ids, 0..) |operand_span_id, index| {
            if (index < instruction.typed_aggregate_operand_count) {
                if (!operand_span_id.isValid() or operand_span_id.index() >= function.span_identities.len) return false;
                if (is_array and instruction.typed_aggregate_field_indices[index] != std.math.maxInt(usize)) return false;
                if (is_struct) {
                    const field_index = instruction.typed_aggregate_field_indices[index];
                    if (field_index == std.math.maxInt(usize)) return false;
                    for (instruction.typed_aggregate_field_indices[0..index]) |previous| {
                        if (previous == field_index) return false;
                    }
                }
            } else {
                if (operand_span_id.isValid()) return false;
                if (instruction.typed_aggregate_field_indices[index] != std.math.maxInt(usize)) return false;
            }
        }
    } else {
        for (instruction.typed_aggregate_operand_span_ids, instruction.typed_aggregate_field_indices) |operand_span_id, field_index| {
            if (operand_span_id.isValid()) return false;
            if (field_index != std.math.maxInt(usize)) return false;
        }
    }
    if (instruction.typed_switch_pattern_count > Instruction.max_switch_patterns) return false;
    if (instruction.typed_switch_pattern_count != 0) {
        if (instruction.kind != .expr or instruction.result_ty != .branch) return false;
        for (instruction.typed_switch_patterns, 0..) |pattern, index| {
            const unused = switch (pattern) {
                .unused => true,
                else => false,
            };
            if (index < instruction.typed_switch_pattern_count) {
                if (unused) return false;
            } else if (!unused) return false;
        }
    } else {
        for (instruction.typed_switch_patterns) |pattern| {
            switch (pattern) {
                .unused => {},
                else => return false,
            }
        }
    }
    if (instruction.kind == .assign) {
        if (!instruction.typed_target_operand_span_id.isValid() or !instruction.typed_value_operand_span_id.isValid()) return false;
        if (instruction.typed_target_operand_span_id.index() >= function.span_identities.len) return false;
    } else if (instruction.typed_target_operand_span_id.isValid()) return false;
    if (instruction.typed_value_operand_span_id.isValid()) {
        if (instruction.kind != .assign and instruction.kind != .return_value and instruction.kind != .local and
            instruction.kind != .assert_condition) return false;
        if (instruction.typed_value_operand_span_id.index() >= function.span_identities.len) return false;
    }
    const is_direct_argument = instruction.kind == .target_type and std.mem.eql(u8, instruction.detail, @tagName(TargetTypeKind.direct_call_argument));
    const is_indirect_argument = instruction.kind == .target_type and std.mem.eql(u8, instruction.detail, @tagName(TargetTypeKind.indirect_call_argument));
    const is_for_element = instruction.kind == .target_type and std.mem.eql(u8, instruction.detail, @tagName(TargetTypeKind.for_element));
    const is_call_target = instruction.kind == .call_target;
    if (instruction.kind == .call or instruction.kind == .indirect_call or is_call_target or is_direct_argument or is_indirect_argument) {
        if (!instruction.typed_callee_span_id.isValid()) return false;
        if (instruction.typed_callee_span_id.index() >= function.span_identities.len) return false;
    } else if (instruction.typed_callee_span_id.isValid()) {
        return false;
    }
    if (is_direct_argument or is_indirect_argument or is_for_element) {
        if (is_indirect_argument and !instruction.typed_operand_value_id.isValid()) return false;
        if (is_for_element and !instruction.typed_operand_value_id.isValid()) return false;
        if (instruction.typed_operand_value_id.isValid() and instruction.typed_operand_value_id.index() >= function.value_identities.len) return false;
    } else if (instruction.typed_operand_value_id.isValid()) {
        return false;
    }
    if (instruction.kind == .indirect_call and instruction.typed_callee_root_value_id.isValid()) {
        if (!instruction.typed_callee_root_span_id.isValid()) return false;
        if (instruction.typed_callee_root_value_id.index() >= function.value_identities.len) return false;
        if (instruction.typed_callee_root_span_id.index() >= function.span_identities.len) return false;
        if (instruction.typed_target_owner_id == null) return false;
    } else if (instruction.typed_callee_root_value_id.isValid() or instruction.typed_callee_root_span_id.isValid() or instruction.callee_field_index != null) {
        return false;
    }
    if (instruction.typed_value_id) |value_id| if (!valueIdValid(function, value_id)) return false;
    if (instruction.typed_target_owner_id) |owner_id| {
        if (!owner_id.isValid()) return false;
        const index = owner_id.index();
        if (index >= function.target_owner_identities.len) return false;
        if (!function.target_owner_identities[index].id.eql(owner_id)) return false;
    }
    return true;
}

fn instructionAtSpan(function: Function, span_id: SpanId) ?Instruction {
    var matched: ?Instruction = null;
    for (function.blocks) |block| for (block.instructions) |candidate| {
        if (!candidate.typed_span_id.eql(span_id)) continue;
        if (candidate.kind != .expr) continue;
        if (matched != null) return null;
        matched = candidate;
    };
    return matched;
}

/// A representation fact names the typed obligation it describes:
/// `ExecutableExpression.representation_obligation`. One node, one fact, in
/// both directions -- the builder records the obligation where it appends the
/// fact, so a fact deleted from the table leaves an obligation no fact names
/// and is caught.
///
/// The `detail` agreement is dropped rather than restated. It compared
/// `RepresentationFact.detail` against the instruction's string, and for a
/// `representation_use` it compared the same string against `@tagName(use)`:
/// the enum was already the authority and the string its rendering. What the
/// fact and the obligation agree about now is the instruction kind, the use
/// context, the result `TypeId` and the value identity -- all typed.
///
/// The walk over representation-sensitive instructions remains only for a
/// body the typed form does not represent; see `typedObligationsRepresented`.
pub fn validateRepresentationFactsForLowering(module: Module) error{InvalidMirRepresentationFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        const typed = typedObligationsRepresented(module, function);
        if (!typed) {
            for (function.blocks) |block| {
                for (block.instructions) |instruction| {
                    if (!representationFactKind(instruction.kind, instruction.result_ty)) continue;
                    if (countMatchingRepresentationFacts(function, instruction) != 1) return error.InvalidMirRepresentationFacts;
                }
            }
        }
        for (function.representation_facts) |fact| {
            if (!representationFactTypedIdentitiesValid(function, fact)) return error.InvalidMirRepresentationFacts;
            // A `representation_use` fact carries the typed use context, and
            // nothing else does. Without this a consumer reading `fact.use`
            // would silently fall back to the string it is replacing.
            if ((fact.kind == .representation_use) != (fact.use != null)) return error.InvalidMirRepresentationFacts;
            if (typed) {
                if (mir_model.executableRepresentationObligationCount(body, fact.typed_inst_id) != 1)
                    return error.InvalidMirRepresentationFacts;
                const obligation = mir_model.executableRepresentationObligation(body, fact.typed_inst_id) orelse
                    return error.InvalidMirRepresentationFacts;
                if (!representationFactAgreesWithObligation(fact, obligation)) return error.InvalidMirRepresentationFacts;
            } else if (countMatchingRepresentationInstructions(function, fact) != 1) {
                return error.InvalidMirRepresentationFacts;
            }
        }
        if (!typed) continue;
        for (body.representation_obligations) |obligation| {
            if (!executableObligationOwnerValid(body, obligation.owner)) return error.InvalidMirRepresentationFacts;
            if (countRepresentationFactsForObligation(function, obligation.id) != 1) return error.InvalidMirRepresentationFacts;
        }
    }
}

fn representationFactAgreesWithObligation(fact: RepresentationFact, obligation: mir_model.ExecutableRepresentationObligation) bool {
    if (!fact.typed_inst_id.isValid() or !fact.typed_inst_id.eql(obligation.id)) return false;
    if (fact.kind != obligation.kind) return false;
    if (fact.use != obligation.use) return false;
    if (!fact.typed_result_ty.eql(obligation.result_type_id)) return false;
    return fact.typed_value_id.eql(obligation.value_id);
}

fn countRepresentationFactsForObligation(function: Function, id: mir_model.InstId) usize {
    var count: usize = 0;
    for (function.representation_facts) |fact| {
        if (fact.typed_inst_id.eql(id)) count += 1;
    }
    return count;
}

/// An integer fact names the typed literal node its conversion belongs to:
/// `ExecutableExpression.literal_conversion`. One node, one fact, in both
/// directions -- the builder records the obligation where it appends the
/// fact, so a fact deleted from the table leaves an obligation no fact names
/// and is caught.
///
/// The fact no longer agrees with anything about the literal's *spelling*.
/// That agreement compared `IntegerFact.literal` against `Instruction.detail`,
/// which is the string classification the typed body exists to replace; the
/// authority is the identity plus the target type, both of which are checked.
///
/// The walk over `integer_literal_conversion` instructions remains only for a
/// body the typed form does not represent; see `typedObligationsRepresented`.
pub fn validateIntegerFactsForLowering(module: Module) error{InvalidMirIntegerFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        const typed = typedObligationsRepresented(module, function);
        for (function.integer_facts) |fact| {
            if (!integerFactTypedIdentitiesValid(function, fact)) return error.InvalidMirIntegerFacts;
            if (countMatchingIntegerFacts(function, fact) != 1) return error.InvalidMirIntegerFacts;
            if (typed) {
                if (mir_model.executableLiteralConversionCount(body, fact.typed_inst_id) != 1)
                    return error.InvalidMirIntegerFacts;
                // The obligation records the type the conversion produces, so
                // a fact retargeted at another type disagrees with the node.
                // This is what replaces the agreement the fact used to hold
                // with `Instruction.typed_result_ty`.
                const node = mir_model.executableLiteralConversionNode(body, fact.typed_inst_id) orelse
                    return error.InvalidMirIntegerFacts;
                if (mir_model.executableLiteralConversionIsFloat(node)) return error.InvalidMirIntegerFacts;
                if (!node.literal_conversion.target_type_id.eql(fact.target_type_id))
                    return error.InvalidMirIntegerFacts;
            } else if (countMatchingIntegerInstructions(function, fact) != 1) {
                return error.InvalidMirIntegerFacts;
            }
        }
        if (typed) {
            for (body.expressions) |expression| {
                if (!expression.literal_conversion.isValid()) continue;
                // A literal is integer or float, never both. The node says
                // which, so a missing float fact stays a float refusal.
                if (mir_model.executableLiteralConversionIsFloat(expression)) continue;
                if (countIntegerFactsForConversion(function, expression.literal_conversion.id) != 1)
                    return error.InvalidMirIntegerFacts;
            }
            continue;
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (!isIntegerLiteralConversionInstruction(instruction)) continue;
                if (countMatchingIntegerFactsForInstruction(function, instruction) != 1) return error.InvalidMirIntegerFacts;
            }
        }
    }
}

fn countIntegerFactsForConversion(function: Function, id: mir_model.InstId) usize {
    var count: usize = 0;
    for (function.integer_facts) |fact| {
        if (fact.typed_inst_id.eql(id)) count += 1;
    }
    return count;
}

/// A float fact names the same typed obligation an integer fact does: the
/// literal-conversion record on the typed literal node. A literal is numeric
/// one way or the other, so the two families share the field and the
/// exactly-one rule is stated the same way in both directions.
///
/// The `expr`-with-`detail == "float"` walk remains only for a body the typed
/// form does not represent; see `typedObligationsRepresented`.
pub fn validateFloatFactsForLowering(module: Module) error{InvalidMirFloatFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        const typed = typedObligationsRepresented(module, function);
        for (function.float_facts) |fact| {
            if (!floatFactTypedIdentitiesValid(function, fact)) return error.InvalidMirFloatFacts;
            if (countMatchingFloatFacts(function, fact) != 1) return error.InvalidMirFloatFacts;
            if (typed) {
                if (mir_model.executableLiteralConversionCount(body, fact.typed_inst_id) != 1)
                    return error.InvalidMirFloatFacts;
                const node = mir_model.executableLiteralConversionNode(body, fact.typed_inst_id) orelse
                    return error.InvalidMirFloatFacts;
                if (!mir_model.executableLiteralConversionIsFloat(node)) return error.InvalidMirFloatFacts;
                if (!node.literal_conversion.target_type_id.eql(fact.target_type_id))
                    return error.InvalidMirFloatFacts;
            } else if (countMatchingFloatInstructions(function, fact) != 1) {
                return error.InvalidMirFloatFacts;
            }
        }
        if (typed) {
            for (body.expressions) |expression| {
                if (!expression.literal_conversion.isValid()) continue;
                if (!mir_model.executableLiteralConversionIsFloat(expression)) continue;
                if (countFloatFactsForConversion(function, expression.literal_conversion.id) != 1)
                    return error.InvalidMirFloatFacts;
            }
            continue;
        }
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (!isFloatLiteralInstruction(instruction)) continue;
                if (countMatchingFloatFactsForInstruction(function, instruction) != 1) return error.InvalidMirFloatFacts;
            }
        }
    }
}

fn countFloatFactsForConversion(function: Function, id: mir_model.InstId) usize {
    var count: usize = 0;
    for (function.float_facts) |fact| {
        if (fact.typed_inst_id.eql(id)) count += 1;
    }
    return count;
}

/// A no-overflow fact names the typed range obligation the operation it
/// describes owns: `ExecutableExpression.range_obligation`.
///
/// Several facts name one obligation on purpose -- the same operation is
/// recorded once per target label (as a binary operand, an aggregate element,
/// a field, and as the assigned value) -- so the uniqueness rule is stated
/// within a target-label group, exactly as it was, while each fact must still
/// name exactly one obligation. Executable-body completeness separately
/// proves that every unchecked executable projection has a fact.
///
/// The obligation carries the operation as `ExecutableUncheckedOp`, which is
/// the typed form of `RangeFact.op`; that field is still text in the legacy
/// table, so the agreement crosses `@tagName` until it is not. Everything
/// else the fact used to agree with the `unchecked_assume` instruction about
/// -- the contract region, the span and the result type -- is on the
/// obligation.
///
/// The walk over `unchecked_assume` instructions remains only for a body the
/// typed form does not represent; see `typedObligationsRepresented`.
pub fn validateRangeFactsForLowering(module: Module) error{InvalidMirRangeFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        const typed = typedObligationsRepresented(module, function);
        for (function.range_facts) |fact| {
            if (!rangeFactTypedIdentityValid(function, fact)) return error.InvalidMirRangeFacts;
            if (countMatchingRangeFactsInOwnershipGroup(function, fact) != 1) return error.InvalidMirRangeFacts;
            if (typed) {
                if (mir_model.executableRangeObligationCount(body, fact.typed_inst_id) != 1)
                    return error.InvalidMirRangeFacts;
                const obligation = mir_model.executableRangeObligation(body, fact.typed_inst_id) orelse
                    return error.InvalidMirRangeFacts;
                if (!rangeFactAgreesWithObligation(function, fact, obligation)) return error.InvalidMirRangeFacts;
            } else if (countMatchingRangeInstructions(function, fact) != 1) {
                return error.InvalidMirRangeFacts;
            }
        }
    }
}

fn rangeFactAgreesWithObligation(function: Function, fact: RangeFact, obligation: mir_model.ExecutableRangeObligation) bool {
    if (!fact.typed_inst_id.isValid() or !fact.typed_inst_id.eql(obligation.id)) return false;
    if (fact.region_id != obligation.region_id) return false;
    if (!fact.typed_span_id.eql(obligation.span_id)) return false;
    if (!std.mem.eql(u8, fact.op, @tagName(obligation.op))) return false;
    return typeIdMatchesValueType(function, obligation.result_type_id, fact.result_ty);
}

/// A bounds fact names the typed bounds obligation its check realizes, and
/// the checked access by the operand's canonical SpanId.
///
/// The obligation is a field on the typed node -- `index.bounds_obligation`,
/// `range_slice.bounds_obligation`, or the same field on an `index` place
/// projection -- so the exactly-one rule is stated over `ExecutableBody`: a
/// fact names exactly one typed obligation, and an obligation is named by at
/// most one fact. Two checks that share a source span stay distinct because
/// each claims its own typed node.
///
/// The reverse direction is deliberately "at most one" rather than "exactly
/// one": the executable body already owns complete trap-edge validation, so a
/// missing legacy fact does not block canonical lowering, and requiring one
/// per obligation would make the legacy table load-bearing again.
///
/// The walk over `cmp_bounds` instructions remains only for a body the typed
/// form does not represent: an incomplete body, an `extern` declaration, and
/// a global initializer's pseudo-callable, which is an expression rather than
/// a statement sequence and has no typed body to carry the obligation.
pub fn validateBoundsFactsForLowering(module: Module) error{InvalidMirBoundsFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        const typed = typedObligationsRepresented(module, function);
        for (function.bounds_facts) |fact| {
            if (!boundsFactTypedIdentityValid(function, fact)) return error.InvalidMirBoundsFacts;
            if (countMatchingBoundsFacts(function, fact) != 1) return error.InvalidMirBoundsFacts;
            if (typed) {
                if (mir_model.executableBoundsObligationCount(body, fact.typed_inst_id, fact.kind) != 1)
                    return error.InvalidMirBoundsFacts;
            } else if (countMatchingBoundsInstructions(function, fact) != 1) {
                return error.InvalidMirBoundsFacts;
            }
            if (countMatchingBoundsAccessFacts(function, fact) != 1) return error.InvalidMirBoundsFacts;
        }
        if (!typed) continue;
        for (body.expressions) |expression| {
            const obligation = mir_model.executableExpressionBoundsObligation(expression) orelse continue;
            if (countBoundsFactsForObligation(function, obligation) > 1) return error.InvalidMirBoundsFacts;
        }
        for (body.places) |place| {
            for (place.projections[0..place.projection_count]) |projection| {
                const obligation = mir_model.executablePlaceBoundsObligation(projection) orelse continue;
                if (countBoundsFactsForObligation(function, obligation) > 1) return error.InvalidMirBoundsFacts;
            }
        }
    }
}

/// Does this function's typed body carry the obligations its checks own? A
/// body the builder stopped partway through, an `extern` declaration and a
/// global initializer's pseudo-callable do not, and are the only shapes still
/// verified against the instruction stream.
fn typedObligationsRepresented(module: Module, function: Function) bool {
    const body = &function.executable_body;
    if (!body.isComplete() or function.is_extern or executableBodyIsEmpty(body)) return false;
    return !functionIsGlobalInitializer(module, function);
}

fn countBoundsFactsForObligation(function: Function, obligation: mir_model.ExecutableBoundsObligation) usize {
    var count: usize = 0;
    for (function.bounds_facts) |fact| {
        if (fact.kind == obligation.kind and fact.typed_inst_id.eql(obligation.id)) count += 1;
    }
    return count;
}

fn boundsFactTypedIdentityValid(function: Function, fact: BoundsFact) bool {
    return fact.typed_inst_id.isValid() and spanIdValid(function, fact.typed_span_id);
}

/// One bounds check, one fact. Counted on the obligation identity rather than
/// on the operand span, which two distinct checks can share.
fn countMatchingBoundsFacts(function: Function, target: BoundsFact) usize {
    var count: usize = 0;
    for (function.bounds_facts) |fact| {
        if (fact.typed_inst_id.eql(target.typed_inst_id)) count += 1;
    }
    return count;
}

/// The check an index fact describes is `i < len`; a slice fact's is
/// `start <= end <= len`. Used only for the bodies the typed form does not
/// represent; see `validateBoundsFactsForLowering`.
fn boundsFactMatchesInstruction(fact: BoundsFact, instruction: Instruction) bool {
    if (instruction.kind != .cmp_bounds) return false;
    if (!fact.typed_inst_id.isValid() or !fact.typed_inst_id.eql(instruction.typed_inst_id)) return false;
    return switch (fact.kind) {
        .index => std.mem.eql(u8, instruction.detail, "i < len"),
        .slice => std.mem.eql(u8, instruction.detail, "start <= end <= len"),
    };
}

fn countMatchingBoundsInstructions(function: Function, fact: BoundsFact) usize {
    var count: usize = 0;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (boundsFactMatchesInstruction(fact, instruction)) count += 1;
        }
    }
    return count;
}

fn countMatchingBoundsAccessFacts(function: Function, fact: BoundsFact) usize {
    var count: usize = 0;
    for (function.access_facts) |access| switch (access) {
        .index => |index| {
            if (fact.kind == .index and index.index_span_id.eql(fact.typed_span_id)) count += 1;
        },
        .range_slice => |slice| {
            if (fact.kind == .slice and slice.typed_span_id.eql(fact.typed_span_id)) count += 1;
        },
        else => {},
    };
    return count;
}

/// Resolves the sole type authority carried by a float literal fact. A
/// spelling-only identity is deliberately insufficient: it would make the
/// backend recover type semantics from source-shaped data again.
pub fn floatFactTargetType(function: *const Function, fact: FloatFact) ?ValueType {
    const type_index = if (fact.target_type_id.isValid()) fact.target_type_id.index() else return null;
    if (type_index >= function.type_identities.len) return null;
    const target_ty = function.type_identities[type_index].ty orelse return null;
    return switch (target_ty) {
        .float => |name| if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64")) target_ty else null,
        else => null,
    };
}

/// Resolves the sole type authority carried by an integer literal fact. A
/// spelling-only identity is deliberately insufficient: it would make
/// lowering recover type semantics from source-shaped data again.
pub fn integerFactTargetType(function: *const Function, fact: IntegerFact) ?ValueType {
    const type_index = if (fact.target_type_id.isValid()) fact.target_type_id.index() else return null;
    if (type_index >= function.type_identities.len) return null;
    const target_ty = function.type_identities[type_index].ty orelse return null;
    return switch (target_ty) {
        .integer => |name| if (checkedIntBoundsByName(name) != null) target_ty else null,
        else => null,
    };
}

/// A `const_get` fact names the typed obligation its compile-time index
/// belongs to: `ExecutableExpression.const_get_obligation`. One node, one
/// fact, in both directions.
///
/// This obligation carries no payload of its own. A `const_get` is a
/// `builtin_call` node and the index is already part of it, so the agreement
/// the fact used to make with `Instruction.const_index` -- beside a
/// `detail == "const_get"` string test to find the instruction at all -- is
/// made against the node instead, and the string test is gone.
///
/// The instruction walk, including the source cross-check that the four
/// instructions one `const_get` expression emits appear in equal numbers,
/// remains only for a body the typed form does not represent: in a
/// represented body the call-target and target-type halves carry their own
/// typed obligations with their own exactly-one rules.
pub fn validateConstGetFactsForLowering(module: Module) error{InvalidMirConstGetFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        const typed = typedObligationsRepresented(module, function);
        if (typed) {
            for (function.const_get_facts) |fact| {
                if (!fact.typed_inst_id.isValid()) return error.InvalidMirConstGetFacts;
                if (!fact.typed_span_id.isValid() or sourcePointForSpanId(function, fact.typed_span_id) == null) return error.InvalidMirConstGetFacts;
                if (countConstGetFactsSharingIdentity(function, fact) != 1) return error.InvalidMirConstGetFacts;
                const index = mir_model.executableConstGetObligationIndex(body, fact.typed_inst_id) orelse
                    return error.InvalidMirConstGetFacts;
                if (index != fact.index) return error.InvalidMirConstGetFacts;
            }
            for (body.expressions) |expression| {
                if (!expression.const_get_obligation.isValid()) continue;
                if (countConstGetFactsForObligation(function, expression.const_get_obligation) != 1)
                    return error.InvalidMirConstGetFacts;
            }
            continue;
        }
        for (function.blocks) |block| for (block.instructions) |instruction| {
            // The four instructions one `const_get` expression emits (index,
            // call target, base and result target types) are cross-checked by
            // source: they are all stamped with the same span, so a copied
            // expression copies all four together.
            if (callTargetKindForInstruction(instruction) == .const_get) {
                const call_count = countConstGetCallTargetsAtSource(function, instruction.typed_span_id);
                if (countConstGetInstructionsAtSource(function, instruction.typed_span_id) != call_count) return error.InvalidMirConstGetFacts;
                if (countTargetTypeInstructionsAtSource(function, .const_get_base, instruction.typed_span_id) != call_count) return error.InvalidMirConstGetFacts;
                if (countTargetTypeInstructionsAtSource(function, .const_get_result, instruction.typed_span_id) != call_count) return error.InvalidMirConstGetFacts;
            }
            const is_const_get = instruction.kind == .index and std.mem.eql(u8, instruction.detail, "const_get");
            if (!is_const_get) {
                if (instruction.const_index != null) return error.InvalidMirConstGetFacts;
                continue;
            }
            if (countConstGetCallTargetsAtSource(function, instruction.typed_span_id) != countConstGetInstructionsAtSource(function, instruction.typed_span_id)) return error.InvalidMirConstGetFacts;
            if (instruction.const_index == null) return error.InvalidMirConstGetFacts;
            if (countMatchingConstGetFacts(function, instruction) != 1) return error.InvalidMirConstGetFacts;
        };
        for (function.const_get_facts) |fact| {
            if (!fact.typed_inst_id.isValid()) return error.InvalidMirConstGetFacts;
            if (!fact.typed_span_id.isValid() or sourcePointForSpanId(function, fact.typed_span_id) == null) return error.InvalidMirConstGetFacts;
            if (countMatchingConstGetInstructions(function, fact) != 1) return error.InvalidMirConstGetFacts;
            if (countConstGetFactsSharingIdentity(function, fact) != 1) return error.InvalidMirConstGetFacts;
        }
    }
}

fn countConstGetFactsForObligation(function: Function, id: mir_model.InstId) usize {
    var count: usize = 0;
    for (function.const_get_facts) |fact| {
        if (fact.typed_inst_id.eql(id)) count += 1;
    }
    return count;
}

fn countConstGetCallTargetsAtSource(function: Function, span_id: SpanId) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (callTargetKindForInstruction(instruction) == .const_get and instructionMatchesSpanId(function, instruction, span_id)) count += 1;
    };
    return count;
}

fn countConstGetInstructionsAtSource(function: Function, span_id: SpanId) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind == .index and std.mem.eql(u8, instruction.detail, "const_get") and instructionMatchesSpanId(function, instruction, span_id)) count += 1;
    };
    return count;
}

fn countTargetTypeInstructionsAtSource(function: Function, kind: TargetTypeKind, span_id: SpanId) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (targetTypeKindForInstruction(instruction) == kind and instructionMatchesSpanId(function, instruction, span_id)) count += 1;
    };
    return count;
}

/// A fact describes a `const_get` index instruction when it names it by
/// identity and still agrees with it about the constant index and the span.
/// The identity, not the span, is the join key; see
/// `integerFactMatchesInstruction`.
fn constGetFactMatchesInstruction(function: Function, fact: ConstGetFact, instruction: Instruction) bool {
    if (instruction.kind != .index or !std.mem.eql(u8, instruction.detail, "const_get")) return false;
    if (!fact.typed_inst_id.isValid() or !fact.typed_inst_id.eql(instruction.typed_inst_id)) return false;
    const index = instruction.const_index orelse return false;
    return index == fact.index and instructionMatchesSpanId(function, instruction, fact.typed_span_id);
}

fn countMatchingConstGetFacts(function: Function, instruction: Instruction) usize {
    var count: usize = 0;
    for (function.const_get_facts) |fact| {
        if (constGetFactMatchesInstruction(function, fact, instruction)) count += 1;
    }
    return count;
}

fn countMatchingConstGetInstructions(function: Function, fact: ConstGetFact) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (constGetFactMatchesInstruction(function, fact, instruction)) count += 1;
    };
    return count;
}

fn countConstGetFactsSharingIdentity(function: Function, target: ConstGetFact) usize {
    var count: usize = 0;
    for (function.const_get_facts) |fact| {
        if (fact.typed_inst_id.eql(target.typed_inst_id)) count += 1;
    }
    return count;
}

/// A call-target fact names the typed call-target obligation its target
/// realizes: `ExecutableExpression.call_target_obligation` for a call that
/// produces a value, `ExecutableTerminator.call_target_obligation` for a
/// diverging explicit trap, which is neither a statement nor an expression
/// and so had no node to name before.
///
/// One node, one fact, in both directions. The kind travels on the
/// obligation, so a fact retargeted at another `CallTargetKind` still fails;
/// that agreement used to be `std.meta.stringToEnum` over
/// `Instruction.detail`, which is the string classification the typed body
/// exists to replace.
///
/// The walk over `call_target` instructions remains only for a body the typed
/// form does not represent; see `typedObligationsRepresented`.
pub fn validateCallTargetFactsForLowering(module: Module) error{InvalidMirCallTargetFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        const typed = typedObligationsRepresented(module, function);
        if (!typed) {
            for (function.blocks) |block| for (block.instructions) |instruction| {
                if (callTargetKindForInstruction(instruction) == null) continue;
                if (countMatchingCallTargetFacts(function, instruction) != 1) return error.InvalidMirCallTargetFacts;
            };
        }
        for (function.call_target_facts) |fact| {
            if (!callTargetFactTypedIdentityValid(function, fact)) return error.InvalidMirCallTargetFacts;
            if (countMatchingCallTargetFactsForFact(function, fact) != 1) return error.InvalidMirCallTargetFacts;
            if (typed) {
                if (mir_model.executableCallTargetObligationCount(body, fact.typed_inst_id) != 1)
                    return error.InvalidMirCallTargetFacts;
                const obligation = mir_model.executableCallTargetObligation(body, fact.typed_inst_id) orelse
                    return error.InvalidMirCallTargetFacts;
                if (obligation.kind != fact.kind) return error.InvalidMirCallTargetFacts;
            } else if (countMatchingCallTargetInstructions(function, fact) != 1) {
                return error.InvalidMirCallTargetFacts;
            }
        }
        if (!typed) continue;
        for (body.expressions) |expression| {
            const obligation = expression.call_target_obligation orelse continue;
            if (countCallTargetFactsForObligation(function, obligation.id) != 1) return error.InvalidMirCallTargetFacts;
        }
        for (body.terminators) |terminator| {
            const obligation = terminator.call_target_obligation orelse continue;
            if (countCallTargetFactsForObligation(function, obligation.id) != 1) return error.InvalidMirCallTargetFacts;
        }
    }
}

fn countCallTargetFactsForObligation(function: Function, id: mir_model.InstId) usize {
    var count: usize = 0;
    for (function.call_target_facts) |fact| {
        if (fact.typed_inst_id.eql(id)) count += 1;
    }
    return count;
}

/// Bind facts are the identity bridge between a captured local and a later
/// closure value.  They deliberately validate only facts available in MIR;
/// consumers never need to rediscover the capture or target from an AST body.
pub fn validateBindThunkFactsForLowering(module: Module) error{InvalidMirBindThunkFacts}!void {
    for (module.functions) |function| {
        const typed = typedObligationsRepresented(module, function);
        for (function.bind_thunk_facts) |fact| {
            if (!bindThunkFactIdentitiesValid(function, fact)) return error.InvalidMirBindThunkFacts;
            if (countBindThunkFactsSharingIdentity(function, fact) != 1) return error.InvalidMirBindThunkFacts;
            const target = functionByTargetOwnerForBind(module, function, fact.typed_target_fn_symbol_id) orelse return error.InvalidMirBindThunkFacts;
            if (target.param_count != fact.target_param_count or !typeIdMatchesValueType(function, fact.target_return_ty, target.return_ty)) return error.InvalidMirBindThunkFacts;
            if (fact.target_param_count != fact.closure_param_count + 1 or !fact.target_return_ty.eql(fact.closure_return_ty)) return error.InvalidMirBindThunkFacts;
            if (!bindFactHasTargetType(function, fact) or !bindFactHasCallTarget(function, fact) or !bindFactHasCaptureAccess(function, fact)) return error.InvalidMirBindThunkFacts;
            const closure_local = if (typed)
                bindFactHasTypedClosureLocal(function, fact)
            else
                bindFactHasClosureLocal(function, fact);
            if (!closure_local) return error.InvalidMirBindThunkFacts;
        }
    }
}

/// The closure local a bind fact names, found in the typed body.
///
/// `BindThunkFact` names it by `closure_value_id`, and `.local` is a joinable
/// instruction kind -- so this half was never blocked on a missing node, only
/// on a missing *correspondence*: `ExecutableLocalIdentity` carried no
/// `ValueId`, and joining by spelling would have been weaker than the
/// instruction join it replaces. It carries one now.
///
/// A `ValueId` is a name and a `LocalId` is a declaration generation, so a
/// name reused after its scope ends gives several locals one `ValueId`. The
/// disambiguator is the same thing the instruction join used: the closure
/// local is the one whose initializer is the bind expression itself, at
/// `closure_span_id`. Storage type and span are checked exactly as before, so
/// the typed join proves at least as much.
fn bindFactHasTypedClosureLocal(function: Function, fact: BindThunkFact) bool {
    const body = &function.executable_body;
    var count: usize = 0;
    for (body.locals) |local| {
        if (!local.value_id.isValid() or !local.value_id.eql(fact.closure_value_id)) continue;
        if (!local.type_id.eql(fact.closure_ty)) continue;
        if (!typedLocalInitializedAt(body, local.id, fact.closure_span_id)) continue;
        count += 1;
    }
    return count == 1;
}

/// Is `local` initialized by an expression at `span_id`?
fn typedLocalInitializedAt(body: *const mir_model.ExecutableBody, local: mir_model.LocalId, span_id: SpanId) bool {
    for (body.statements) |statement| switch (statement.operation) {
        .local_init => |init| {
            if (!init.local.eql(local)) continue;
            const value = init.value orelse continue;
            if (value.index() >= body.expressions.len) continue;
            if (body.expressions[value.index()].span_id.eql(span_id)) return true;
        },
        else => {},
    };
    return false;
}

/// One bind instruction, one bind fact; counted on the identity.
fn countBindThunkFactsSharingIdentity(function: Function, target: BindThunkFact) usize {
    var count: usize = 0;
    for (function.bind_thunk_facts) |fact| {
        if (fact.typed_inst_id.eql(target.typed_inst_id)) count += 1;
    }
    return count;
}

fn bindThunkFactIdentitiesValid(function: Function, fact: BindThunkFact) bool {
    if (!fact.typed_inst_id.isValid() or !fact.typed_target_type_inst_id.isValid()) return false;
    if (!fact.typed_target_fn_symbol_id.isValid() or !fact.target_span_id.isValid() or !fact.target_return_ty.isValid() or !fact.capture_value_id.isValid() or !fact.capture_span_id.isValid() or !fact.capture_operand_span_id.isValid() or !fact.capture_ty.isValid() or !fact.target_capture_ty.isValid() or !fact.closure_value_id.isValid() or !fact.closure_span_id.isValid() or !fact.closure_ty.isValid() or !fact.closure_return_ty.isValid()) return false;
    if (targetOwnerSpelling(function, fact.typed_target_fn_symbol_id) == null) return false;
    if (!spanIdValid(function, fact.closure_span_id) or !spanIdValid(function, fact.target_span_id) or !spanIdValid(function, fact.capture_span_id) or !spanIdValid(function, fact.capture_operand_span_id)) return false;
    if (!valueIdValid(function, fact.capture_value_id) or !valueIdValid(function, fact.closure_value_id)) return false;
    if (!typeIdValid(function, fact.target_return_ty) or !typeIdValid(function, fact.capture_ty) or !typeIdValid(function, fact.target_capture_ty) or !typeIdValid(function, fact.closure_ty) or !typeIdValid(function, fact.closure_return_ty)) return false;
    const capture_ty = typeForId(function, fact.capture_ty) orelse return false;
    const target_capture_ty = typeForId(function, fact.target_capture_ty) orelse return false;
    if (sameValueType(capture_ty, target_capture_ty)) return true;
    return switch (capture_ty) {
        .pointer => |capture| switch (target_capture_ty) {
            .pointer => |target| capture.kind == target.kind and
                std.mem.eql(u8, capture.child, target.child) and
                capture.mutability == .mut and
                (target.mutability == .none or target.mutability == .@"const"),
            else => false,
        },
        else => false,
    };
}

/// The closure's `target_type bind` fact, found by the instruction identity
/// the bind fact carries; it must still agree on the closure span and type.
fn bindFactHasTargetType(function: Function, fact: BindThunkFact) bool {
    var count: usize = 0;
    for (function.target_type_facts) |target| {
        if (!target.typed_inst_id.eql(fact.typed_target_type_inst_id)) continue;
        if (target.kind != .bind or !target.typed_span_id.eql(fact.closure_span_id)) return false;
        if (!target.typed_result_ty.eql(fact.closure_ty)) return false;
        count += 1;
    }
    return count == 1;
}

/// The `call_target bind` fact for the bind fact's own instruction; it must
/// still agree on the closure span and type.
fn bindFactHasCallTarget(function: Function, fact: BindThunkFact) bool {
    var count: usize = 0;
    for (function.call_target_facts) |target| {
        if (!target.typed_inst_id.eql(fact.typed_inst_id)) continue;
        if (target.kind != .bind or !target.typed_span_id.eql(fact.closure_span_id)) return false;
        if (!sameValueType(target.result_ty, typeForId(function, fact.closure_ty) orelse return false)) return false;
        count += 1;
    }
    return count == 1;
}

fn bindFactHasCaptureAccess(function: Function, fact: BindThunkFact) bool {
    var access_count: usize = 0;
    for (function.access_facts) |access| switch (access) {
        .address_of => |address| {
            if (!address.typed_span_id.eql(fact.capture_span_id)) continue;
            if (!address.operand_span_id.eql(fact.capture_operand_span_id) or !sameValueType(address.result_ty, typeForId(function, fact.capture_ty) orelse return false)) return false;
            access_count += 1;
        },
        else => {},
    };
    if (access_count != 1) return false;
    const operand = instructionAtSpan(function, fact.capture_operand_span_id) orelse return false;
    return operand.kind == .expr and operand.typed_value_id != null and operand.typed_value_id.?.eql(fact.capture_value_id);
}

/// Used only for the bodies the typed form does not represent; see
/// `bindFactHasTypedClosureLocal`.
fn bindFactHasClosureLocal(function: Function, fact: BindThunkFact) bool {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.kind != .local or instruction.typed_value_id == null or !instruction.typed_value_id.?.eql(fact.closure_value_id)) continue;
        if (!instruction.typed_value_operand_span_id.eql(fact.closure_span_id) or !instruction.typed_result_ty.eql(fact.closure_ty)) return false;
        count += 1;
    };
    return count == 1;
}

fn functionByTargetOwnerForBind(module: Module, owner_function: Function, target_owner_id: SymbolId) ?Function {
    const name = targetOwnerSpelling(owner_function, target_owner_id) orelse return null;
    var found: ?Function = null;
    for (module.functions) |function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (found != null) return null;
        found = function;
    }
    return found;
}

fn spanIdValid(function: Function, id: SpanId) bool {
    return id.isValid() and id.index() < function.span_identities.len and function.span_identities[id.index()].id.eql(id);
}
fn spanIdMatchesSource(function: Function, id: SpanId, source: SourcePoint) bool {
    if (!spanIdValid(function, id)) return false;
    const actual = function.span_identities[id.index()].source;
    return actual.line == source.line and actual.column == source.column and actual.offset == source.offset and actual.len == source.len and actual.file_id == source.file_id;
}
fn valueIdValid(function: Function, id: ValueId) bool {
    return id.isValid() and id.index() < function.value_identities.len and function.value_identities[id.index()].id.eql(id);
}
pub fn valueSpelling(function: Function, id: ValueId) ?[]const u8 {
    if (!id.isValid() or !valueIdValid(function, id)) return null;
    return function.value_identities[id.index()].spelling;
}
fn typeIdValid(function: Function, id: TypeId) bool {
    return id.isValid() and id.index() < function.type_identities.len and function.type_identities[id.index()].id.eql(id);
}
fn typeForId(function: Function, id: TypeId) ?ValueType {
    if (!typeIdValid(function, id)) return null;
    const identity = function.type_identities[id.index()];
    if (identity.ty) |ty| return ty;
    const name = identity.spelling;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.typed_result_ty.eql(id) and std.mem.eql(u8, instruction.result_ty.name(), name)) return instruction.result_ty;
    };
    return null;
}
fn typeIdMatchesValueType(function: Function, id: TypeId, ty: ValueType) bool {
    return typeIdValid(function, id) and function.type_identities[id.index()].matches(ty);
}
pub fn sameValueType(left: ValueType, right: ValueType) bool {
    return ValueType.eql(left, right);
}


pub const LoweringAdmissionError = error{
    InvalidMirInstructionIdentities,
    InvalidMirRepresentationFacts,
    InvalidMirIntegerFacts,
    InvalidMirConstGetFacts,
    InvalidMirCallTargetFacts,
    InvalidMirBindThunkFacts,
    InvalidMirDropGlueFacts,
    InvalidMirTypeOwnershipFacts,
    InvalidMirTypeAliasFacts,
    InvalidMirEnumFacts,
    InvalidMirPackedBitsFacts,
    InvalidMirOverlayUnionFacts,
    InvalidMirTaggedUnionFacts,
    InvalidMirStructFacts,
    InvalidMirGlobalInitializerFacts,
    InvalidMirCallableEmissionFacts,
    InvalidMirSourceMapDeclarationFacts,
    InvalidMirOwnershipEvents,
    InvalidMirTargetTypeFacts,
    InvalidMirFloatFacts,
    InvalidMirRangeFacts,
    InvalidMirBoundsFacts,
    InvalidMirElidedBounds,
    InvalidMirExecutableLocalFacts,
    InvalidMirExecutableTypeFacts,
    InvalidMirExecutableBodyJoin,
    StaleMirTargetTypeFacts,
    UnknownMirLoweringType,
    InvalidMirExecutableBody,
    /// The ownership-event check solves a per-block dataflow over the CFG and
    /// needs scratch storage proportional to the block count.
    OutOfMemory,
};

/// Backends consume this single admission seam before lowering.  Conservative
/// facts such as pointer provenance may still be `unknown`, but codegen-owned
/// type facts must not use the `.unknown` ValueType placeholder.
pub fn validateLoweringAdmission(module: Module) LoweringAdmissionError!void {
    // Exact call identities are inputs to canonical CFG projection (notably
    // explicit trap reasons), so reject missing/stale identities before the
    // executable-body verifier checks their projection.
    try validateCallTargetFactsForLowering(module);
    try validateInstructionSpanIdentitiesForLowering(module);
    for (module.functions) |*function| mir_executable_body.verify(function) catch return error.InvalidMirExecutableBody;
    try validateExecutableRefusalsNamed(module);
    try validateExecutableBodyJoinForLowering(module);
    try validateExecutableLocalFactsForLowering(module);
    try validateExecutableTypeFactsForLowering(module);
    try validateRepresentationFactsForLowering(module);
    try validateIntegerFactsForLowering(module);
    try validateFloatFactsForLowering(module);
    try validateRangeFactsForLowering(module);
    try validateBoundsFactsForLowering(module);
    try validateElidedBoundsForLowering(module);
    try validateConstGetFactsForLowering(module);
    try validateBindThunkFactsForLowering(module);
    try validateDropGlueFactsForLowering(module);
    try validateTypeOwnershipFactsForLowering(module);
    try validateTypeAliasFactsForLowering(module);
    try validateEnumFactsForLowering(module);
    try validatePackedBitsFactsForLowering(module);
    try validateOverlayUnionFactsForLowering(module);
    try validateTaggedUnionFactsForLowering(module);
    try validateStructFactsForLowering(module);
    try validateGlobalInitializerFactsForLowering(module);
    try validateCallableEmissionFactsForLowering(module);
    try validateSourceMapDeclarationFactsForLowering(module);
    try validateOwnershipEventsForLowering(module);
    try validateTargetTypeFactsForLowering(module);
    try validateKnownFactTypesForLowering(module);
}

/// The executable-body verifier proves LocalId/type/span coherence. This
/// module-level check additionally validates a present source-shape key
/// against the one authoritative SignatureTypeTable. Pattern/legacy locals
/// may intentionally omit that optional shape; their ValueType/TypeId record
/// remains sufficient for mechanical storage rendering.
fn executableBodyIsEmpty(body: *const mir_model.ExecutableBody) bool {
    return body.parameters.len == 0 and body.locals.len == 0 and body.symbols.len == 0 and
        body.aggregate_types.len == 0 and body.enum_types.len == 0 and body.result_types.len == 0 and
        body.tagged_union_types.len == 0 and body.expressions.len == 0 and body.places.len == 0 and
        body.statements.len == 0 and body.terminators.len == 0;
}

/// The legacy instruction stream and `ExecutableBody` are one body.
///
/// `ExecutableStatement.id` and `ExprId` are array positions, so on their own
/// they cannot say which instruction a typed node replaces. The join is
/// `ExecutableStatement.inst_id` / `ExecutableExpression.inst_id`, and this is
/// what makes it usable as an identity rather than a hint:
///
///   1. a recorded `inst_id` names an instruction that exists in this
///      function, so a consumer that follows it cannot land on nothing;
///   2. no two typed nodes name the same instruction, so
///      "the node that realizes this instruction" is single-valued;
///   3. in a complete body every instruction the model declares joinable
///      (`instructionJoinsExecutableBody`) is named by exactly one node, so
///      the function is total on the declared domain.
///
/// An incomplete body is exempt from (3) only: the builder stopped partway,
/// so there is nothing to be total against. (1) and (2) still hold there.
fn validateExecutableBodyJoinForLowering(module: Module) error{InvalidMirExecutableBodyJoin}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        for (body.statements) |statement| {
            if (!statement.inst_id.isValid()) continue;
            if (!functionHasInstructionId(function, statement.inst_id)) return error.InvalidMirExecutableBodyJoin;
            if (countExecutableNodesForInstruction(body, statement.inst_id) != 1) return error.InvalidMirExecutableBodyJoin;
        }
        for (body.expressions) |expression| {
            if (!expression.inst_id.isValid()) continue;
            if (!functionHasInstructionId(function, expression.inst_id)) return error.InvalidMirExecutableBodyJoin;
            if (countExecutableNodesForInstruction(body, expression.inst_id) != 1) return error.InvalidMirExecutableBodyJoin;
        }
        // A body that was never built as a statement sequence has no typed
        // form to be total against: an extern declaration has no body at all,
        // and a global initializer's pseudo-function carries only the
        // instruction stream for its initializer expression.
        if (!body.isComplete() or function.is_extern or executableBodyIsEmpty(body)) continue;
        if (functionIsGlobalInitializer(module, function)) continue;
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (!mir_model.instructionJoinsExecutableBody(instruction)) continue;
                if (countExecutableNodesForInstruction(body, instruction.typed_inst_id) != 1) return error.InvalidMirExecutableBodyJoin;
            }
        }
    }
}

/// A global's initializer is compiled as a pseudo-callable so its expression
/// gets the same checks a function body's does. It is not a statement
/// sequence, and `CheckedProgram` is where that distinction is recorded.
fn functionIsGlobalInitializer(module: Module, function: Function) bool {
    if (!function.typed_symbol_id.isValid()) return false;
    for (module.checked_callables) |checked| {
        if (checked.kind != .global_initializer) continue;
        if (checked.symbol_id.eql(function.typed_symbol_id)) return true;
    }
    return false;
}

fn functionHasInstructionId(function: Function, inst_id: mir_model.InstId) bool {
    if (!inst_id.isValid()) return false;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.typed_inst_id.eql(inst_id)) return true;
        }
    }
    return false;
}

fn countExecutableNodesForInstruction(body: *const mir_model.ExecutableBody, inst_id: mir_model.InstId) usize {
    if (!inst_id.isValid()) return 0;
    var count: usize = 0;
    for (body.statements) |statement| {
        if (statement.inst_id.eql(inst_id)) count += 1;
    }
    for (body.expressions) |expression| {
        if (expression.inst_id.eql(inst_id)) count += 1;
    }
    return count;
}

/// A refused executable body says why it was refused.
///
/// An unexplained refusal reaches a user as "the C backend does not yet
/// support this construct" with no construct named, which is the one shape of
/// report that cannot be acted on. The builder names every refusal; this is
/// the admission boundary that keeps it that way.
fn validateExecutableRefusalsNamed(module: Module) error{InvalidMirExecutableBody}!void {
    for (module.functions) |function| {
        if (function.executable_body.complete) continue;
        // An extern declaration has no body to refuse, and a body with no
        // content at all was never built rather than rejected -- the
        // executable-body verifier returns early on exactly that shape.
        if (function.is_extern or executableBodyIsEmpty(&function.executable_body)) continue;
        if (function.executable_body.incomplete_reason == .none) return error.InvalidMirExecutableBody;
    }
}

fn validateExecutableLocalFactsForLowering(module: Module) error{InvalidMirExecutableLocalFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        if (!body.complete) continue;
        for (body.locals) |local| switch (local.kind) {
            .parameter, .local => if (local.signature_type_id.isValid() and !module.signature_types.contains(local.signature_type_id))
                return error.InvalidMirExecutableLocalFacts,
            .synthetic => if (local.signature_type_id.isValid()) return error.InvalidMirExecutableLocalFacts,
        };
    }
}

/// Validate the optional source-shape IDs carried by executable aggregate
/// layouts and the required Result declaration shape. TypeId/ValueType
/// agreement is checked by `mir_executable_body`; this joins the remaining
/// backend-facing shape identities to the module-owned signature table.
fn validateExecutableTypeFactsForLowering(module: Module) error{InvalidMirExecutableTypeFacts}!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        if (!body.complete) continue;
        for (body.aggregate_types) |aggregate| {
            for (aggregate.field_signature_type_ids[0..aggregate.field_count]) |id|
                if (id.isValid() and !module.signature_types.contains(id))
                    return error.InvalidMirExecutableTypeFacts;
        }
        for (body.result_types) |result| {
            if (!result.signature_type_id.isValid() or !result.ok_signature_type_id.isValid() or
                !result.err_signature_type_id.isValid() or !module.signature_types.contains(result.signature_type_id) or
                !module.signature_types.contains(result.ok_signature_type_id) or
                !module.signature_types.contains(result.err_signature_type_id))
                return error.InvalidMirExecutableTypeFacts;
        }
        for (body.parameters) |parameter| {
            if (parameter.atomic_payload_type_id.isValid()) {
                if (!parameter.atomic_payload_signature_type_id.isValid() or
                    !module.signature_types.contains(parameter.atomic_payload_signature_type_id))
                    return error.InvalidMirExecutableTypeFacts;
            } else if (parameter.atomic_payload_signature_type_id.isValid()) {
                return error.InvalidMirExecutableTypeFacts;
            }
            if (parameter.dma_payload_type_id.isValid()) {
                if (!parameter.dma_payload_signature_type_id.isValid() or
                    !module.signature_types.contains(parameter.dma_payload_signature_type_id))
                    return error.InvalidMirExecutableTypeFacts;
            } else if (parameter.dma_payload_signature_type_id.isValid()) {
                return error.InvalidMirExecutableTypeFacts;
            }
        }
    }
}

/// Optimizer elision records are semantic SpanIds, not source-coordinate
/// projections. Each must resolve through the owning function and appear once.
pub fn validateElidedBoundsForLowering(module: Module) error{InvalidMirElidedBounds}!void {
    for (module.functions) |function| {
        for (function.elided_bounds, 0..) |span_id, index| {
            if (!spanIdValid(function, span_id)) return error.InvalidMirElidedBounds;
            for (function.elided_bounds[0..index]) |prior| {
                if (prior.eql(span_id)) return error.InvalidMirElidedBounds;
            }
        }
    }
}

fn validateInstructionSpanIdentitiesForLowering(module: Module) error{InvalidMirInstructionIdentities}!void {
    for (module.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (!instruction.typed_span_id.isValid() or instructionSourcePoint(function, instruction) == null)
            return error.InvalidMirInstructionIdentities;
    };
}

/// Every non-extern global definition must have exactly one admitted
/// initializer plan. Extern declarations deliberately have no storage plan.
/// This is the fail-closed boundary now that codegen retains no AST global
/// initializer fallback.
fn validateGlobalInitializerFactsForLowering(module: Module) error{InvalidMirGlobalInitializerFacts}!void {
    for (module.checked_globals) |global| {
        const fact = module.checkedGlobalInitializer(global);
        if (global.is_extern) {
            if (global.has_initializer_plan or fact != null) return error.InvalidMirGlobalInitializerFacts;
            continue;
        }
        if (!global.has_initializer_plan or fact == null) return error.InvalidMirGlobalInitializerFacts;
    }
}

/// `emit-map` receives these rows only through `VerifiedProgram`, so reject
/// malformed presentation metadata at the same admission boundary as the
/// executable facts.  The rows are intentionally syntax-free, but their
/// identity and source coordinates must still agree with the module facts.
fn validateSourceMapDeclarationFactsForLowering(module: Module) error{InvalidMirSourceMapDeclarationFacts}!void {
    for (module.source_map_declarations, 0..) |fact, index| {
        if (!moduleSymbolIdentityValid(module, fact.symbol_id)) return error.InvalidMirSourceMapDeclarationFacts;
        if (!sourceMapSourcePointValid(module, fact.source_id, fact.declaration_source))
            return error.InvalidMirSourceMapDeclarationFacts;
        if (fact.initializer_source) |source| {
            if (fact.kind != .global or !sourceMapSourcePointValid(module, fact.source_id, source))
                return error.InvalidMirSourceMapDeclarationFacts;
        }
        if (fact.backend_name) |name| {
            if (name.len == 0 or fact.kind != .function) return error.InvalidMirSourceMapDeclarationFacts;
        }
        for (module.source_map_declarations[0..index]) |prior| {
            if (prior.symbol_id.eql(fact.symbol_id)) return error.InvalidMirSourceMapDeclarationFacts;
        }
        if (!sourceMapDeclarationMatchesModule(module, fact)) return error.InvalidMirSourceMapDeclarationFacts;
    }
}

fn sourceMapSourcePointValid(module: Module, source_id: SourceId, source: SourcePoint) bool {
    if (source.line == 0 or source.column == 0 or source.len == 0) return false;
    if (!source_id.isValid()) return true;
    if (source_id.index() >= module.source_identities.len) return false;
    const identity = module.source_identities[source_id.index()];
    return identity.id.eql(source_id) and source.file_id == identity.file_id;
}

fn sourceMapDeclarationMatchesModule(module: Module, fact: SourceMapDeclarationFact) bool {
    const identity = module.symbol_identities[fact.symbol_id.index()];
    const source_matches = switch (fact.kind) {
        .global => for (module.checked_globals) |global| {
            if (!global.symbol_id.eql(fact.symbol_id)) continue;
            break global.source_id.eql(fact.source_id) and global.is_const == fact.is_const and global.exported == fact.exported;
        } else false,
        .function, .extern_fn => for (module.checked_callables) |callable| {
            if (!callable.symbol_id.eql(fact.symbol_id)) continue;
            const expected_kind: CallableKind = if (fact.kind == .function) .function else .extern_function;
            break callable.kind == expected_kind and callable.source_id.eql(fact.source_id);
        } else false,
        .type_alias => sourceMapTypeFactMatches(module.type_aliases, fact.symbol_id, fact.source_id),
        .struct_ => sourceMapTypeFactMatches(module.structs, fact.symbol_id, fact.source_id),
        .enum_ => sourceMapTypeFactMatches(module.enums, fact.symbol_id, fact.source_id),
        .union_ => sourceMapTypeFactMatches(module.tagged_unions, fact.symbol_id, fact.source_id),
        .packed_bits => sourceMapTypeFactMatches(module.packed_bits, fact.symbol_id, fact.source_id),
        .overlay_union => sourceMapTypeFactMatches(module.overlay_unions, fact.symbol_id, fact.source_id),
        // Opaque declarations have no layout/ABI fact yet, but still require
        // an admitted module symbol and a coherent source location.
        .@"opaque" => identity.kind == .type_,
    };
    const expected_identity_kind: @TypeOf(identity.kind) = switch (fact.kind) {
        .global => .global,
        .function, .extern_fn => .function,
        .type_alias, .struct_, .enum_, .union_, .packed_bits, .overlay_union, .@"opaque" => .type_,
    };
    return identity.id.eql(fact.symbol_id) and identity.kind == expected_identity_kind and source_matches;
}

fn sourceMapTypeFactMatches(facts: anytype, symbol_id: SymbolId, source_id: SourceId) bool {
    for (facts) |fact| if (fact.symbol_id.eql(symbol_id)) return fact.source_id.eql(source_id);
    return false;
}

test "source-map declaration facts are module-owned and admitted" {
    const test_support = @import("test_support.zig");
    const source =
        \\struct Header { value: u32, }
        \\const COUNT: u32 = 1;
        \\extern fn sink(value: u32) -> void;
        \\#[backend_name("mc_entry")]
        \\export fn entry() -> u32 { return COUNT; }
    ;
    var parsed = try test_support.parseModule("source_map_declaration_facts.mc", source);
    defer parsed.deinit();
    var module = try buildFromDecls(std.testing.allocator, parsed.decls());
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 4), module.source_map_declarations.len);
    try std.testing.expectEqual(SourceMapDeclarationKind.struct_, module.source_map_declarations[0].kind);
    try std.testing.expectEqual(SourceMapDeclarationKind.global, module.source_map_declarations[1].kind);
    try std.testing.expectEqual(SourceMapDeclarationKind.extern_fn, module.source_map_declarations[2].kind);
    try std.testing.expectEqual(SourceMapDeclarationKind.function, module.source_map_declarations[3].kind);
    try std.testing.expectEqualStrings("mc_entry", module.source_map_declarations[3].backend_name.?);
    try validateLoweringAdmission(module);
}

test "lowering admission rejects malformed source-map declaration facts" {
    const test_support = @import("test_support.zig");
    const source =
        \\const COUNT: u32 = 1;
        \\fn entry() -> u32 { return COUNT; }
    ;
    var parsed = try test_support.parseModule("malformed_source_map_declaration_facts.mc", source);
    defer parsed.deinit();
    var module = try buildFromDecls(std.testing.allocator, parsed.decls());
    defer module.deinit();
    try validateLoweringAdmission(module);

    const saved_source = module.source_map_declarations[0].declaration_source;
    module.source_map_declarations[0].declaration_source.line = 0;
    try std.testing.expectError(error.InvalidMirSourceMapDeclarationFacts, validateLoweringAdmission(module));
    module.source_map_declarations[0].declaration_source = saved_source;

    const saved_symbol = module.source_map_declarations[1].symbol_id;
    module.source_map_declarations[1].symbol_id = module.source_map_declarations[0].symbol_id;
    try std.testing.expectError(error.InvalidMirSourceMapDeclarationFacts, validateLoweringAdmission(module));
    module.source_map_declarations[1].symbol_id = saved_symbol;

    module.source_map_declarations[0].source_id = SourceId.fromIndex(0);
    try std.testing.expectError(error.InvalidMirSourceMapDeclarationFacts, validateLoweringAdmission(module));
}

fn validateTypeAliasFactsForLowering(module: Module) error{InvalidMirTypeAliasFacts}!void {
    for (module.type_aliases, 0..) |fact, index| {
        if (!fact.symbol_id.isValid() or fact.symbol_id.index() >= module.symbol_identities.len or
            !fact.target_type_id.isValid() or !module.signature_types.contains(fact.target_type_id))
            return error.InvalidMirTypeAliasFacts;
        const identity = module.symbol_identities[fact.symbol_id.index()];
        if (!identity.id.eql(fact.symbol_id) or identity.kind != .type_) return error.InvalidMirTypeAliasFacts;
        if (fact.source_id.isValid() and (fact.source_id.index() >= module.source_identities.len or
            !module.source_identities[fact.source_id.index()].id.eql(fact.source_id)))
            return error.InvalidMirTypeAliasFacts;
        for (module.type_aliases[0..index]) |prior| {
            if (prior.symbol_id.eql(fact.symbol_id)) return error.InvalidMirTypeAliasFacts;
        }
    }
}

fn validateEnumFactsForLowering(module: Module) error{InvalidMirEnumFacts}!void {
    for (module.enums, 0..) |enum_fact, index| {
        if (!enum_fact.symbol_id.isValid() or enum_fact.symbol_id.index() >= module.symbol_identities.len or
            mir_model.ExecutableCastKind.integerInfo(enum_fact.repr_ty) == null or
            !enum_fact.repr_type_id.isValid() or !module.signature_types.contains(enum_fact.repr_type_id) or
            !enumFactReprMatchesSignature(module, enum_fact))
            return error.InvalidMirEnumFacts;
        const identity = module.symbol_identities[enum_fact.symbol_id.index()];
        if (!identity.id.eql(enum_fact.symbol_id) or identity.kind != .type_) return error.InvalidMirEnumFacts;
        if (enum_fact.source_id.isValid() and (enum_fact.source_id.index() >= module.source_identities.len or
            !module.source_identities[enum_fact.source_id.index()].id.eql(enum_fact.source_id)))
            return error.InvalidMirEnumFacts;
        for (enum_fact.cases, 0..) |case, case_index| {
            if (case.spelling.len == 0 or !enumCaseFitsRepr(case, enum_fact.repr_ty)) return error.InvalidMirEnumFacts;
            for (enum_fact.cases[0..case_index]) |prior| {
                if (std.mem.eql(u8, prior.spelling, case.spelling)) return error.InvalidMirEnumFacts;
                if (prior.negative == case.negative and prior.magnitude == case.magnitude) return error.InvalidMirEnumFacts;
            }
        }
        for (module.enums[0..index]) |prior| {
            if (prior.symbol_id.eql(enum_fact.symbol_id)) return error.InvalidMirEnumFacts;
        }
        for (module.type_aliases) |alias| {
            if (alias.symbol_id.eql(enum_fact.symbol_id)) return error.InvalidMirEnumFacts;
        }
    }
}

fn validatePackedBitsFactsForLowering(module: Module) error{InvalidMirPackedBitsFacts}!void {
    for (module.packed_bits, 0..) |fact, index| {
        const info = mir_model.ExecutableCastKind.integerInfo(fact.repr_ty) orelse return error.InvalidMirPackedBitsFacts;
        if (!fact.symbol_id.isValid() or fact.symbol_id.index() >= module.symbol_identities.len or
            !fact.repr_type_id.isValid() or !module.signature_types.contains(fact.repr_type_id) or
            !packedBitsFactReprMatchesSignature(module, fact) or fact.fields.len > info.bits)
            return error.InvalidMirPackedBitsFacts;
        const identity = module.symbol_identities[fact.symbol_id.index()];
        if (!identity.id.eql(fact.symbol_id) or identity.kind != .type_) return error.InvalidMirPackedBitsFacts;
        if (fact.source_id.isValid() and (fact.source_id.index() >= module.source_identities.len or
            !module.source_identities[fact.source_id.index()].id.eql(fact.source_id)))
            return error.InvalidMirPackedBitsFacts;
        for (fact.fields, 0..) |field, field_index| {
            if (field.spelling.len == 0) return error.InvalidMirPackedBitsFacts;
            for (fact.fields[0..field_index]) |prior| if (std.mem.eql(u8, prior.spelling, field.spelling)) return error.InvalidMirPackedBitsFacts;
        }
        for (module.packed_bits[0..index]) |prior| if (prior.symbol_id.eql(fact.symbol_id)) return error.InvalidMirPackedBitsFacts;
        for (module.type_aliases) |alias| if (alias.symbol_id.eql(fact.symbol_id)) return error.InvalidMirPackedBitsFacts;
        for (module.enums) |enum_fact| if (enum_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirPackedBitsFacts;
    }
}

fn validateOverlayUnionFactsForLowering(module: Module) error{InvalidMirOverlayUnionFacts}!void {
    for (module.overlay_unions, 0..) |fact, index| {
        if (!fact.symbol_id.isValid() or fact.symbol_id.index() >= module.symbol_identities.len or
            fact.storage_size == 0 or fact.storage_alignment == 0)
            return error.InvalidMirOverlayUnionFacts;
        const identity = module.symbol_identities[fact.symbol_id.index()];
        if (!identity.id.eql(fact.symbol_id) or identity.kind != .type_) return error.InvalidMirOverlayUnionFacts;
        if (fact.source_id.isValid() and (fact.source_id.index() >= module.source_identities.len or
            !module.source_identities[fact.source_id.index()].id.eql(fact.source_id)))
            return error.InvalidMirOverlayUnionFacts;
        var max_size: usize = 1;
        var max_alignment: usize = 1;
        for (fact.fields, 0..) |field, field_index| {
            if (field.spelling.len == 0 or !field.type_id.isValid() or !module.signature_types.contains(field.type_id) or
                field.offset != 0 or field.size == 0 or field.alignment == 0)
                return error.InvalidMirOverlayUnionFacts;
            if (field.byte_array_length) |length| if (length == 0 or field.size != length) return error.InvalidMirOverlayUnionFacts;
            if (field.array_element_size) |element_size| if (element_size == 0 or field.size % element_size != 0) return error.InvalidMirOverlayUnionFacts;
            for (fact.fields[0..field_index]) |prior| if (std.mem.eql(u8, prior.spelling, field.spelling)) return error.InvalidMirOverlayUnionFacts;
            max_size = @max(max_size, field.size);
            max_alignment = @max(max_alignment, field.alignment);
        }
        if (fact.storage_alignment != max_alignment or fact.storage_size != (alignOverlayStorage(max_size, max_alignment) orelse return error.InvalidMirOverlayUnionFacts))
            return error.InvalidMirOverlayUnionFacts;
        for (module.overlay_unions[0..index]) |prior| if (prior.symbol_id.eql(fact.symbol_id)) return error.InvalidMirOverlayUnionFacts;
        for (module.type_aliases) |alias| if (alias.symbol_id.eql(fact.symbol_id)) return error.InvalidMirOverlayUnionFacts;
        for (module.enums) |enum_fact| if (enum_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirOverlayUnionFacts;
        for (module.packed_bits) |packed_bits_fact| if (packed_bits_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirOverlayUnionFacts;
    }
}

fn validateTaggedUnionFactsForLowering(module: Module) error{InvalidMirTaggedUnionFacts}!void {
    for (module.tagged_unions, 0..) |fact, index| {
        const layout = fact.layout;
        if (!fact.symbol_id.isValid() or fact.symbol_id.index() >= module.symbol_identities.len or
            layout.size == 0 or layout.alignment < 4 or layout.payload_size == 0 or
            layout.payload_alignment == 0 or layout.storage_count == 0 or
            (layout.payload_field_index != 1 and layout.payload_field_index != 2))
            return error.InvalidMirTaggedUnionFacts;
        const identity = module.symbol_identities[fact.symbol_id.index()];
        if (!identity.id.eql(fact.symbol_id) or identity.kind != .type_) return error.InvalidMirTaggedUnionFacts;
        if (fact.source_id.isValid() and (fact.source_id.index() >= module.source_identities.len or
            !module.source_identities[fact.source_id.index()].id.eql(fact.source_id)))
            return error.InvalidMirTaggedUnionFacts;
        for (fact.cases, 0..) |case, case_index| {
            if (case.spelling.len == 0) return error.InvalidMirTaggedUnionFacts;
            if (case.payload_type_id) |payload_type_id| {
                if (!payload_type_id.isValid() or !module.signature_types.contains(payload_type_id))
                    return error.InvalidMirTaggedUnionFacts;
            }
            for (fact.cases[0..case_index]) |prior| if (std.mem.eql(u8, prior.spelling, case.spelling)) return error.InvalidMirTaggedUnionFacts;
        }
        for (module.tagged_unions[0..index]) |prior| if (prior.symbol_id.eql(fact.symbol_id)) return error.InvalidMirTaggedUnionFacts;
        for (module.type_aliases) |alias| if (alias.symbol_id.eql(fact.symbol_id)) return error.InvalidMirTaggedUnionFacts;
        for (module.enums) |enum_fact| if (enum_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirTaggedUnionFacts;
        for (module.packed_bits) |packed_bits_fact| if (packed_bits_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirTaggedUnionFacts;
        for (module.overlay_unions) |overlay_union_fact| if (overlay_union_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirTaggedUnionFacts;
    }
}

fn validateStructFactsForLowering(module: Module) error{InvalidMirStructFacts}!void {
    for (module.structs, 0..) |fact, index| {
        if (!fact.symbol_id.isValid() or fact.symbol_id.index() >= module.symbol_identities.len or
            (fact.is_c_union and (fact.storage_size == null or fact.storage_alignment == null)))
            return error.InvalidMirStructFacts;
        const identity = module.symbol_identities[fact.symbol_id.index()];
        if (!identity.id.eql(fact.symbol_id) or identity.kind != .type_) return error.InvalidMirStructFacts;
        if (fact.source_id.isValid() and (fact.source_id.index() >= module.source_identities.len or
            !module.source_identities[fact.source_id.index()].id.eql(fact.source_id)))
            return error.InvalidMirStructFacts;
        for (fact.type_params, 0..) |param, param_index| {
            if (param.len == 0) return error.InvalidMirStructFacts;
            for (fact.type_params[0..param_index]) |prior| if (std.mem.eql(u8, prior, param)) return error.InvalidMirStructFacts;
        }
        for (fact.fields, 0..) |field, field_index| {
            if (field.spelling.len == 0 or !field.type_id.isValid() or !module.signature_types.contains(field.type_id))
                return error.InvalidMirStructFacts;
            if (field.offset) |offset| if (fact.storage_size) |storage_size| if (offset > storage_size) return error.InvalidMirStructFacts;
            if (field.size) |size| if (size == 0) return error.InvalidMirStructFacts;
            if (field.alignment) |alignment| if (alignment == 0) return error.InvalidMirStructFacts;
            if (field.offset) |offset| if (field.size) |size| if (fact.storage_size) |storage_size| if (size > storage_size - offset) return error.InvalidMirStructFacts;
            if (field.explicit_offset) |explicit_offset| if (field.offset) |offset| if (!fact.is_c_union and explicit_offset != offset) return error.InvalidMirStructFacts;
            if (fact.is_c_union and field.offset != null and field.offset.? != 0) return error.InvalidMirStructFacts;
            for (fact.fields[0..field_index]) |prior| if (std.mem.eql(u8, prior.spelling, field.spelling)) return error.InvalidMirStructFacts;
        }
        for (module.structs[0..index]) |prior| if (prior.symbol_id.eql(fact.symbol_id)) return error.InvalidMirStructFacts;
        for (module.type_aliases) |alias| if (alias.symbol_id.eql(fact.symbol_id)) return error.InvalidMirStructFacts;
        for (module.enums) |enum_fact| if (enum_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirStructFacts;
        for (module.packed_bits) |packed_bits_fact| if (packed_bits_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirStructFacts;
        for (module.overlay_unions) |overlay_union_fact| if (overlay_union_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirStructFacts;
        for (module.tagged_unions) |tagged_union_fact| if (tagged_union_fact.symbol_id.eql(fact.symbol_id)) return error.InvalidMirStructFacts;
    }
}

fn validateCallableEmissionFactsForLowering(module: Module) error{InvalidMirCallableEmissionFacts}!void {
    for (module.callable_emission_facts, 0..) |fact, index| {
        if (!fact.def_id.isValid() or !fact.symbol_id.isValid() or fact.symbol_id.index() >= module.symbol_identities.len)
            return error.InvalidMirCallableEmissionFacts;
        const identity = module.symbol_identities[fact.symbol_id.index()];
        if (!identity.id.eql(fact.symbol_id) or identity.kind != .function) return error.InvalidMirCallableEmissionFacts;
        if (fact.source_id.isValid()) {
            if (fact.source_id.index() >= module.source_identities.len or !module.source_identities[fact.source_id.index()].id.eql(fact.source_id))
                return error.InvalidMirCallableEmissionFacts;
            if (fact.declaration_source.file_id != diagnostics.invalid_file_id and
                fact.declaration_source.file_id != module.source_identities[fact.source_id.index()].file_id)
                return error.InvalidMirCallableEmissionFacts;
        }
        if (fact.backend_name) |name| if (name.len == 0) return error.InvalidMirCallableEmissionFacts;
        if (fact.render_attrs.effective_align) |alignment| if (alignment == 0) return error.InvalidMirCallableEmissionFacts;
        var checked_count: usize = 0;
        var checked: ?CheckedCallableFact = null;
        for (module.checked_callables) |candidate| {
            if (!candidate.def_id.eql(fact.def_id)) continue;
            checked_count += 1;
            checked = candidate;
        }
        if (checked_count != 1) return error.InvalidMirCallableEmissionFacts;
        const callable = checked.?;
        if (!callable.symbol_id.eql(fact.symbol_id) or !callable.source_id.eql(fact.source_id) or
            (callable.kind != .function and callable.kind != .extern_function) or
            fact.params.len != callable.param_count or fact.params.len != callable.param_types.len or
            fact.params.len != callable.signature_param_type_ids.len)
            return error.InvalidMirCallableEmissionFacts;
        for (fact.params, 0..) |param, param_index| {
            if (param.spelling.len == 0)
                return error.InvalidMirCallableEmissionFacts;
            for (fact.params[0..param_index]) |prior| if (std.mem.eql(u8, prior.spelling, param.spelling)) return error.InvalidMirCallableEmissionFacts;
        }
        for (module.callable_emission_facts[0..index]) |prior| if (prior.def_id.eql(fact.def_id) or prior.symbol_id.eql(fact.symbol_id)) return error.InvalidMirCallableEmissionFacts;
    }
    for (module.checked_callables) |callable| {
        if (callable.kind != .function and callable.kind != .extern_function) continue;
        if (module.callableEmissionFact(callable.def_id) == null) return error.InvalidMirCallableEmissionFacts;
    }
}

fn enumCaseFitsRepr(case: EnumCaseFact, repr_ty: ValueType) bool {
    const info = mir_model.ExecutableCastKind.integerInfo(repr_ty) orelse return false;
    if (case.negative) {
        if (!info.signed) return false;
        const minimum_magnitude: u128 = if (info.bits == 128)
            @as(u128, 1) << 127
        else
            @as(u128, 1) << @as(u7, @intCast(info.bits - 1));
        return case.magnitude <= minimum_magnitude;
    }
    const maximum: u128 = if (info.signed)
        if (info.bits == 128)
            @as(u128, @intCast(std.math.maxInt(i128)))
        else
            (@as(u128, 1) << @as(u7, @intCast(info.bits - 1))) - 1
    else if (info.bits == 128)
        std.math.maxInt(u128)
    else
        (@as(u128, 1) << @as(u7, @intCast(info.bits))) - 1;
    return case.magnitude <= maximum;
}

/// A type alias may name an enum representation, but the checked executable
/// representation must still agree with the syntax-free signature graph. This
/// prevents a stale fact from making C and LLVM emit a different integer width
/// than executable MIR uses.
fn enumFactReprMatchesSignature(module: Module, fact: EnumFact) bool {
    const repr_name = enumReprSignatureName(module, fact.repr_type_id, 0) orelse return false;
    return switch (fact.repr_ty) {
        .integer => |name| std.mem.eql(u8, name, repr_name),
        else => false,
    };
}

fn packedBitsFactReprMatchesSignature(module: Module, fact: PackedBitsFact) bool {
    const repr_name = enumReprSignatureName(module, fact.repr_type_id, 0) orelse return false;
    return switch (fact.repr_ty) {
        .integer => |name| std.mem.eql(u8, name, repr_name),
        else => false,
    };
}

fn enumReprSignatureName(module: Module, id: SignatureTypeId, depth: usize) ?[]const u8 {
    if (depth > 16) return null;
    const shape = module.signature_types.get(id) orelse return null;
    const name = switch (shape) {
        .name => |value| value,
        else => return null,
    };
    for (module.type_aliases) |alias| {
        if (!alias.symbol_id.isValid() or alias.symbol_id.index() >= module.symbol_identities.len) return null;
        const identity = module.symbol_identities[alias.symbol_id.index()];
        if (!identity.id.eql(alias.symbol_id) or identity.kind != .type_) return null;
        if (std.mem.eql(u8, identity.spelling, name)) return enumReprSignatureName(module, alias.target_type_id, depth + 1);
    }
    return name;
}

pub fn validateKnownFactTypesForLowering(module: Module) error{UnknownMirLoweringType}!void {
    for (module.checked_globals) |global| {
        if (valueTypeIsUnknownPlaceholder(global.ty)) return error.UnknownMirLoweringType;
    }
    for (module.functions) |function| {
        if (valueTypeIsUnknownPlaceholder(function.return_ty)) return error.UnknownMirLoweringType;
        for (function.blocks) |block| {
            switch (block.terminator) {
                .return_ => |ty| if (valueTypeIsUnknownPlaceholder(ty)) return error.UnknownMirLoweringType,
                else => {},
            }
            for (block.instructions) |instruction| {
                if (instructionRequiresKnownLoweringType(instruction) and valueTypeIsUnknownPlaceholder(instruction.result_ty)) return error.UnknownMirLoweringType;
            }
        }
        for (function.range_facts) |fact| {
            if (valueTypeIsUnknownPlaceholder(fact.result_ty)) return error.UnknownMirLoweringType;
        }
        for (function.call_target_facts) |fact| {
            if (valueTypeIsUnknownPlaceholder(fact.result_ty)) return error.UnknownMirLoweringType;
        }
        for (function.target_type_facts) |fact| {
            if (valueTypeIsUnknownPlaceholder(fact.result_ty)) return error.UnknownMirLoweringType;
        }
        for (function.representation_facts) |fact| {
            if (valueTypeIsUnknownPlaceholder(fact.result_ty)) return error.UnknownMirLoweringType;
        }
    }
}

fn valueTypeIsUnknownPlaceholder(ty: ValueType) bool {
    return switch (ty) {
        .unknown => true,
        else => false,
    };
}

fn instructionRequiresKnownLoweringType(instruction: Instruction) bool {
    return switch (instruction.kind) {
        .param,
        .local,
        .assign,
        .expr,
        .unary,
        .binary,
        .add_overflow,
        .cmp_bounds,
        .index,
        .typed_load,
        .call,
        .indirect_call,
        .call_target,
        .target_type,
        .unchecked_assume,
        .address_deref,
        .address_conversion,
        .address_operation,
        .representation_use,
        .integer_literal_conversion,
        .nullability_conversion,
        .assert_condition,
        .asm_effect,
        .defer_cleanup,
        .return_value,
        => true,

        .contract_begin,
        .contract_end,
        .ffi_check,
        .usage_check,
        .mmio_check,
        .representation_check,
        .conversion_check,
        .aggregate_check,
        .result_check,
        .switch_check,
        .assignment_check,
        .arithmetic_domain_check,
        .operator_check,
        .unsafe_check,
        .control_transfer,
        => false,
    };
}

/// A target-type fact names the typed obligation it describes, a row of
/// `ExecutableBody.target_type_obligations`. One obligation, one fact, in
/// both directions.
///
/// The obligation is a row in a list on the body rather than a field on a
/// node, because one node owns several of them and a seventh of them own no
/// node at all; `ExecutableTargetTypeObligation` records that measurement.
///
/// Everything `targetTypeFactAgreesWithInstruction` checked against the
/// `target_type` instruction is recorded on the obligation, except the kind:
/// that was `std.meta.stringToEnum` over `Instruction.detail`, and on the
/// obligation it is already the enum. The result-type agreement moved with it
/// as a `TypeId`; the fact's `ValueType` stays pinned, because
/// `targetTypeFactTypedIdentitiesValid` compares it against the function's own
/// type identity for that id.
///
/// `targetTypeSyntaxMatches` moved too, as the obligation's `target_type_id`
/// and `aggregate_construction`, and is still checked separately so a fact
/// whose target shape has gone stale is reported as `StaleMirTargetTypeFacts`
/// rather than merely rejected.
///
/// The walk over `target_type` instructions remains only for a body the typed
/// form does not represent; see `typedObligationsRepresented`.
pub fn validateTargetTypeFactsForLowering(module: Module) error{ InvalidMirTargetTypeFacts, StaleMirTargetTypeFacts }!void {
    for (module.functions) |function| {
        const body = &function.executable_body;
        const typed = typedObligationsRepresented(module, function);
        for (function.target_type_facts) |fact| {
            if (!targetTypeFactTypedIdentitiesValid(module.signature_types, function, fact)) return error.InvalidMirTargetTypeFacts;
            if (!targetTypeFactFamilyValid(fact)) return error.InvalidMirTargetTypeFacts;
        }
        if (typed) {
            for (body.target_type_obligations) |obligation| {
                if (!executableObligationOwnerValid(body, obligation.owner)) return error.InvalidMirTargetTypeFacts;
                if (countMatchingTargetTypeFactsForObligation(function, obligation) != 1) {
                    if (hasStaleTargetTypeFactForObligation(function, obligation)) return error.StaleMirTargetTypeFacts;
                    return error.InvalidMirTargetTypeFacts;
                }
            }
        } else {
            for (function.blocks) |block| for (block.instructions) |instruction| {
                const kind = targetTypeKindForInstruction(instruction) orelse continue;
                if (countMatchingTargetTypeFacts(function, kind, instruction) != 1) {
                    if (hasStaleTargetTypeFact(function, kind, instruction)) return error.StaleMirTargetTypeFacts;
                    return error.InvalidMirTargetTypeFacts;
                }
            };
        }
        for (function.target_type_facts) |fact| {
            if (typed) {
                if (mir_model.executableTargetTypeObligationCount(body, fact.typed_inst_id) != 1)
                    return error.InvalidMirTargetTypeFacts;
                const obligation = mir_model.executableTargetTypeObligation(body, fact.typed_inst_id) orelse
                    return error.InvalidMirTargetTypeFacts;
                if (!targetTypeFactAgreesWithObligation(fact, obligation)) return error.InvalidMirTargetTypeFacts;
                if (!targetTypeSyntaxMatchesObligation(fact, obligation)) return error.StaleMirTargetTypeFacts;
            } else if (countMatchingTargetTypeInstructions(function, fact) != 1) {
                return error.InvalidMirTargetTypeFacts;
            }
            if (countMatchingTargetTypeFactsForFact(function, fact) != 1) return error.InvalidMirTargetTypeFacts;
        }
    }
}

/// An obligation that names an owning node must name one that exists. An
/// obligation that owns no node is not an error -- see
/// `ExecutableTargetTypeObligation` for why a tenth of the target-type ones
/// do not -- but a dangling `ExprId` is.
fn executableObligationOwnerValid(body: *const mir_model.ExecutableBody, owner: mir_model.ExprId) bool {
    if (!owner.isValid()) return true;
    const index = owner.index();
    return index < body.expressions.len and body.expressions[index].id.eql(owner);
}

/// Everything the fact and the obligation must agree about except the target
/// shape, which is checked separately so a stale one is reported as stale.
fn targetTypeFactAgreesWithObligation(fact: TargetTypeFact, obligation: mir_model.ExecutableTargetTypeObligation) bool {
    if (!fact.typed_inst_id.isValid() or !fact.typed_inst_id.eql(obligation.id)) return false;
    if (fact.kind != obligation.kind) return false;
    if (fact.target_index != obligation.target_index) return false;
    if (!fact.typed_target_owner_id.eql(obligation.target_owner_id)) return false;
    if (!fact.typed_result_ty.eql(obligation.result_type_id)) return false;
    if (!fact.typed_span_id.eql(obligation.span_id)) return false;
    if (!fact.typed_callee_span_id.eql(obligation.callee_span_id)) return false;
    return fact.typed_operand_value_id.eql(obligation.operand_value_id);
}

fn targetTypeSyntaxMatchesObligation(fact: TargetTypeFact, obligation: mir_model.ExecutableTargetTypeObligation) bool {
    return obligation.target_type_id.isValid() and
        fact.target_type_id.eql(obligation.target_type_id) and
        fact.aggregate_construction == obligation.aggregate_construction;
}

fn countMatchingTargetTypeFactsForObligation(function: Function, obligation: mir_model.ExecutableTargetTypeObligation) usize {
    var count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (targetTypeFactAgreesWithObligation(fact, obligation) and targetTypeSyntaxMatchesObligation(fact, obligation)) count += 1;
    }
    return count;
}

fn hasStaleTargetTypeFactForObligation(function: Function, obligation: mir_model.ExecutableTargetTypeObligation) bool {
    for (function.target_type_facts) |fact| {
        if (targetTypeFactAgreesWithObligation(fact, obligation) and !targetTypeSyntaxMatchesObligation(fact, obligation)) return true;
    }
    return false;
}

fn targetTypeFactFamilyValid(fact: TargetTypeFact) bool {
    return switch (fact.kind) {
        .if_let_subject => isResultOrNullableTargetType(fact.result_ty),
        .try_operand => isResultOrNullableTargetType(fact.result_ty),
        .direct_call_argument => fact.target_index != null and fact.typed_target_owner_id.isValid() and fact.typed_callee_span_id.isValid(),
        .indirect_call_argument => fact.target_index != null and fact.typed_target_owner_id.isValid() and fact.typed_callee_span_id.isValid(),
        .for_element => fact.typed_operand_value_id.isValid(),
        else => true,
    };
}

fn isResultOrNullableTargetType(ty: ValueType) bool {
    return switch (ty) {
        .result, .nullable_pointer, .nullable_dyn_trait, .nullable_value => true,
        else => false,
    };
}

fn targetTypeFactTypedIdentitiesValid(signature_types: SignatureTypeTable, function: Function, fact: TargetTypeFact) bool {
    if (!fact.typed_inst_id.isValid()) return false;
    if (!fact.target_type_id.isValid() or !signature_types.contains(fact.target_type_id)) return false;
    if (!fact.typed_result_ty.isValid()) return false;
    const result_index = fact.typed_result_ty.index();
    if (result_index >= function.type_identities.len) return false;
    if (!function.type_identities[result_index].matches(fact.result_ty)) return false;

    if (!fact.typed_span_id.isValid()) return false;
    const span_index = fact.typed_span_id.index();
    if (span_index >= function.span_identities.len) return false;
    if (!function.span_identities[span_index].id.eql(fact.typed_span_id)) return false;

    if (fact.kind == .direct_call_argument or fact.kind == .indirect_call_argument) {
        if (!fact.typed_callee_span_id.isValid()) return false;
        if (fact.typed_callee_span_id.index() >= function.span_identities.len) return false;
        if (fact.kind == .indirect_call_argument and !fact.typed_operand_value_id.isValid()) return false;
        if (fact.typed_operand_value_id.isValid() and fact.typed_operand_value_id.index() >= function.value_identities.len) return false;
    } else if (fact.kind == .for_element) {
        if (fact.typed_callee_span_id.isValid() or !fact.typed_operand_value_id.isValid()) return false;
        if (fact.typed_operand_value_id.index() >= function.value_identities.len) return false;
    } else if (fact.typed_callee_span_id.isValid()) {
        return false;
    } else if (fact.typed_operand_value_id.isValid()) {
        return false;
    }

    if (fact.typed_target_owner_id.isValid()) {
        const owner_index = fact.typed_target_owner_id.index();
        if (owner_index >= function.target_owner_identities.len) return false;
        if (!function.target_owner_identities[owner_index].id.eql(fact.typed_target_owner_id)) return false;
    }

    return true;
}

fn targetTypeKindForInstruction(instruction: Instruction) ?TargetTypeKind {
    if (instruction.kind != .target_type) return null;
    return std.meta.stringToEnum(TargetTypeKind, instruction.detail);
}

fn targetTypeTypedOwnerCompatible(instruction: Instruction, fact: TargetTypeFact) bool {
    if (instruction.typed_target_owner_id) |owner_id| {
        return fact.typed_target_owner_id.isValid() and fact.typed_target_owner_id.eql(owner_id);
    }
    return !fact.typed_target_owner_id.isValid();
}

fn targetTypeTypedResultCompatible(instruction: Instruction, fact: TargetTypeFact) bool {
    if (instruction.typed_result_ty.isValid()) {
        return fact.typed_result_ty.isValid() and fact.typed_result_ty.eql(instruction.typed_result_ty);
    }
    return !fact.typed_result_ty.isValid();
}

fn targetTypeTypedSpanCompatible(instruction: Instruction, fact: TargetTypeFact) bool {
    if (instruction.typed_span_id.isValid()) {
        return fact.typed_span_id.isValid() and fact.typed_span_id.eql(instruction.typed_span_id);
    }
    return !fact.typed_span_id.isValid();
}

fn targetTypeTypedCalleeSpanCompatible(instruction: Instruction, fact: TargetTypeFact) bool {
    if (fact.kind == .for_element) {
        return !fact.typed_callee_span_id.isValid() and !instruction.typed_callee_span_id.isValid() and
            fact.typed_operand_value_id.isValid() and instruction.typed_operand_value_id.isValid() and
            fact.typed_operand_value_id.eql(instruction.typed_operand_value_id);
    }
    if (fact.kind != .direct_call_argument and fact.kind != .indirect_call_argument) {
        return !fact.typed_callee_span_id.isValid() and !instruction.typed_callee_span_id.isValid() and !fact.typed_operand_value_id.isValid() and !instruction.typed_operand_value_id.isValid();
    }
    if (!fact.typed_callee_span_id.isValid() or !instruction.typed_callee_span_id.isValid() or !fact.typed_callee_span_id.eql(instruction.typed_callee_span_id)) return false;
    if (fact.kind == .indirect_call_argument and (!fact.typed_operand_value_id.isValid() or !instruction.typed_operand_value_id.isValid())) return false;
    if (fact.typed_operand_value_id.isValid() != instruction.typed_operand_value_id.isValid()) return false;
    return !fact.typed_operand_value_id.isValid() or fact.typed_operand_value_id.eql(instruction.typed_operand_value_id);
}

fn targetTypeSourceMatches(kind: TargetTypeKind, fact: TargetTypeFact, instruction: Instruction) bool {
    _ = kind;
    return fact.typed_span_id.eql(instruction.typed_span_id);
}

fn targetTypeSyntaxMatches(fact: TargetTypeFact, instruction: Instruction) bool {
    return instruction.target_type_id.isValid() and
        fact.target_type_id.eql(instruction.target_type_id) and
        fact.aggregate_construction == instruction.aggregate_construction;
}

/// A fact agrees with a `target_type` instruction when it names it by
/// identity and still matches its kind, target index, owner, result type,
/// span, callee span and operand identity. Syntax agreement is checked
/// separately so a stale target type can be reported as such.
fn targetTypeFactAgreesWithInstruction(kind: TargetTypeKind, fact: TargetTypeFact, instruction: Instruction) bool {
    if (!fact.typed_inst_id.isValid() or !fact.typed_inst_id.eql(instruction.typed_inst_id)) return false;
    if (fact.kind != kind) return false;
    if (fact.target_index != instruction.target_index) return false;
    if (!targetTypeTypedOwnerCompatible(instruction, fact)) return false;
    if (!targetTypeTypedResultCompatible(instruction, fact)) return false;
    if (!targetTypeTypedSpanCompatible(instruction, fact)) return false;
    if (!targetTypeTypedCalleeSpanCompatible(instruction, fact)) return false;
    if (!sameRepresentationValueType(fact.result_ty, instruction.result_ty)) return false;
    return targetTypeSourceMatches(kind, fact, instruction);
}

fn targetTypeFactMatchesInstruction(kind: TargetTypeKind, fact: TargetTypeFact, instruction: Instruction) bool {
    return targetTypeFactAgreesWithInstruction(kind, fact, instruction) and targetTypeSyntaxMatches(fact, instruction);
}

fn hasStaleTargetTypeFact(function: Function, kind: TargetTypeKind, instruction: Instruction) bool {
    for (function.target_type_facts) |fact| {
        if (targetTypeFactAgreesWithInstruction(kind, fact, instruction) and !targetTypeSyntaxMatches(fact, instruction)) return true;
    }
    return false;
}

fn countMatchingTargetTypeFacts(function: Function, kind: TargetTypeKind, instruction: Instruction) usize {
    var count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (targetTypeFactMatchesInstruction(kind, fact, instruction)) count += 1;
    }
    return count;
}

fn countMatchingTargetTypeInstructions(function: Function, fact: TargetTypeFact) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        const kind = targetTypeKindForInstruction(instruction) orelse continue;
        if (targetTypeFactMatchesInstruction(kind, fact, instruction)) count += 1;
    };
    return count;
}

fn countMatchingTargetTypeFactsForFact(function: Function, target: TargetTypeFact) usize {
    var count: usize = 0;
    for (function.target_type_facts) |fact| {
        if (fact.typed_inst_id.eql(target.typed_inst_id)) count += 1;
    }
    return count;
}

fn callTargetKindForInstruction(instruction: Instruction) ?CallTargetKind {
    if (instruction.kind != .call_target) return null;
    return std.meta.stringToEnum(CallTargetKind, instruction.detail);
}

/// Used only for the bodies the typed form does not represent; see
/// `validateCallTargetFactsForLowering`.
fn callTargetFactMatchesInstruction(fact: CallTargetFact, instruction: Instruction) bool {
    const kind = callTargetKindForInstruction(instruction) orelse return false;
    if (!fact.typed_inst_id.isValid() or !fact.typed_inst_id.eql(instruction.typed_inst_id)) return false;
    return fact.kind == kind and
        sameRepresentationValueType(fact.result_ty, instruction.result_ty) and
        fact.typed_span_id.isValid() and fact.typed_span_id.eql(instruction.typed_callee_span_id);
}

fn countMatchingCallTargetFacts(function: Function, instruction: Instruction) usize {
    var count: usize = 0;
    for (function.call_target_facts) |fact| {
        if (callTargetFactMatchesInstruction(fact, instruction)) count += 1;
    }
    return count;
}

fn countMatchingCallTargetInstructions(function: Function, fact: CallTargetFact) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (callTargetFactMatchesInstruction(fact, instruction)) count += 1;
    };
    return count;
}

fn countMatchingCallTargetFactsForFact(function: Function, target: CallTargetFact) usize {
    var count: usize = 0;
    for (function.call_target_facts) |fact| {
        if (fact.typed_inst_id.eql(target.typed_inst_id)) count += 1;
    }
    return count;
}

fn callTargetFactTypedIdentityValid(function: Function, fact: CallTargetFact) bool {
    return fact.typed_inst_id.isValid() and sourcePointForSpanId(function, fact.typed_span_id) != null;
}

fn integerFactTypedIdentitiesValid(function: Function, fact: IntegerFact) bool {
    if (integerFactTargetType(&function, fact) == null) return false;
    if (!fact.typed_inst_id.isValid()) return false;
    return sourcePointForSpanId(function, fact.typed_span_id) != null;
}

fn isIntegerLiteralConversionInstruction(instruction: Instruction) bool {
    return instruction.kind == .integer_literal_conversion;
}

/// A fact describes an instruction when it names it by identity and still
/// agrees with it about the target type. Used only for the bodies the typed
/// form does not represent; see `validateIntegerFactsForLowering`.
///
/// The identity, not the span, is the join key. A span is not unique: the
/// async transform stamps one function-name span onto every node it
/// synthesizes, so two distinct literal conversions in a generated body share
/// one span and would otherwise collapse into a single key.
fn integerFactMatchesInstruction(fact: IntegerFact, instruction: Instruction) bool {
    return fact.typed_inst_id.isValid() and
        fact.typed_inst_id.eql(instruction.typed_inst_id) and
        fact.target_type_id.eql(instruction.typed_result_ty);
}

fn countMatchingIntegerInstructions(function: Function, fact: IntegerFact) usize {
    var count: usize = 0;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (isIntegerLiteralConversionInstruction(instruction) and integerFactMatchesInstruction(fact, instruction)) count += 1;
        }
    }
    return count;
}

fn countMatchingIntegerFacts(function: Function, target: IntegerFact) usize {
    var count: usize = 0;
    for (function.integer_facts) |fact| {
        if (!fact.typed_inst_id.eql(target.typed_inst_id)) continue;
        count += 1;
    }
    return count;
}

fn countMatchingIntegerFactsForInstruction(function: Function, instruction: Instruction) usize {
    var count: usize = 0;
    for (function.integer_facts) |fact| {
        if (integerFactMatchesInstruction(fact, instruction)) count += 1;
    }
    return count;
}

fn floatFactTypedIdentitiesValid(function: Function, fact: FloatFact) bool {
    if (floatFactTargetType(&function, fact) == null) return false;
    if (!fact.typed_inst_id.isValid()) return false;
    return sourcePointForSpanId(function, fact.typed_span_id) != null;
}

fn rangeFactTypedIdentityValid(function: Function, fact: RangeFact) bool {
    if (fact.target.len == 0 or fact.op.len == 0 or fact.left.len == 0 or fact.right.len == 0) return false;
    if (!fact.typed_inst_id.isValid()) return false;
    if (sourcePointForSpanId(function, fact.typed_span_id) == null) return false;
    for (function.contract_regions) |region| {
        if (region.id == fact.region_id) return std.mem.eql(u8, region.kind, "no_overflow");
    }
    return false;
}

/// A fact describes an unchecked instruction when it names it by identity
/// and still agrees with it about region, span, operation and type. Used only
/// for the bodies the typed form does not represent; see
/// `validateRangeFactsForLowering`.
fn rangeFactMatchesInstruction(fact: RangeFact, instruction: Instruction) bool {
    if (instruction.kind != .unchecked_assume or instruction.contract_region_id == null) return false;
    const op = noOverflowUncheckedOp(instruction.detail) orelse return false;
    return fact.typed_inst_id.isValid() and
        fact.typed_inst_id.eql(instruction.typed_inst_id) and
        fact.region_id == instruction.contract_region_id.? and
        fact.typed_span_id.eql(instruction.typed_span_id) and
        std.mem.eql(u8, fact.op, op) and
        sameValueType(fact.result_ty, instruction.result_ty);
}

fn countMatchingRangeInstructions(function: Function, fact: RangeFact) usize {
    var count: usize = 0;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (rangeFactMatchesInstruction(fact, instruction)) count += 1;
        }
    }
    return count;
}

/// One instruction, one fact per target label; counted on the identity.
fn rangeFactSameOwnershipGroup(left: RangeFact, right: RangeFact) bool {
    return left.region_id == right.region_id and
        left.typed_inst_id.eql(right.typed_inst_id) and
        std.mem.eql(u8, left.target, right.target) and
        std.mem.eql(u8, left.op, right.op) and
        sameValueType(left.result_ty, right.result_ty);
}

fn countMatchingRangeFactsInOwnershipGroup(function: Function, target: RangeFact) usize {
    var count: usize = 0;
    for (function.range_facts) |fact| {
        if (rangeFactSameOwnershipGroup(fact, target)) count += 1;
    }
    return count;
}

fn isFloatLiteralInstruction(instruction: Instruction) bool {
    return instruction.kind == .expr and
        sameRepresentationValueType(instruction.result_ty, .{ .float = "comptime_float" }) and
        std.mem.eql(u8, instruction.detail, "float");
}

/// Float literal facts join on the instruction identity for the same reason
/// integer facts do; see `integerFactMatchesInstruction`.
fn floatFactMatchesInstruction(fact: FloatFact, instruction: Instruction) bool {
    return fact.typed_inst_id.isValid() and fact.typed_inst_id.eql(instruction.typed_inst_id);
}

fn countMatchingFloatInstructions(function: Function, fact: FloatFact) usize {
    var count: usize = 0;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (isFloatLiteralInstruction(instruction) and floatFactMatchesInstruction(fact, instruction)) count += 1;
        }
    }
    return count;
}

fn countMatchingFloatFacts(function: Function, target: FloatFact) usize {
    var count: usize = 0;
    for (function.float_facts) |fact| {
        if (!fact.typed_inst_id.eql(target.typed_inst_id)) continue;
        count += 1;
    }
    return count;
}

fn countMatchingFloatFactsForInstruction(function: Function, instruction: Instruction) usize {
    var count: usize = 0;
    for (function.float_facts) |fact| {
        if (floatFactMatchesInstruction(fact, instruction)) count += 1;
    }
    return count;
}

/// One representation-sensitive instruction, one fact. Counted on the
/// instruction identity: a span is shared by every node the async transform
/// synthesizes, so it cannot tell two such instructions apart.
fn countMatchingRepresentationFacts(function: Function, instruction: Instruction) usize {
    var count: usize = 0;
    for (function.representation_facts) |fact| {
        if (representationFactMatchesInstruction(instruction, fact)) count += 1;
    }
    return count;
}

fn countMatchingRepresentationInstructions(function: Function, fact: RepresentationFact) usize {
    var count: usize = 0;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (!representationFactKind(instruction.kind, instruction.result_ty)) continue;
            if (representationFactMatchesInstruction(instruction, fact)) count += 1;
        }
    }
    return count;
}

/// A fact describes an instruction when it names it by identity and still
/// agrees with it about kind, detail, result type, span and value identity.
/// Used only for the bodies the typed form does not represent; see
/// `validateRepresentationFactsForLowering`.
fn representationFactMatchesInstruction(instruction: Instruction, fact: RepresentationFact) bool {
    return fact.typed_inst_id.isValid() and
        fact.typed_inst_id.eql(instruction.typed_inst_id) and
        fact.kind == instruction.kind and
        sameRepresentationValueType(fact.result_ty, instruction.result_ty) and
        std.mem.eql(u8, fact.detail, instruction.detail) and
        representationTypedSpansCompatible(instruction, fact) and
        representationTypedResultTypesCompatible(instruction, fact) and
        representationTypedValueIdsCompatible(instruction, fact);
}

fn representationFactTypedIdentitiesValid(function: Function, fact: RepresentationFact) bool {
    if (!fact.typed_inst_id.isValid()) return false;
    if (!fact.typed_result_ty.isValid()) return false;
    const result_index = fact.typed_result_ty.index();
    if (result_index >= function.type_identities.len) return false;
    if (!function.type_identities[result_index].matches(fact.result_ty)) return false;

    return sourcePointForSpanId(function, fact.typed_span_id) != null;
}

fn representationTypedValueIdsCompatible(instruction: Instruction, fact: RepresentationFact) bool {
    if (instruction.typed_value_id) |typed_value_id| {
        return fact.typed_value_id.isValid() and fact.typed_value_id.eql(typed_value_id);
    }
    return !fact.typed_value_id.isValid();
}

fn representationTypedResultTypesCompatible(instruction: Instruction, fact: RepresentationFact) bool {
    if (instruction.typed_result_ty.isValid()) {
        return fact.typed_result_ty.isValid() and fact.typed_result_ty.eql(instruction.typed_result_ty);
    }
    return !fact.typed_result_ty.isValid();
}

fn representationTypedSpansCompatible(instruction: Instruction, fact: RepresentationFact) bool {
    if (instruction.typed_span_id.isValid()) {
        return fact.typed_span_id.isValid() and fact.typed_span_id.eql(instruction.typed_span_id);
    }
    return !fact.typed_span_id.isValid();
}

pub fn sameRepresentationValueType(left: ValueType, right: ValueType) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right) and
        std.mem.eql(u8, left.name(), right.name());
}
