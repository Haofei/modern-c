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

pub const FileBoundary = struct {
    start: usize,
    path: []const u8,
};

pub const Location = struct {
    path: []const u8,
    line: usize,
    column: usize,
};

pub const Reporter = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    file_boundaries: ?[]const FileBoundary = null,
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
            const loc = self.location(diag.span);
            std.debug.print("{s}:{d}:{d}: {s}: {s}\n", .{
                loc.path,
                loc.line,
                loc.column,
                severity,
                diag.message,
            });
        }
    }

    pub fn location(self: *const Reporter, span: Span) Location {
        const boundaries = self.file_boundaries orelse return .{ .path = self.path, .line = span.line, .column = span.column };
        if (boundaries.len == 0) return .{ .path = self.path, .line = span.line, .column = span.column };

        var boundary = boundaries[0];
        for (boundaries[1..]) |candidate| {
            if (candidate.start > span.offset) break;
            boundary = candidate;
        }
        if (span.offset < boundary.start or boundary.start > self.source.len) {
            return .{ .path = self.path, .line = span.line, .column = span.column };
        }

        var line: usize = 1;
        var column: usize = 1;
        const end = @min(span.offset, self.source.len);
        for (self.source[boundary.start..end]) |byte| {
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        return .{ .path = boundary.path, .line = line, .column = column };
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

test "Reporter maps flattened import offsets back to source file locations" {
    const root_source = "fn root() -> void {}\n";
    const imported_source = "fn imported() -> void {\n    missing;\n}\n";
    const source = root_source ++ imported_source;
    var reporter = Reporter.init(std.testing.allocator, "root.mc", source);
    defer reporter.deinit();
    const boundaries = [_]FileBoundary{
        .{ .start = 0, .path = "root.mc" },
        .{ .start = root_source.len, .path = "lib.mc" },
    };
    reporter.file_boundaries = &boundaries;

    const offset = std.mem.indexOf(u8, source, "missing").?;
    const loc = reporter.location(.{ .offset = offset, .len = "missing".len, .line = 3, .column = 5 });
    try std.testing.expectEqualStrings("lib.mc", loc.path);
    try std.testing.expectEqual(@as(usize, 2), loc.line);
    try std.testing.expectEqual(@as(usize, 5), loc.column);
}
