const std = @import("std");

pub const Span = struct {
    offset: usize,
    len: usize,
    line: usize,
    column: usize,
};

pub const Severity = enum {
    error_,
    warning,
};

pub const Diagnostic = struct {
    severity: Severity,
    span: Span,
    message: []const u8,
};

pub const Reporter = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    diagnostics: std.ArrayList(Diagnostic),
    has_errors: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, source: []const u8) Reporter {
        return .{
            .allocator = allocator,
            .path = path,
            .source = source,
            .diagnostics = .empty,
        };
    }

    pub fn deinit(self: *Reporter) void {
        for (self.diagnostics.items) |diag| {
            self.allocator.free(diag.message);
        }
        self.diagnostics.deinit(self.allocator);
    }

    pub fn err(self: *Reporter, span: Span, comptime fmt: []const u8, args: anytype) void {
        self.add(.error_, span, fmt, args);
    }

    pub fn warn(self: *Reporter, span: Span, comptime fmt: []const u8, args: anytype) void {
        self.add(.warning, span, fmt, args);
    }

    fn add(self: *Reporter, severity: Severity, span: Span, comptime fmt: []const u8, args: anytype) void {
        if (severity == .error_) self.has_errors = true;
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.diagnostics.append(self.allocator, .{
            .severity = severity,
            .span = span,
            .message = msg,
        }) catch {
            self.allocator.free(msg);
            return;
        };
    }

    pub fn render(self: *Reporter) void {
        for (self.diagnostics.items) |diag| {
            const severity = switch (diag.severity) {
                .error_ => "error",
                .warning => "warning",
            };
            std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{
                self.path,
                diag.span.line,
                diag.span.column,
                severity,
                diag.message,
            });
        }
    }
};

test "Reporter errors fail closed when diagnostic allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var reporter = Reporter.init(failing.allocator(), "oom.mc", "");
    defer reporter.deinit();

    reporter.err(.{ .offset = 0, .len = 0, .line = 1, .column = 1 }, "E_TEST: {s}", .{"boom"});

    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 0), reporter.diagnostics.items.len);
}
