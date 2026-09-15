//! MIR facade.
//!
//! The implementation is split into cohesive modules; this file re-exports
//! their public surface so existing `mir.X` call sites compile unchanged:
//!
//!   * `mir_model.zig`       -- the data model (types, ids, facts, Module)
//!   * `mir_build.zig`       -- `FunctionBuilder` and the `buildOptFromDecls` family
//!   * `mir_verify.zig`      -- `verifyBuiltMir`, `validate*ForLowering`, `validateLoweringAdmission`
//!   * `mir_cleanup_cfg.zig` -- defer/ownership cleanup edge tables, `CleanupCfg`, ownership events
//!   * `mir_dump.zig`        -- `appendDump*` / `appendVerificationFacts*` rendering
//!
//! What remains here beyond the re-exports is the shared AST-shape and
//! type-alias query surface that both the builder and the verifier use. It is
//! the next natural extraction, but it is deliberately left in place: this
//! split was mechanical, with no behavior change.

const std = @import("std");

const array_len = @import("array_len.zig");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const attr_syntax = @import("attr_syntax.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const expr_syntax = @import("expr_syntax.zig");
const module_parser = @import("module_parser.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const numeric = @import("numeric.zig");
const ownership_facts = @import("ownership_facts.zig");
const parser = @import("parser.zig");
const sema_builtin = @import("sema_builtin.zig");
const sema_type = @import("sema_type.zig");
const scalar_repr = @import("scalar_repr.zig");
const sema_types = @import("sema_types.zig");
const string_literal = @import("string_literal.zig");

// Pure AST-shape queries shared with `sema.zig`/`lower_c.zig` (see `ast_query.zig`).
const MmioRegisterAccess = ast_query.MmioRegisterAccess;
const mmioRegisterAccessFromModeType = ast_query.mmioRegisterAccessFromModeType;
const mmioMapCallPayloadType = ast_query.mmioMapCallPayloadType;
const exprIsIdentNamed = ast_query.exprIsIdentNamed;
const exprHandlesAnyResult = ast_query.exprHandlesAnyResult;
const isResultNarrowingTag = ast_query.isResultNarrowingTag;
const localDeclaresName = ast_query.localDeclaresName;
const resultIfLetHandlesLocal = ast_query.resultIfLetHandlesLocal;
const resultSwitchHandlesLocal = ast_query.resultSwitchHandlesLocal;
const contractName = ast_query.contractName;
const isSatPreservingBinary = ast_query.isSatPreservingBinary;
const isWrapPreservingBinary = ast_query.isWrapPreservingBinary;
const reduceCallKind = expr_syntax.reduceCallKind;
const byteViewCallKind = ast_query.byteViewCallKind;
const isBindCallNode = ast_query.isBindCallNode;
const resultConstructorCallTag = ast_query.resultConstructorCallTag;
const isDeclassifyCall = ast_query.isDeclassifyCall;
const calleeIdentName = ast_query.calleeIdentName;
const memberExpr = ast_query.memberExpr;
const memberCallee = ast_query.memberCallee;
const reflectionKind = sema_builtin.reflectionKind;
const reflectionRequiresField = sema_builtin.reflectionRequiresField;

// Numeric-literal and integer-bounds primitives shared with `sema.zig` and `lower_c.zig`
// (see `numeric.zig`); aliased here so the existing call sites read unchanged.
const LiteralValue = numeric.LiteralValue;
const IntBounds = numeric.IntBounds;
const maxUnsigned = numeric.maxUnsigned;
const signedBounds = numeric.signedBounds;
const integerLiteralValue = numeric.integerLiteralValue;
const parseArrayLen = array_len.parseArrayLen;
const parseArrayLenWithReflect = array_len.parseArrayLenWithReflect;

// The literal -> scalar-type rule now has exactly one implementation, in
// `sema_types.zig`, which sema uses when it records and the builder uses when
// no recording is available. These two render that one answer back to the
// `ast.TypeExpr` the builder still passes around.
pub fn integerLiteralTypeExpr(literal: []const u8, span: ast.Span) ast.TypeExpr {
    return ast_query.simpleNameType(sema_types.integerOfLiteral(literal).scalarSpelling().?, span);
}

pub fn suffixedIntegerLiteralTypeExpr(literal: []const u8, span: ast.Span) ?ast.TypeExpr {
    const resolved = sema_types.suffixedIntegerOfLiteral(literal) orelse return null;
    return ast_query.simpleNameType(resolved.scalarSpelling().?, span);
}

const mir_model = @import("mir_model.zig");
const mir_operator = @import("mir_operator.zig");
const mir_representation = @import("mir_representation.zig");
const mir_reflect = @import("mir_reflect.zig");
const mir_summary = @import("mir_summary.zig");
const mir_syntax = @import("mir_syntax.zig");
const mir_type = @import("mir_type.zig");
const mir_verify_util = @import("mir_verify_util.zig");

pub const TrapKind = mir_model.TrapKind;
pub const TrapSource = mir_model.TrapSource;
pub const AddressClass = mir_model.AddressClass;
pub const PointerKind = mir_model.PointerKind;
pub const PointerShape = mir_model.PointerShape;
pub const ResultShape = mir_model.ResultShape;
pub const SourceId = mir_model.SourceId;
pub const DefId = mir_model.DefId;
pub const NodeId = mir_model.NodeId;
pub const SymbolId = mir_model.SymbolId;
pub const TypeId = mir_model.TypeId;
pub const SignatureTypeId = mir_model.SignatureTypeId;
pub const TypeMutability = mir_model.TypeMutability;
pub const TypeShape = mir_model.TypeShape;
pub const SignatureTypeTable = mir_model.SignatureTypeTable;
pub const ValueId = mir_model.ValueId;
pub const BlockId = mir_model.BlockId;
pub const SpanId = mir_model.SpanId;
pub const ValueType = mir_model.ValueType;
pub const Instruction = mir_model.Instruction;
pub const Terminator = mir_model.Terminator;
pub const TrapEdge = mir_model.TrapEdge;
pub const ContractRegion = mir_model.ContractRegion;
pub const RangeFact = mir_model.RangeFact;
pub const BoundsFact = mir_model.BoundsFact;
pub const BoundsFactKind = mir_model.BoundsFactKind;
pub const AccessFact = mir_model.AccessFact;
pub const IntegerFact = mir_model.IntegerFact;
pub const FloatFact = mir_model.FloatFact;
pub const CallTargetKind = mir_model.CallTargetKind;
pub const CallTargetFact = mir_model.CallTargetFact;
pub const BindThunkFact = mir_model.BindThunkFact;
pub const DropGlueFact = mir_model.DropGlueFact;
pub const TargetTypeKind = mir_model.TargetTypeKind;
pub const AggregateConstructionKind = mir_model.AggregateConstructionKind;
pub const ExecutableCastKind = mir_model.ExecutableCastKind;
pub const ExecutableUnaryOp = mir_model.ExecutableUnaryOp;
pub const ExecutableIncompleteReason = mir_model.ExecutableIncompleteReason;
pub const IntegerDomainKind = mir_model.IntegerDomainKind;
pub const TargetTypeFact = mir_model.TargetTypeFact;
pub const FfiParamContract = mir_model.FfiParamContract;
pub const TypeAliasFact = mir_model.TypeAliasFact;
pub const EnumFact = mir_model.EnumFact;
pub const EnumCaseFact = mir_model.EnumCaseFact;
pub const PackedBitsFact = mir_model.PackedBitsFact;
pub const PackedBitsFieldFact = mir_model.PackedBitsFieldFact;
pub const OverlayUnionFact = mir_model.OverlayUnionFact;
pub const OverlayUnionFieldFact = mir_model.OverlayUnionFieldFact;
pub const TaggedUnionFact = mir_model.TaggedUnionFact;
pub const TaggedUnionCaseFact = mir_model.TaggedUnionCaseFact;
pub const StructFact = mir_model.StructFact;
pub const StructFieldFact = mir_model.StructFieldFact;
pub const SourceMapDeclarationKind = mir_model.SourceMapDeclarationKind;
pub const SourceMapDeclarationFact = mir_model.SourceMapDeclarationFact;

pub const ResultConstructorFactInfo = struct {
    target_kind: TargetTypeKind,
    tag: []const u8,
};

pub const DomainCallFactInfo = struct {
    op: []const u8,
    has_interval: bool = false,
};

pub const DmaCallFactInfo = struct {
    op: []const u8,
    cache: bool,
};

pub fn uncheckedCallFactInfo(kind: CallTargetKind) ?[]const u8 {
    return switch (kind) {
        .unchecked_add => "add",
        .unchecked_sub => "sub",
        .unchecked_mul => "mul",
        else => null,
    };
}

pub fn wrappingCallFactInfo(kind: CallTargetKind) ?[]const u8 {
    return if (kind == .wrapping_add) "add" else null;
}

pub fn dmaCallFactInfo(kind: CallTargetKind) ?DmaCallFactInfo {
    return switch (kind) {
        .dma_cache_clean => .{ .op = "clean", .cache = true },
        .dma_cache_invalidate => .{ .op = "invalidate", .cache = true },
        .dma_addr => .{ .op = "dma_addr", .cache = false },
        .dma_as_slice => .{ .op = "as_slice", .cache = false },
        else => null,
    };
}

pub fn domainCallFactInfo(kind: CallTargetKind) ?DomainCallFactInfo {
    return switch (kind) {
        .wrap_residue => .{ .op = "residue" },
        .serial_before => .{ .op = "before" },
        .serial_after => .{ .op = "after" },
        .serial_distance => .{ .op = "distance" },
        .serial_compare => .{ .op = "compare" },
        .counter_delta_mod => .{ .op = "delta_mod" },
        .counter_elapsed_assume_within => .{ .op = "elapsed_assume_within", .has_interval = true },
        .counter_elapsed_bounded => .{ .op = "elapsed_bounded", .has_interval = true },
        else => null,
    };
}

pub fn resultConstructorFactInfo(kind: CallTargetKind) ?ResultConstructorFactInfo {
    return switch (kind) {
        .result_ok => .{ .target_kind = .result_ok, .tag = "ok" },
        .result_err => .{ .target_kind = .result_err, .tag = "err" },
        else => null,
    };
}
pub const SourcePoint = mir_model.SourcePoint;
pub const transparentSignatureTypeId = mir_model.transparentSignatureTypeId;

// MIR construction lives in `mir_build.zig`.
const mir_build = @import("mir_build.zig");

pub const alignOverlayStorage = mir_build.alignOverlayStorage;
pub const buildFromDecls = mir_build.buildFromDecls;
pub const buildOptFromDecls = mir_build.buildOptFromDecls;
pub const buildOptFromResolvedDecls = mir_build.buildOptFromResolvedDecls;


// MIR verification and lowering admission live in `mir_verify.zig`.
const mir_verify = @import("mir_verify.zig");

pub const verifyFromDecls = mir_verify.verifyFromDecls;
pub const verifyOptFromDecls = mir_verify.verifyOptFromDecls;
pub const verifyBuiltMir = mir_verify.verifyBuiltMir;
pub const validateRepresentationFactsForLowering = mir_verify.validateRepresentationFactsForLowering;
pub const validateIntegerFactsForLowering = mir_verify.validateIntegerFactsForLowering;
pub const validateFloatFactsForLowering = mir_verify.validateFloatFactsForLowering;
pub const validateRangeFactsForLowering = mir_verify.validateRangeFactsForLowering;
pub const validateBoundsFactsForLowering = mir_verify.validateBoundsFactsForLowering;
pub const floatFactTargetType = mir_verify.floatFactTargetType;
pub const integerFactTargetType = mir_verify.integerFactTargetType;
pub const validateConstGetFactsForLowering = mir_verify.validateConstGetFactsForLowering;
pub const validateCallTargetFactsForLowering = mir_verify.validateCallTargetFactsForLowering;
pub const validateBindThunkFactsForLowering = mir_verify.validateBindThunkFactsForLowering;
pub const valueSpelling = mir_verify.valueSpelling;
pub const LoweringAdmissionError = mir_verify.LoweringAdmissionError;
pub const validateLoweringAdmission = mir_verify.validateLoweringAdmission;
pub const validateElidedBoundsForLowering = mir_verify.validateElidedBoundsForLowering;
pub const validateKnownFactTypesForLowering = mir_verify.validateKnownFactTypesForLowering;
pub const validateTargetTypeFactsForLowering = mir_verify.validateTargetTypeFactsForLowering;

const sameRepresentationValueType = mir_verify.sameRepresentationValueType;
const sameValueType = mir_verify.sameValueType;

// Dump/verification-fact rendering lives in `mir_dump.zig`.
const mir_dump = @import("mir_dump.zig");

pub const appendDumpFromDecls = mir_dump.appendDumpFromDecls;
pub const appendDumpFromMir = mir_dump.appendDumpFromMir;
pub const appendDumpOptFromDecls = mir_dump.appendDumpOptFromDecls;
pub const appendVerificationFactsFromDecls = mir_dump.appendVerificationFactsFromDecls;
pub const appendVerificationFactsFromMir = mir_dump.appendVerificationFactsFromMir;

// Cleanup CFG and ownership-event authority lives in `mir_cleanup_cfg.zig`.
// Re-exported here so existing `mir.X` call sites compile unchanged.
const mir_cleanup_cfg = @import("mir_cleanup_cfg.zig");

pub const DeferCleanupRef = mir_cleanup_cfg.DeferCleanupRef;
pub const OwnershipRootState = mir_cleanup_cfg.OwnershipRootState;
pub const appendOwnershipCleanupCancellationPlan = mir_cleanup_cfg.appendOwnershipCleanupCancellationPlan;
pub const appendOwnershipCleanupPlan = mir_cleanup_cfg.appendOwnershipCleanupPlan;
pub const buildCleanupCfg = mir_cleanup_cfg.buildCleanupCfg;
pub const buildCleanupCfgFromEdgeTables = mir_cleanup_cfg.buildCleanupCfgFromEdgeTables;
pub const buildDeferCleanupEdgeTable = mir_cleanup_cfg.buildDeferCleanupEdgeTable;
pub const buildOwnershipCleanupEdgeTable = mir_cleanup_cfg.buildOwnershipCleanupEdgeTable;
pub const buildOwnershipCleanupPlan = mir_cleanup_cfg.buildOwnershipCleanupPlan;
pub const callTargetFactMatchesSpanId = mir_cleanup_cfg.callTargetFactMatchesSpanId;
pub const cleanupCfgEdgeKindFromDefer = mir_cleanup_cfg.cleanupCfgEdgeKindFromDefer;
pub const cleanupCfgEdgeKindFromOwnership = mir_cleanup_cfg.cleanupCfgEdgeKindFromOwnership;
pub const cleanupCfgEquivalent = mir_cleanup_cfg.cleanupCfgEquivalent;
pub const cleanupCfgValid = mir_cleanup_cfg.cleanupCfgValid;
pub const deferCleanupEdgeTableContainsRef = mir_cleanup_cfg.deferCleanupEdgeTableContainsRef;
pub const deferCleanupEdgeTableValid = mir_cleanup_cfg.deferCleanupEdgeTableValid;
pub const deferCleanupRefAtSource = mir_cleanup_cfg.deferCleanupRefAtSource;
pub const deferCleanupRefValid = mir_cleanup_cfg.deferCleanupRefValid;
pub const instructionMatchesSpanId = mir_cleanup_cfg.instructionMatchesSpanId;
pub const instructionSourcePoint = mir_cleanup_cfg.instructionSourcePoint;
pub const ownershipCleanupEdgeTableValid = mir_cleanup_cfg.ownershipCleanupEdgeTableValid;
pub const ownershipCleanupPlanEquivalent = mir_cleanup_cfg.ownershipCleanupPlanEquivalent;
pub const ownershipLocalHasAutoDropResourceEvent = mir_cleanup_cfg.ownershipLocalHasAutoDropResourceEvent;
pub const ownershipLocalHasConsumingResourceEvent = mir_cleanup_cfg.ownershipLocalHasConsumingResourceEvent;
pub const sourcePointForSpanId = mir_cleanup_cfg.sourcePointForSpanId;
pub const sourcePointFromSpan = mir_cleanup_cfg.sourcePointFromSpan;
pub const spanIdAtSource = mir_cleanup_cfg.spanIdAtSource;
pub const targetOwnerIdBySpelling = mir_cleanup_cfg.targetOwnerIdBySpelling;
pub const targetOwnerSpelling = mir_cleanup_cfg.targetOwnerSpelling;
pub const targetTypeFactMatchesSpanId = mir_cleanup_cfg.targetTypeFactMatchesSpanId;
pub const validateDropGlueFactsForLowering = mir_cleanup_cfg.validateDropGlueFactsForLowering;
pub const validateOwnershipEventsForLowering = mir_cleanup_cfg.validateOwnershipEventsForLowering;
pub const validateTypeOwnershipFactsForLowering = mir_cleanup_cfg.validateTypeOwnershipFactsForLowering;

const canonicalOperatorOperand = mir_cleanup_cfg.canonicalOperatorOperand;
const moduleSymbolIdentityValid = mir_cleanup_cfg.moduleSymbolIdentityValid;
const moduleSymbolSpelling = mir_cleanup_cfg.moduleSymbolSpelling;
const simpleOwnershipRootValue = mir_cleanup_cfg.simpleOwnershipRootValue;
const sourcePointSpan = mir_cleanup_cfg.sourcePointSpan;
const verifyFunctionOwnershipEvents = mir_cleanup_cfg.verifyFunctionOwnershipEvents;

pub const PointerProvenance = mir_model.PointerProvenance;
pub const PointerProvenanceFact = mir_model.PointerProvenanceFact;
pub const ConstGetFact = mir_model.ConstGetFact;
pub const AggregateReturnSummaryFact = mir_model.AggregateReturnSummaryFact;
pub const AggregateReturnPointerFact = mir_model.AggregateReturnPointerFact;
pub const RepresentationFact = mir_model.RepresentationFact;
pub const TypeOwnershipKind = mir_model.TypeOwnershipKind;
pub const TypeOwnershipFact = mir_model.TypeOwnershipFact;
pub const SymbolIdentity = mir_model.SymbolIdentity;
pub const SourceIdentity = mir_model.SourceIdentity;
pub const SpanIdentity = mir_model.SpanIdentity;
pub const TypeIdentity = mir_model.TypeIdentity;
pub const ExecutableBinaryOp = mir_model.ExecutableBinaryOp;
pub const ExecutableArithmeticSemantics = mir_model.ExecutableArithmeticSemantics;
pub const ValueIdentity = mir_model.ValueIdentity;
pub const OwnershipEventKind = mir_model.OwnershipEventKind;
pub const OwnershipLoanKind = mir_model.OwnershipLoanKind;
pub const OwnershipPlaceProjection = mir_model.OwnershipPlaceProjection;
pub const OwnershipPlace = mir_model.OwnershipPlace;
pub const OwnershipEvent = mir_model.OwnershipEvent;
pub const CleanupActionKind = mir_model.CleanupActionKind;
pub const CleanupActionPlanEntry = mir_model.CleanupActionPlanEntry;
pub const CleanupCancellationKind = mir_model.CleanupCancellationKind;
pub const CleanupCancellationPlanEntry = mir_model.CleanupCancellationPlanEntry;
pub const OwnershipCleanupPlan = mir_model.OwnershipCleanupPlan;
pub const OwnershipCleanupEdgeKind = mir_model.OwnershipCleanupEdgeKind;
pub const OwnershipCleanupEdgeActionRef = mir_model.OwnershipCleanupEdgeActionRef;
pub const OwnershipCleanupEdge = mir_model.OwnershipCleanupEdge;
pub const OwnershipCleanupEdgeTable = mir_model.OwnershipCleanupEdgeTable;
pub const DeferCleanupEdgeKind = mir_model.DeferCleanupEdgeKind;
pub const DeferCleanupEdgeActionRef = mir_model.DeferCleanupEdgeActionRef;
pub const DeferCleanupEdge = mir_model.DeferCleanupEdge;
pub const DeferCleanupEdgeTable = mir_model.DeferCleanupEdgeTable;
pub const CleanupCfgEdgeKind = mir_model.CleanupCfgEdgeKind;
pub const CleanupCfgActionRef = mir_model.CleanupCfgActionRef;
pub const CleanupCfgEdge = mir_model.CleanupCfgEdge;
pub const CleanupCfg = mir_model.CleanupCfg;
pub const PointerProvenanceInvalidationPolicy = mir_model.PointerProvenanceInvalidationPolicy;
pub const PointerProvenanceInvalidationReason = mir_model.PointerProvenanceInvalidationReason;
pub const Block = mir_model.Block;
pub const BodyId = mir_model.BodyId;
pub const InstId = mir_model.InstId;
pub const ExprId = mir_model.ExprId;
pub const LocalId = mir_model.LocalId;
pub const PlaceId = mir_model.PlaceId;
pub const CleanupActionId = mir_model.CleanupActionId;
pub const ExecutableParameter = mir_model.ExecutableParameter;
pub const ExecutableLocalKind = mir_model.ExecutableLocalKind;
pub const ExecutableLocalIdentity = mir_model.ExecutableLocalIdentity;
pub const ExecutableExpression = mir_model.ExecutableExpression;
pub const ExecutableAtomicOrdering = mir_model.ExecutableAtomicOrdering;
pub const ExecutableMmioOrdering = mir_model.ExecutableMmioOrdering;
pub const ExecutablePlaceStorage = mir_model.ExecutablePlaceStorage;
pub const ExecutableTrapOwner = mir_model.ExecutableTrapOwner;
pub const ExecutableTrapEdge = mir_model.ExecutableTrapEdge;
pub const ExecutablePlace = mir_model.ExecutablePlace;
pub const ExecutableAggregatePointerFieldDeref = mir_model.ExecutableAggregatePointerFieldDeref;
pub const executableAggregatePointerFieldDerefPlace = mir_model.executableAggregatePointerFieldDerefPlace;
pub const ExecutableStatement = mir_model.ExecutableStatement;
pub const ExecutableTerminator = mir_model.ExecutableTerminator;
pub const ExecutableCleanupAction = mir_model.ExecutableCleanupAction;
pub const ExecutableBody = mir_model.ExecutableBody;
pub const executableCheckedBinaryTrapRequirements = mir_model.executableCheckedBinaryTrapRequirements;
pub const CallableKind = mir_model.CallableKind;
pub const CheckedCallableFact = mir_model.CheckedCallableFact;
pub const CallableEmissionFact = mir_model.CallableEmissionFact;
pub const CallableParameterEmissionFact = mir_model.CallableParameterEmissionFact;
pub const CheckedGlobalFact = mir_model.CheckedGlobalFact;
pub const ConstScalarValue = mir_model.ConstScalarValue;
pub const GlobalInitializerFact = mir_model.GlobalInitializerFact;
pub const AtomicInitializerPlan = mir_model.AtomicInitializerPlan;
pub const GlobalAddressInitializerPlan = mir_model.GlobalAddressInitializerPlan;
pub const FunctionSymbolInitializerPlan = mir_model.FunctionSymbolInitializerPlan;
pub const StringBackingId = mir_model.StringBackingId;
pub const StringBytesInitializerPlan = mir_model.StringBytesInitializerPlan;
pub const AggregateInitializerPlan = mir_model.AggregateInitializerPlan;
pub const EnumInitializerPlan = mir_model.EnumInitializerPlan;
pub const valueTypeRequiresScalarGlobalInitializerFact = mir_model.valueTypeRequiresScalarGlobalInitializerFact;
pub const Function = mir_model.Function;
pub const Module = mir_model.Module;
pub const BuildOptions = mir_model.BuildOptions;

/// Converts a checked scalar-global fact to the evaluator's value domain for
/// residual const evaluation. Codegen uses the same admitted MIR fact for its
/// declaration renderer; it must not recreate the value from AST syntax.
pub fn comptimeValueFromGlobalInitializerFact(fact: GlobalInitializerFact) eval.ComptimeValue {
    return switch (fact.scalarValue()) {
        .int => |value| .{ .int = value },
        .uint => |value| .{ .uint = value },
        .boolean => |value| .{ .boolean = value },
        .float => |value| .{ .float = .{ .bits = value.bits, .width = value.width } },
    };
}
const addressClassName = mir_model.addressClassName;

const FunctionSummary = mir_summary.FunctionSummary;
const EnumSummary = mir_summary.EnumSummary;
const StructSummary = mir_summary.StructSummary;
const UnionSummary = mir_summary.UnionSummary;
const PackedBitsSummary = mir_summary.PackedBitsSummary;
const MirReflectEnv = mir_summary.ReflectEnv;

pub fn executableAggregateConstruction(summary: StructSummary) AggregateConstructionKind {
    return if (summary.is_c_union) .c_union else .declared_struct;
}

const directCalleeName = mir_syntax.directCalleeName;
const directIdentName = mir_syntax.directIdentName;
const exprTerminates = mir_syntax.exprTerminates;
const exprText = mir_syntax.exprText;
const enumLiteralText = mir_syntax.enumLiteralText;
const isTrapCall = mir_syntax.isTrapCall;
const isUnwrapCall = mir_syntax.isUnwrapCall;
const assignmentTargetIdentName = mir_syntax.assignmentTargetIdentName;
const patternText = mir_syntax.patternText;
const typeText = mir_syntax.typeText;
const ConversionContext = mir_verify_util.ConversionContext;
const IrqContextCallFinding = mir_verify_util.IrqContextCallFinding;
const MmioOperation = mir_verify_util.MmioOperation;
const MmioAccessInfo = mir_verify_util.MmioAccessInfo;
const ArithmeticDomain = mir_verify_util.ArithmeticDomain;
const irqContextFindingName = mir_verify_util.irqContextFindingName;
const irqContextDiagnostic = mir_verify_util.irqContextDiagnostic;
const contractAllowsUnchecked = mir_verify_util.contractAllowsUnchecked;
const noOverflowUncheckedOp = mir_verify_util.noOverflowUncheckedOp;
const hasAttr = mir_verify_util.hasAttr;
const nullabilityDiagnostic = mir_verify_util.nullabilityDiagnostic;
const conversionDiagnostic = mir_verify_util.conversionDiagnostic;
const aggregateDiagnostic = mir_verify_util.aggregateDiagnostic;
const resultFindingDiagnostic = mir_verify_util.resultFindingDiagnostic;
const switchFindingDiagnostic = mir_verify_util.switchFindingDiagnostic;
const assignmentFindingDiagnostic = mir_verify_util.assignmentFindingDiagnostic;
const arithmeticDomainFindingDiagnostic = mir_verify_util.arithmeticDomainFindingDiagnostic;
const operatorFindingDiagnostic = mir_verify_util.operatorFindingDiagnostic;
const addressDerefDiagnostic = mir_verify_util.addressDerefDiagnostic;
const addressClassMismatchDiagnostic = mir_verify_util.addressClassMismatchDiagnostic;
const ffiFindingDiagnostic = mir_verify_util.ffiFindingDiagnostic;
const usageFindingDiagnostic = mir_verify_util.usageFindingDiagnostic;
const isRepresentationSensitiveProducer = mir_representation.isSensitiveProducer;
const isRepresentationSensitiveUse = mir_representation.isSensitiveUse;
const defaultInstructionValueId = mir_representation.defaultInstructionValueId;
const producerHasDominatingRepresentationCheck = mir_representation.producerHasDominatingCheck;
const useHasDominatingRepresentationCheck = mir_representation.useHasDominatingCheck;
const representationCheckKind = mir_representation.checkKind;
const representationTypeName = mir_representation.typeName;
const representationCheckTraps = mir_representation.checkTraps;
const isVoidLike = mir_type.isVoidLike;
const nullabilityFinding = mir_type.nullabilityFinding;
const conversionFinding = mir_type.conversionFinding;
const integerLiteralRangeFinding = mir_type.integerLiteralRangeFinding;
const integerLiteralFitsTarget = mir_type.integerLiteralFitsTarget;
const checkedIntBoundsByName = mir_type.checkedIntBoundsByName;
const isDynTraitMirType = mir_type.isDynTraitMirType;
const isViewConstNarrowCast = mir_type.isViewConstNarrowCast;
const valueTypeFromExpr = mir_type.valueTypeFromExpr;
const valueTypeFromType = mir_type.valueTypeFromType;
const valueTypeFromTypeAlias = mir_type.valueTypeFromTypeAlias;
const valueTypeFromTypeName = mir_type.valueTypeFromTypeName;
const valueTypeFromTypeNameAlias = mir_type.valueTypeFromTypeNameAlias;
const aggregateTargetType = mir_type.aggregateTargetType;
const aggregateTargetTypeAlias = mir_type.aggregateTargetTypeAlias;
const arrayElementType = mir_type.arrayElementType;
const arrayElementTypeAlias = mir_type.arrayElementTypeAlias;
const storageElementTypeAlias = mir_type.storageElementTypeAlias;
const sliceTypeForBaseAlias = mir_type.sliceTypeForBaseAlias;
const tryPayloadTypeExprAlias = mir_type.tryPayloadTypeExprAlias;
const resultPayloadTypeExprAlias = mir_type.resultPayloadTypeExprAlias;
const structTypeNameAlias = mir_type.structTypeNameAlias;
const isDynTraitTypeAlias = mir_type.isDynTraitTypeAlias;
const unionTypeNameAlias = mir_type.unionTypeNameAlias;
const pointerShape = mir_type.pointerShape;
const pointerShapeAlias = mir_type.pointerShapeAlias;
const nullPointerShape = mir_type.nullPointerShape;
const pointerShapeFromName = mir_type.pointerShapeFromName;
const addressClassFromName = mir_type.addressClassFromName;
const isWrapTypeAlias = mir_type.isWrapTypeAlias;
const isSatTypeAlias = mir_type.isSatTypeAlias;
const arithmeticDomainTypeAlias = mir_type.arithmeticDomainTypeAlias;
const isTryCapableType = mir_type.isTryCapableType;
const isResultType = mir_type.isResultType;
const isMirNullableValue = mir_type.isMirNullableValue;
const isMirEnum = mir_type.isMirEnum;
const isMirIntegerLike = mir_type.isMirIntegerLike;
const unknownResultType = mir_type.unknownResultType;
const mirTypesAreCompatible = mir_type.typesAreCompatible;
const isMirForIterable = mir_type.isMirForIterable;
const isMirIndexableBase = mir_type.isMirIndexableBase;
const isMirIndexType = mir_type.isMirIndexType;
const isPointerViewConversion = mir_type.isPointerViewConversion;
const isCVoidPointerConversion = mir_type.isCVoidPointerConversion;
const isCVoidPointerType = mir_type.isCVoidPointerType;
const isPointerLikeType = mir_type.isPointerLikeType;
const samePointerShape = mir_type.samePointerShape;
const isNullPointerShape = mir_type.isNullPointerShape;
const addressClassMismatch = mir_type.addressClassMismatch;
const binaryMayOverflow = mir_operator.binaryMayOverflow;
const binaryTrapKind = mir_operator.binaryTrapKind;
const isShiftOp = mir_operator.isShiftOp;
const binaryChecksAddressClass = mir_operator.binaryChecksAddressClass;
const mirIsArithmeticBinary = mir_operator.isArithmeticBinary;
const mirIsBitwiseBinary = mir_operator.isBitwiseBinary;
const mirIsLogicalBinary = mir_operator.isLogicalBinary;
const mirIsOrderedComparison = mir_operator.isOrderedComparison;
const mirIsPointerArithmetic = mir_operator.isPointerArithmetic;
const isMirSingleObjectPointer = mir_operator.isSingleObjectPointer;
const isMirPointerOrView = mir_operator.isPointerOrView;
const isMirCVoidPointer = mir_operator.isCVoidPointer;
const isMirForbiddenOrderingDomain = mir_operator.isForbiddenOrderingDomain;
const mirIsComparisonBinary = mir_operator.isComparisonBinary;
const logicalOperandsAllowed = mir_operator.logicalOperandsAllowed;
const unaryNegOperandAllowed = mir_operator.unaryNegOperandAllowed;
const bitwiseOperandAllowed = mir_operator.bitwiseOperandAllowed;
const checkedIntegerBinaryFinding = mir_operator.checkedIntegerBinaryFinding;
const floatBinaryFinding = mir_operator.floatBinaryFinding;
const isCheckedUnsignedType = mir_operator.isCheckedUnsignedType;
const isCheckedSignedType = mir_operator.isCheckedSignedType;

pub fn dynTraitNameFromTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return dynTraitNameFromTypeAliasDepth(ty, aliases, 0);
}

// TargetTypeFact has one owner/index pair. Reserve a compact, target-independent
// index namespace for trait-object fixed arguments: the owner is the trait name,
// the high bits identify the vtable slot, and the low bits identify the explicit
// argument position. The bound is far beyond any supported trait signature while
// keeping the identity stable on 32-bit hosts too.
pub fn dynDispatchArgumentFactIndex(method_index: usize, argument_index: usize) usize {
    const bits = 16;
    return (method_index << bits) | argument_index;
}

fn dynTraitNameFromTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .dyn_trait => |dyn| dyn.trait_name.text,
        .name => |name| if (aliases.get(name.text)) |resolved| dynTraitNameFromTypeAliasDepth(resolved, aliases, depth + 1) else null,
        .qualified => |node| dynTraitNameFromTypeAliasDepth(node.child.*, aliases, depth + 1),
        .nullable => |child| dynTraitNameFromTypeAliasDepth(child.*, aliases, depth + 1),
        .pointer => |node| dynTraitNameFromTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn representationFactKind(kind: Instruction.Kind, ty: ValueType) bool {
    return switch (kind) {
        .representation_check, .representation_use => true,
        .typed_load => representationCheckKind(ty) != null,
        else => false,
    };
}

pub fn integerFactLiteralText(expr: ast.Expr) []const u8 {
    return switch (expr.kind) {
        .grouped => |inner| integerFactLiteralText(inner.*),
        .cast => |node| integerFactLiteralText(node.value.*),
        .int_literal => |text| text,
        .char_literal => |text| text,
        else => exprText(expr),
    };
}

pub fn floatFactLiteralText(expr: ast.Expr) []const u8 {
    return switch (expr.kind) {
        .grouped => |inner| floatFactLiteralText(inner.*),
        .cast => |node| floatFactLiteralText(node.value.*),
        .float_literal => |text| text,
        else => exprText(expr),
    };
}

pub fn functionFallsThrough(function: Function) ?SourcePoint {
    if (isVoidLike(function.return_ty)) return null;
    var stack_buf: [512]usize = undefined;
    var seen_buf: [512]bool = [_]bool{false} ** 512;
    if (function.blocks.len > stack_buf.len or function.blocks.len == 0) return null;

    var stack_len: usize = 1;
    stack_buf[0] = 0;
    seen_buf[0] = true;

    while (stack_len > 0) {
        stack_len -= 1;
        const id = stack_buf[stack_len];
        const block = function.blocks[id];
        if (block.successors.len == 0 and block.terminator == .fallthrough) return blockLastSpan(function, block);
        for (block.successors) |successor| {
            if (!successor.isValid() or successor.index() >= function.blocks.len or seen_buf[successor.index()]) continue;
            seen_buf[successor.index()] = true;
            stack_buf[stack_len] = successor.index();
            stack_len += 1;
        }
    }
    return null;
}

pub fn cfgHasStructuralError(function: Function) ?SourcePoint {
    if (function.blocks.len == 0) return null;
    for (function.blocks, 0..) |block, block_index| {
        if (!block.id.isValid() or block.id.index() != block_index) return blockLastSpan(function, block);
        for (block.successors) |successor| {
            if (!successor.isValid() or successor.index() >= function.blocks.len or !function.blocks[successor.index()].id.eql(successor)) return blockLastSpan(function, block);
        }
        if (!terminatorSuccessorsAreConsistent(function, block)) return blockLastSpan(function, block);
    }
    for (function.trap_edges) |edge| {
        const source = sourcePointForSpanId(function, edge.typed_span_id) orelse return .{ .line = 0, .column = 0 };
        if (!edge.from_block.isValid() or !edge.trap_block.isValid() or edge.from_block.index() >= function.blocks.len or edge.trap_block.index() >= function.blocks.len) {
            return source;
        }
        const from = function.blocks[edge.from_block.index()];
        if (!successorListed(from, edge.trap_block)) return source;
        const trap_block = function.blocks[edge.trap_block.index()];
        switch (trap_block.terminator) {
            .trap_ => |trap_kind| if (trap_kind != edge.kind) return source,
            else => return source,
        }
    }
    return null;
}

pub fn verifyFunctionCfg(function: Function, reporter: *diagnostics.Reporter) void {
    if (cfgHasStructuralError(function)) |point| {
        reporter.err(
            sourcePointSpan(point),
            "E_MIR_CFG: MIR verifier found malformed control-flow graph",
            .{},
        );
    }
}

fn terminatorSuccessorsAreConsistent(function: Function, block: Block) bool {
    return switch (block.terminator) {
        .fallthrough => normalSuccessorCount(function, block) == 0,
        .jump => |target| (normalSuccessorCount(function, block) == 1 and normalSuccessorListed(function, block, target)) or
            terminalTrapSuccessor(function, block, target),
        .branch => |branch| normalSuccessorCount(function, block) == 2 and
            successorListed(block, branch.true_block) and
            successorListed(block, branch.false_block),
        .return_, .trap_, .unreachable_ => normalSuccessorCount(function, block) == 0,
        .switch_ => normalSuccessorCount(function, block) > 0,
    };
}

fn terminalTrapSuccessor(function: Function, block: Block, target: BlockId) bool {
    if (block.successors.len != 1 or !block.successors[0].eql(target)) return false;
    for (function.trap_edges) |edge| {
        if (!edge.from_block.eql(block.id) or !edge.trap_block.eql(target)) continue;
        return edge.source == .explicit_trap or edge.source == .unreachable_expr;
    }
    return false;
}

fn normalSuccessorCount(function: Function, block: Block) usize {
    var count: usize = 0;
    for (block.successors) |successor| {
        if (!isTrapSuccessor(function, block.id, successor)) count += 1;
    }
    return count;
}

fn normalSuccessorListed(function: Function, block: Block, target: BlockId) bool {
    return successorListed(block, target) and !isTrapSuccessor(function, block.id, target);
}

fn isTrapSuccessor(function: Function, from_block: BlockId, to_block: BlockId) bool {
    for (function.trap_edges) |edge| {
        if (edge.from_block.eql(from_block) and edge.trap_block.eql(to_block)) return true;
    }
    return false;
}

fn successorListed(block: Block, target: BlockId) bool {
    for (block.successors) |successor| {
        if (successor.eql(target)) return true;
    }
    return false;
}

fn blockLastSpan(function: Function, block: Block) SourcePoint {
    if (block.instructions.len == 0) return .{ .line = 0, .column = 0 };
    const last = block.instructions[block.instructions.len - 1];
    return instructionSourcePoint(function, last) orelse .{ .line = 0, .column = 0 };
}

fn functionByName(module: Module, name: []const u8) ?Function {
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn calleeIsIrqContext(module: Module, name: []const u8) bool {
    const callee = functionByName(module, name) orelse return false;
    return callee.irq_context;
}

pub fn irqContextCallFinding(module: Module, function: Function, instruction: Instruction) ?IrqContextCallFinding {
    if (!function.irq_context) return null;
    if (instruction.kind != .call and instruction.kind != .indirect_call) return null;
    if (isNonBlockingPrimitive(instruction.detail)) return null;
    if (isKnownBlockingIrqCallee(instruction.detail)) return .blocking;
    if (instruction.kind == .indirect_call or !calleeIsIrqContext(module, instruction.detail)) return .unproven_call;
    return null;
}

pub fn uncheckedAssumeHasMatchingContract(function: Function, instruction: Instruction) bool {
    const region_id = instruction.contract_region_id orelse return false;
    for (function.contract_regions) |region| {
        if (region.id != region_id) continue;
        return contractAllowsUnchecked(region.kind, instruction.detail);
    }
    return false;
}

pub fn switchBoolLiteralValue(expr: ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_literal => |value| value,
        .grouped => |inner| switchBoolLiteralValue(inner.*),
        else => null,
    };
}

pub fn enumContainsCase(info: EnumSummary, case_name: []const u8) bool {
    for (info.cases) |case| {
        if (std.mem.eql(u8, case.name.text, case_name)) return true;
    }
    return false;
}

pub fn switchCoversAllMirEnumCases(node: ast.Switch, info: EnumSummary) bool {
    for (info.cases) |case| {
        if (!switchCoversMirEnumCase(node, case.name.text)) return false;
    }
    return true;
}

fn switchCoversMirEnumCase(node: ast.Switch, case_name: []const u8) bool {
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

pub fn isArrayTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isArrayTypeAliasDepth(ty, aliases, 0);
}

fn isArrayTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isArrayTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .array => true,
        .qualified => |node| isArrayTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

pub fn isConstStorageTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isConstStorageTypeAliasDepth(ty, aliases, 0);
}

