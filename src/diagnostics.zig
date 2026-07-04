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
    notes: []const Note = &.{},
};

pub const Note = struct {
    span: ?Span = null,
    message: []const u8,
};

pub const NoteMessage = struct {
    span: ?Span = null,
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

const MappedSpan = struct {
    path: []const u8,
    offset: usize,
    len: usize,
    line: usize,
    column: usize,
};

pub const SourceLine = struct {
    text: []const u8,
    column: usize,
    highlight_len: usize,
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
            for (diag.notes) |note| self.allocator.free(note.message);
            self.allocator.free(diag.notes);
        }
        self.diagnostics.deinit(self.allocator);
    }

    pub fn err(self: *Reporter, span: Span, comptime fmt: []const u8, args: anytype) void {
        self.add(.error_, span, fmt, args);
    }

    pub fn errWithNotes(self: *Reporter, span: Span, comptime fmt: []const u8, args: anytype, notes: []const NoteMessage) void {
        self.addWithNotes(.error_, span, fmt, args, notes);
    }

    pub fn warn(self: *Reporter, span: Span, comptime fmt: []const u8, args: anytype) void {
        self.add(.warning, span, fmt, args);
    }

    fn add(self: *Reporter, severity: Severity, span: Span, comptime fmt: []const u8, args: anytype) void {
        self.addWithNotes(severity, span, fmt, args, &.{});
    }

    fn addWithNotes(self: *Reporter, severity: Severity, span: Span, comptime fmt: []const u8, args: anytype, notes: []const NoteMessage) void {
        if (severity == .error_) self.has_errors = true;
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;

        const owned_notes = self.allocator.alloc(Note, notes.len) catch {
            self.allocator.free(msg);
            return;
        };
        var initialized: usize = 0;
        for (notes, 0..) |note, i| {
            const note_msg = self.allocator.dupe(u8, note.message) catch {
                for (owned_notes[0..initialized]) |owned_note| self.allocator.free(owned_note.message);
                self.allocator.free(owned_notes);
                self.allocator.free(msg);
                return;
            };
            owned_notes[i] = .{
                .span = note.span,
                .message = note_msg,
            };
            initialized += 1;
        }

        self.diagnostics.append(self.allocator, .{
            .severity = severity,
            .span = span,
            .message = msg,
            .notes = owned_notes,
        }) catch {
            for (owned_notes) |note| self.allocator.free(note.message);
            self.allocator.free(owned_notes);
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
            if (self.sourceLine(diag.span)) |line| {
                std.debug.print("  | {s}\n  | ", .{line.text});
                var pad: usize = 1;
                while (pad < line.column) : (pad += 1) std.debug.print(" ", .{});
                std.debug.print("^", .{});
                var tail: usize = 1;
                while (tail < line.highlight_len) : (tail += 1) std.debug.print("~", .{});
                std.debug.print("\n", .{});
            }
            for (diag.notes) |note| {
                if (note.span) |note_span| {
                    const note_loc = self.location(note_span);
                    std.debug.print("{s}:{d}:{d}: note: {s}\n", .{
                        note_loc.path,
                        note_loc.line,
                        note_loc.column,
                        note.message,
                    });
                    if (self.sourceLine(note_span)) |line| {
                        std.debug.print("  | {s}\n  | ", .{line.text});
                        var pad: usize = 1;
                        while (pad < line.column) : (pad += 1) std.debug.print(" ", .{});
                        std.debug.print("^", .{});
                        var tail: usize = 1;
                        while (tail < line.highlight_len) : (tail += 1) std.debug.print("~", .{});
                        std.debug.print("\n", .{});
                    }
                } else {
                    std.debug.print("note: {s}\n", .{note.message});
                }
            }
        }
    }

    pub fn appendJson(self: *const Reporter, out: *std.ArrayList(u8)) !void {
        var error_count: usize = 0;
        var warning_count: usize = 0;
        for (self.diagnostics.items) |diag| {
            switch (diag.severity) {
                .error_ => error_count += 1,
                .warning => warning_count += 1,
            }
        }

        try out.appendSlice(self.allocator, "{\"diagnostics\":[");
        for (self.diagnostics.items, 0..) |diag, i| {
            if (i > 0) try out.append(self.allocator, ',');
            const severity = switch (diag.severity) {
                .error_ => "error",
                .warning => "warning",
            };
            const loc = self.mappedSpan(diag.span);
            const parsed = parseDiagnosticMessage(diag.message);

            try out.appendSlice(self.allocator, "{\"severity\":");
            try appendJsonString(out, self.allocator, severity);
            try out.appendSlice(self.allocator, ",\"message\":");
            try appendJsonString(out, self.allocator, parsed.message);
            try out.appendSlice(self.allocator, ",\"path\":");
            try appendJsonString(out, self.allocator, loc.path);
            try out.appendSlice(self.allocator, ",\"file\":");
            try appendJsonString(out, self.allocator, loc.path);
            try out.print(self.allocator, ",\"line\":{d},\"column\":{d}", .{ loc.line, loc.column });
            if (parsed.code) |code| {
                try out.appendSlice(self.allocator, ",\"code\":");
                try appendJsonString(out, self.allocator, code);
            }
            try out.print(self.allocator, ",\"span\":{{\"offset\":{d},\"length\":{d},\"line\":{d},\"column\":{d}}}", .{
                loc.offset,
                loc.len,
                loc.line,
                loc.column,
            });
            if (self.sourceLine(diag.span)) |line| {
                try out.appendSlice(self.allocator, ",\"source\":{");
                try out.appendSlice(self.allocator, "\"text\":");
                try appendJsonString(out, self.allocator, line.text);
                try out.print(self.allocator, ",\"column\":{d},\"highlight_length\":{d},\"caret\":", .{
                    line.column,
                    line.highlight_len,
                });
                try appendCaretJsonString(out, self.allocator, line.highlight_len);
                try out.append(self.allocator, '}');
            }
            if (diag.notes.len > 0) {
                try out.appendSlice(self.allocator, ",\"notes\":[");
                for (diag.notes, 0..) |note, note_i| {
                    if (note_i > 0) try out.append(self.allocator, ',');
                    try out.appendSlice(self.allocator, "{\"message\":");
                    try appendJsonString(out, self.allocator, note.message);
                    if (note.span) |note_span| {
                        const note_loc = self.mappedSpan(note_span);
                        try out.appendSlice(self.allocator, ",\"path\":");
                        try appendJsonString(out, self.allocator, note_loc.path);
                        try out.appendSlice(self.allocator, ",\"file\":");
                        try appendJsonString(out, self.allocator, note_loc.path);
                        try out.print(self.allocator, ",\"line\":{d},\"column\":{d}", .{ note_loc.line, note_loc.column });
                        try out.print(self.allocator, ",\"span\":{{\"offset\":{d},\"length\":{d},\"line\":{d},\"column\":{d}}}", .{
                            note_loc.offset,
                            note_loc.len,
                            note_loc.line,
                            note_loc.column,
                        });
                        if (self.sourceLine(note_span)) |line| {
                            try out.appendSlice(self.allocator, ",\"source\":{");
                            try out.appendSlice(self.allocator, "\"text\":");
                            try appendJsonString(out, self.allocator, line.text);
                            try out.print(self.allocator, ",\"column\":{d},\"highlight_length\":{d},\"caret\":", .{
                                line.column,
                                line.highlight_len,
                            });
                            try appendCaretJsonString(out, self.allocator, line.highlight_len);
                            try out.append(self.allocator, '}');
                        }
                    }
                    try out.append(self.allocator, '}');
                }
                try out.append(self.allocator, ']');
            }
            try out.append(self.allocator, '}');
        }
        try out.print(self.allocator, "],\"error_count\":{d},\"warning_count\":{d}}}\n", .{ error_count, warning_count });
    }

    pub fn location(self: *const Reporter, span: Span) Location {
        const loc = self.mappedSpan(span);
        return .{ .path = loc.path, .line = loc.line, .column = loc.column };
    }

    fn mappedSpan(self: *const Reporter, span: Span) MappedSpan {
        const raw = MappedSpan{
            .path = self.path,
            .offset = span.offset,
            .len = span.len,
            .line = span.line,
            .column = span.column,
        };
        const boundaries = self.file_boundaries orelse return raw;
        if (boundaries.len == 0) return raw;

        var boundary = boundaries[0];
        for (boundaries[1..]) |candidate| {
            if (candidate.start > span.offset) break;
            boundary = candidate;
        }
        if (span.offset < boundary.start or boundary.start > self.source.len) {
            return raw;
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
        return .{
            .path = boundary.path,
            .offset = span.offset - boundary.start,
            .len = span.len,
            .line = line,
            .column = column,
        };
    }

    pub fn sourceLine(self: *const Reporter, span: Span) ?SourceLine {
        if (self.source.len == 0) return null;
        const bounded_offset = @min(span.offset, self.source.len - 1);
        var start = bounded_offset;
        while (start > 0 and self.source[start - 1] != '\n') : (start -= 1) {}
        var end = bounded_offset;
        while (end < self.source.len and self.source[end] != '\n' and self.source[end] != '\r') : (end += 1) {}
        const line = self.source[start..end];
        if (std.mem.trim(u8, line, " \t\r").len == 0) return null;

        const column = if (span.offset >= start) span.offset - start + 1 else span.column;
        const offset_in_line = if (column > 0) column - 1 else 0;
        const remaining = if (offset_in_line < line.len) line.len - offset_in_line else 0;
        const highlight_len = @max(@as(usize, 1), @min(span.len, remaining));
        return .{ .text = line, .column = column, .highlight_len = highlight_len };
    }
};

