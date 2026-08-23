const std = @import("std");

pub const invalid_file_id = std.math.maxInt(u32);

pub const Span = struct {
    offset: usize,
    len: usize,
    line: usize,
    column: u32,
    /// Stable per-file identity. Legacy/synthetic spans leave this invalid;
    /// per-file parsing sets it directly so diagnostics never need a combined
    /// source offset to recover their origin.
    file_id: u32 = invalid_file_id,
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

pub const SourceView = struct {
    file_id: u32,
    path: []const u8,
    source: []const u8,
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
    source_views: ?[]const SourceView = null,
    owned_source_views: std.ArrayList(SourceView) = .empty,
    diagnostics: std.ArrayList(Diagnostic),
    has_errors: bool = false,
    diagnostic_oom: bool = false,

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
        for (self.owned_source_views.items) |view| {
            self.allocator.free(view.path);
            self.allocator.free(view.source);
        }
        self.owned_source_views.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    /// Retain a diagnostic-only source view when a producer may fail before it
    /// can return its normal SourceDatabase owner. Successful compilation uses
    /// the borrowed `source_views` table and pays no duplication cost.
    pub fn captureSourceView(self: *Reporter, file_id: u32, path: []const u8, source: []const u8) void {
        if (self.sourceView(file_id) != null) return;
        const owned_path = self.allocator.dupe(u8, path) catch {
            self.markDiagnosticOom();
            return;
        };
        const owned_source = self.allocator.dupe(u8, source) catch {
            self.allocator.free(owned_path);
            self.markDiagnosticOom();
            return;
        };
        self.owned_source_views.append(self.allocator, .{
            .file_id = file_id,
            .path = owned_path,
            .source = owned_source,
        }) catch {
            self.allocator.free(owned_path);
            self.allocator.free(owned_source);
            self.markDiagnosticOom();
        };
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
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            self.markDiagnosticOom();
            return;
        };

        const owned_notes = self.allocator.alloc(Note, notes.len) catch {
            self.allocator.free(msg);
            self.markDiagnosticOom();
            return;
        };
        var initialized: usize = 0;
        for (notes, 0..) |note, i| {
            const note_msg = self.allocator.dupe(u8, note.message) catch {
                for (owned_notes[0..initialized]) |owned_note| self.allocator.free(owned_note.message);
                self.allocator.free(owned_notes);
                self.allocator.free(msg);
                self.markDiagnosticOom();
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
            self.markDiagnosticOom();
            return;
        };
    }

    fn markDiagnosticOom(self: *Reporter) void {
        self.has_errors = true;
        self.diagnostic_oom = true;
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
        if (self.diagnostic_oom) {
            std.debug.print("{s}:1:1: error: E_DIAGNOSTIC_OOM: compiler diagnostic allocation failed\n", .{self.path});
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
        if (self.diagnostic_oom) error_count += 1;

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
        if (self.diagnostic_oom) {
            if (self.diagnostics.items.len > 0) try out.append(self.allocator, ',');
            try out.appendSlice(self.allocator, "{\"severity\":\"error\",\"message\":\"compiler diagnostic allocation failed\",\"path\":");
            try appendJsonString(out, self.allocator, self.path);
            try out.appendSlice(self.allocator, ",\"file\":");
            try appendJsonString(out, self.allocator, self.path);
            try out.appendSlice(self.allocator, ",\"line\":1,\"column\":1,\"code\":\"E_DIAGNOSTIC_OOM\",\"span\":{\"offset\":0,\"length\":0,\"line\":1,\"column\":1}}");
        }
        try out.print(self.allocator, "],\"error_count\":{d},\"warning_count\":{d}}}\n", .{ error_count, warning_count });
    }

    pub fn location(self: *const Reporter, span: Span) Location {
        const loc = self.mappedSpan(span);
        return .{ .path = loc.path, .line = loc.line, .column = loc.column };
    }

    pub fn pathForFileId(self: *const Reporter, file_id: u32) ?[]const u8 {
        return (self.sourceView(file_id) orelse return null).path;
    }

    fn mappedSpan(self: *const Reporter, span: Span) MappedSpan {
        if (span.file_id != invalid_file_id) {
            if (self.sourceView(span.file_id)) |view| {
                return .{
                    .path = view.path,
                    .offset = span.offset,
                    .len = span.len,
                    .line = span.line,
                    .column = span.column,
                };
            }
        }
        return .{
            .path = self.path,
            .offset = span.offset,
            .len = span.len,
            .line = span.line,
            .column = span.column,
        };
    }

    pub fn sourceLine(self: *const Reporter, span: Span) ?SourceLine {
        const source = if (span.file_id != invalid_file_id)
            if (self.sourceView(span.file_id)) |view| view.source else self.source
        else
            self.source;
        if (source.len == 0) return null;
        const bounded_offset = @min(span.offset, source.len - 1);
        var start = bounded_offset;
        while (start > 0 and source[start - 1] != '\n') : (start -= 1) {}
        var end = bounded_offset;
        while (end < source.len and source[end] != '\n' and source[end] != '\r') : (end += 1) {}
        const line = source[start..end];
        if (std.mem.trim(u8, line, " \t\r").len == 0) return null;

        const column = if (span.offset >= start) span.offset - start + 1 else span.column;
        const offset_in_line = if (column > 0) column - 1 else 0;
        const remaining = if (offset_in_line < line.len) line.len - offset_in_line else 0;
        const highlight_len = @max(@as(usize, 1), @min(span.len, remaining));
        return .{ .text = line, .column = column, .highlight_len = highlight_len };
    }

    fn sourceView(self: *const Reporter, file_id: u32) ?SourceView {
        if (self.source_views) |views| for (views) |view| if (view.file_id == file_id) return view;
        for (self.owned_source_views.items) |view| if (view.file_id == file_id) return view;
        return null;
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

test "Reporter retains a per-file source view across producer failure" {
    var reporter = Reporter.init(std.testing.allocator, "root.mc", "import \"lib.mc\";\n");
    defer reporter.deinit();
    reporter.captureSourceView(7, "lib.mc", "import \"missing.mc\";\n");

    const span = Span{ .offset = 0, .len = 6, .line = 1, .column = 1, .file_id = 7 };
    reporter.err(span, "E_IMPORT_NOT_FOUND: missing", .{});
    const loc = reporter.location(span);
    try std.testing.expectEqualStrings("lib.mc", loc.path);
    const line = reporter.sourceLine(span) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("import \"missing.mc\";", line.text);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    try reporter.appendJson(&json);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"path\":\"lib.mc\"") != null);
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

test "Reporter records emergency diagnostic when allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var reporter = Reporter.init(failing.allocator(), "oom.mc", "fn f() {}\n");
    defer reporter.deinit();

    reporter.err(.{ .offset = 0, .len = 0, .line = 1, .column = 1 }, "E_TEST: {s}", .{"primary"});

    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(reporter.diagnostic_oom);
    try std.testing.expectEqual(@as(usize, 0), reporter.diagnostics.items.len);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    const saved_allocator = reporter.allocator;
    reporter.allocator = std.testing.allocator;
    defer reporter.allocator = saved_allocator;
    try reporter.appendJson(&out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"code\":\"E_DIAGNOSTIC_OOM\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"error_count\":1") != null);
}

test "Reporter uses per-file source views for diagnostics and notes" {
    const root_source = "fn root() -> void {}\n";
    const lib_source = "fn lib() -> void {\n    missing;\n}\n";
    const views = [_]SourceView{
        .{ .file_id = 3, .path = "root.mc", .source = root_source },
        .{ .file_id = 7, .path = "lib.mc", .source = lib_source },
    };
    var reporter = Reporter.init(std.testing.allocator, "fallback.mc", "unrelated");
    defer reporter.deinit();
    reporter.source_views = &views;

    const missing_offset = std.mem.indexOf(u8, lib_source, "missing").?;
    reporter.errWithNotes(
        .{ .offset = missing_offset, .len = "missing".len, .line = 2, .column = 5, .file_id = 7 },
        "E_UNKNOWN_IDENTIFIER: unknown identifier missing",
        .{},
        &.{.{ .span = .{ .offset = 0, .len = 2, .line = 1, .column = 1, .file_id = 3 }, .message = "declared from root" }},
    );

    const location = reporter.location(reporter.diagnostics.items[0].span);
    try std.testing.expectEqualStrings("lib.mc", location.path);
    try std.testing.expectEqual(@as(usize, 2), location.line);
    const line = reporter.sourceLine(reporter.diagnostics.items[0].span).?;
    try std.testing.expectEqualStrings("    missing;", line.text);
    try std.testing.expectEqual(@as(usize, 5), line.column);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try reporter.appendJson(&out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"path\":\"lib.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"text\":\"    missing;\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"path\":\"root.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"text\":\"fn root() -> void {}\"") != null);
}