fn isConstStorageTypeAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isConstStorageTypeAliasDepth(resolved, aliases, depth + 1) else false,
        .pointer => |node| node.mutability == .@"const",
        .raw_many_pointer => |node| node.mutability == .@"const",
        .slice => |node| node.mutability == .@"const",
        .qualified => |node| isConstStorageTypeAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

pub fn unionContainsCase(info: UnionSummary, case_name: []const u8) bool {
    for (info.cases) |case| {
        if (std.mem.eql(u8, case.name.text, case_name)) return true;
    }
    return false;
}

pub fn unionCasePayloadType(info: UnionSummary, case_name: []const u8) ?ast.TypeExpr {
    for (info.cases) |case| {
        if (std.mem.eql(u8, case.name.text, case_name)) return case.ty;
    }
    return null;
}

pub fn exprContainsTargetTypedLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        // Integer literals, including `-N`, acquire their storage type from a
        // typed binary sibling. This lets MIR own the unary result rather than
        // leaving C/LLVM to choose the literal's C default type.
        .int_literal, .char_literal, .enum_literal, .string_literal, .float_literal, .null_literal => true,
        .grouped => |inner| exprContainsTargetTypedLiteral(inner.*),
        .unary => |node| exprContainsTargetTypedLiteral(node.expr.*),
        else => false,
    };
}

