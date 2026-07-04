const std = @import("std");

const diagnostics_md = @embedFile("diagnostics_reference_md");

const Row = struct {
    message_cell: []const u8,
    source_cell: []const u8,
};

pub fn explain(allocator: std.mem.Allocator, code: []const u8) !?[]u8 {
    const row = findRow(code) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "{s}\n", .{code});
    try appendCell(&out, allocator, "messages", row.message_cell);
    try appendCell(&out, allocator, "sources", row.source_cell);
    return try out.toOwnedSlice(allocator);
}

fn findRow(code: []const u8) ?Row {
    var lines = std.mem.splitScalar(u8, diagnostics_md, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| `E_")) continue;
        var cells = std.mem.splitSequence(u8, line, " | ");
        const code_cell = cells.next() orelse continue;
        const message_cell = cells.next() orelse continue;
        const source_cell = cells.next() orelse continue;
        const parsed_code = std.mem.trim(u8, code_cell, "| `");
        if (std.mem.eql(u8, parsed_code, code)) {
            return .{
                .message_cell = std.mem.trim(u8, message_cell, " "),
                .source_cell = std.mem.trim(u8, source_cell, " |"),
            };
        }
    }
    return null;
}

fn appendCell(out: *std.ArrayList(u8), allocator: std.mem.Allocator, heading: []const u8, cell: []const u8) !void {
    try out.print(allocator, "\n{s}:\n", .{heading});
    var parts = std.mem.splitSequence(u8, cell, "<br>");
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " ");
        if (part.len == 0) continue;
        try out.appendSlice(allocator, "  - ");
        try appendCleanMarkdown(out, allocator, part);
        try out.append(allocator, '\n');
    }
}

fn appendCleanMarkdown(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "\\`")) {
            try out.append(allocator, '`');
            i += 2;
        } else if (std.mem.startsWith(u8, text[i..], "&lt;")) {
            try out.append(allocator, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, text[i..], "&gt;")) {
            try out.append(allocator, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, text[i..], "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else {
            try out.append(allocator, text[i]);
            i += 1;
        }
    }
}
