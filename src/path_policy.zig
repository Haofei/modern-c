const std = @import("std");
const builtin = @import("builtin");

pub fn isSeparatorFor(os_tag: std.Target.Os.Tag, ch: u8) bool {
    return ch == '/' or (os_tag == .windows and ch == '\\');
}

pub fn isSeparator(ch: u8) bool {
    return isSeparatorFor(builtin.os.tag, ch);
}

fn prefixEqualsFor(os_tag: std.Target.Os.Tag, left: []const u8, right: []const u8) bool {
    return if (os_tag == .windows)
        std.ascii.eqlIgnoreCase(left, right)
    else
        std.mem.eql(u8, left, right);
}

pub fn hasPrefixBoundaryFor(os_tag: std.Target.Os.Tag, prefix: []const u8, path: []const u8) bool {
    if (prefix.len > path.len or !prefixEqualsFor(os_tag, prefix, path[0..prefix.len])) return false;
    if (prefix.len == path.len) return true;
    if (prefix.len == 0) return false;
    return isSeparatorFor(os_tag, prefix[prefix.len - 1]) or
        isSeparatorFor(os_tag, path[prefix.len]);
}

pub fn hasPrefixBoundary(prefix: []const u8, path: []const u8) bool {
    return hasPrefixBoundaryFor(builtin.os.tag, prefix, path);
}

pub fn pathWithinFor(os_tag: std.Target.Os.Tag, root: []const u8, path: []const u8) bool {
    return hasPrefixBoundaryFor(os_tag, root, path);
}

pub fn pathWithin(root: []const u8, path: []const u8) bool {
    return pathWithinFor(builtin.os.tag, root, path);
}

pub fn isExplicitlyRelativeFor(os_tag: std.Target.Os.Tag, path: []const u8) bool {
    if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) return true;
    return std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../") or
        (os_tag == .windows and
            (std.mem.startsWith(u8, path, ".\\") or std.mem.startsWith(u8, path, "..\\")));
}

pub fn isExplicitlyRelative(path: []const u8) bool {
    return isExplicitlyRelativeFor(builtin.os.tag, path);
}

test "path containment uses operating-system-native component separators" {
    try std.testing.expect(pathWithinFor(.linux, "/tmp/project", "/tmp/project/sub/file.mc"));
    try std.testing.expect(!pathWithinFor(.linux, "/tmp/project", "/tmp/project2/file.mc"));
    try std.testing.expect(!pathWithinFor(.linux, "/tmp/project", "/tmp/project\\escape/file.mc"));
    try std.testing.expect(!pathWithinFor(.linux, "/tmp/project", "/tmp/project\\\\escape/file.mc"));

    try std.testing.expect(pathWithinFor(.windows, "C:\\project", "c:\\project\\sub\\file.mc"));
    try std.testing.expect(pathWithinFor(.windows, "C:\\project", "C:\\project/sub/file.mc"));
    try std.testing.expect(!pathWithinFor(.windows, "C:\\project", "C:\\project2\\file.mc"));
    try std.testing.expect(isExplicitlyRelativeFor(.windows, "..\\child.mc"));
    try std.testing.expect(!isExplicitlyRelativeFor(.linux, "..\\child.mc"));
}