pub fn canonicalNegatedIntegerLiteral(input: ast.Expr, ty: ValueType) ?i128 {
    const info = mir_model.ExecutableCastKind.integerInfo(ty) orelse return null;
    if (!info.signed) return null;
    var expr = input;
    while (expr.kind == .grouped) expr = expr.kind.grouped.*;
    const literal = switch (expr.kind) {
        .int_literal => |value| value,
        else => return null,
    };
    const parts = numeric.parseIntegerLiteralParts(literal) orelse return null;
    const limit = @as(u128, 1) << @intCast(info.bits - 1);
    if (parts.magnitude > limit) return null;
    if (info.bits == 128 and parts.magnitude == limit) return std.math.minInt(i128);
    return -@as(i128, @intCast(parts.magnitude));
}

pub fn mmioMapPayloadTypeForExpr(expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .call => |call| mmioMapCallPayloadType(call),
        .grouped => |inner| mmioMapPayloadTypeForExpr(inner.*),
        else => null,
    };
}

pub fn reduceCallReturnTypeExpr(call: anytype) ?ast.TypeExpr {
    const kind = reduceCallKind(call.callee.*) orelse return null;
    if (call.type_args.len != 1) return null;
    return switch (kind) {
        .sum_checked => null,
        .sum_left, .sum_fast => call.type_args[0],
    };
}

