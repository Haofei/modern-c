const std = @import("std");
const builtin = @import("builtin");

const ast = @import("ast.zig");
const backend = @import("backend.zig");
const path_policy = @import("path_policy.zig");

pub const Options = struct {
    profile: backend.Profile = .kernel,
    checks: backend.Checks = .{},
    check_fmt: bool = false,
    json_diagnostics: bool = false,
    structs_flag: ?[]const u8 = null,
    arch_flag: ?[]const u8 = null,
    platform_flag: ?[]const u8 = null,
    std_dir: ?[]const u8 = null,
    visibility_mode: ast.VisibilityMode = .legacy_pub_opt_in,
    output_path: ?[]const u8 = null,
    stub_asm: bool = false,
    linux_kernel: bool = false,
    remap_prefix: ?PathRemap = null,

    pub const PathRemap = struct {
        from: []const u8,
        to: []const u8,
    };

    pub fn parse(command: []const u8, args: *std.process.Args.Iterator) !Options {
        var opts: Options = .{};
        var saw_profile_flag = false;
        var saw_checks_flag = false;
        var saw_arch_flag = false;
        var saw_platform_flag = false;
        var saw_stub_asm_flag = false;
        var saw_linux_kernel_flag = false;
        var saw_std_dir_flag = false;
        var saw_visibility_flag = false;
        var saw_output_flag = false;
        var saw_remap_prefix_flag = false;
        var saw_json_flag = false;
        var saw_check_fmt_flag = false;
        var saw_structs_flag = false;

        while (args.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "--arch=")) {
                if (saw_arch_flag) return duplicateOption("--arch");
                saw_arch_flag = true;
                const value = flag["--arch=".len..];
                if (std.mem.eql(u8, value, "riscv64") or std.mem.eql(u8, value, "x86_64") or
                    std.mem.eql(u8, value, "aarch64"))
                {
                    opts.arch_flag = value;
                } else {
                    return error.InvalidArgs;
                }
            } else if (std.mem.startsWith(u8, flag, "--platform=")) {
                if (saw_platform_flag) return duplicateOption("--platform");
                saw_platform_flag = true;
                const value = flag["--platform=".len..];
                if (std.mem.eql(u8, value, "qemu_virt")) {
                    opts.platform_flag = value;
                } else {
                    return error.InvalidArgs;
                }
            } else if (std.mem.startsWith(u8, flag, "--structs=")) {
                if (saw_structs_flag) return duplicateOption("--structs");
                saw_structs_flag = true;
                opts.structs_flag = flag["--structs=".len..];
            } else if (std.mem.startsWith(u8, flag, "--std-dir=")) {
                if (saw_std_dir_flag) return duplicateOption("--std-dir");
                saw_std_dir_flag = true;
                const value = flag["--std-dir=".len..];
                if (value.len == 0) return error.InvalidArgs;
                opts.std_dir = value;
            } else if (std.mem.startsWith(u8, flag, "--visibility=")) {
                if (saw_visibility_flag) return duplicateOption("--visibility");
                saw_visibility_flag = true;
                const value = flag["--visibility=".len..];
                if (std.mem.eql(u8, value, "legacy")) {
                    opts.visibility_mode = .legacy_pub_opt_in;
                } else if (std.mem.eql(u8, value, "explicit")) {
                    opts.visibility_mode = .explicit_public;
                } else {
                    return error.InvalidArgs;
                }
            } else if (std.mem.eql(u8, flag, "-o")) {
                if (saw_output_flag) return duplicateOption("-o");
                saw_output_flag = true;
                const value = args.next() orelse return error.InvalidArgs;
                if (value.len == 0) return error.InvalidArgs;
                opts.output_path = value;
            } else if (std.mem.startsWith(u8, flag, "--profile=")) {
                if (saw_profile_flag) return duplicateOption("--profile");
                saw_profile_flag = true;
                const value = flag["--profile=".len..];
                if (std.mem.eql(u8, value, "kernel")) {
                    opts.profile = .kernel;
                } else if (std.mem.eql(u8, value, "hosted")) {
                    opts.profile = .hosted;
                } else {
                    return error.InvalidArgs;
                }
            } else if (std.mem.startsWith(u8, flag, "--checks=")) {
                if (saw_checks_flag) return duplicateOption("--checks");
                saw_checks_flag = true;
                try opts.parseChecks(flag["--checks=".len..]);
            } else if (std.mem.eql(u8, flag, "--optimize")) {
                // Deprecated alias for `--checks=elide-proven`.
                if (saw_checks_flag) return duplicateOption("--checks");
                saw_checks_flag = true;
                opts.checks.optimize = true;
            } else if (std.mem.eql(u8, flag, "--check")) {
                if (saw_check_fmt_flag) return duplicateOption("--check");
                saw_check_fmt_flag = true;
                opts.check_fmt = true;
            } else if (std.mem.eql(u8, flag, "--json")) {
                if (saw_json_flag) return duplicateOption("--json");
                saw_json_flag = true;
                opts.json_diagnostics = true;
            } else if (std.mem.eql(u8, flag, "--stub-asm")) {
                if (saw_stub_asm_flag) return duplicateOption("--stub-asm");
                saw_stub_asm_flag = true;
                opts.stub_asm = true;
            } else if (std.mem.eql(u8, flag, "--linux-kernel")) {
                if (saw_linux_kernel_flag) return duplicateOption("--linux-kernel");
                saw_linux_kernel_flag = true;
                opts.linux_kernel = true;
            } else if (std.mem.startsWith(u8, flag, "--remap-prefix=")) {
                if (saw_remap_prefix_flag) return duplicateOption("--remap-prefix");
                saw_remap_prefix_flag = true;
                opts.remap_prefix = try parsePathRemap(flag["--remap-prefix=".len..]);
            } else {
                if (std.mem.eql(u8, command, "build") and !std.mem.startsWith(u8, flag, "-")) {
                    std.debug.print("mcc build: multiple input files are not supported\n", .{});
                    return error.InvalidArgs;
                }
                std.debug.print("error: unknown option: {s}\n", .{flag});
                return error.InvalidArgs;
            }
        }

        try opts.validate(command, .{
            .saw_profile_flag = saw_profile_flag,
            .saw_checks_flag = saw_checks_flag,
            .saw_arch_flag = saw_arch_flag,
            .saw_platform_flag = saw_platform_flag,
            .saw_stub_asm_flag = saw_stub_asm_flag,
            .saw_linux_kernel_flag = saw_linux_kernel_flag,
            .saw_std_dir_flag = saw_std_dir_flag,
            .saw_visibility_flag = saw_visibility_flag,
            .saw_output_flag = saw_output_flag,
            .saw_remap_prefix_flag = saw_remap_prefix_flag,
            .saw_json_flag = saw_json_flag,
        });
        return opts;
    }

    pub fn remappedSourcePath(self: Options, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const remap = self.remap_prefix orelse return null;
        return remappedSourcePathForOs(allocator, remap, path, builtin.os.tag);
    }

    pub fn artifactSourcePath(self: Options, allocator: std.mem.Allocator, path: []const u8, cwd: ?[]const u8) !?[]const u8 {
        return artifactSourcePathForOs(self, allocator, path, cwd, builtin.os.tag);
    }

    fn artifactSourcePathForOs(self: Options, allocator: std.mem.Allocator, path: []const u8, cwd: ?[]const u8, os_tag: std.Target.Os.Tag) !?[]const u8 {
        if (self.remap_prefix) |remap| {
            if (try remappedSourcePathForOs(allocator, remap, path, os_tag)) |remapped| return remapped;
        }
        return defaultArtifactSourcePathForOs(allocator, path, cwd, os_tag);
    }

    fn remappedSourcePathForOs(allocator: std.mem.Allocator, remap: PathRemap, path: []const u8, os_tag: std.Target.Os.Tag) !?[]const u8 {
        if (!path_policy.hasPrefixBoundaryFor(os_tag, remap.from, path)) return null;
        const tail = path[remap.from.len..];
        const needs_separator = tail.len > 0 and !path_policy.isSeparatorFor(os_tag, tail[0]) and
            remap.to.len > 0 and !path_policy.isSeparatorFor(os_tag, remap.to[remap.to.len - 1]);
        const separator: u8 = if (os_tag == .windows) '\\' else '/';
        const remapped = if (needs_separator)
            try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ remap.to, separator, tail })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ remap.to, tail });
        return remapped;
    }

    fn defaultArtifactSourcePathForOs(allocator: std.mem.Allocator, path: []const u8, cwd: ?[]const u8, os_tag: std.Target.Os.Tag) !?[]const u8 {
        if (!isAbsolutePathFor(os_tag, path)) return null;

        if (cwd) |root| {
            if (root.len > 0 and path_policy.pathWithinFor(os_tag, root, path)) {
                const tail = stripLeadingSeparatorsFor(os_tag, path[root.len..]);
                return try allocVirtualSourcePath(allocator, tail);
            }
        }

        const basename = basenameFor(os_tag, path);
        return try allocVirtualSourcePath(allocator, if (basename.len == 0) "input.mc" else basename);
    }

    fn allocVirtualSourcePath(allocator: std.mem.Allocator, tail: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "/src");
        if (tail.len > 0) {
            try out.append(allocator, '/');
            for (tail) |ch| try out.append(allocator, if (ch == '\\') '/' else ch);
        }
        return try out.toOwnedSlice(allocator);
    }

    fn isAbsolutePathFor(os_tag: std.Target.Os.Tag, path: []const u8) bool {
        if (path.len == 0) return false;
        if (os_tag == .windows) {
            if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and path_policy.isSeparatorFor(os_tag, path[2])) return true;
            return path.len >= 2 and path_policy.isSeparatorFor(os_tag, path[0]) and path_policy.isSeparatorFor(os_tag, path[1]);
        }
        return path[0] == '/';
    }

    fn stripLeadingSeparatorsFor(os_tag: std.Target.Os.Tag, path: []const u8) []const u8 {
        var index: usize = 0;
        while (index < path.len and path_policy.isSeparatorFor(os_tag, path[index])) : (index += 1) {}
        return path[index..];
    }

    fn basenameFor(os_tag: std.Target.Os.Tag, path: []const u8) []const u8 {
        var end = path.len;
        while (end > 0 and path_policy.isSeparatorFor(os_tag, path[end - 1])) : (end -= 1) {}
        var start = end;
        while (start > 0 and !path_policy.isSeparatorFor(os_tag, path[start - 1])) : (start -= 1) {}
        return path[start..end];
    }

    pub fn targetArch(self: Options) backend.TargetArch {
        return backend.targetArchFromName(self.arch_flag orelse "riscv64").?;
    }

    pub fn isEmitLayout(command: []const u8) bool {
        return std.mem.eql(u8, command, "emit-layout");
    }

    pub fn isEmitCStruct(command: []const u8) bool {
        return std.mem.eql(u8, command, "emit-c-struct");
    }

    pub fn isSourceLoadingCommand(command: []const u8) bool {
        return std.mem.eql(u8, command, "lex") or
            std.mem.eql(u8, command, "build") or
            std.mem.eql(u8, command, "check") or
            std.mem.eql(u8, command, "run-trap") or
            std.mem.eql(u8, command, "facts") or
            std.mem.eql(u8, command, "lower-hir") or
            std.mem.eql(u8, command, "verify-hir") or
            std.mem.eql(u8, command, "lower-mir") or
            std.mem.eql(u8, command, "verify") or
            std.mem.eql(u8, command, "lower-ir") or
            std.mem.eql(u8, command, "lower-c") or
            std.mem.eql(u8, command, "emit-c") or
            std.mem.eql(u8, command, "emit-map") or
            std.mem.eql(u8, command, "emit-llvm") or
            isEmitLayout(command) or
            isEmitCStruct(command) or
            std.mem.eql(u8, command, "symbols") or
            std.mem.eql(u8, command, "list-tests");
    }

    fn parseChecks(self: *Options, value: []const u8) !void {
        var saw_all = false;
        var saw_elide_proven = false;
        var tokens = std.mem.splitScalar(u8, value, ',');
        while (tokens.next()) |tok| {
            if (tok.len == 0) return error.InvalidArgs;
            if (std.mem.eql(u8, tok, "all")) {
                if (saw_all or saw_elide_proven) return error.InvalidArgs;
                saw_all = true;
                self.checks.optimize = false;
            } else if (std.mem.eql(u8, tok, "elide-proven")) {
                if (saw_all or saw_elide_proven) return error.InvalidArgs;
                saw_elide_proven = true;
                self.checks.optimize = true;
            } else if (std.mem.eql(u8, tok, "ksan")) {
                self.checks.ksan = true;
            } else if (std.mem.eql(u8, tok, "msan")) {
                // KMSAN builds on the ksan shadow and implies its instrumentation.
                self.checks.msan = true;
                self.checks.ksan = true;
            } else if (std.mem.eql(u8, tok, "csan")) {
                self.checks.csan = true;
            } else {
                return error.InvalidArgs;
            }
        }
    }

    fn parsePathRemap(value: []const u8) !PathRemap {
        const sep = std.mem.indexOfScalar(u8, value, '=') orelse return error.InvalidArgs;
        if (sep == 0 or sep + 1 >= value.len) return error.InvalidArgs;
        return .{
            .from = value[0..sep],
            .to = value[sep + 1 ..],
        };
    }

    const SeenFlags = struct {
        saw_profile_flag: bool,
        saw_checks_flag: bool,
        saw_arch_flag: bool,
        saw_platform_flag: bool,
        saw_stub_asm_flag: bool,
        saw_linux_kernel_flag: bool,
        saw_std_dir_flag: bool,
        saw_visibility_flag: bool,
        saw_output_flag: bool,
        saw_remap_prefix_flag: bool,
        saw_json_flag: bool,
    };

    fn validate(self: Options, command: []const u8, seen: SeenFlags) !void {
        const is_c_artifact_command = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-map");
        const accepts_output_path = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-map") or
            std.mem.eql(u8, command, "emit-llvm") or std.mem.eql(u8, command, "build");
        const accepts_checks = std.mem.eql(u8, command, "verify") or std.mem.eql(u8, command, "lower-mir") or
            std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-map") or
            std.mem.eql(u8, command, "emit-llvm");
        const accepts_remap_prefix = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-map") or
            std.mem.eql(u8, command, "emit-llvm") or std.mem.eql(u8, command, "build");
        const needs_structs = isEmitLayout(command) or isEmitCStruct(command);
        const is_emit_command = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-map") or
            std.mem.eql(u8, command, "emit-llvm");

        if (seen.saw_profile_flag and !is_c_artifact_command) return invalidOptionForCommand("--profile", command);
        if (seen.saw_checks_flag and !accepts_checks) return invalidOptionForCommand("--checks", command);
        if (seen.saw_stub_asm_flag and !is_emit_command) return invalidOptionForCommand("--stub-asm", command);
        if (seen.saw_linux_kernel_flag and !std.mem.eql(u8, command, "emit-llvm"))
            return invalidOptionForCommand("--linux-kernel", command);
        if (seen.saw_arch_flag and !accepts_checks) return invalidOptionForCommand("--arch", command);
        if (seen.saw_platform_flag and !accepts_checks) return invalidOptionForCommand("--platform", command);
        if (seen.saw_std_dir_flag and !isSourceLoadingCommand(command)) return invalidOptionForCommand("--std-dir", command);
        if (seen.saw_visibility_flag and !isSourceLoadingCommand(command)) return invalidOptionForCommand("--visibility", command);
        if (seen.saw_output_flag and !accepts_output_path) return invalidOptionForCommand("-o", command);
        if (seen.saw_remap_prefix_flag and !accepts_remap_prefix) return invalidOptionForCommand("--remap-prefix", command);
        if (seen.saw_json_flag and !std.mem.eql(u8, command, "check")) return invalidOptionForCommand("--json", command);
        if (self.checks.csan and (self.checks.ksan or self.checks.msan)) {
            std.debug.print("error: --checks=csan cannot be combined with ksan/msan (a single raw access wraps one shadow protocol)\n", .{});
            return error.InvalidArgs;
        }
        if (self.check_fmt and !std.mem.eql(u8, command, "fmt")) return invalidOptionForCommand("--check", command);
        if (self.structs_flag != null and !needs_structs) return invalidOptionForCommand("--structs", command);
        if (needs_structs and self.structs_flag == null) return error.InvalidArgs;
        if (std.mem.eql(u8, command, "build") and self.output_path == null) {
            std.debug.print("mcc build: missing -o <exe>\n", .{});
            return error.InvalidArgs;
        }
    }

    fn invalidOptionForCommand(option: []const u8, command: []const u8) error{InvalidArgs} {
        std.debug.print("error: option {s} is not valid for command `{s}`\n", .{ option, command });
        return error.InvalidArgs;
    }

    fn duplicateOption(option: []const u8) error{InvalidArgs} {
        std.debug.print("error: duplicate option: {s}\n", .{option});
        return error.InvalidArgs;
    }
};

