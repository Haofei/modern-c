const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const monomorphize = @import("monomorphize.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const sema_model = @import("sema_model.zig");

fn checkSource(source: []const u8, reporter: *diagnostics.Reporter) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var checker = sema.Checker.init(reporter);
    checker.checkModule(module);
}

fn hasDiagnosticCode(reporter: *const diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, code) != null) return true;
    }
    return false;
}

fn countDiagnosticCode(reporter: *const diagnostics.Reporter, code: []const u8) usize {
    var count: usize = 0;
    for (reporter.diagnostics.items) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, code) != null) count += 1;
    }
    return count;
}

fn appendProjectionDepthLiteral(source: *std.ArrayList(u8), depth: usize) !void {
    for (0..depth) |_| try source.appendSlice(std.testing.allocator, ".{ .f = ");
    try source.appendSlice(std.testing.allocator, "make_res(1)");
    for (0..depth) |_| try source.appendSlice(std.testing.allocator, " }");
}

fn appendProjectionDepthFunction(source: *std.ArrayList(u8), name: []const u8, depth: usize) !void {
    try source.print(std.testing.allocator, "fn {s}() -> u32 {{\n    var root: N{d} = ", .{ name, depth });
    try appendProjectionDepthLiteral(source, depth);
    try source.appendSlice(std.testing.allocator, ";\n    let moved: Res = move root");
    for (0..depth) |_| try source.appendSlice(std.testing.allocator, ".f");
    try source.appendSlice(std.testing.allocator,
        \\;
        \\    unsafe { forget_unchecked(root); }
        \\    return consume(move moved);
        \\}
        \\
    );
}

fn parseWithAllocator(source: []const u8, allocator: std.mem.Allocator, reporter: *diagnostics.Reporter) !ast.Module {
    var p = parser.Parser.init(source, reporter);
    return p.parseModule(allocator);
}

fn checkVisibilityMode(source: []const u8, imported_offset: usize, mode: ast.VisibilityMode) !bool {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "visibility_root.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var module = try parseWithAllocator(source, arena.allocator(), &reporter);
    defer module.deinit(arena.allocator());
    module.visibility_mode = mode;
    const boundaries = [_]diagnostics.FileBoundary{
        .{ .start = 0, .path = "visibility_root.mc" },
        .{ .start = imported_offset, .path = "visibility_lib.mc" },
    };
    var checker = sema.Checker.init(&reporter);
    checker.file_boundaries = &boundaries;
    checker.checkModule(module);
    return hasDiagnosticCode(&reporter, "E_PRIVATE_IMPORT");
}

test "explicit visibility is independent of unrelated pub declarations" {
    const importer = "fn use_hidden() -> u32 { return hidden(); }\n";
    const private_library = "fn hidden() -> u32 { return 1; }\n";
    const private_library_with_unrelated_pub = private_library ++ "pub fn unrelated() -> u32 { return 2; }\n";
    const public_library = "pub fn hidden() -> u32 { return 1; }\n";

    try std.testing.expect(!try checkVisibilityMode(importer ++ private_library, importer.len, .legacy_pub_opt_in));
    try std.testing.expect(try checkVisibilityMode(importer ++ private_library_with_unrelated_pub, importer.len, .legacy_pub_opt_in));

    try std.testing.expect(try checkVisibilityMode(importer ++ private_library, importer.len, .explicit_public));
    try std.testing.expect(try checkVisibilityMode(importer ++ private_library_with_unrelated_pub, importer.len, .explicit_public));
    try std.testing.expect(!try checkVisibilityMode(importer ++ public_library, importer.len, .explicit_public));
}

test "trait orphan ownership keeps double-underscore type names exact" {
    const defining_file =
        \\trait Marked { fn mark(self: *Self) -> u32; }
        \\struct Vault__Inner { value: u32 }
    ;
    const peer_file =
        \\impl Marked for Vault__Inner {
        \\    fn mark(self: *Vault__Inner) -> u32 { return self.value; }
        \\}
    ;
    const source = defining_file ++ peer_file;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "owner_exact_a.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    const boundaries = [_]diagnostics.FileBoundary{
        .{ .start = 0, .path = "owner_exact_a.mc" },
        .{ .start = defining_file.len, .path = "owner_exact_b.mc" },
    };
    var checker = sema.Checker.init(&reporter);
    checker.file_boundaries = &boundaries;
    checker.checkModule(module);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_ORPHAN_IMPL"));
}

test "move type query depth exhaustion fails closed" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "move struct Token { id: u32 }\nstruct Box { token: ");
    for (0..65) |_| try source.appendSlice(std.testing.allocator, "[1]");
    try source.appendSlice(std.testing.allocator, "Token }\n");

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "deep_move.mc", source.items);
    defer reporter.deinit();
    try checkSource(source.items, &reporter);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_MOVE_ARRAY_UNSUPPORTED"));
}

test "ordinary structs with resource fields become checked resource aggregates" {
    const source =
        \\move struct Ticket { id: u32 }
        \\struct Box { ticket: Ticket }
        \\fn issue() -> Ticket { return .{ .id = 1 }; }
        \\fn make_box() -> Box { return .{ .ticket = issue() }; }
        \\fn consume_box(box: Box) -> u32 {
        \\    let id: u32 = box.ticket.id;
        \\    unsafe { forget_unchecked(box); }
        \\    return id;
        \\}
        \\fn accept_auto_move_aggregate() -> u32 {
        \\    let box: Box = make_box();
        \\    return consume_box(move box);
        \\}
        \\fn reject_implicit_copy() -> u32 {
        \\    let box: Box = make_box();
        \\    let copied: Box = box;
        \\    return consume_box(move copied);
        \\}
        \\fn reject_leak() -> u32 {
        \\    let box: Box = make_box();
        \\    return box.ticket.id;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "auto_move_aggregate.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_EXPLICIT_MOVE_REQUIRED
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_EXPLICIT_MOVE_REQUIRED"));
    // DIAGNOSTIC_UNIT: E_RESOURCE_LEAK
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_RESOURCE_LEAK"));
}

test "linear struct uses existing exactly-once resource checker" {
    const source =
        \\linear struct Token { id: u32 }
        \\fn make() -> Token { return .{ .id = 1 }; }
        \\fn consume(t: Token) -> u32 {
        \\    let id: u32 = t.id;
        \\    unsafe { forget_unchecked(t); }
        \\    return id;
        \\}
        \\fn reject_use_after_linear_move() -> u32 {
        \\    let t: Token = make();
        \\    let a: u32 = consume(t);
        \\    let b: u32 = consume(t);
        \\    return a + b;
        \\}
        \\fn reject_linear_leak() -> u32 {
        \\    let t: Token = make();
        \\    return 0;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "linear_checker.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_USE_AFTER_MOVE"));
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_RESOURCE_LEAK"));
}

test "ownership resources cannot be compared by payload value" {
    const source =
        \\move struct Ticket { id: u32 }
        \\linear struct Token { id: u32 }
        \\enum E { Bad }
        \\struct Cell { value: u32 }
        \\view struct CellView { ptr: *Cell }
        \\fn make_ticket(id: u32) -> Ticket { return .{ .id = id }; }
        \\fn make_token(id: u32) -> Token { return .{ .id = id }; }
        \\fn reject_move_equality() -> bool {
        \\    let a: Ticket = make_ticket(1);
        \\    let b: Ticket = make_ticket(2);
        \\    let same: bool = a == b;
        \\    unsafe {
        \\        forget_unchecked(a);
        \\        forget_unchecked(b);
        \\    }
        \\    return same;
        \\}
        \\fn reject_linear_ordering() -> bool {
        \\    let a: Token = make_token(1);
        \\    let b: Token = make_token(2);
        \\    let ordered: bool = a < b;
        \\    unsafe {
        \\        forget_unchecked(a);
        \\        forget_unchecked(b);
        \\    }
        \\    return ordered;
        \\}
        \\fn reject_view_equality(cell: *Cell, other: *Cell) -> bool {
        \\    let a: CellView = .{ .ptr = borrow cell.* };
        \\    let b: CellView = .{ .ptr = borrow other.* };
        \\    return a == b;
        \\}
        \\fn accept_nullable_resource_presence() -> bool {
        \\    let maybe: ?Ticket = null;
        \\    let empty: bool = maybe == null;
        \\    unsafe { forget_unchecked(maybe); }
        \\    return empty;
        \\}
        \\fn reject_move_switch_subject() -> u32 {
        \\    let ticket: Ticket = make_ticket(3);
        \\    switch ticket {
        \\        _ => {
        \\            unsafe { forget_unchecked(ticket); }
        \\            return 1;
        \\        }
        \\    }
        \\}
        \\fn reject_view_switch_subject(cell: *Cell) -> u32 {
        \\    let view: CellView = .{ .ptr = borrow cell.* };
        \\    switch view {
        \\        _ => { return 1; }
        \\    }
        \\}
        \\fn accept_result_resource_narrow() -> u32 {
        \\    let result: Result<Ticket, E> = ok(make_ticket(4));
        \\    switch result {
        \\        ok(ticket) => {
        \\            unsafe { forget_unchecked(ticket); }
        \\            return 1;
        \\        }
        \\        err(e) => { return 0; }
        \\    }
        \\}
        \\fn accept_nullable_resource_narrow() -> u32 {
        \\    let maybe: ?Ticket = make_ticket(5);
        \\    if let ticket = maybe {
        \\        unsafe { forget_unchecked(ticket); }
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "resource_comparison.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_RESOURCE_COMPARISON
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_RESOURCE_COMPARISON"));
    // DIAGNOSTIC_UNIT: E_RESOURCE_PATTERN
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_RESOURCE_PATTERN"));
}

test "for iteration cannot bind ownership resources by value" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Cell { value: u32 }
        \\view struct CellView { ptr: *Cell }
        \\fn make_ticket(id: u32) -> Ticket { return .{ .id = id }; }
        \\fn accept_pointer_elements(items: [2]*mut Ticket) -> u32 {
        \\    var count: u32 = 0;
        \\    for ptr in items {
        \\        if ptr != null { count = count + 1; }
        \\    }
        \\    return count;
        \\}
        \\fn reject_move_array_iteration() -> u32 {
        \\    var tickets: [2]Ticket = .{ make_ticket(1), make_ticket(2) };
        \\    for ticket in tickets {
        \\        unsafe { forget_unchecked(ticket); }
        \\    }
        \\    unsafe { forget_unchecked(tickets); }
        \\    return 0;
        \\}
        \\fn reject_move_slice_iteration(tickets: []Ticket) -> u32 {
        \\    for ticket in tickets {
        \\        unsafe { forget_unchecked(ticket); }
        \\    }
        \\    return 0;
        \\}
        \\fn reject_region_array_iteration(nodes: [2]Node) -> u32 {
        \\    for node in nodes {
        \\        let id: u32 = node.id;
        \\    }
        \\    return 0;
        \\}
        \\fn reject_view_array_iteration(cell: *Cell) -> u32 {
        \\    let views: [1]CellView = .{ .{ .ptr = borrow cell.* } };
        \\    for view in views {
        \\        return view.ptr.value;
        \\    }
        \\    return 0;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "resource_for_iteration.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_RESOURCE_ITERATION
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_RESOURCE_ITERATION"));
}

test "explicit move expression marks checked resource transfer" {
    const source =
        \\move struct Ticket { id: u32 }
        \\fn issue() -> Ticket { return .{ .id = 1 }; }
        \\fn consume(t: Ticket) -> u32 {
        \\    let id: u32 = t.id;
        \\    unsafe { forget_unchecked(t); }
        \\    return id;
        \\}
        \\fn accept_explicit_move() -> u32 {
        \\    let t: Ticket = issue();
        \\    return consume(move t);
        \\}
        \\fn reject_after_explicit_move() -> u32 {
        \\    let t: Ticket = issue();
        \\    let first: u32 = consume(move t);
        \\    let second: u32 = consume(t);
        \\    return first + second;
        \\}
        \\fn accept_plain_value_marker(x: u32) -> u32 {
        \\    return move x;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "explicit_move_expr.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_USE_AFTER_MOVE
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_USE_AFTER_MOVE"));
}

test "checked resources require explicit move for existing owners" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\fn issue() -> Ticket { return .{ .id = 1 }; }
        \\fn consume(t: Ticket) -> u32 {
        \\    return t.id;
        \\}
        \\fn accept_call_arg() -> u32 {
        \\    let t: Ticket = issue();
        \\    return consume(move t);
        \\}
        \\fn accept_fresh_call_arg() -> u32 {
        \\    return consume(issue());
        \\}
        \\fn reject_call_arg() -> u32 {
        \\    let t: Ticket = issue();
        \\    return consume(t);
        \\}
        \\fn accept_local_init() -> u32 {
        \\    let source: Ticket = issue();
        \\    let target: Ticket = move source;
        \\    return target.id;
        \\}
        \\fn reject_local_init() -> u32 {
        \\    let source: Ticket = issue();
        \\    let target: Ticket = source;
        \\    return target.id;
        \\}
        \\fn accept_return(t: Ticket) -> Ticket {
        \\    return move t;
        \\}
        \\fn reject_return(t: Ticket) -> Ticket {
        \\    return t;
        \\}
        \\fn accept_array_literal_element() -> u32 {
        \\    let source: Ticket = issue();
        \\    let items: [1]Ticket = .{ move source };
        \\    return items[0].id;
        \\}
        \\fn reject_array_literal_element() -> u32 {
        \\    let source: Ticket = issue();
        \\    let items: [1]Ticket = .{ source };
        \\    return items[0].id;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "checked_resource_explicit_move.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_EXPLICIT_MOVE_REQUIRED
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_EXPLICIT_MOVE_REQUIRED"));
}

test "closure bind cannot capture checked resources by value" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\struct Env { base: u32 }
        \\fn add_ticket(env: Ticket, x: u32) -> u32 {
        \\    return env.id + x;
        \\}
        \\fn add_env(env: *Env, x: u32) -> u32 {
        \\    return env.base + x;
        \\}
        \\fn accept_pointer_environment() -> u32 {
        \\    var env: Env = .{ .base = 3 };
        \\    let cb: closure(u32) -> u32 = bind(&env, add_env);
        \\    return cb(4);
        \\}
        \\fn reject_resource_environment() -> u32 {
        \\    let ticket: Ticket = .{ .id = 7 };
        \\    let cb: closure(u32) -> u32 = bind(ticket, add_ticket);
        \\    return cb(1);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "closure_resource_capture.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_CLOSURE_RESOURCE_CAPTURE
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_CLOSURE_RESOURCE_CAPTURE"));
}

test "trivial move can finish at scope exit but trivial linear cannot leak" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\#[trivial_drop]
        \\linear struct Token { id: u32 }
        \\fn issue_ticket() -> Ticket { return .{ .id = 1 }; }
        \\fn issue_token() -> Token { return .{ .id = 2 }; }
        \\fn accept_trivial_move_auto_finish() -> u32 {
        \\    let t: Ticket = issue_ticket();
        \\    return t.id;
        \\}
        \\fn reject_trivial_linear_leak() -> u32 {
        \\    let t: Token = issue_token();
        \\    return t.id;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "trivial_move_linear.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_RESOURCE_LEAK"));
}

test "global storage cannot own checked resources by value" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\enum TicketError { Bad }
        \\global reject_ticket: Ticket;
        \\global reject_result: Result<Ticket, TicketError>;
        \\global accept_ticket_ptr: *mut Ticket = null;
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "global_resource_storage.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_GLOBAL_RESOURCE_STORAGE
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_GLOBAL_RESOURCE_STORAGE"));
}