pub fn reduceCallValueType(call: anytype, enums: *const std.StringHashMap(EnumSummary), structs: *const std.StringHashMap(StructSummary), packed_bits: *const std.StringHashMap(PackedBitsSummary), aliases: *const std.StringHashMap(ast.TypeExpr)) ?ValueType {
    const kind = reduceCallKind(call.callee.*) orelse return null;
    if (call.type_args.len != 1) return null;
    return switch (kind) {
        .sum_checked => .{ .result = .{ .ok = typeText(call.type_args[0]), .err = "Overflow" } },
        .sum_left, .sum_fast => valueTypeFromTypeAlias(call.type_args[0], enums, structs, packed_bits, aliases),
    };
}

pub fn dmaBufModeName(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return dmaBufModeNameDepth(ty, aliases, 0);
}

fn dmaBufModeNameDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |n| if (aliases.get(n.text)) |t| dmaBufModeNameDepth(t, aliases, depth + 1) else null,
        .qualified => |node| dmaBufModeNameDepth(node.child.*, aliases, depth + 1),
        .generic => |node| if (std.mem.eql(u8, node.base.text, "DmaBuf") and node.args.len == 2)
            (switch (node.args[1].kind) {
                .enum_literal => |id| id.text,
                else => null,
            })
        else
            null,
        else => null,
    };
}

