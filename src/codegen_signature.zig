//! Normalized function signature facts shared by declaration collection and
//! backend call/signature registries.

const ast_bridge = @import("ast_bridge.zig");
const mir = @import("mir_model.zig");

pub const FunctionParamFact = struct {
    name: ast_bridge.Ident,
    /// Canonical checked parameter type. Signature emission must prefer this
    /// value over the transitional syntax payload below.
    value_ty: mir.ValueType,
    ty: ast_bridge.TypeExpr,
    is_comptime: bool = false,

    pub fn fromParam(param: ast_bridge.Param, value_ty: mir.ValueType) FunctionParamFact {
        return .{
            .name = param.name,
            .value_ty = value_ty,
            .ty = param.ty,
            .is_comptime = param.is_comptime,
        };
    }
};