test "source remap accepts trailing separators and preserves boundaries" {
    const allocator = std.testing.allocator;
    const posix = Options{ .remap_prefix = .{ .from = "/work/project/", .to = "/src" } };
    const remapped = (try posix.remappedSourcePath(allocator, "/work/project/file.mc")).?;
    defer allocator.free(remapped);
    try std.testing.expectEqualStrings("/src/file.mc", remapped);

    const windows_remapped = (try Options.remappedSourcePathForOs(
        allocator,
        .{ .from = "C:\\work\\", .to = "Z:\\src" },
        "c:\\work\\file.mc",
        .windows,
    )).?;
    defer allocator.free(windows_remapped);
    try std.testing.expectEqualStrings("Z:\\src\\file.mc", windows_remapped);

    const bounded = Options{ .remap_prefix = .{ .from = "/work/project", .to = "/src" } };
    try std.testing.expect((try bounded.remappedSourcePath(allocator, "/work/project2/file.mc")) == null);
    try std.testing.expect((try bounded.remappedSourcePath(allocator, "/work/project\\other/file.mc")) == null);
}

test "artifact source path redacts absolute paths by default" {
    const allocator = std.testing.allocator;
    const opts: Options = .{};

    try std.testing.expect((try opts.artifactSourcePathForOs(allocator, "src/main.mc", "/work/project", .linux)) == null);

    const under_cwd = (try opts.artifactSourcePathForOs(allocator, "/work/project/src/main.mc", "/work/project", .linux)).?;
    defer allocator.free(under_cwd);
    try std.testing.expectEqualStrings("/src/src/main.mc", under_cwd);

    const outside_cwd = (try opts.artifactSourcePathForOs(allocator, "/tmp/build/private/input.mc", "/work/project", .linux)).?;
    defer allocator.free(outside_cwd);
    try std.testing.expectEqualStrings("/src/input.mc", outside_cwd);

    const windows = (try opts.artifactSourcePathForOs(allocator, "C:\\work\\project\\src\\main.mc", "C:\\work\\project", .windows)).?;
    defer allocator.free(windows);
    try std.testing.expectEqualStrings("/src/src/main.mc", windows);
}

test "explicit source remap overrides default artifact redaction" {
    const allocator = std.testing.allocator;
    const opts = Options{ .remap_prefix = .{ .from = "/work/project", .to = "/repo" } };

    const remapped = (try opts.artifactSourcePathForOs(allocator, "/work/project/src/main.mc", "/work/project", .linux)).?;
    defer allocator.free(remapped);
    try std.testing.expectEqualStrings("/repo/src/main.mc", remapped);
}