pub fn isMirIntegerType(ty: ValueType) bool {
    return ty == .integer;
}

// bitcast operands must have a fixed scalar/pointer/address layout (section 15);
// `.unknown` is treated as valid to avoid false positives.
pub fn isMirBitcastLayout(ty: ValueType) bool {
    return switch (ty) {
        .integer, .float, .bool, .cstr, .pointer, .nullable_pointer, .address, .unknown => true,
        else => false,
    };
}

pub fn isMirBitcastCallee(callee: ast.Expr) bool {
    const name = calleeIdentName(callee) orelse return false;
    return std.mem.eql(u8, name, "bitcast");
}

pub fn isMirMmioReadOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "acquire");
}

pub fn isMirMmioWriteOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "release");
}

pub fn isMirAtomicLoadOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "acquire") or std.mem.eql(u8, o, "seq_cst");
}

pub fn isMirAtomicStoreOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "release") or std.mem.eql(u8, o, "seq_cst");
}

pub fn isMirAtomicOrdering(o: []const u8) bool {
    return std.mem.eql(u8, o, "relaxed") or std.mem.eql(u8, o, "acquire") or
        std.mem.eql(u8, o, "release") or std.mem.eql(u8, o, "acq_rel") or std.mem.eql(u8, o, "seq_cst");
}

