//! Normalized function signature facts shared by declaration collection and
//! backend call/signature registries.

const ast_bridge = @import("ast_bridge.zig");
const mir = @import("mir_model.zig");

pub const FunctionParamFact = struct {
    name: ast_bridge.Ident,
    /// Canonical checked parameter type. Signature emission must prefer this
    /// value over the transitional syntax payload below.
    value_ty: mir.ValueType,
    /// Module-owned recursive type shape. This remains alongside `ty` during
    /// the declaration-artifact migration; renderers do not consume it yet.
    type_id: mir.SignatureTypeId = .invalid,
    ty: ast_bridge.TypeExpr,
    is_comptime: bool = false,

    pub fn fromParam(param: ast_bridge.Param, value_ty: mir.ValueType, type_id: mir.SignatureTypeId) FunctionParamFact {
        return .{
            .name = param.name,
            .value_ty = value_ty,
            .type_id = type_id,
            .ty = param.ty,
            .is_comptime = param.is_comptime,
        };
    }
};