test "uninit cannot create ownership resource storage" {
    const source =
        \\move struct Ticket { id: u32 }
        \\linear struct Token { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn accept_plain_uninit() -> u8 {
        \\    var buf: [4]u8 = uninit;
        \\    buf[0] = 7;
        \\    return buf[0];
        \\}
        \\fn reject_move_uninit() -> void {
        \\    var ticket: Ticket = uninit;
        \\}
        \\fn reject_linear_uninit() -> void {
        \\    var token: Token = uninit;
        \\}
        \\fn reject_region_uninit() -> void {
        \\    var node: Node = uninit;
        \\}
        \\fn reject_view_uninit() -> void {
        \\    var view: PlainView = uninit;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "uninit_resource_storage.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNINIT_RESOURCE_STORAGE
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_UNINIT_RESOURCE_STORAGE"));
}

test "generic structs embedding resource type parameters are resource storage" {
    const source =
        \\move struct Ticket { id: u32 }
        \\linear struct Token { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Cell { value: u32 }
        \\view struct CellView { ptr: *Cell }
        \\struct Box<T> { value: T }
        \\struct ArrayBox<T> { values: [1]T }
        \\struct MaybeBox<T> { value: ?T }
        \\struct Phantom<T> { id: usize }
        \\fn accept_phantom() -> usize {
        \\    var p: Phantom<Ticket> = uninit;
        \\    p.id = 7;
        \\    return p.id;
        \\}
        \\fn reject_move_box_uninit() -> void {
        \\    var b: Box<Ticket> = uninit;
        \\}
        \\fn reject_linear_array_box_uninit() -> void {
        \\    var b: ArrayBox<Token> = uninit;
        \\}
        \\fn reject_move_maybe_box_uninit() -> void {
        \\    var b: MaybeBox<Ticket> = uninit;
        \\}
        \\fn reject_region_box_uninit() -> void {
        \\    var b: Box<Node> = uninit;
        \\}
        \\fn reject_view_box_uninit() -> void {
        \\    var b: Box<CellView> = uninit;
        \\}
        \\fn reject_raw_ptr_box(addr: PAddr) -> void {
        \\    unsafe { raw.ptr<Box<Ticket>>(addr); }
        \\}
        \\fn accept_raw_ptr_phantom(addr: PAddr) -> *mut Phantom<Ticket> {
        \\    unsafe { return raw.ptr<Phantom<Ticket>>(addr); }
        \\}
        \\fn consume_ticket(t: Ticket) -> u32 {
        \\    unsafe { forget_unchecked(t); }
        \\    return 1;
        \\}
        \\fn reject_generic_struct_literal_implicit_resource_copy(ticket: Ticket) -> u32 {
        \\    let b: Box<Ticket> = .{ .value = ticket };
        \\    return consume_ticket(move ticket) + consume_ticket(move b.value);
        \\}
        \\fn accept_generic_struct_literal_explicit_move(ticket: Ticket) -> u32 {
        \\    let b: Box<Ticket> = .{ .value = move ticket };
        \\    return consume_ticket(move b.value);
        \\}
        \\fn reject_generic_array_field_literal_implicit_resource_copy(ticket: Token) -> u32 {
        \\    let b: ArrayBox<Token> = .{ .values = .{ ticket } };
        \\    unsafe { forget_unchecked(ticket); }
        \\    unsafe { forget_unchecked(b.values[0]); }
        \\    return 1;
        \\}
        \\fn accept_generic_array_field_literal_explicit_move(ticket: Token) -> u32 {
        \\    let b: ArrayBox<Token> = .{ .values = .{ move ticket } };
        \\    unsafe { forget_unchecked(b.values[0]); }
        \\    return 1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "generic_resource_struct_storage.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNINIT_RESOURCE_STORAGE
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_UNINIT_RESOURCE_STORAGE"));
    // DIAGNOSTIC_UNIT: E_RAW_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_RAW_RESOURCE_PAYLOAD"));
    // DIAGNOSTIC_UNIT: E_EXPLICIT_MOVE_REQUIRED
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_EXPLICIT_MOVE_REQUIRED"));
}

test "generic tagged unions embedding resource type parameters are resource storage" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\linear struct Token { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Cell { value: u32 }
        \\view struct CellView { ptr: *Cell }
        \\union Slot<T> { some: T, none }
        \\union ArraySlot<T> { some: [1]T, none }
        \\union MaybeSlot<T> { some: ?T, none }
        \\union Signal<T> { ready, idle }
        \\fn accept_signal_phantom() -> u32 {
        \\    var s: Signal<Ticket> = uninit;
        \\    s = ready();
        \\    switch s {
        \\        .ready => { return 1; },
        \\        .idle => { return 0; },
        \\    }
        \\}
        \\fn reject_move_slot_uninit() -> void {
        \\    var s: Slot<Ticket> = uninit;
        \\}
        \\fn reject_linear_array_slot_uninit() -> void {
        \\    var s: ArraySlot<Token> = uninit;
        \\}
        \\fn reject_move_maybe_slot_uninit() -> void {
        \\    var s: MaybeSlot<Ticket> = uninit;
        \\}
        \\fn reject_region_slot_uninit() -> void {
        \\    var s: Slot<Node> = uninit;
        \\}
        \\fn reject_view_slot_uninit() -> void {
        \\    var s: Slot<CellView> = uninit;
        \\}
        \\fn reject_raw_ptr_slot(addr: PAddr) -> void {
        \\    unsafe { raw.ptr<Slot<Ticket>>(addr); }
        \\}
        \\fn accept_raw_ptr_signal(addr: PAddr) -> *mut Signal<Ticket> {
        \\    unsafe { return raw.ptr<Signal<Ticket>>(addr); }
        \\}
        \\fn consume_ticket(t: Ticket) -> u32 {
        \\    return t.id;
        \\}
        \\fn consume_slot(s: Slot<Ticket>) -> u32 {
        \\    switch s {
        \\        some(t) => { return consume_ticket(move t); },
        \\        .none => { return 0; },
        \\    }
        \\}
        \\fn reject_generic_union_constructor_implicit_resource_copy(ticket: Ticket) -> u32 {
        \\    let s: Slot<Ticket> = some(ticket);
        \\    return consume_ticket(move ticket) + consume_slot(move s);
        \\}
        \\fn accept_generic_union_constructor_explicit_move(ticket: Ticket) -> u32 {
        \\    let s: Slot<Ticket> = some(move ticket);
        \\    return consume_slot(move s);
        \\}
        \\fn reject_qualified_generic_union_constructor_implicit_resource_copy(ticket: Ticket) -> u32 {
        \\    let s: Slot<Ticket> = Slot.some(ticket);
        \\    return consume_ticket(move ticket) + consume_slot(move s);
        \\}
        \\fn accept_qualified_generic_union_constructor_explicit_move(ticket: Ticket) -> u32 {
        \\    let s: Slot<Ticket> = Slot.some(move ticket);
        \\    return consume_slot(move s);
        \\}
        \\fn pass_slot(s: Slot<Ticket>) -> u32 {
        \\    return consume_slot(move s);
        \\}
        \\fn reject_qualified_generic_union_call_arg_implicit_resource_copy(ticket: Ticket) -> u32 {
        \\    return pass_slot(Slot.some(ticket)) + consume_ticket(move ticket);
        \\}
        \\fn accept_qualified_generic_union_call_arg_explicit_move(ticket: Ticket) -> u32 {
        \\    return pass_slot(Slot.some(move ticket));
        \\}
        \\fn reject_generic_union_array_payload_implicit_resource_copy(token: Token) -> u32 {
        \\    let s: ArraySlot<Token> = some(.{ token });
        \\    unsafe { forget_unchecked(token); }
        \\    unsafe { forget_unchecked(s); }
        \\    return 1;
        \\}
        \\fn accept_generic_union_array_payload_explicit_move(token: Token) -> u32 {
        \\    let s: ArraySlot<Token> = some(.{ move token });
        \\    unsafe { forget_unchecked(s); }
        \\    return 1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "generic_resource_union_storage.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNINIT_RESOURCE_STORAGE
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_UNINIT_RESOURCE_STORAGE"));
    // DIAGNOSTIC_UNIT: E_RAW_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_RAW_RESOURCE_PAYLOAD"));
    // DIAGNOSTIC_UNIT: E_EXPLICIT_MOVE_REQUIRED
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_EXPLICIT_MOVE_REQUIRED"));
}

test "drop attribute releases resource through mut pointer call and defer" {
    const source =
        \\move struct Ticket { id: u32 }
        \\fn issue_ticket() -> Ticket { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_ticket(t: *mut Ticket) -> void {
        \\    t.id = 0;
        \\}
        \\fn accept_direct_release() -> u32 {
        \\    var t: Ticket = issue_ticket();
        \\    close_ticket(&t);
        \\    return 1;
        \\}
        \\fn accept_deferred_release(flag: bool) -> u32 {
        \\    var t: Ticket = issue_ticket();
        \\    defer close_ticket(&t);
        \\    if flag {
        \\        return 1;
        \\    }
        \\    return 2;
        \\}
        \\fn reject_use_after_pointer_release() -> u32 {
        \\    var t: Ticket = issue_ticket();
        \\    close_ticket(&t);
        \\    return t.id;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "drop_attr_release.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_RESOURCE_LEAK"));
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_USE_AFTER_MOVE"));
}

test "drop attribute explicit release is place-local with auto-drop" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void {
        \\    g.id = 0;
        \\}
        \\fn accept_explicit_release_and_other_auto_drop() -> u32 {
        \\    var g: Guard = make_guard(1);
        \\    var h: Guard = make_guard(2);
        \\    close_guard(&g);
        \\    return h.id;
        \\}
        \\fn accept_deferred_release_and_other_auto_drop(flag: bool) -> u32 {
        \\    var g: Guard = make_guard(3);
        \\    var h: Guard = make_guard(4);
        \\    defer close_guard(&g);
        \\    if flag {
        \\        return h.id;
        \\    }
        \\    return 5;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "drop_attr_place_local_auto_drop.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_RESOURCE_LEAK"));
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_USE_AFTER_MOVE"));
}

test "drop attribute enables deterministic auto-drop and explicit transfer for affine move locals" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn accept_auto_drop_fallthrough(flag: bool) -> u32 {
        \\    var g: Guard = make_guard();
        \\    if flag {
        \\        return 1;
        \\    }
        \\    return g.id;
        \\}
        \\fn accept_auto_drop_inferred() -> u32 {
        \\    var g = make_guard();
        \\    return g.id;
        \\}
        \\fn accept_auto_drop_transfer() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return move g;
        \\}
        \\struct Wrapper { guard: Guard }
        \\fn make_wrapper() -> Wrapper { return .{ .guard = make_guard() }; }
        \\#[drop]
        \\fn close_wrapper(w: *mut Wrapper) -> void { close_guard(&w.guard); }
        \\fn accept_implicit_aggregate_auto_drop() -> u32 {
        \\    var w: Wrapper = make_wrapper();
        \\    return w.guard.id;
        \\}
        \\fn reject_implicit_auto_drop_transfer() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return g;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "drop_attr_auto_drop.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_RESOURCE_LEAK"));
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_EXPLICIT_MOVE_REQUIRED"));
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_USE_AFTER_MOVE"));
}

test "auto-drop v0 rejects alias moves forget and moved reinitialization" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn reject_return_via_alias() -> Guard {
        \\    var g: Guard = make_guard(1);
        \\    let p: *Guard = &g;
        \\    return move p.*;
        \\}
        \\fn reject_implicit_alias_move() -> Guard {
        \\    var g: Guard = make_guard(2);
        \\    let result: Guard = (&g).*;
        \\    return move result;
        \\}
        \\fn reject_forget_auto_drop() -> void {
        \\    var g: Guard = make_guard(3);
        \\    unsafe {
        \\        forget_unchecked(g);
        \\    }
        \\}
        \\fn reject_reinit_after_move() -> Guard {
        \\    var g: Guard = make_guard(4);
        \\    let result: Guard = move g;
        \\    g = make_guard(5);
        \\    return move result;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "auto_drop_v0_rejects_unsound_holes.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_AUTO_DROP_UNSUPPORTED
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_AUTO_DROP_UNSUPPORTED"));
}

test "ownership place projection depth emits explicit diagnostic" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);

    try source.appendSlice(std.testing.allocator,
        \\move struct Res { id: u32 }
        \\fn make_res(id: u32) -> Res { return .{ .id = id }; }
        \\fn consume(r: Res) -> u32 {
        \\    let id: u32 = r.id;
        \\    unsafe { forget_unchecked(r); }
        \\    return id;
        \\}
    );

    for (1..18) |depth| {
        if (depth == 1) {
            try source.print(std.testing.allocator, "struct N1 {{ f: Res }}\n", .{});
        } else {
            try source.print(std.testing.allocator, "struct N{d} {{ f: N{d} }}\n", .{ depth, depth - 1 });
        }
    }

    try appendProjectionDepthFunction(&source, "accept_projection_depth_15", 15);
    try appendProjectionDepthFunction(&source, "accept_projection_depth_16", 16);
    try appendProjectionDepthFunction(&source, "reject_projection_depth_17", 17);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move_place_projection_depth.mc", source.items);
    defer reporter.deinit();
    try checkSource(source.items, &reporter);
    // DIAGNOSTIC_UNIT: E_OWNERSHIP_PLACE_TOO_DEEP
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_OWNERSHIP_PLACE_TOO_DEEP"));
}