pub fn isAtomicTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) bool {
    return isAtomicTypeExprAliasDepth(ty, aliases, 0);
}

fn isAtomicTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) bool {
    if (depth > 64) return false;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| isAtomicTypeExprAliasDepth(resolved, aliases, depth + 1) else false,
        .generic => |node| std.mem.eql(u8, node.base.text, "atomic"),
        .qualified => |node| isAtomicTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => false,
    };
}

pub fn atomicPayloadTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return directAtomicPayloadTypeExprAlias(ty, aliases, true);
}

pub fn directAtomicPayloadTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), allow_pointer: bool) ?ast.TypeExpr {
    return atomicPayloadTypeExprAliasDepth(ty, aliases, 0, allow_pointer);
}

pub fn executableAtomicOrdering(expr: ast.Expr) ?mir_model.ExecutableAtomicOrdering {
    const spelling = enumLiteralText(expr) orelse return null;
    if (std.mem.eql(u8, spelling, "relaxed")) return .relaxed;
    if (std.mem.eql(u8, spelling, "acquire")) return .acquire;
    if (std.mem.eql(u8, spelling, "release")) return .release;
    if (std.mem.eql(u8, spelling, "acq_rel")) return .acq_rel;
    if (std.mem.eql(u8, spelling, "seq_cst")) return .seq_cst;
    return null;
}

pub fn executableMmioOrdering(expr: ast.Expr) ?mir_model.ExecutableMmioOrdering {
    const spelling = enumLiteralText(expr) orelse return null;
    if (std.mem.eql(u8, spelling, "relaxed")) return .relaxed;
    if (std.mem.eql(u8, spelling, "acquire")) return .acquire;
    if (std.mem.eql(u8, spelling, "release")) return .release;
    return null;
}

pub fn executableMmioStorageSupported(ty: ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
            std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64"),
        else => false,
    };
}

pub fn executableAtomicPayloadSupported(ty: ValueType) bool {
    return switch (ty) {
        .bool => true,
        .integer => mir_model.ExecutableMemoryAccess.scalarAlignment(ty) != null,
        else => false,
    };
}

pub fn executableClosureCaptureEncoding(ty: ValueType) ?mir_model.ExecutableClosureCaptureEncoding {
    return switch (ty) {
        .pointer => |shape| if (shape.kind == .slice) null else .pointer,
        .integer => |name| if ((scalar_repr.integer(name) orelse return null).bits <= 64) .integer else null,
        .domain_integer => |shape| if ((scalar_repr.integer(shape.child) orelse return null).bits <= 64) .integer else null,
        else => null,
    };
}

fn atomicPayloadTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize, allow_pointer: bool) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| atomicPayloadTypeExprAliasDepth(resolved, aliases, depth + 1, allow_pointer) else null,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "atomic") and node.args.len == 1) node.args[0] else null,
        .pointer => |node| if (!allow_pointer) null else atomicPayloadTypeExprAliasDepth(node.child.*, aliases, depth + 1, false),
        .qualified => |node| atomicPayloadTypeExprAliasDepth(node.child.*, aliases, depth + 1, allow_pointer),
        else => null,
    };
}

pub fn maybeUninitPayloadTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return maybeUninitPayloadTypeExprAliasDepth(ty, aliases, 0);
}