const ParsedMessage = struct {
    code: ?[]const u8,
    message: []const u8,
};

fn parseDiagnosticMessage(message: []const u8) ParsedMessage {
    if (!std.mem.startsWith(u8, message, "E_")) return .{ .code = null, .message = message };
    const sep = std.mem.indexOfScalar(u8, message, ':') orelse return .{ .code = null, .message = message };
    const code = message[0..sep];
    for (code) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return .{ .code = null, .message = message };
    }
    const rest = std.mem.trimStart(u8, message[sep + 1 ..], " \t");
    return .{ .code = code, .message = rest };
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try out.print(allocator, "\\u{x:0>4}", .{c}),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

fn appendCaretJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, highlight_len: usize) !void {
    try out.append(allocator, '"');
    try out.append(allocator, '^');
    var tail: usize = 1;
    while (tail < highlight_len) : (tail += 1) try out.append(allocator, '~');
    try out.append(allocator, '"');
}

test "Reporter errors fail closed when diagnostic allocation fails" {
    for ([_]usize{ 0, 1 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var reporter = Reporter.init(failing.allocator(), "oom.mc", "");
        defer reporter.deinit();

        reporter.err(.{ .offset = 0, .len = 0, .line = 1, .column = 1 }, "E_TEST: {s}", .{"boom"});

        try std.testing.expect(reporter.has_errors);
        try std.testing.expectEqual(@as(usize, 0), reporter.diagnostics.items.len);
    }
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

test "Reporter extracts source line and caret width for a diagnostic span" {
    const source = "fn f() -> u32 {\n    return missing;\n}\n";
    var reporter = Reporter.init(std.testing.allocator, "line.mc", source);
    defer reporter.deinit();

    const offset = std.mem.indexOf(u8, source, "missing").?;
    const line = reporter.sourceLine(.{ .offset = offset, .len = "missing".len, .line = 2, .column = 12 }).?;
    try std.testing.expectEqualStrings("    return missing;", line.text);
    try std.testing.expectEqual(@as(usize, 12), line.column);
    try std.testing.expectEqual(@as(usize, "missing".len), line.highlight_len);
}

test "Reporter omits snippets for blanked import lines" {
    const source = "                         \nfn f() -> void {}\n";
    var reporter = Reporter.init(std.testing.allocator, "blank.mc", source);
    defer reporter.deinit();

    try std.testing.expectEqual(@as(?SourceLine, null), reporter.sourceLine(.{ .offset = 0, .len = 6, .line = 1, .column = 1 }));
}

test "Reporter emits structured JSON diagnostics" {
    const source = "fn f() -> u32 {\n    return missing;\n}\n";
    var reporter = Reporter.init(std.testing.allocator, "json.mc", source);
    defer reporter.deinit();

    const offset = std.mem.indexOf(u8, source, "missing").?;
    reporter.err(.{ .offset = offset, .len = "missing".len, .line = 2, .column = 12 }, "E_UNKNOWN_IDENTIFIER: unknown identifier `{s}`", .{"missing"});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try reporter.appendJson(&out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"diagnostics\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"severity\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"code\":\"E_UNKNOWN_IDENTIFIER\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"message\":\"unknown identifier `missing`\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"path\":\"json.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"line\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"column\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"caret\":\"^~~~~~~\"") != null);
}

test "Reporter emits structured diagnostic notes" {
    const source = "fn f() -> u32 {\n    return missing;\n}\n";
    var reporter = Reporter.init(std.testing.allocator, "notes.mc", source);
    defer reporter.deinit();

    const offset = std.mem.indexOf(u8, source, "missing").?;
    const span = Span{ .offset = offset, .len = "missing".len, .line = 2, .column = 12 };
    reporter.errWithNotes(span, "E_TEST: primary", .{}, &.{
        .{ .message = "required from here:" },
        .{ .span = span, .message = "function `f` required from here" },
    });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try reporter.appendJson(&out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"notes\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"message\":\"required from here:\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"message\":\"function `f` required from here\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"path\":\"notes.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"caret\":\"^~~~~~~\"") != null);
}