test "drop attribute shape is restricted to mut pointer checked resource returning void" {
    const source =
        \\move struct Ticket { id: u32 }
        \\linear struct Token { id: u32 }
        \\struct Plain { id: u32 }
        \\#[drop]
        \\fn reject_plain(p: *mut Plain) -> void {
        \\    p.id = 0;
        \\}
        \\#[drop]
        \\fn reject_by_value(t: Ticket) -> void {
        \\    unsafe { forget_unchecked(t); }
        \\}
        \\#[drop]
        \\fn reject_nonvoid(t: *mut Ticket) -> u32 {
        \\    t.id = 0;
        \\    return 1;
        \\}
        \\#[drop]
        \\fn reject_linear(t: *mut Token) -> void {
        \\    t.id = 0;
        \\}
        \\#[drop]
        \\fn reject_extra_param(t: *mut Ticket, mode: u32) -> void {
        \\    t.id = mode;
        \\}
        \\#[drop]
        \\fn close_ticket(t: *mut Ticket) -> void {
        \\    t.id = 0;
        \\}
        \\#[drop]
        \\fn reject_duplicate_ticket_drop(t: *mut Ticket) -> void {
        \\    t.id = 1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "drop_attr_shape.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_DROP_ATTR_SHAPE
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_DROP_ATTR_SHAPE"));
    // DIAGNOSTIC_UNIT: E_DUPLICATE_DROP_GLUE
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_DUPLICATE_DROP_GLUE"));
}

test "MaybeUninit cannot store affine, region, or view payloads" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct RegionNode { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn make_ticket() -> Ticket { return .{ .id = 1 }; }
        \\fn accept_plain() -> u32 {
        \\    var slot: MaybeUninit<Plain> = uninit;
        \\    slot.write(.{ .id = 1 });
        \\    let value: Plain = slot.assume_init();
        \\    return value.id;
        \\}
        \\fn reject_move_write() -> void {
        \\    var slot: MaybeUninit<Ticket> = uninit;
        \\    let ticket: Ticket = make_ticket();
        \\    slot.write(ticket);
        \\    unsafe { forget_unchecked(ticket); }
        \\}
        \\fn reject_move_assume_init() -> void {
        \\    var slot: MaybeUninit<Ticket> = uninit;
        \\    let ticket: Ticket = slot.assume_init();
        \\    unsafe { forget_unchecked(ticket); }
        \\}
        \\fn reject_region_write(node: RegionNode) -> void {
        \\    var slot: MaybeUninit<RegionNode> = uninit;
        \\    slot.write(node);
        \\}
        \\fn reject_region_assume_init() -> void {
        \\    var slot: MaybeUninit<RegionNode> = uninit;
        \\    slot.assume_init();
        \\}
        \\fn reject_view_slot() -> void {
        \\    var slot: MaybeUninit<PlainView> = uninit;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "maybe_uninit_resource_payload.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_MAYBEUNINIT_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 9), countDiagnosticCode(&reporter, "E_MAYBEUNINIT_RESOURCE_PAYLOAD"));
}

test "atomic cannot store affine or region payloads" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct RegionNode { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn accept_copyable_atomic() -> u32 {
        \\    var state: atomic<u32> = atomic.init(1);
        \\    return state.load(.relaxed);
        \\}
        \\fn reject_move_atomic() -> void {
        \\    var state: atomic<Ticket> = uninit;
        \\}
        \\fn reject_region_atomic() -> void {
        \\    var state: atomic<RegionNode> = uninit;
        \\}
        \\fn reject_view_atomic() -> void {
        \\    var state: atomic<PlainView> = uninit;
        \\}
        \\fn reject_move_atomic_init(ticket: Ticket) -> void {
        \\    var state = atomic.init(ticket);
        \\    unsafe { forget_unchecked(ticket); }
        \\}
        \\fn reject_view_atomic_init(view: PlainView) -> void {
        \\    var state = atomic.init(view);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "atomic_resource_payload.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_ATOMIC_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_ATOMIC_RESOURCE_PAYLOAD"));
}

test "external address and DMA payloads cannot store affine or region resources" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct RegionNode { id: u32 }
        \\struct Packet { id: u32 }
        \\view struct PacketView { ptr: *Packet }
        \\extern mmio struct Uart {
        \\    data: Reg<u32, .read_write>,
        \\}
        \\move extern mmio struct MoveUart {
        \\    data: Reg<u32, .read_write>,
        \\}
        \\fn accept_copyable_external(user: UserPtr<Packet>, phys: PhysPtr<Packet>, dma: DmaBuf<Packet, .coherent>) -> usize {
        \\    return sizeof(UserPtr<Packet>) + sizeof(PhysPtr<Packet>) + sizeof(DmaBuf<Packet, .coherent>) + sizeof(MmioPtr<Uart>);
        \\}
        \\fn reject_userptr_move(ptr: UserPtr<Ticket>) -> void {}
        \\fn reject_userptr_region(ptr: UserPtr<RegionNode>) -> void {}
        \\fn reject_physptr_move(ptr: PhysPtr<Ticket>) -> void {}
        \\fn reject_physptr_region(ptr: PhysPtr<RegionNode>) -> void {}
        \\fn reject_dmabuf_move(buf: DmaBuf<Ticket, .coherent>) -> void {}
        \\fn reject_dmabuf_region(buf: DmaBuf<RegionNode, .noncoherent>) -> void {}
        \\fn reject_userptr_view(ptr: UserPtr<PacketView>) -> void {}
        \\fn reject_dmabuf_view(buf: DmaBuf<PacketView, .coherent>) -> void {}
        \\fn reject_mmio_map_move(pa: PAddr) -> void {
        \\    unsafe {
        \\        mmio.map<MoveUart>(pa);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "address_resource_payload.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_ADDRESS_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 9), countDiagnosticCode(&reporter, "E_ADDRESS_RESOURCE_PAYLOAD"));
}

test "region structs are not independent move or drop resources" {
    const source =
        \\region move struct BadMove { id: u32 }
        \\region linear struct BadLinear { id: u32 }
        \\#[trivial_drop]
        \\region struct BadTrivial { id: u32 }
        \\region struct Node { id: u32 }
        \\#[drop]
        \\fn reject_region_drop(node: *mut Node) -> void {
        \\    node.id = 0;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "region_resource_conflict.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_REGION_RESOURCE_CONFLICT
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_REGION_RESOURCE_CONFLICT"));
}

test "region structs do not escape by value through non-region storage or C ABI" {
    const source =
        \\region struct Node { id: u32 }
        \\type NodeAlias = Node;
        \\region struct GraphNode { child: Node }
        \\struct NodePtrBox { node: *mut Node }
        \\struct BadBox { node: Node }
        \\struct BadAliasBox { node: NodeAlias }
        \\global bad_global: Node;
        \\extern "C" fn bad_param(node: Node) -> void;
        \\extern "C" fn bad_return() -> NodeAlias;
        \\extern "C" fn ok_ptr(node: *mut Node) -> void;
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "region_by_value_escape.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_REGION_RESOURCE_CONFLICT
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_REGION_RESOURCE_CONFLICT"));
}

test "region structs do not escape by value through ordinary locals or signatures" {
    const source =
        \\region struct Node { id: u32 }
        \\type NodeAlias = Node;
        \\region struct GraphNode { child: Node }
        \\fn bad_local() -> void {
        \\    let node: Node = .{ .id = 1 };
        \\}
        \\fn bad_param(node: Node) -> void {}
        \\fn bad_return() -> NodeAlias {
        \\    return .{ .id = 1 };
        \\}
        \\fn ok_ptr(node: *mut Node) -> void {}
        \\fn ok_graph_ptr(node: *mut GraphNode) -> void {}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "region_ordinary_by_value_escape.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_REGION_RESOURCE_CONFLICT
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_REGION_RESOURCE_CONFLICT"));
}

test "union storage cannot contain affine region or view resources by value" {
    const source =
        \\move struct Ticket { id: u32 }
        \\linear struct Cap { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\type TicketAlias = Ticket;
        \\type NodeAlias = Node;
        \\type ViewAlias = PlainView;
        \\union BadTaggedMove { ticket: TicketAlias, none }
        \\union BadTaggedRegion { node: NodeAlias, none }
        \\union BadTaggedView { view: ViewAlias, none }
        \\overlay union BadOverlayMove { ticket: Ticket, bytes: [4]u8 }
        \\overlay union BadOverlayRegion { node: Node, bytes: [4]u8 }
        \\overlay union BadOverlayView { view: PlainView, raw: usize }
        \\#[c_union]
        \\struct BadCUnionMove { ticket: Cap, raw: u32 }
        \\#[c_union]
        \\struct BadCUnionRegion { node: Node, raw: u32 }
        \\#[c_union]
        \\struct BadCUnionView { view: PlainView, raw: usize }
        \\union OkTaggedPtr { ticket: *mut Ticket, node: *mut Node, none }
        \\overlay union OkOverlayPtr { ticket: *mut Ticket, node: *mut Node, view: *mut PlainView }
        \\#[c_union]
        \\struct OkCUnionPtr { ticket: *mut Ticket, node: *mut Node, view: *mut PlainView }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "union_resource_storage.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_MOVE_UNION_RESOURCE
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_MOVE_UNION_RESOURCE"));
    // DIAGNOSTIC_UNIT: E_REGION_RESOURCE_CONFLICT
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_REGION_RESOURCE_CONFLICT"));
    // DIAGNOSTIC_UNIT: E_BORROW_ESCAPES_SCOPE
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_BORROW_ESCAPES_SCOPE"));
}

test "byte views cannot expose affine or region resources by value" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn reject_ticket(ticket: Ticket) -> void {
        \\    mem.as_bytes(&ticket);
        \\}
        \\fn reject_ticket_with_move_wrapper(ticket: Ticket) -> void {
        \\    mem.as_bytes(move &ticket);
        \\}
        \\fn reject_node(node: *mut Node) -> void {
        \\    mem.as_bytes(&node.*);
        \\}
        \\fn reject_view() -> void {
        \\    var plain: Plain = .{ .id = 1 };
        \\    let view: PlainView = .{ .ptr = borrow plain };
        \\    mem.as_bytes(&view);
        \\}
        \\fn accept_plain(plain: Plain) -> []const u8 {
        \\    return mem.as_bytes(&plain);
        \\}
        \\fn accept_pointer_variable(node: *mut Node) -> []const u8 {
        \\    return mem.as_bytes(&node);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "byte_view_resource.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BYTE_VIEW_RESOURCE
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_BYTE_VIEW_RESOURCE"));
}

test "pointer bitcast cannot reinterpret affine region or view pointees" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Plain { id: u32 }
        \\struct Other { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn reject_from_ticket(ticket: *mut Ticket) -> *mut Plain {
        \\    return bitcast<*mut Plain>(ticket);
        \\}
        \\fn reject_to_ticket(plain: *mut Plain) -> *mut Ticket {
        \\    return bitcast<*mut Ticket>(plain);
        \\}
        \\fn reject_from_node(node: *mut Node) -> *mut Plain {
        \\    return bitcast<*mut Plain>(node);
        \\}
        \\fn reject_to_node(plain: *mut Plain) -> *mut Node {
        \\    return bitcast<*mut Node>(plain);
        \\}
        \\fn reject_from_view(view: *mut PlainView) -> *mut Plain {
        \\    return bitcast<*mut Plain>(view);
        \\}
        \\fn reject_to_view(plain: *mut Plain) -> *mut PlainView {
        \\    return bitcast<*mut PlainView>(plain);
        \\}
        \\fn accept_plain(plain: *mut Plain) -> *mut Other {
        \\    return bitcast<*mut Other>(plain);
        \\}
        \\fn accept_same_ticket(ticket: *mut Ticket) -> *mut Ticket {
        \\    return bitcast<*mut Ticket>(ticket);
        \\}
        \\fn accept_same_view(view: *mut PlainView) -> *mut PlainView {
        \\    return bitcast<*mut PlainView>(view);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bitcast_resource_pointee.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BITCAST_TYPE
    try std.testing.expectEqual(@as(usize, 6), countDiagnosticCode(&reporter, "E_BITCAST_TYPE"));
}

test "thread spawn boundaries require explicit thread_move resources" {
    const source =
        \\move struct Ticket { id: u32 }
        \\thread_move move struct SendTicket { id: u32 }
        \\thread_move struct SendBox { ticket: SendTicket }
        \\thread_move struct Plain { id: u32 }
        \\thread_move move struct BadBox { ticket: Ticket }
        \\view struct TicketView { ptr: *Ticket }
        \\struct Cell { id: u32 }
        \\fn make_ticket() -> Ticket { return .{ .id = 1 }; }
        \\fn make_send() -> SendTicket { return .{ .id = 2 }; }
        \\fn make_send_box() -> SendBox { return .{ .ticket = make_send() }; }
        \\fn thread_spawn(t: Ticket) -> void {
        \\    unsafe { forget_unchecked(t); }
        \\}
        \\fn task_spawn(t: SendTicket) -> void {
        \\    unsafe { forget_unchecked(t); }
        \\}
        \\fn box_spawn(box: SendBox) -> void {
        \\    unsafe { forget_unchecked(box); }
        \\}
        \\fn spawn(p: *Ticket) -> void {
        \\    let id: u32 = p.id;
        \\}
        \\fn proc_spawn(p: *Cell) -> void {
        \\    let id: u32 = p.id;
        \\}
        \\fn sched_spawn(p: *Ticket) -> void {
        \\    let id: u32 = p.id;
        \\}
        \\fn agent_spawn(view: TicketView) -> void {
        \\    let id: u32 = view.ptr.id;
        \\}
        \\#[thread_spawn]
        \\fn handoff(t: Ticket) -> void {
        \\    unsafe { forget_unchecked(t); }
        \\}
        \\#[thread_spawn]
        \\fn handoff_send(t: SendTicket) -> void {
        \\    unsafe { forget_unchecked(t); }
        \\}
        \\#[thread_spawn]
        \\fn handoff_ptr(p: *Ticket) -> void {
        \\    let id: u32 = p.id;
        \\}
        \\fn reject_plain_resource_transfer() -> void {
        \\    thread_spawn(make_ticket());
        \\}
        \\fn reject_attr_plain_resource_transfer() -> void {
        \\    handoff(make_ticket());
        \\}
        \\fn accept_thread_move_transfer() -> void {
        \\    task_spawn(make_send());
        \\}
        \\fn accept_attr_thread_move_transfer() -> void {
        \\    handoff_send(make_send());
        \\}
        \\fn accept_thread_move_aggregate_transfer() -> void {
        \\    box_spawn(make_send_box());
        \\}
        \\fn reject_borrow_transfer() -> void {
        \\    var t: Ticket = make_ticket();
        \\    spawn(borrow t);
        \\    unsafe { forget_unchecked(t); }
        \\}
        \\fn reject_local_address_transfer() -> void {
        \\    var cell: Cell = .{ .id = 3 };
        \\    proc_spawn(&cell);
        \\}
        \\fn reject_resource_address_transfer() -> void {
        \\    var t: Ticket = make_ticket();
        \\    sched_spawn(&t);
        \\    unsafe { forget_unchecked(t); }
        \\}
        \\fn reject_resource_pointer_transfer(t: *Ticket) -> void {
        \\    sched_spawn(t);
        \\}
        \\fn reject_attr_resource_pointer_transfer(t: *Ticket) -> void {
        \\    handoff_ptr(t);
        \\}
        \\fn reject_view_transfer() -> void {
        \\    var t: Ticket = make_ticket();
        \\    let view: TicketView = .{ .ptr = borrow t };
        \\    agent_spawn(view);
        \\    unsafe { forget_unchecked(t); }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "thread_move_spawn.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_THREAD_MOVE_RESOURCE
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_THREAD_MOVE_RESOURCE"));
    // DIAGNOSTIC_UNIT: E_BORROW_THREAD_BOUNDARY
    try std.testing.expectEqual(@as(usize, 6), countDiagnosticCode(&reporter, "E_BORROW_THREAD_BOUNDARY"));
}

test "safe module forbids raw many pointer surface outside unsafe blocks" {
    const source =
        \\#[safe_module]
        \\struct Marker { id: u32 }
        \\struct BadField { p: [*]mut u8 }
        \\type BadAlias = [*]mut u8;
        \\fn bad_param(p: [*]mut u8) -> void;
        \\fn bad_return() -> [*]mut u8;
        \\trait BadTrait {
        \\    fn use_raw(self: *Self, p: [*]mut u8) -> void;
        \\}
        \\fn unsafe_local_ok() -> void {
        \\    unsafe {
        \\        var p: [*]mut u8 = uninit;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "safe_module_raw_surface.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_SAFE_MODULE_RAW_POINTER
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_SAFE_MODULE_RAW_POINTER"));
}

test "safe module requires explicit unsafe ffi boundary" {
    const source =
        \\#[safe_module]
        \\struct Marker { id: u32 }
        \\extern fn bare_ext() -> void;
        \\extern "C" fn c_ext() -> void;
        \\#[unsafe_ffi]
        \\extern fn audited_bare_ext() -> void;
        \\#[unsafe_ffi]
        \\extern "C" fn audited_c_ext() -> void;
        \\export fn exported_c() -> void {}
        \\#[unsafe_ffi]
        \\export fn audited_export() -> void {}
        \\#[mc_abi]
        \\export fn mc_export() -> void {}
        \\extern global ext_counter: u32;
        \\#[unsafe_ffi]
        \\extern global audited_ext_counter: u32;
        \\export global published_counter: u32 = 1;
        \\#[unsafe_ffi]
        \\export global audited_published_counter: u32 = 1;
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "safe_module_ffi_boundary.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_SAFE_MODULE_FFI_BOUNDARY
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_SAFE_MODULE_FFI_BOUNDARY"));
}

test "unsafe ffi declarations require unsafe calls" {
    const source =
        \\#[safe_module]
        \\struct Marker { id: u32 }
        \\#[unsafe_ffi]
        \\extern "C" fn c_ping() -> u32;
        \\#[unsafe_ffi]
        \\export fn exported_ping() -> u32 {
        \\    return 1;
        \\}
        \\#[unsafe_ffi]
        \\#[mc_abi]
        \\export fn exported_mc_ping() -> u32 {
        \\    return 2;
        \\}
        \\fn reject_extern_call() -> u32 {
        \\    return c_ping();
        \\}
        \\fn reject_export_call() -> u32 {
        \\    return exported_ping();
        \\}
        \\fn consume_callback(cb: fn() -> u32) -> u32 {
        \\    return cb();
        \\}
        \\fn reject_unsafe_fnptr_bind() -> u32 {
        \\    let cb: fn() -> u32 = exported_mc_ping;
        \\    return cb();
        \\}
        \\fn reject_unsafe_fnptr_infer() -> u32 {
        \\    let cb = exported_mc_ping;
        \\    return cb();
        \\}
        \\fn reject_fnptr_argument() -> u32 {
        \\    return consume_callback(exported_mc_ping);
        \\}
        \\fn accept_wrapped_calls() -> u32 {
        \\    unsafe {
        \\        return c_ping() + exported_ping();
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "unsafe_ffi_call_boundary.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNSAFE_REQUIRED
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_UNSAFE_REQUIRED"));
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_SAFE_MODULE_FFI_BOUNDARY"));
}

test "unsafe ffi data symbols require unsafe access" {
    const source =
        \\#[safe_module]
        \\struct Marker { id: u32 }
        \\#[unsafe_ffi]
        \\extern global ext_counter: u32;
        \\#[unsafe_ffi]
        \\export global published_counter: u32 = 1;
        \\fn reject_read() -> u32 {
        \\    return ext_counter + published_counter;
        \\}
        \\fn reject_write() -> void {
        \\    ext_counter = 1;
        \\    published_counter = 2;
        \\}
        \\fn accept_wrapped_access() -> u32 {
        \\    unsafe {
        \\        ext_counter = 3;
        \\        published_counter = 4;
        \\        return ext_counter + published_counter;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "unsafe_ffi_data_boundary.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNSAFE_REQUIRED
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_UNSAFE_REQUIRED"));
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_SAFE_MODULE_FFI_BOUNDARY"));
}

test "raw pointer minting requires unsafe context" {
    const source =
        \\fn reject_raw_ptr(addr: PAddr) -> *mut u32 {
        \\    return raw.ptr<u32>(addr);
        \\}
        \\fn reject_integer_pointer_cast(addr: usize) -> *mut u32 {
        \\    return addr as *mut u32;
        \\}
        \\fn accept_raw_ptr(addr: PAddr) -> *mut u32 {
        \\    unsafe {
        \\        return raw.ptr<u32>(addr);
        \\    }
        \\}
        \\fn accept_integer_pointer_cast(addr: usize) -> *mut u32 {
        \\    unsafe {
        \\        return addr as *mut u32;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "raw_ptr_requires_unsafe.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNSAFE_REQUIRED
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_UNSAFE_REQUIRED"));
}

test "checked resource casts require unsafe context" {
    const source =
        \\move struct Ticket { id: u32 }
        \\move struct OtherTicket { id: u32 }
        \\struct Plain { id: u32 }
        \\fn issue() -> Ticket { return .{ .id = 1 }; }
        \\fn reject_resource_to_integer() -> usize {
        \\    let ticket: Ticket = issue();
        \\    return ticket as usize;
        \\}
        \\fn reject_resource_to_plain() -> Plain {
        \\    let ticket: Ticket = issue();
        \\    return ticket as Plain;
        \\}
        \\fn reject_plain_to_resource(plain: Plain) -> Ticket {
        \\    return plain as Ticket;
        \\}
        \\fn reject_resource_to_resource(ticket: Ticket) -> OtherTicket {
        \\    return ticket as OtherTicket;
        \\}
        \\fn accept_identity_cast(ticket: Ticket) -> Ticket {
        \\    return move (ticket as Ticket);
        \\}
        \\fn accept_unsafe_resource_cast(ticket: Ticket) -> usize {
        \\    unsafe {
        \\        return ticket as usize;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "resource_cast_boundary.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNSAFE_REQUIRED
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_UNSAFE_REQUIRED"));
}

test "c_void casts cannot erase ownership resource provenance in safe code" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn reject_move_pointer_to_void(ptr: *Ticket) -> *const c_void {
        \\    return ptr as *const c_void;
        \\}
        \\fn reject_move_address_to_void(ticket: Ticket) -> *const c_void {
        \\    return (&ticket) as *const c_void;
        \\}
        \\fn reject_region_pointer_to_void(ptr: *mut Node) -> *mut c_void {
        \\    return ptr as *mut c_void;
        \\}
        \\fn reject_view_pointer_to_void(ptr: *PlainView) -> *const c_void {
        \\    return ptr as *const c_void;
        \\}
        \\fn reject_void_to_move_pointer(raw: *const c_void) -> *Ticket {
        \\    return raw as *Ticket;
        \\}
        \\fn accept_plain_pointer_to_void(ptr: *Plain) -> *const c_void {
        \\    return ptr as *const c_void;
        \\}
        \\fn accept_unsafe_move_pointer_to_void(ptr: *Ticket) -> *const c_void {
        \\    unsafe {
        \\        return ptr as *const c_void;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "resource_c_void_cast_boundary.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNSAFE_REQUIRED
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_UNSAFE_REQUIRED"));
}

test "implicit c_void conversions cannot erase ownership resource provenance in safe code" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn take_void(ptr: *const c_void) -> void {}
        \\fn take_ticket(ptr: *Ticket) -> void {}
        \\fn reject_move_pointer_init(ptr: *Ticket) -> void {
        \\    let erased: *const c_void = ptr;
        \\}
        \\fn reject_move_address_init(ticket: Ticket) -> void {
        \\    let erased: *const c_void = &ticket;
        \\}
        \\fn reject_region_pointer_return(ptr: *mut Node) -> *mut c_void {
        \\    return ptr;
        \\}
        \\fn reject_view_pointer_arg(ptr: *PlainView) -> void {
        \\    take_void(ptr);
        \\}
        \\fn reject_void_to_move_return(raw: *const c_void) -> *Ticket {
        \\    return raw;
        \\}
        \\fn reject_void_to_move_arg(raw: *const c_void) -> void {
        \\    take_ticket(raw);
        \\}
        \\fn accept_plain_pointer_init(ptr: *Plain) -> void {
        \\    let erased: *const c_void = ptr;
        \\}
        \\fn accept_unsafe_move_pointer_init(ptr: *Ticket) -> void {
        \\    unsafe {
        \\        let erased: *const c_void = ptr;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "resource_c_void_implicit_boundary.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_UNSAFE_REQUIRED
    try std.testing.expectEqual(@as(usize, 6), countDiagnosticCode(&reporter, "E_UNSAFE_REQUIRED"));
}

test "safe module keeps raw pointer dereference behind unsafe and allows scoped borrow" {
    const source =
        \\#[safe_module]
        \\struct Cell { value: u32 }
        \\fn inspect(cell: *Cell) -> u32 {
        \\    unsafe {
        \\        return cell.value;
        \\    }
        \\}
        \\fn reject_param_field(cell: *Cell) -> u32 {
        \\    return cell.value;
        \\}
        \\fn reject_param_deref(cell: *Cell) -> u32 {
        \\    return cell.*.value;
        \\}
        \\fn raw_address_rejected() -> u32 {
        \\    var cell: Cell = .{ .value = 1 };
        \\    let ptr: *Cell = &cell;
        \\    return inspect(ptr);
        \\}
        \\fn raw_address_allowed_inside_unsafe() -> u32 {
        \\    var cell: Cell = .{ .value = 2 };
        \\    unsafe {
        \\        let ptr: *Cell = &cell;
        \\        return inspect(ptr);
        \\    }
        \\}
        \\fn scoped_borrow_allowed() -> u32 {
        \\    var cell: Cell = .{ .value = 3 };
        \\    let ptr: *Cell = borrow cell;
        \\    return ptr.value;
        \\}
        \\fn scoped_borrow_assignment_allowed() -> u32 {
        \\    var cell: Cell = .{ .value = 4 };
        \\    var ptr: *Cell = borrow cell;
        \\    ptr = borrow cell;
        \\    return ptr.value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "safe_module_address_of.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_SAFE_MODULE_ADDRESS_OF
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_SAFE_MODULE_ADDRESS_OF"));
    // DIAGNOSTIC_UNIT: E_SAFE_MODULE_POINTER_DEREF
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_SAFE_MODULE_POINTER_DEREF"));
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_BORROW_ESCAPES_SCOPE"));
}

test "safe module requires unsafe for pointer reinterpret casts" {
    const source =
        \\#[safe_module]
        \\struct A { value: u32 }
        \\struct B { value: u32 }
        \\fn reject_pointer_reinterpret(ptr: *A) -> *B {
        \\    return ptr as *B;
        \\}
        \\fn reject_mut_pointer_reinterpret(ptr: *mut A) -> *mut B {
        \\    return ptr as *mut B;
        \\}
        \\fn accept_identity_cast(ptr: *A) -> *A {
        \\    return ptr as *A;
        \\}
        \\fn accept_const_narrow(ptr: *mut A) -> *const A {
        \\    return ptr as *const A;
        \\}
        \\fn accept_unsafe_reinterpret(ptr: *A) -> *B {
        \\    unsafe {
        \\        return ptr as *B;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "safe_module_pointer_cast.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_SAFE_MODULE_POINTER_CAST
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_SAFE_MODULE_POINTER_CAST"));
}

test "scoped borrow blocks moves and conflicting mutable borrows" {
    const source =
        \\move struct Ticket { id: u32 }
        \\fn issue_ticket() -> Ticket { return .{ .id = 1 }; }
        \\fn touch(t: *mut Ticket) -> void {
        \\    t.id = t.id + 1;
        \\}
        \\fn consume(t: Ticket) -> u32 {
        \\    let id: u32 = t.id;
        \\    unsafe { forget_unchecked(t); }
        \\    return id;
        \\}
        \\fn mutate2(a: *mut Ticket, b: *mut Ticket) -> void {
        \\    a.id = b.id;
        \\}
        \\fn handoff(p: *mut Ticket, t: Ticket) -> u32 {
        \\    p.id = t.id;
        \\    unsafe { forget_unchecked(t); }
        \\    return p.id;
        \\}
        \\fn accept_shared_borrows_then_move() -> u32 {
        \\    let t: Ticket = issue_ticket();
        \\    {
        \\        let a: *Ticket = borrow t;
        \\        let b: *Ticket = borrow t;
        \\        let x: u32 = a.id + b.id;
        \\    }
        \\    return consume(move t);
        \\}
        \\fn reject_move_while_shared_borrow_live() -> u32 {
        \\    let t: Ticket = issue_ticket();
        \\    let a: *Ticket = borrow t;
        \\    return consume(t);
        \\}
        \\fn reject_mut_borrow_while_shared_live() -> u32 {
        \\    var t: Ticket = issue_ticket();
        \\    let a: *Ticket = borrow t;
        \\    let b: *mut Ticket = borrow mut t;
        \\    return a.id + b.id;
        \\}
        \\fn reject_second_mut_borrow() -> u32 {
        \\    var t: Ticket = issue_ticket();
        \\    let a: *mut Ticket = borrow mut t;
        \\    let b: *mut Ticket = borrow mut t;
        \\    return a.id + b.id;
        \\}
        \\fn reject_call_arg_second_mut_borrow() -> void {
        \\    var t: Ticket = issue_ticket();
        \\    mutate2(borrow mut t, borrow mut t);
        \\    unsafe { forget_unchecked(t); }
        \\}
        \\fn reject_call_arg_borrow_and_move() -> u32 {
        \\    var t: Ticket = issue_ticket();
        \\    return handoff(borrow mut t, move t);
        \\}
        \\fn reject_reborrow_alias_conflict() -> u32 {
        \\    var t: Ticket = issue_ticket();
        \\    let p: *mut Ticket = borrow mut t;
        \\    let q: *mut Ticket = borrow mut p.*;
        \\    return p.id + q.id;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "scoped_borrow.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_CONFLICT
    try std.testing.expectEqual(@as(usize, 6), countDiagnosticCode(&reporter, "E_BORROW_CONFLICT"));
}

test "scoped borrow ends at lexical block before move" {
    const source =
        \\move struct Ticket { id: u32 }
        \\fn issue_ticket() -> Ticket { return .{ .id = 1 }; }
        \\fn touch(t: *mut Ticket) -> void {
        \\    t.id = t.id + 1;
        \\}
        \\fn consume(t: Ticket) -> u32 {
        \\    let id: u32 = t.id;
        \\    unsafe { forget_unchecked(t); }
        \\    return id;
        \\}
        \\fn accept_shared_borrows_then_move() -> u32 {
        \\    let t: Ticket = issue_ticket();
        \\    {
        \\        let a: *Ticket = borrow t;
        \\        let b: *Ticket = borrow t;
        \\        let x: u32 = a.id + b.id;
        \\    }
        \\    return consume(move t);
        \\}
        \\fn accept_call_borrow_ends_after_full_expression() -> u32 {
        \\    var t: Ticket = issue_ticket();
        \\    touch(borrow mut t);
        \\    touch(borrow mut t);
        \\    return consume(move t);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "scoped_borrow_accept.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    try std.testing.expect(!reporter.has_errors);
}

test "shared borrow cannot satisfy mutable pointer targets" {
    const source =
        \\struct Cell { value: u32 }
        \\fn write_cell(c: *mut Cell) -> void {
        \\    c.value = 1;
        \\}
        \\fn accept_mut_borrow() -> void {
        \\    var c: Cell = .{ .value = 0 };
        \\    let p: *mut Cell = borrow mut c;
        \\    write_cell(borrow mut c);
        \\    p.value = 2;
        \\}
        \\fn reject_init() -> void {
        \\    var c: Cell = .{ .value = 0 };
        \\    let p: *mut Cell = borrow c;
        \\    p.value = 2;
        \\}
        \\fn reject_call() -> void {
        \\    var c: Cell = .{ .value = 0 };
        \\    write_cell(borrow c);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "borrow_mut_required.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_MUT_REQUIRED
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_BORROW_MUT_REQUIRED"));
}

test "explicit borrow requires addressable mutable storage" {
    const source =
        \\struct Cell { value: u32 }
        \\fn make_cell() -> Cell {
        \\    return .{ .value = 1 };
        \\}
        \\fn accept_local_borrow() -> u32 {
        \\    let cell: Cell = make_cell();
        \\    let ptr: *Cell = borrow cell;
        \\    return ptr.value;
        \\}
        \\fn reject_temporary_borrow() -> *Cell {
        \\    return borrow make_cell();
        \\}
        \\fn reject_literal_borrow() -> *Cell {
        \\    return borrow .{ .value = 2 };
        \\}
        \\fn reject_mut_borrow_of_immutable() -> *Cell {
        \\    let cell: Cell = make_cell();
        \\    return borrow mut cell;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "borrow_requires_storage.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_REQUIRES_STORAGE
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_BORROW_REQUIRES_STORAGE"));
    // DIAGNOSTIC_UNIT: E_BORROW_MUT_REQUIRES_MUTABLE_STORAGE
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_BORROW_MUT_REQUIRES_MUTABLE_STORAGE"));
}

test "scoped borrow conflicts apply to ordinary locals" {
    const source =
        \\struct Cell { value: u32 }
        \\struct Pair { left: u32, right: u32 }
        \\fn reject_plain_mut_after_shared() -> u32 {
        \\    var c: Cell = .{ .value = 0 };
        \\    let a: *Cell = borrow c;
        \\    let b: *mut Cell = borrow mut c;
        \\    return a.value + b.value;
        \\}
        \\fn reject_plain_second_mut() -> u32 {
        \\    var c: Cell = .{ .value = 0 };
        \\    let a: *mut Cell = borrow mut c;
        \\    let b: *mut Cell = borrow mut c;
        \\    return a.value + b.value;
        \\}
        \\fn reject_plain_assign_while_borrowed() -> u32 {
        \\    var c: Cell = .{ .value = 0 };
        \\    let a: *Cell = borrow c;
        \\    c = .{ .value = 2 };
        \\    return a.value;
        \\}
        \\fn reject_field_assign_while_field_borrowed() -> u32 {
        \\    var pair: Pair = .{ .left = 1, .right = 2 };
        \\    let left: *u32 = borrow pair.left;
        \\    pair.left = 3;
        \\    return pair.right;
        \\}
        \\fn reject_whole_assign_while_field_borrowed() -> u32 {
        \\    var pair: Pair = .{ .left = 1, .right = 2 };
        \\    let left: *u32 = borrow pair.left;
        \\    pair = .{ .left = 3, .right = 4 };
        \\    return pair.right;
        \\}
        \\fn reject_index_assign_while_element_borrowed() -> u32 {
        \\    var items: [2]u32 = .{ 1, 2 };
        \\    let first: *u32 = borrow items[0];
        \\    items[1] = 3;
        \\    return items[1];
        \\}
        \\fn accept_after_block() -> u32 {
        \\    var c: Cell = .{ .value = 0 };
        \\    {
        \\        let a: *Cell = borrow c;
        \\        let value: u32 = a.value;
        \\    }
        \\    c = .{ .value = 3 };
        \\    let b: *mut Cell = borrow mut c;
        \\    return b.value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "plain_scoped_borrow.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_CONFLICT
    try std.testing.expectEqual(@as(usize, 6), countDiagnosticCode(&reporter, "E_BORROW_CONFLICT"));
}

test "explicit borrow cannot be stored inside ordinary aggregates" {
    const source =
        \\struct Cell { value: u32 }
        \\struct Holder { ptr: *Cell }
        \\fn reject_struct_literal() -> Holder {
        \\    var c: Cell = .{ .value = 1 };
        \\    return .{ .ptr = borrow c };
        \\}
        \\fn reject_array_literal() -> *Cell {
        \\    var c: Cell = .{ .value = 1 };
        \\    let items: [1]*Cell = .{ borrow c };
        \\    return items[0];
        \\}
        \\fn reject_struct_field_assignment() -> Holder {
        \\    var c: Cell = .{ .value = 1 };
        \\    var h: Holder = .{ .ptr = null };
        \\    h.ptr = borrow c;
        \\    return h;
        \\}
        \\fn reject_array_element_assignment() -> *Cell {
        \\    var c: Cell = .{ .value = 1 };
        \\    var items: [1]*Cell = .{ null };
        \\    items[0] = borrow c;
        \\    return items[0];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "borrow_aggregate_escape.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_BORROW_ESCAPES_SCOPE"));
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_LOCAL_ADDRESS_ESCAPE"));
}

test "view structs are lexical borrow aggregates" {
    const source =
        \\struct Cell { value: u32 }
        \\struct E { code: u32 }
        \\view struct CellView { ptr: *Cell }
        \\view struct CellViewWithLen { ptr: *Cell, len: usize }
        \\view struct NestedCellView { inner: CellView }
        \\struct BadStoredView { view: CellView }
        \\struct BadStoredViewArray { views: [2]CellView }
        \\struct BadStoredOptionalView { view: ?CellView }
        \\move struct BadMoveStoredView { view: CellView }
        \\region struct BadRegionStoredView { view: CellView }
        \\global saved: CellView = .{ .ptr = null };
        \\fn accept_local_view() -> u32 {
        \\    var c: Cell = .{ .value = 1 };
        \\    let view: CellView = .{ .ptr = borrow c };
        \\    return view.ptr.value;
        \\}
        \\fn accept_return_source_view(cell: *Cell) -> borrow(cell) CellView {
        \\    return .{ .ptr = cell };
        \\}
        \\fn accept_nested_view(cell: *Cell) -> borrow(cell) NestedCellView {
        \\    return .{ .inner = .{ .ptr = cell } };
        \\}
        \\fn reject_borrow_result_view(cell: *Cell) -> borrow(cell) Result<CellView, E> {
        \\    return ok(.{ .ptr = cell });
        \\}
        \\fn reject_borrow_optional_view(cell: *Cell) -> borrow(cell) ?CellView {
        \\    return .{ .ptr = cell };
        \\}
        \\fn reject_borrow_array_view(cell: *Cell) -> borrow(cell) [1]CellView {
        \\    return .{ .{ .ptr = cell } };
        \\}
        \\fn reject_result_view_local() -> void {
        \\    var c: Cell = .{ .value = 1 };
        \\    let view: CellView = .{ .ptr = borrow c };
        \\    let wrapped: Result<CellView, E> = ok(view);
        \\}
        \\fn reject_optional_view_local() -> void {
        \\    var c: Cell = .{ .value = 1 };
        \\    let view: CellView = .{ .ptr = borrow c };
        \\    let wrapped: ?CellView = view;
        \\}
        \\fn reject_array_view_local() -> void {
        \\    var c: Cell = .{ .value = 1 };
        \\    let view: CellView = .{ .ptr = borrow c };
        \\    let wrapped: [1]CellView = .{ view };
        \\}
        \\fn reject_return_other_view(cell: *Cell, other: *Cell) -> borrow(cell) CellView {
        \\    return .{ .ptr = other };
        \\}
        \\fn reject_return_mixed_source_view(cell: *Cell, other: *Cell) -> borrow(cell) CellViewWithLen {
        \\    return .{ .ptr = other, .len = cell.value as usize };
        \\}
        \\fn reject_param_view(view: CellView) -> u32 {
        \\    return view.ptr.value;
        \\}
        \\fn reject_plain_return(cell: *Cell) -> CellView {
        \\    return .{ .ptr = cell };
        \\}
        \\fn reject_result_local_view() -> Result<CellView, bool> {
        \\    var c: Cell = .{ .value = 1 };
        \\    let view: CellView = .{ .ptr = borrow c };
        \\    return ok(view);
        \\}
        \\fn reject_bad_combo() -> void {
        \\}
        \\view move struct BadView { ptr: *Cell }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "view_struct_borrow_aggregate.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_ESCAPES_SCOPE
    try std.testing.expectEqual(@as(usize, 13), countDiagnosticCode(&reporter, "E_BORROW_ESCAPES_SCOPE"));
    // DIAGNOSTIC_UNIT: E_BORROW_RETURN_CONTRACT
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_BORROW_RETURN_CONTRACT"));
}

test "explicit borrow cannot cross extern C ABI call boundaries" {
    const source =
        \\struct Cell { value: u32 }
        \\extern "C" fn c_take(cell: *Cell) -> void;
        \\extern fn extern_take(cell: *Cell) -> void;
        \\export fn exported_take(cell: *Cell) -> void {
        \\    let value: u32 = cell.value;
        \\}
        \\#[mc_abi]
        \\export fn mc_take(cell: *Cell) -> void {
        \\    let value: u32 = cell.value;
        \\}
        \\fn local_take(cell: *Cell) -> void {
        \\    let value: u32 = cell.value;
        \\}
        \\fn use_borrow() -> void {
        \\    var c: Cell = .{ .value = 1 };
        \\    c_take(borrow c);
        \\    extern_take(borrow c);
        \\    exported_take(borrow c);
        \\    mc_take(borrow c);
        \\    local_take(borrow c);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "borrow_ffi_boundary.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_FFI_BOUNDARY
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_BORROW_FFI_BOUNDARY"));
}

test "explicit borrow cannot be stored into escaping storage" {
    const source =
        \\struct Cell { value: u32 }
        \\struct Holder { ptr: *Cell }
        \\global saved: ?*Cell = null;
        \\fn accept_lexical_parameter_view(cell: *Cell) -> u32 {
        \\    let view: *Cell = borrow cell.*;
        \\    return view.value;
        \\}
        \\fn reject_global_parameter_view(cell: *Cell) -> void {
        \\    saved = borrow cell.*;
        \\}
        \\fn reject_out_parameter_view(out: *mut Holder, cell: *Cell) -> void {
        \\    out.ptr = borrow cell.*;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "borrow_escaping_storage.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_ESCAPES_SCOPE
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_BORROW_ESCAPES_SCOPE"));
}

test "safe extern calls cannot receive pointers to resource storage" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct Node { id: u32 }
        \\extern "C" fn inspect_ticket(ticket: *const Ticket) -> void;
        \\extern "C" fn inspect_void(handle: *const c_void) -> void;
        \\extern "C" fn inspect_region(node: *mut Node) -> void;
        \\extern "C" fn log_ptr(format: cstr, ...) -> void;
        \\fn reject_direct_address() -> void {
        \\    var ticket: Ticket = .{ .id = 1 };
        \\    inspect_ticket(&ticket);
        \\    unsafe { forget_unchecked(ticket); }
        \\}
        \\fn reject_c_void_cast() -> void {
        \\    var ticket: Ticket = .{ .id = 2 };
        \\    inspect_void((&ticket) as *const c_void);
        \\    unsafe { forget_unchecked(ticket); }
        \\}
        \\fn reject_laundered_pointer() -> void {
        \\    var ticket: Ticket = .{ .id = 3 };
        \\    let ptr: *const Ticket = &ticket;
        \\    inspect_ticket(ptr);
        \\    unsafe { forget_unchecked(ticket); }
        \\}
        \\fn reject_variadic_tail() -> void {
        \\    var ticket: Ticket = .{ .id = 4 };
        \\    log_ptr("%p", &ticket);
        \\    unsafe { forget_unchecked(ticket); }
        \\}
        \\fn reject_region_pointer(node: *mut Node) -> void {
        \\    inspect_region(node);
        \\}
        \\fn accept_inside_unsafe(ticket: *const Ticket, node: *mut Node) -> void {
        \\    unsafe {
        \\        inspect_ticket(ticket);
        \\        inspect_region(node);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "resource_ffi_pointer_boundary.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_MOVE_FFI_ADDRESS
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_MOVE_FFI_ADDRESS"));
}

test "single-source return borrow contracts are checked conservatively" {
    const source =
        \\struct Cell { value: u32 }
        \\struct Box { ptr: *Cell }
        \\fn ok(cell: *Cell) -> borrow(cell) *Cell {
        \\    return cell;
        \\}
        \\fn ok_member(box: *Box) -> borrow(box) *Cell {
        \\    return box.ptr;
        \\}
        \\fn choose(cell: *Cell) -> *Cell {
        \\    return cell;
        \\}
        \\fn reject_call_path(cell: *Cell) -> borrow(cell) *Cell {
        \\    return choose(cell);
        \\}
        \\fn wrong_source(cell: *Cell, other: *Cell) -> borrow(cell) *Cell {
        \\    return other;
        \\}
        \\fn missing_source(cell: *Cell) -> borrow(other) *Cell {
        \\    return cell;
        \\}
        \\fn non_view_source(value: u32) -> borrow(value) *Cell {
        \\    return null;
        \\}
        \\fn non_view_return(cell: *Cell) -> borrow(cell) u32 {
        \\    return 1;
        \\}
        \\fn explicit_borrow_escape() -> *Cell {
        \\    var cell: Cell = .{ .value = 1 };
        \\    return borrow cell;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "return_borrow_contract.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_RETURN_CONTRACT
    try std.testing.expectEqual(@as(usize, 5), countDiagnosticCode(&reporter, "E_BORROW_RETURN_CONTRACT"));
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_BORROW_ESCAPES_SCOPE"));
}

test "scoped borrow cannot escape through returned wrappers" {
    const source =
        \\struct Cell { value: u32 }
        \\enum E { Bad }
        \\fn accept_param_result(cell: *Cell) -> Result<*Cell, E> {
        \\    return ok(cell);
        \\}
        \\fn reject_result_local_view() -> Result<*Cell, E> {
        \\    var cell: Cell = .{ .value = 1 };
        \\    let view: *Cell = borrow cell;
        \\    return ok(view);
        \\}
        \\fn reject_result_direct_borrow() -> Result<*Cell, E> {
        \\    var cell: Cell = .{ .value = 1 };
        \\    return ok(borrow cell);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "borrow_return_wrapper_escape.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_ESCAPES_SCOPE
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_BORROW_ESCAPES_SCOPE"));
}

test "explicit borrow cannot be captured by bind closure environment" {
    const source =
        \\struct Cell { value: u32 }
        \\fn callback(env: *Cell, value: u32) -> u32 {
        \\    return env.value + value;
        \\}
        \\fn reject_capture() -> void {
        \\    var cell: Cell = .{ .value = 1 };
        \\    let cb: closure(u32) -> u32 = bind(borrow cell, callback);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "borrow_closure_capture.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);
    // DIAGNOSTIC_UNIT: E_BORROW_ESCAPES_SCOPE
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_BORROW_ESCAPES_SCOPE"));
}

test "move alias query depth exhaustion fails closed" {
    const span = ast.Span{ .offset = 0, .len = 1, .line = 1, .column = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.StringHashMap(ast.TypeExpr).init(std.testing.allocator);
    defer aliases.deinit();
    var previous: []const u8 = "Token";
    var final_name: []const u8 = previous;
    for (0..66) |i| {
        const name = try std.fmt.allocPrint(arena.allocator(), "A{d}", .{i});
        try aliases.put(name, .{ .span = span, .kind = .{ .name = .{ .text = previous, .span = span } } });
        previous = name;
        final_name = name;
    }
    const queried = ast.TypeExpr{ .span = span, .kind = .{ .name = .{ .text = final_name, .span = span } } };
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "deep_move_alias.mc", "");
    defer reporter.deinit();
    var checker = sema.Checker.init(&reporter);
    try std.testing.expect(checker.typeEmbedsMoveByValue(queried, &aliases));
}

test "move CFG skeleton joins branch states through worklist" {
    var cfg = sema_model.MoveCfg.init(std.testing.allocator);
    defer cfg.deinit();

    const entry = try cfg.addBlock(.entry);
    const then_block = try cfg.addBlock(.statement);
    const else_block = try cfg.addBlock(.statement);
    const join = try cfg.addBlock(.branch_join);
    try cfg.addEdge(entry, then_block, .branch);
    try cfg.addEdge(entry, else_block, .branch);
    try cfg.addEdge(then_block, join, .normal);
    try cfg.addEdge(else_block, join, .normal);

    var worklist = try sema_model.MoveCfgWorklist.init(std.testing.allocator, &cfg, entry, .{});
    defer worklist.deinit();

    try std.testing.expectEqual(entry, worklist.pop().?);
    _ = try worklist.propagateSuccessors(entry, worklist.state(entry).?);
    try std.testing.expectEqual(then_block, worklist.pop().?);
    try std.testing.expectEqual(else_block, worklist.pop().?);

    _ = try worklist.propagateSuccessors(then_block, worklist.state(then_block).?.withMoved(0));
    _ = try worklist.propagateSuccessors(else_block, worklist.state(else_block).?.withMoved(1));

    const joined = worklist.state(join) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0b11), joined.moved_mask);
    try std.testing.expectEqual(join, worklist.pop().?);
}

test "move CFG skeleton requeues loop head on backedge state change" {
    var cfg = sema_model.MoveCfg.init(std.testing.allocator);
    defer cfg.deinit();

    const entry = try cfg.addBlock(.entry);
    const loop_head = try cfg.addBlock(.loop_head);
    const body = try cfg.addBlock(.statement);
    try cfg.addEdge(entry, loop_head, .normal);
    try cfg.addEdge(loop_head, body, .normal);
    try cfg.addEdge(body, loop_head, .backedge);

    var worklist = try sema_model.MoveCfgWorklist.init(std.testing.allocator, &cfg, entry, .{});
    defer worklist.deinit();

    try std.testing.expectEqual(entry, worklist.pop().?);
    _ = try worklist.propagateSuccessors(entry, worklist.state(entry).?);
    try std.testing.expectEqual(loop_head, worklist.pop().?);
    _ = try worklist.propagateSuccessors(loop_head, worklist.state(loop_head).?);
    try std.testing.expectEqual(body, worklist.pop().?);

    _ = try worklist.propagateSuccessors(body, worklist.state(body).?.withMoved(2));
    const loop_state = worklist.state(loop_head) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0b100), loop_state.moved_mask);
    try std.testing.expectEqual(loop_head, worklist.pop().?);
}

test "move CFG skeleton carries early-exit state to exit block" {
    var cfg = sema_model.MoveCfg.init(std.testing.allocator);
    defer cfg.deinit();

    const entry = try cfg.addBlock(.entry);
    const body = try cfg.addBlock(.statement);
    const exit = try cfg.addBlock(.exit);
    try cfg.addEdge(entry, body, .normal);
    try cfg.addEdge(body, exit, .early_exit);

    var worklist = try sema_model.MoveCfgWorklist.init(std.testing.allocator, &cfg, entry, .{});
    defer worklist.deinit();

    try std.testing.expectEqual(entry, worklist.pop().?);
    _ = try worklist.propagateSuccessors(entry, worklist.state(entry).?);
    try std.testing.expectEqual(body, worklist.pop().?);
    _ = try worklist.propagateSuccessors(body, worklist.state(body).?.withMoved(3));

    const exit_state = worklist.state(exit) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0b1000), exit_state.moved_mask);
    try std.testing.expectEqual(exit, worklist.pop().?);
}

test "move dynamic-place policy separates symbolic identity from overlap" {
    const root: sema_model.MovePlace = .{ .root = "arr" };
    const symbolic_i = root.project(.{ .symbolic_index = "i" }).?;
    const same_symbolic_i = root.project(.{ .symbolic_index = "i" }).?;
    const symbolic_j = root.project(.{ .symbolic_index = "j" }).?;
    const constant_zero = root.project(.{ .constant_index = 0 }).?;
    const constant_one = root.project(.{ .constant_index = 1 }).?;
    const wildcard = root.project(.wildcard_index).?;

    try std.testing.expect(symbolic_i.eql(same_symbolic_i));
    try std.testing.expect(symbolic_i.conflicts(same_symbolic_i));
    try std.testing.expect(!symbolic_i.eql(symbolic_j));
    try std.testing.expect(symbolic_i.conflicts(symbolic_j));
    try std.testing.expect(!symbolic_i.eql(constant_zero));
    try std.testing.expect(symbolic_i.conflicts(constant_zero));
    try std.testing.expect(!constant_zero.conflicts(constant_one));
    try std.testing.expect(wildcard.conflicts(symbolic_i));
    try std.testing.expect(wildcard.conflicts(constant_zero));
}

test "move dynamic-place policy keeps wildcard indexes behind field boundaries" {
    const root: sema_model.MovePlace = .{ .root = "arr" };
    const field = root.project(.{ .field = "items" }).?;
    const wildcard = root.project(.wildcard_index).?;
    const symbolic = root.project(.{ .symbolic_index = "i" }).?;

    try std.testing.expectEqual(
        sema_model.MovePlaceProjectionRelation.disjoint,
        sema_model.movePlaceProjectionRelation(.wildcard_index, .{ .field = "items" }),
    );
    try std.testing.expectEqual(
        sema_model.MovePlaceProjectionRelation.may_overlap,
        sema_model.movePlaceProjectionRelation(.wildcard_index, .{ .symbolic_index = "i" }),
    );
    try std.testing.expectEqual(
        sema_model.MovePlaceProjectionRelation.may_overlap,
        sema_model.movePlaceProjectionRelation(.{ .symbolic_index = "i" }, .{ .constant_index = 0 }),
    );
    try std.testing.expect(!field.conflicts(wildcard));
    try std.testing.expect(!field.conflicts(symbolic));
}

test "allocation failure across parse monomorphize and sema never reports clean success" {
    {
        const source = "fn main() -> void {}\n";
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena.deinit();

        var reporter = diagnostics.Reporter.init(std.testing.allocator, "parse_oom.mc", source);
        defer reporter.deinit();

        const parsed = parseWithAllocator(source, arena.allocator(), &reporter);
        if (parsed) |module| {
            module.deinit(arena.allocator());
            try std.testing.expect(reporter.has_errors);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }

    {
        const source =
            \\fn make(comptime N: usize) -> [N]u8 {
            \\    var scratch: [N]u8 = uninit;
            \\    scratch[0] = 0;
            \\    return scratch;
            \\}
            \\
            \\fn trigger() -> u8 {
            \\    let a: [1]u8 = make(1);
            \\    return a[0];
            \\}
        ;

        var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "mono_oom_pipeline.mc", source);
        defer parse_reporter.deinit();
        var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer parse_arena.deinit();

        const module = try parseWithAllocator(source, parse_arena.allocator(), &parse_reporter);
        try std.testing.expect(!parse_reporter.has_errors);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var mono_arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer mono_arena.deinit();

        var reporter = diagnostics.Reporter.init(std.testing.allocator, "mono_oom_pipeline.mc", source);
        defer reporter.deinit();

        const specialized = monomorphize.transformReport(mono_arena.allocator(), module, &reporter);
        if (specialized) |_| {
            try std.testing.expect(reporter.has_errors);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }

    {
        const source =
            \\fn id(x: u32) -> u32 {
            \\    return x;
            \\}
            \\
            \\fn main() -> u32 {
            \\    return id(1);
            \\}
        ;

        var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "sema_oom.mc", source);
        defer parse_reporter.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const module = try parseWithAllocator(source, arena.allocator(), &parse_reporter);
        try std.testing.expect(!parse_reporter.has_errors);
        const specialized = try monomorphize.transformReport(arena.allocator(), module, &parse_reporter);
        try std.testing.expect(!parse_reporter.has_errors);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var reporter = diagnostics.Reporter.init(failing.allocator(), "sema_oom.mc", source);
        defer reporter.deinit();

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(specialized);

        try std.testing.expect(reporter.has_errors);
        try std.testing.expect(checker.oom);
    }
}

test "allocation failure while checking type alias cycles fails closed" {
    const source =
        \\type A = B;
        \\type B = A;
        \\
        \\fn main() -> void {}
    ;

    var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "alias_cycle_oom.mc", source);
    defer parse_reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseWithAllocator(source, arena.allocator(), &parse_reporter);
    try std.testing.expect(!parse_reporter.has_errors);

    var saw_oom = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reporter = diagnostics.Reporter.init(failing.allocator(), "alias_cycle_oom.mc", source);
        defer reporter.deinit();

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(module);

        try std.testing.expect(reporter.has_errors or checker.oom);
        if (checker.oom) saw_oom = true;
    }
    try std.testing.expect(saw_oom);
}

test "allocation failure while tracking asm register conflicts fails closed" {
    const source =
        \\fn reject_asm_register_conflict(x: u64) -> u64 {
        \\    var out_val: u64 = 0;
        \\    #[unsafe_contract(precise_asm)] {
        \\        unsafe {
        \\            asm precise volatile {
        \\                "nop"
        \\                out("rax") out_val: u64,
        \\                in("rax") x: u64
        \\            }
        \\        }
        \\    }
        \\    return out_val;
        \\}
    ;

    var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "asm_conflict_oom.mc", source);
    defer parse_reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseWithAllocator(source, arena.allocator(), &parse_reporter);
    try std.testing.expect(!parse_reporter.has_errors);

    var saw_oom = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reporter = diagnostics.Reporter.init(failing.allocator(), "asm_conflict_oom.mc", source);
        defer reporter.deinit();

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(module);

        try std.testing.expect(reporter.has_errors or checker.oom);
        if (checker.oom) saw_oom = true;
    }
    try std.testing.expect(saw_oom);
}

test "allocation failure while tracking backend name collisions fails closed" {
    const source =
        \\#[backend_name("mc_fixture_collision")]
        \\fn first_backend_name() -> u32 {
        \\    return 1;
        \\}
        \\
        \\#[backend_name("mc_fixture_collision")]
        \\fn second_backend_name() -> u32 {
        \\    return 2;
        \\}
    ;

    var parse_reporter = diagnostics.Reporter.init(std.testing.allocator, "backend_name_oom.mc", source);
    defer parse_reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const module = try parseWithAllocator(source, arena.allocator(), &parse_reporter);
    try std.testing.expect(!parse_reporter.has_errors);

    var saw_oom = false;
    for (0..128) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reporter = diagnostics.Reporter.init(failing.allocator(), "backend_name_oom.mc", source);
        defer reporter.deinit();

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(module);

        try std.testing.expect(reporter.has_errors or checker.oom);
        if (checker.oom) saw_oom = true;
    }
    try std.testing.expect(saw_oom);
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

    try checkSource(source, &reporter);

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

    try checkSource(source, &reporter);

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

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_CONST_GET_BOUNDS"));
    try std.testing.expect(hasDiagnosticCode(&reporter, "E_CONST_GET_BASE"));
    try std.testing.expect(!hasDiagnosticCode(&reporter, "E_UNKNOWN_FUNCTION"));
}

test "varargs calls require exact shape and mutable va_list cursor" {
    const source =
        \\fn accepted_local(last: i32, ...) -> i64 {
        \\    var local: va_list = va.start();
        \\    var value: i64 = 0;
        \\    unsafe { value = va.arg<i64>(&local); }
        \\    va.end(&local);
        \\    return value + (last as i64);
        \\}
        \\
        \\fn accepted_parameter(ap: *mut va_list) -> i64 {
        \\    var value: i64 = 0;
        \\    unsafe { value = va.arg<i64>(ap); }
        \\    va.end(ap);
        \\    return value;
        \\}
        \\
        \\fn rejected(value: u32, ap: *const va_list, ...) -> void {
        \\    var local: va_list = va.start<u32>();
        \\    var result: i64 = 0;
        \\    unsafe { result = va.arg<i64>(); }
        \\    unsafe { result = va.arg<i64>(&value); }
        \\    unsafe { result = va.arg<i64>(ap); }
        \\    va.end();
        \\}
        \\
        \\fn rejected_start_context() -> void {
        \\    var local: va_list = va.start();
        \\    va.end(&local);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "varargs_call_contract.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_CALL_ARG_COUNT"));
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_NO_IMPLICIT_CONVERSION"));
    // DIAGNOSTIC_UNIT: E_VA_START_CONTEXT
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_VA_START_CONTEXT"));
}

test "va.arg cannot materialize affine, region, or view resources" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct RegionNode { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn accept_copyable(ap: *mut va_list) -> Plain {
        \\    unsafe {
        \\        return va.arg<Plain>(ap);
        \\    }
        \\}
        \\fn reject_move(ap: *mut va_list) -> void {
        \\    unsafe {
        \\        let ticket: Ticket = va.arg<Ticket>(ap);
        \\        forget_unchecked(ticket);
        \\    }
        \\}
        \\fn reject_region(ap: *mut va_list) -> void {
        \\    unsafe {
        \\        va.arg<RegionNode>(ap);
        \\    }
        \\}
        \\fn reject_view(ap: *mut va_list) -> void {
        \\    unsafe {
        \\        va.arg<PlainView>(ap);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "varargs_resource_payload.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    // DIAGNOSTIC_UNIT: E_VA_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_VA_RESOURCE_PAYLOAD"));
}

test "copying generic APIs cannot use affine, region, or view element types" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct RegionNode { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\struct State { descending: bool }
        \\global state: State = .{ .descending = false };
        \\struct Vec<T> { len: usize }
        \\move struct Arc<T> { id: u32 }
        \\struct StrHashMap<V> { len: usize }
        \\struct Ring<T, N> { len: usize }
        \\struct Pool<T, N> { len: usize }
        \\struct PoolRef<T> { index: usize }
        \\struct SlotMap<T, N> { len: usize }
        \\fn sort(comptime T: type, xs: []mut T, less: closure(T, T) -> bool) -> void {}
        \\fn is_sorted(comptime T: type, xs: []mut T, less: closure(T, T) -> bool) -> bool { return true; }
        \\fn lower_bound(comptime T: type, xs: []mut T, key: T, less: closure(T, T) -> bool) -> usize { return 0; }
        \\fn find_index(comptime T: type, comptime N: usize, arr: [N]T, pred: closure(T) -> bool) -> usize { return 0; }
        \\fn any(comptime T: type, comptime N: usize, arr: [N]T, pred: closure(T) -> bool) -> bool { return false; }
        \\fn ring_init(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> void {}
        \\fn ring_len(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> usize { return 0; }
        \\fn ring_is_empty(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> bool { return true; }
        \\fn ring_is_full(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> bool { return false; }
        \\fn ring_push(comptime T: type, comptime N: usize, r: *mut Ring<T, N>, x: T) -> bool { return true; }
        \\fn ring_front(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> T { return zero<T>(); }
        \\fn ring_pop(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> T { return zero<T>(); }
        \\fn pool_init(comptime T: type, comptime N: usize, p: *mut Pool<T, N>) -> void {}
        \\fn pool_alloc(comptime T: type, comptime N: usize, p: *mut Pool<T, N>) -> PoolRef<T> { return .{ .index = 0 }; }
        \\fn pool_set(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>, value: T) -> bool { return true; }
        \\fn pool_load(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>) -> T { return zero<T>(); }
        \\fn pool_free(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>) -> bool { return true; }
        \\fn slotmap_init(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>) -> void {}
        \\fn slotmap_alloc(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>) -> usize { return 0; }
        \\fn slotmap_alloc_at(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize) -> usize { return h; }
        \\fn slotmap_live(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize) -> bool { return true; }
        \\fn slotmap_set(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize, value: T) -> bool { return true; }
        \\fn slotmap_get(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize) -> T { return zero<T>(); }
        \\fn slotmap_free(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize) -> bool { return true; }
        \\fn slotmap_count(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>) -> usize { return 0; }
        \\fn vec_new(comptime T: type) -> Vec<T> { return .{ .len = 0 }; }
        \\fn vec_push(comptime T: type, v: *mut Vec<T>, x: T) -> void {}
        \\fn vec_free(comptime T: type, v: *mut Vec<T>) -> void {}
        \\fn arc_new(comptime T: type, value: T) -> Arc<T> { return .{ .id = 1 }; }
        \\fn arc_get(comptime T: type, h: *Arc<T>) -> *const T { return null; }
        \\fn arc_drop(comptime T: type, h: Arc<T>) -> bool {
        \\    unsafe { forget_unchecked(h); }
        \\    return true;
        \\}
        \\fn strmap_new(comptime V: type) -> StrHashMap<V> { return .{ .len = 0 }; }
        \\fn strmap_put(comptime V: type, m: *mut StrHashMap<V>, key: []const u8, value: V) -> void {}
        \\fn strmap_free(comptime V: type, m: *mut StrHashMap<V>) -> void {}
        \\fn less_plain(env: *State, a: Plain, b: Plain) -> bool { return false; }
        \\fn less_ticket(env: *State, a: Ticket, b: Ticket) -> bool {
        \\    unsafe {
        \\        forget_unchecked(a);
        \\        forget_unchecked(b);
        \\    }
        \\    return false;
        \\}
        \\fn pred_plain(env: *State, a: Plain) -> bool { return false; }
        \\fn pred_ticket(env: *State, a: Ticket) -> bool {
        \\    unsafe { forget_unchecked(a); }
        \\    return false;
        \\}
        \\fn accept_plain_sort() -> void {
        \\    var items: [2]Plain = .{ .{ .id = 2 }, .{ .id = 1 } };
        \\    let cmp: closure(Plain, Plain) -> bool = bind(&state, less_plain);
        \\    sort(Plain, items[0..2], cmp);
        \\}
        \\fn accept_plain_scan() -> void {
        \\    let items: [2]Plain = .{ .{ .id = 2 }, .{ .id = 1 } };
        \\    let pred: closure(Plain) -> bool = bind(&state, pred_plain);
        \\    find_index(Plain, 2, items, pred);
        \\    any(Plain, 2, items, pred);
        \\}
        \\fn accept_plain_static_containers() -> void {
        \\    var ring: Ring<Plain, 2> = .{ .len = 0 };
        \\    ring_init(Plain, 2, &ring);
        \\    ring_push(Plain, 2, &ring, .{ .id = 1 });
        \\    ring_len(Plain, 2, &ring);
        \\    ring_is_empty(Plain, 2, &ring);
        \\    ring_is_full(Plain, 2, &ring);
        \\    let _front: Plain = ring_front(Plain, 2, &ring);
        \\    let _pop: Plain = ring_pop(Plain, 2, &ring);
        \\    var pool: Pool<Plain, 2> = .{ .len = 0 };
        \\    pool_init(Plain, 2, &pool);
        \\    let pr: PoolRef<Plain> = pool_alloc(Plain, 2, &pool);
        \\    pool_set(Plain, 2, &pool, pr, .{ .id = 1 });
        \\    let _loaded: Plain = pool_load(Plain, 2, &pool, pr);
        \\    pool_free(Plain, 2, &pool, pr);
        \\    var slots: SlotMap<Plain, 2> = .{ .len = 0 };
        \\    slotmap_init(Plain, 2, &slots);
        \\    let h: usize = slotmap_alloc(Plain, 2, &slots);
        \\    slotmap_alloc_at(Plain, 2, &slots, h);
        \\    slotmap_live(Plain, 2, &slots, h);
        \\    slotmap_set(Plain, 2, &slots, h, .{ .id = 1 });
        \\    let _got: Plain = slotmap_get(Plain, 2, &slots, h);
        \\    slotmap_free(Plain, 2, &slots, h);
        \\    slotmap_count(Plain, 2, &slots);
        \\}
        \\fn accept_plain_vec() -> void {
        \\    var v: Vec<Plain> = vec_new(Plain);
        \\    vec_push(Plain, &v, .{ .id = 1 });
        \\    vec_free(Plain, &v);
        \\}
        \\fn accept_plain_vec_type_arg() -> void {
        \\    var v: Vec<Plain> = vec_new<Plain>();
        \\    vec_free<Plain>(&v);
        \\}
        \\fn accept_plain_arc() -> void {
        \\    let h: Arc<Plain> = arc_new(Plain, .{ .id = 1 });
        \\    let p: *const Plain = arc_get(Plain, &h);
        \\    arc_drop(Plain, h);
        \\}
        \\fn accept_plain_strmap(key: []const u8) -> void {
        \\    var m: StrHashMap<Plain> = strmap_new(Plain);
        \\    strmap_put(Plain, &m, key, .{ .id = 1 });
        \\    strmap_free(Plain, &m);
        \\}
        \\fn reject_move_sort() -> void {
        \\    var items: [2]Ticket = .{ .{ .id = 2 }, .{ .id = 1 } };
        \\    let cmp: closure(Ticket, Ticket) -> bool = bind(&state, less_ticket);
        \\    sort(Ticket, items[0..2], cmp);
        \\}
        \\fn reject_move_is_sorted() -> bool {
        \\    var items: [2]Ticket = .{ .{ .id = 2 }, .{ .id = 1 } };
        \\    let cmp: closure(Ticket, Ticket) -> bool = bind(&state, less_ticket);
        \\    return is_sorted(Ticket, items[0..2], cmp);
        \\}
        \\fn reject_region_lower_bound(xs: []mut RegionNode, key: RegionNode, cmp: closure(RegionNode, RegionNode) -> bool) -> usize {
        \\    return lower_bound(RegionNode, xs, key, cmp);
        \\}
        \\fn reject_move_scan() -> void {
        \\    let items: [2]Ticket = .{ .{ .id = 2 }, .{ .id = 1 } };
        \\    let pred: closure(Ticket) -> bool = bind(&state, pred_ticket);
        \\    find_index(Ticket, 2, items, pred);
        \\    any(Ticket, 2, items, pred);
        \\}
        \\fn reject_region_scan(items: [2]RegionNode, pred: closure(RegionNode) -> bool) -> void {
        \\    find_index(RegionNode, 2, items, pred);
        \\    any(RegionNode, 2, items, pred);
        \\}
        \\fn reject_move_ring() -> void {
        \\    var ring: Ring<Ticket, 2> = .{ .len = 0 };
        \\    ring_init(Ticket, 2, &ring);
        \\    ring_push(Ticket, 2, &ring, .{ .id = 1 });
        \\    ring_len(Ticket, 2, &ring);
        \\    ring_is_empty(Ticket, 2, &ring);
        \\    ring_is_full(Ticket, 2, &ring);
        \\    let front: Ticket = ring_front(Ticket, 2, &ring);
        \\    unsafe { forget_unchecked(front); }
        \\    let pop: Ticket = ring_pop(Ticket, 2, &ring);
        \\    unsafe { forget_unchecked(pop); }
        \\}
        \\fn reject_region_ring(node: RegionNode) -> void {
        \\    var ring: Ring<RegionNode, 2> = .{ .len = 0 };
        \\    ring_init(RegionNode, 2, &ring);
        \\    ring_push(RegionNode, 2, &ring, node);
        \\    ring_len(RegionNode, 2, &ring);
        \\    ring_is_empty(RegionNode, 2, &ring);
        \\    ring_is_full(RegionNode, 2, &ring);
        \\    ring_front(RegionNode, 2, &ring);
        \\    ring_pop(RegionNode, 2, &ring);
        \\}
        \\fn reject_move_pool() -> void {
        \\    var pool: Pool<Ticket, 2> = .{ .len = 0 };
        \\    pool_init(Ticket, 2, &pool);
        \\    let pr: PoolRef<Ticket> = pool_alloc(Ticket, 2, &pool);
        \\    pool_set(Ticket, 2, &pool, pr, .{ .id = 1 });
        \\    let loaded: Ticket = pool_load(Ticket, 2, &pool, pr);
        \\    unsafe { forget_unchecked(loaded); }
        \\    pool_free(Ticket, 2, &pool, pr);
        \\}
        \\fn reject_region_pool(node: RegionNode) -> void {
        \\    var pool: Pool<RegionNode, 2> = .{ .len = 0 };
        \\    pool_init(RegionNode, 2, &pool);
        \\    let pr: PoolRef<RegionNode> = pool_alloc(RegionNode, 2, &pool);
        \\    pool_set(RegionNode, 2, &pool, pr, node);
        \\    pool_load(RegionNode, 2, &pool, pr);
        \\    pool_free(RegionNode, 2, &pool, pr);
        \\}
        \\fn reject_move_slotmap() -> void {
        \\    var slots: SlotMap<Ticket, 2> = .{ .len = 0 };
        \\    slotmap_init(Ticket, 2, &slots);
        \\    let h: usize = slotmap_alloc(Ticket, 2, &slots);
        \\    slotmap_alloc_at(Ticket, 2, &slots, h);
        \\    slotmap_live(Ticket, 2, &slots, h);
        \\    slotmap_set(Ticket, 2, &slots, h, .{ .id = 1 });
        \\    let got: Ticket = slotmap_get(Ticket, 2, &slots, h);
        \\    unsafe { forget_unchecked(got); }
        \\    slotmap_free(Ticket, 2, &slots, h);
        \\    slotmap_count(Ticket, 2, &slots);
        \\}
        \\fn reject_region_slotmap(node: RegionNode) -> void {
        \\    var slots: SlotMap<RegionNode, 2> = .{ .len = 0 };
        \\    slotmap_init(RegionNode, 2, &slots);
        \\    let h: usize = slotmap_alloc(RegionNode, 2, &slots);
        \\    slotmap_alloc_at(RegionNode, 2, &slots, h);
        \\    slotmap_live(RegionNode, 2, &slots, h);
        \\    slotmap_set(RegionNode, 2, &slots, h, node);
        \\    slotmap_get(RegionNode, 2, &slots, h);
        \\    slotmap_free(RegionNode, 2, &slots, h);
        \\    slotmap_count(RegionNode, 2, &slots);
        \\}
        \\fn reject_move_vec() -> void {
        \\    var v: Vec<Ticket> = vec_new(Ticket);
        \\    vec_push(Ticket, &v, .{ .id = 1 });
        \\    vec_free(Ticket, &v);
        \\}
        \\fn reject_move_vec_type_arg() -> void {
        \\    var v: Vec<Ticket> = vec_new<Ticket>();
        \\    vec_free<Ticket>(&v);
        \\}
        \\fn reject_region_vec() -> void {
        \\    var v: Vec<RegionNode> = vec_new(RegionNode);
        \\    vec_free(RegionNode, &v);
        \\}
        \\fn reject_move_arc() -> void {
        \\    let h: Arc<Ticket> = arc_new(Ticket, .{ .id = 1 });
        \\    arc_get(Ticket, &h);
        \\    arc_drop(Ticket, h);
        \\}
        \\fn reject_region_arc(node: RegionNode) -> void {
        \\    let h: Arc<RegionNode> = arc_new(RegionNode, node);
        \\    arc_drop(RegionNode, h);
        \\}
        \\fn reject_move_strmap(key: []const u8) -> void {
        \\    var m: StrHashMap<Ticket> = strmap_new(Ticket);
        \\    strmap_put(Ticket, &m, key, .{ .id = 1 });
        \\    strmap_free(Ticket, &m);
        \\}
        \\fn reject_region_strmap(key: []const u8, node: RegionNode) -> void {
        \\    var m: StrHashMap<RegionNode> = strmap_new(RegionNode);
        \\    strmap_put(RegionNode, &m, key, node);
        \\    strmap_free(RegionNode, &m);
        \\}
        \\fn reject_region_strmap_type_arg(key: []const u8) -> void {
        \\    var m: StrHashMap<RegionNode> = strmap_new<RegionNode>();
        \\    strmap_free<RegionNode>(&m);
        \\}
        \\fn reject_view_storage() -> void {
        \\    var v: Vec<PlainView> = vec_new(PlainView);
        \\    vec_free(PlainView, &v);
        \\    var m: StrHashMap<PlainView> = strmap_new(PlainView);
        \\    strmap_free(PlainView, &m);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "copying_generic_resource_payload.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    // DIAGNOSTIC_UNIT: E_COPYING_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 71), countDiagnosticCode(&reporter, "E_COPYING_RESOURCE_PAYLOAD"));
}

test "memcpy style byte copies cannot copy ownership resource storage" {
    const source =
        \\#[unsafe_ffi]
        \\extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
        \\#[unsafe_ffi]
        \\extern "C" fn memmove(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
        \\#[unsafe_ffi]
        \\extern "C" fn memset(dst: *mut c_void, value: i32, n: usize) -> *mut c_void;
        \\#[unsafe_ffi]
        \\extern "C" fn bzero(dst: *mut c_void, n: usize) -> void;
        \\move struct Ticket { id: u32 }
        \\linear struct Token { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn accept_plain(dst: *mut Plain, src: *Plain) -> void {
        \\    unsafe {
        \\        memcpy(dst, src, sizeof(Plain));
        \\        memset(dst, 0, sizeof(Plain));
        \\    }
        \\}
        \\fn reject_move_memcpy(dst: *mut Ticket, src: *Ticket) -> void {
        \\    unsafe {
        \\        memcpy(dst, src, sizeof(Ticket));
        \\    }
        \\}
        \\fn reject_move_memmove(dst: *mut Ticket, src: *Ticket) -> void {
        \\    unsafe {
        \\        memmove(dst, src, sizeof(Ticket));
        \\    }
        \\}
        \\fn reject_linear_memcpy(dst: *mut Token, src: *Token) -> void {
        \\    unsafe {
        \\        memcpy(dst, src, sizeof(Token));
        \\    }
        \\}
        \\fn reject_move_memset(dst: *mut Ticket) -> void {
        \\    unsafe {
        \\        memset(dst, 0, sizeof(Ticket));
        \\    }
        \\}
        \\fn reject_linear_bzero(dst: *mut Token) -> void {
        \\    unsafe {
        \\        bzero(dst, sizeof(Token));
        \\    }
        \\}
        \\fn reject_region_memcpy(dst: *mut Node, src: *Node) -> void {
        \\    unsafe {
        \\        memcpy(dst, src, sizeof(Node));
        \\    }
        \\}
        \\fn reject_view_memcpy(dst: *mut PlainView, src: *PlainView) -> void {
        \\    unsafe {
        \\        memcpy(dst, src, sizeof(PlainView));
        \\    }
        \\}
        \\fn reject_view_address() -> void {
        \\    var plain: Plain = .{ .id = 1 };
        \\    let view: PlainView = .{ .ptr = borrow plain };
        \\    unsafe {
        \\        memcpy(&view, &view, sizeof(PlainView));
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "raw_copy_resource_payload.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    // DIAGNOSTIC_UNIT: E_RAW_COPY_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 8), countDiagnosticCode(&reporter, "E_RAW_COPY_RESOURCE_PAYLOAD"));
}

test "longjmp style non-local jumps cannot cross ownership state" {
    const source =
        \\#[unsafe_ffi]
        \\extern "C" fn longjmp(env: *mut c_void, value: i32) -> never;
        \\move struct Ticket { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn accept_no_resource(env: *mut c_void) -> never {
        \\    unsafe {
        \\        longjmp(env, 1);
        \\    }
        \\}
        \\fn reject_requires_unsafe(env: *mut c_void) -> never {
        \\    longjmp(env, 1);
        \\}
        \\fn reject_live_move(env: *mut c_void) -> never {
        \\    let ticket: Ticket = .{ .id = 1 };
        \\    unsafe {
        \\        longjmp(env, 1);
        \\        forget_unchecked(ticket);
        \\    }
        \\}
        \\fn reject_live_view(env: *mut c_void) -> never {
        \\    var plain: Plain = .{ .id = 1 };
        \\    let view: PlainView = .{ .ptr = borrow plain };
        \\    unsafe {
        \\        longjmp(env, 1);
        \\    }
        \\}
        \\fn reject_direct_borrow_arg(env: *mut c_void, plain: *Plain) -> never {
        \\    unsafe {
        \\        longjmp(borrow env, 1);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nonlocal_jump_ownership.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    // DIAGNOSTIC_UNIT: E_UNSAFE_REQUIRED
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_UNSAFE_REQUIRED"));
    // DIAGNOSTIC_UNIT: E_NONLOCAL_JUMP_RESOURCE
    try std.testing.expectEqual(@as(usize, 3), countDiagnosticCode(&reporter, "E_NONLOCAL_JUMP_RESOURCE"));
}

test "explicit trap rejects type arguments before MIR construction" {
    const source =
        \\fn rejected() -> never {
        \\    return trap<u32>(.Assert);
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "trap_type_arguments.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_INVALID_TRAP_KIND"));
}

test "explicit C ABI rejects unclassified values and MC ABI permits them" {
    const source =
        \\extern "C" struct Packet {
        \\    value: u32,
        \\}
        \\
        \\struct Plain {
        \\    value: u32,
        \\}
        \\
        \\type PacketAlias = Packet;
        \\type PlainAlias = Plain;
        \\
        \\extern "C" fn take_packet(packet: Packet) -> void;
        \\extern "C" fn make_packet() -> PacketAlias;
        \\extern fn take_packet_ptr(packet: *Packet) -> void;
        \\extern "C" fn take_optional(value: ?u32) -> void;
        \\extern "C" fn make_array() -> [2]u32;
        \\extern "C" fn take_slice(value: []const u8) -> void;
        \\extern "C" fn make_result() -> Result<u32, u32>;
        \\
        \\export fn exported_take(plain: Plain) -> u32 {
        \\    return plain.value;
        \\}
        \\
        \\export fn exported_make() -> PlainAlias {
        \\    return .{ .value = 1 };
        \\}
        \\
        \\fn internal_roundtrip(plain: Plain) -> Plain {
        \\    return plain;
        \\}
        \\
        \\#[mc_abi]
        \\export fn mc_array_roundtrip(value: [2]u32) -> [2]u32 {
        \\    return value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "extern_export_struct_abi.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 8), countDiagnosticCode(&reporter, "E_EXTERN_STRUCT_BY_VALUE"));
}

test "explicit C ABI default-denies unions va_list and unresolved type forms" {
    const source =
        \\union Token { number: u32, none }
        \\overlay union Word { value: u32, bytes: [4]u8 }
        \\#[c_union]
        \\struct CWord { value: u32, bytes: [4]u8 }
        \\struct Error { code: u32 }
        \\extern "C" fn tagged(value: Token) -> void;
        \\extern "C" fn overlayed(value: Word) -> void;
        \\extern "C" fn c_union(value: CWord) -> void;
        \\extern "C" fn shadowed_builtin(value: Error) -> void;
        \\extern "C" fn cursor(value: va_list) -> void;
        \\extern "C" fn cursor_result() -> va_list;
        \\extern "C" fn bad_member(value: u32.NoSuchType) -> void;
        \\extern "C" fn bad_literal(value: .coherent) -> void;
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "extern_c_default_deny.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 8), countDiagnosticCode(&reporter, "E_EXTERN_STRUCT_BY_VALUE"));
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_UNKNOWN_TYPE"));
}

test "C ABI and variadic functions cannot decay to plain MC function pointers" {
    const source =
        \\extern "C" fn c_echo(value: u8) -> u8;
        \\extern "C" fn c_log(format: cstr, ...) -> i32;
        \\fn consume(callback: fn(u8) -> u8) -> void {}
        \\fn rejected() -> void {
        \\    let first: fn(u8) -> u8 = c_echo;
        \\    let inferred = c_echo;
        \\    consume(c_echo);
        \\    let second: fn(cstr) -> i32 = c_log;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "c_function_pointer_abi.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_FN_POINTER_SIGNATURE_MISMATCH"));
}

test "C variadic calls accept classified tails and reject aggregate tails" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\extern "C" fn log_value(format: cstr, ...) -> i32;
        \\fn accepted() -> i32 { return log_value("%d", 42); }
        \\fn rejected(pair: Pair) -> i32 { return log_value("%p", pair); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "c_variadic_calls.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_EXTERN_STRUCT_BY_VALUE"));
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_CALL_ARG_COUNT"));
}

test "C variadic tails cannot pass checked resources by value" {
    const source =
        \\#[trivial_drop]
        \\move struct Ticket { id: u32 }
        \\extern "C" fn log_value(format: cstr, ...) -> i32;
        \\fn reject_move_tail() -> i32 {
        \\    let ticket: Ticket = .{ .id = 7 };
        \\    return log_value("%p", ticket);
        \\}
        \\fn accept_pointer_tail(ticket: *mut Ticket) -> i32 {
        \\    return log_value("%p", ticket);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "c_variadic_resource_tail.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);

    // DIAGNOSTIC_UNIT: E_VA_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 1), countDiagnosticCode(&reporter, "E_VA_RESOURCE_PAYLOAD"));
    try std.testing.expectEqual(@as(usize, 0), countDiagnosticCode(&reporter, "E_EXTERN_STRUCT_BY_VALUE"));
}

test "explicit C ABI cannot pass move resources by value" {
    const source =
        \\move struct Ticket { id: u32 }
        \\enum TicketError { Bad }
        \\extern "C" fn bad_param(ticket: Ticket) -> void;
        \\extern "C" fn bad_return() -> Ticket;
        \\extern "C" fn bad_result() -> Result<Ticket, TicketError>;
        \\extern "C" fn ok_pointer(ticket: *mut Ticket) -> void;
        \\export fn bad_export(ticket: Ticket) -> void {
        \\    unsafe { forget_unchecked(ticket); }
        \\}
        \\#[mc_abi]
        \\export fn ok_mc_export(ticket: Ticket) -> void {
        \\    unsafe { forget_unchecked(ticket); }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "move_c_abi_by_value.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);

    // DIAGNOSTIC_UNIT: E_MOVE_ABI_BY_VALUE
    try std.testing.expectEqual(@as(usize, 4), countDiagnosticCode(&reporter, "E_MOVE_ABI_BY_VALUE"));
}

test "aggregate raw memory operations reject before backend lowering" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\fn read(addr: PAddr) -> Pair { unsafe { return raw.load<Pair>(addr); } }
        \\fn write(addr: PAddr, value: Pair) -> void { unsafe { raw.store<Pair>(addr, value); } }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "raw_aggregate_rejected.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 2), countDiagnosticCode(&reporter, "E_RAW_AGGREGATE_UNSUPPORTED"));
}

test "raw memory operations reject resource payloads explicitly" {
    const source =
        \\move struct Ticket { id: u32 }
        \\region struct Node { id: u32 }
        \\struct Plain { id: u32 }
        \\view struct PlainView { ptr: *Plain }
        \\fn reject_move_load(addr: PAddr) -> void {
        \\    unsafe {
        \\        let ticket: Ticket = raw.load<Ticket>(addr);
        \\        forget_unchecked(ticket);
        \\    }
        \\}
        \\fn reject_move_store(addr: PAddr, ticket: Ticket) -> void {
        \\    unsafe {
        \\        raw.store<Ticket>(addr, ticket);
        \\        forget_unchecked(ticket);
        \\    }
        \\}
        \\fn reject_region_load(addr: PAddr) -> void {
        \\    unsafe {
        \\        raw.load<Node>(addr);
        \\    }
        \\}
        \\fn reject_move_ptr(addr: PAddr) -> void {
        \\    unsafe {
        \\        raw.ptr<Ticket>(addr);
        \\    }
        \\}
        \\fn reject_region_ptr(addr: PAddr) -> void {
        \\    unsafe {
        \\        raw.ptr<Node>(addr);
        \\    }
        \\}
        \\fn reject_view_ptr(addr: PAddr) -> void {
        \\    unsafe {
        \\        raw.ptr<PlainView>(addr);
        \\    }
        \\}
        \\fn accept_scalar(addr: PAddr, value: u64) -> u64 {
        \\    unsafe {
        \\        raw.store<u64>(addr, value);
        \\        return raw.load<u64>(addr);
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "raw_resource_payload_rejected.mc", source);
    defer reporter.deinit();
    try checkSource(source, &reporter);

    // DIAGNOSTIC_UNIT: E_RAW_RESOURCE_PAYLOAD
    try std.testing.expectEqual(@as(usize, 6), countDiagnosticCode(&reporter, "E_RAW_RESOURCE_PAYLOAD"));
}

test "nullable classification resolves aliases inside the type constructor" {
    const source =
        \\type Word = u32;
        \\type Word2 = Word;
        \\type WordPtr = *mut u32;
        \\fn scalar(value: ?Word2) -> bool {
        \\    if let inner = value { return inner != 0; }
        \\    return false;
        \\}
        \\fn pointer(value: ?WordPtr) -> bool {
        \\    if let inner = value { return true; }
        \\    return false;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nullable_aliases.mc", source);
    defer reporter.deinit();

    try checkSource(source, &reporter);
    try std.testing.expect(!reporter.has_errors);
}