fn maybeUninitPayloadTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| maybeUninitPayloadTypeExprAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| if (std.mem.eql(u8, node.base.text, "MaybeUninit") and node.args.len == 1) node.args[0] else null,
        .qualified => |node| maybeUninitPayloadTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn mmioRegisterAccessFromTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?MmioRegisterAccess {
    return mmioRegisterAccessFromTypeExprAliasDepth(ty, aliases, 0);
}

pub fn mmioRegisterReadValueTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return mmioRegisterReadValueTypeExprAliasDepth(ty, aliases, 0);
}

pub fn mmioRegisterStorageTypeExprAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?ast.TypeExpr {
    return mmioRegisterStorageTypeExprAliasDepth(ty, aliases, 0);
}

fn mmioRegisterStorageTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| mmioRegisterStorageTypeExprAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| if ((std.mem.eql(u8, node.base.text, "Reg") and node.args.len == 2) or
            (std.mem.eql(u8, node.base.text, "RegBits") and node.args.len == 3)) node.args[0] else null,
        .qualified => |node| mmioRegisterStorageTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn mmioRegisterReadValueTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| mmioRegisterReadValueTypeExprAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| blk: {
            if (std.mem.eql(u8, node.base.text, "Reg") and node.args.len == 2) break :blk node.args[0];
            if (std.mem.eql(u8, node.base.text, "RegBits") and node.args.len == 3) break :blk node.args[1];
            break :blk null;
        },
        .qualified => |node| mmioRegisterReadValueTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn mmioRegisterAccessFromTypeExprAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?MmioRegisterAccess {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| mmioRegisterAccessFromTypeExprAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| blk: {
            const access_ty: ast.TypeExpr = if (std.mem.eql(u8, node.base.text, "Reg") and node.args.len == 2)
                node.args[1]
            else if (std.mem.eql(u8, node.base.text, "RegBits") and node.args.len == 3)
                node.args[2]
            else
                break :blk null;
            break :blk mmioRegisterAccessFromModeType(access_ty);
        },
        .qualified => |node| mmioRegisterAccessFromTypeExprAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn mmioPtrTargetTypeNameAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return mmioPtrTargetTypeNameAliasDepth(ty, aliases, 0);
}

fn mmioPtrTargetTypeNameAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| mmioPtrTargetTypeNameAliasDepth(resolved, aliases, depth + 1) else null,
        .generic => |node| blk: {
            if (!std.mem.eql(u8, node.base.text, "MmioPtr") or node.args.len != 1) break :blk null;
            break :blk structTypeNameAlias(node.args[0], aliases);
        },
        .qualified => |node| mmioPtrTargetTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

pub fn isUncheckedCall(callee: ast.Expr) bool {
    if (memberExpr(callee)) |member| {
        const base_name = calleeIdentName(member.base.*) orelse return false;
        return std.mem.eql(u8, base_name, "unchecked") or
            (std.mem.eql(u8, base_name, "compiler") and std.mem.eql(u8, member.name.text, "assume_noalias_unchecked"));
    }
    const name = calleeIdentName(callee) orelse return false;
    return std.mem.startsWith(u8, name, "unchecked_") or std.mem.eql(u8, name, "assume_noalias_unchecked");
}

pub fn wrappingAddCall(callee: ast.Expr) bool {
    const member = memberExpr(callee) orelse return false;
    return ast_query.isIdentNamed(member.base.*, "wrapping") and std.mem.eql(u8, member.name.text, "add");
}

pub fn reflectionCallPreservesPointerProvenance(call: anytype) bool {
    const kind = reflectionKind(call.callee.*) orelse return false;
    if (call.type_args.len != 1) return false;
    const expected_args: usize = if (reflectionRequiresField(kind)) 1 else 0;
    return call.args.len == expected_args;
}

pub fn explicitTrapCallTargetKind(call: anytype) ?CallTargetKind {
    if (!isTrapCall(call.callee.*) or call.type_args.len != 0 or call.args.len != 1) return null;
    const name = explicitTrapReasonName(call.args[0]) orelse return null;
    if (std.mem.eql(u8, name, "Bounds")) return .trap_bounds;
    if (std.mem.eql(u8, name, "NullUnwrap")) return .trap_null_unwrap;
    if (std.mem.eql(u8, name, "IntegerOverflow")) return .trap_integer_overflow;
    if (std.mem.eql(u8, name, "DivideByZero")) return .trap_divide_by_zero;
    if (std.mem.eql(u8, name, "InvalidShift")) return .trap_invalid_shift;
    if (std.mem.eql(u8, name, "InvalidRepresentation")) return .trap_invalid_representation;
    if (std.mem.eql(u8, name, "Assert")) return .trap_assert;
    if (std.mem.eql(u8, name, "Unreachable")) return .trap_unreachable;
    return null;
}

pub const TerminalTrap = struct {
    kind: TrapKind,
    source: TrapSource,
};

pub fn terminalTrapForExpr(input: ast.Expr) ?TerminalTrap {
    var expr = input;
    while (expr.kind == .grouped or expr.kind == .move_expr) expr = switch (expr.kind) {
        .grouped => |inner| inner.*,
        .move_expr => |inner| inner.*,
        else => unreachable,
    };
    return switch (expr.kind) {
        .unreachable_expr => .{ .kind = .Unreachable, .source = .unreachable_expr },
        .call => |call| .{
            .kind = explicitTrapKindForTarget(explicitTrapCallTargetKind(call) orelse return null) orelse return null,
            .source = .explicit_trap,
        },
        else => null,
    };
}

pub fn executableExprIsVoidLiteral(input: ast.Expr) bool {
    return switch (input.kind) {
        .void_literal => true,
        .grouped, .move_expr => |inner| executableExprIsVoidLiteral(inner.*),
        else => false,
    };
}

pub const explicitTrapKindForTarget = mir_model.explicitTrapKindForTarget;

fn explicitTrapReasonName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| explicitTrapReasonName(inner.*),
        else => null,
    };
}

pub fn explicitTrapHelperForTarget(kind: CallTargetKind) ?[]const u8 {
    return switch (kind) {
        .trap_bounds => "mc_trap_Bounds",
        .trap_null_unwrap => "mc_trap_NullUnwrap",
        .trap_integer_overflow => "mc_trap_IntegerOverflow",
        .trap_divide_by_zero => "mc_trap_DivideByZero",
        .trap_invalid_shift => "mc_trap_InvalidShift",
        .trap_invalid_representation => "mc_trap_InvalidRepresentation",
        .trap_assert => "mc_trap_Assert",
        .trap_unreachable => "mc_trap_Unreachable",
        else => null,
    };
}

pub fn reflectionCallTargetKind(call: anytype) ?CallTargetKind {
    const kind = reflectionKind(call.callee.*) orelse return null;
    if (kind == .field_type or call.type_args.len != 1) return null;
    const expected_args: usize = if (reflectionRequiresField(kind)) 1 else 0;
    if (call.args.len != expected_args) return null;
    return switch (kind) {
        .size => .reflection_size,
        .alignment => .reflection_alignment,
        .field_offset => .reflection_field_offset,
        .bit_offset => .reflection_bit_offset,
        .repr => .reflection_repr,
        .field_type => unreachable,
    };
}

pub fn byteViewCallTargetKind(call: anytype) ?CallTargetKind {
    const kind = byteViewCallKind(call.callee.*) orelse return null;
    if (call.type_args.len != 0) return null;
    return switch (kind) {
        .as_bytes => if (call.args.len == 1) .byte_view_as_bytes else null,
        .bytes_equal => if (call.args.len == 2) .byte_view_equal else null,
    };
}

pub fn isUnsafeOperationCall(callee: ast.Expr) bool {
    const member = memberExpr(callee) orelse return false;
    if (exprIsIdentNamed(member.base.*, "raw") and std.mem.eql(u8, member.name.text, "store")) return true;
    if (exprIsIdentNamed(member.base.*, "mmio") and std.mem.eql(u8, member.name.text, "map")) return true;
    return false;
}

pub fn isRawManyPointerValue(ty: ValueType) bool {
    return switch (ty) {
        .pointer => |shape| shape.kind == .raw_many,
        else => false,
    };
}

