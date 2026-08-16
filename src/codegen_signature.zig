//! Normalized function signature facts shared by declaration collection and
//! backend call/signature registries.

const ast_bridge = @import("ast_bridge.zig");

pub const FunctionParamFact = struct {
    name: ast_bridge.Ident,
    ty: ast_bridge.TypeExpr,
    is_comptime: bool = false,

    pub fn fromParam(param: ast_bridge.Param) FunctionParamFact {
        return .{
            .name = param.name,
            .ty = param.ty,
            .is_comptime = param.is_comptime,
        };
    }
};