test "Reporter emits boundary-aware JSON spans for imported files" {
    const root_source = "import \"lib.mc\";\n\nexport fn main() -> u32 {\n    return imported();\n}\n";
    const imported_source = "fn imported() -> u32 {\n    return missing;\n}\n";
    const source = root_source ++ imported_source;
    var reporter = Reporter.init(std.testing.allocator, "root.mc", source);
    defer reporter.deinit();
    const boundaries = [_]FileBoundary{
        .{ .start = 0, .path = "root.mc" },
        .{ .start = root_source.len, .path = "lib.mc" },
    };
    reporter.file_boundaries = &boundaries;

    const offset = std.mem.indexOf(u8, source, "missing").?;
    reporter.err(.{ .offset = offset, .len = "missing".len, .line = 7, .column = 12 }, "E_UNKNOWN_IDENTIFIER: unknown identifier `{s}`", .{"missing"});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try reporter.appendJson(&out);

    const file_local_offset = std.mem.indexOf(u8, imported_source, "missing").?;
    const expected_span = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"span\":{{\"offset\":{d},\"length\":{d},\"line\":2,\"column\":12}}",
        .{ file_local_offset, "missing".len },
    );
    defer std.testing.allocator.free(expected_span);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"path\":\"lib.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"line\":2,\"column\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, expected_span) != null);
}