fn isNonBlockingPrimitive(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "raw.") or
        std.mem.startsWith(u8, name, "mmio.") or
        std.mem.startsWith(u8, name, "atomic.") or
        std.mem.startsWith(u8, name, "raw_") or
        std.mem.startsWith(u8, name, "mmio_") or
        std.mem.startsWith(u8, name, "atomic_") or
        // Pure compiler builtins that emit no blocking work and no call: `phys`/`pa`
        // construct an address (an integer cast), `drop`/`forget_unchecked`
        // evaluate-and-discard a value (no destructor). All are legal on an
        // #[irq_context] path — sema already accepts them; the MIR verifier must agree.
        std.mem.eql(u8, name, "phys") or
        std.mem.eql(u8, name, "pa") or
        std.mem.eql(u8, name, "drop") or
        std.mem.eql(u8, name, "forget_unchecked");
}

fn isKnownBlockingIrqCallee(name: []const u8) bool {
    return std.mem.eql(u8, name, "lock.acquire") or
        std.mem.eql(u8, name, "heap.alloc") or
        std.mem.eql(u8, name, "device.wait_irq") or
        std.mem.eql(u8, name, "fs.read");
}

pub fn isKnownNoLanguageTrapPrimitive(name: []const u8) bool {
    return isNonBlockingPrimitive(name) or
        std.mem.startsWith(u8, name, "wrapping.") or
        std.mem.startsWith(u8, name, "saturating.") or
        std.mem.eql(u8, name, "ptr.offset");
}

// Trap behaviour of the scalar/domain builtin member methods (sections 3, 5).
// `trap_from` raises a range trap; the rest are pure casts/clamps/modular ops or
// return a `Result`, and never raise a language trap.
const ConversionTrap = enum { not_builtin, no_trap, traps };

pub fn conversionDomainCallTrap(callee: ast.Expr) ConversionTrap {
    const member = memberExpr(callee) orelse return .not_builtin;
    const m = member.name.text;
    if (std.mem.eql(u8, m, "trap_from")) return .traps;
    if (isMirConversionName(m) or isMirSerialOpName(m) or isMirCounterOpName(m) or std.mem.eql(u8, m, "residue")) return .no_trap;
    return .not_builtin;
}

pub fn isMirConversionName(m: []const u8) bool {
    return std.mem.eql(u8, m, "from") or
        std.mem.eql(u8, m, "try_from") or
        std.mem.eql(u8, m, "trap_from") or
        std.mem.eql(u8, m, "wrap_from") or
        std.mem.eql(u8, m, "sat_from") or
        std.mem.eql(u8, m, "from_mod");
}

pub fn conversionCallTargetKindForName(name: []const u8) ?CallTargetKind {
    if (std.mem.eql(u8, name, "from")) return .conversion_from;
    if (std.mem.eql(u8, name, "try_from")) return .conversion_try_from;
    if (std.mem.eql(u8, name, "trap_from")) return .conversion_trap_from;
    if (std.mem.eql(u8, name, "wrap_from")) return .conversion_wrap_from;
    if (std.mem.eql(u8, name, "sat_from")) return .conversion_sat_from;
    if (std.mem.eql(u8, name, "from_mod")) return .conversion_from_mod;
    return null;
}

pub fn isMirSerialOpName(m: []const u8) bool {
    return std.mem.eql(u8, m, "before") or
        std.mem.eql(u8, m, "after") or
        std.mem.eql(u8, m, "distance") or
        std.mem.eql(u8, m, "compare");
}

pub fn isMirCounterOpName(m: []const u8) bool {
    return std.mem.eql(u8, m, "delta_mod") or
        std.mem.eql(u8, m, "elapsed_assume_within") or
        std.mem.eql(u8, m, "elapsed_bounded");
}

pub fn domainStaticCallTargetKind(domain: ArithmeticDomain, op: []const u8) ?CallTargetKind {
    return switch (domain) {
        .serial => if (std.mem.eql(u8, op, "before"))
            .serial_before
        else if (std.mem.eql(u8, op, "after"))
            .serial_after
        else if (std.mem.eql(u8, op, "distance"))
            .serial_distance
        else if (std.mem.eql(u8, op, "compare"))
            .serial_compare
        else
            null,
        .counter => if (std.mem.eql(u8, op, "delta_mod"))
            .counter_delta_mod
        else if (std.mem.eql(u8, op, "elapsed_assume_within"))
            .counter_elapsed_assume_within
        else if (std.mem.eql(u8, op, "elapsed_bounded"))
            .counter_elapsed_bounded
        else
            null,
        .wrap, .sat => null,
    };
}

pub fn genericTypeExpr(base: []const u8, args: []ast.TypeExpr, span: ast.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = base, .span = span }, .args = args } } };
}

pub fn callResultRepresentationCheckTraps(name: []const u8) bool {
    return !std.mem.eql(u8, name, "ptr.offset");
}

pub fn pointerShapeFromValueType(ty: ValueType) ?PointerShape {
    return switch (ty) {
        .pointer => |shape| shape,
        .nullable_pointer => |shape| if (isNullPointerShape(shape)) null else shape,
        else => null,
    };
}

pub fn arrayLiteralItems(expr: ast.Expr) ?[]ast.Expr {
    return switch (expr.kind) {
        .array_literal => |items| items,
        .grouped => |inner| arrayLiteralItems(inner.*),
        .cast => |node| arrayLiteralItems(node.value.*),
        else => null,
    };
}

pub fn structLiteralFields(expr: ast.Expr) ?[]ast.StructLiteralField {
    return switch (expr.kind) {
        .struct_literal => |fields| fields,
        .grouped => |inner| structLiteralFields(inner.*),
        .cast => |node| structLiteralFields(node.value.*),
        else => null,
    };
}

pub fn structLiteralField(fields: []const ast.StructLiteralField, name: []const u8) ?ast.Expr {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name.text, name)) return field.value;
    }
    return null;
}

pub fn directStructTypeNameAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr)) ?[]const u8 {
    return directStructTypeNameAliasDepth(ty, aliases, 0);
}

fn directStructTypeNameAliasDepth(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?[]const u8 {
    if (depth > 64) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| directStructTypeNameAliasDepth(resolved, aliases, depth + 1) else name.text,
        .qualified => |node| directStructTypeNameAliasDepth(node.child.*, aliases, depth + 1),
        else => null,
    };
}

fn constIndexValue(expr: ast.Expr) ?usize {
    const value = integerLiteralValue(expr) orelse return null;
    if (value.negative or value.magnitude > std.math.maxInt(usize)) return null;
    return @intCast(value.magnitude);
}

pub fn dynamicIndexAssignmentSubject(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .grouped => |inner| dynamicIndexAssignmentSubject(inner.*),
        .index => |node| if (constIndexValue(node.index.*) == null) exprBaseIdentName(node.base.*) else null,
        else => null,
    };
}

pub fn exprBaseIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| exprBaseIdentName(inner.*),
        .member => |node| exprBaseIdentName(node.base.*),
        .index => |node| exprBaseIdentName(node.base.*),
        .deref => |inner| exprBaseIdentName(inner.*),
        else => null,
    };
}

pub fn isKnownDirectPrimitive(name: []const u8) bool {
    return isKnownNoLanguageTrapPrimitive(name) or
        std.mem.startsWith(u8, name, "unchecked.") or
        std.mem.startsWith(u8, name, "unchecked_") or
        std.mem.eql(u8, name, "compiler.assume_noalias_unchecked") or
        std.mem.eql(u8, name, "assume_noalias_unchecked");
}

pub fn isAssumeNoaliasDirectCall(call: anytype) bool {
    const name = directCalleeName(call.callee.*) orelse return false;
    return std.mem.eql(u8, name, "compiler.assume_noalias_unchecked") or
        std.mem.eql(u8, name, "assume_noalias_unchecked");
}

pub fn secretPayloadTypeAlias(ty: ast.TypeExpr, aliases: *const std.StringHashMap(ast.TypeExpr), depth: usize) ?ast.TypeExpr {
    if (depth > 32) return null;
    return switch (ty.kind) {
        .name => |name| if (aliases.get(name.text)) |resolved| secretPayloadTypeAlias(resolved, aliases, depth + 1) else null,
        .qualified => |node| secretPayloadTypeAlias(node.child.*, aliases, depth + 1),
        else => sema_builtin.secretPayloadType(ty),
    };
}

pub fn contractBlockEndLine(block: ast.Block) usize {
    if (block.items.len == 0) return block.span.line;
    return block.items[block.items.len - 1].span.line;
}
