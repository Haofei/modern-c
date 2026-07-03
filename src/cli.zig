const std = @import("std");

const backend = @import("backend.zig");
const lower_c = @import("lower_c.zig");

pub const Options = struct {
    profile: lower_c.Profile = .kernel,
    checks: backend.Checks = .{},
    check_fmt: bool = false,
    structs_flag: ?[]const u8 = null,
    arch_flag: ?[]const u8 = null,
    platform_flag: ?[]const u8 = null,
    std_dir: ?[]const u8 = null,
    stub_asm: bool = false,

    pub fn parse(command: []const u8, args: *std.process.Args.Iterator) !Options {
        var opts: Options = .{};
        var saw_profile_flag = false;
        var saw_checks_flag = false;
        var saw_arch_flag = false;
        var saw_platform_flag = false;
        var saw_stub_asm_flag = false;
        var saw_std_dir_flag = false;

        while (args.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "--arch=")) {
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
                saw_platform_flag = true;
                const value = flag["--platform=".len..];
                if (std.mem.eql(u8, value, "qemu_virt")) {
                    opts.platform_flag = value;
                } else {
                    return error.InvalidArgs;
                }
            } else if (std.mem.startsWith(u8, flag, "--structs=")) {
                opts.structs_flag = flag["--structs=".len..];
            } else if (std.mem.startsWith(u8, flag, "--std-dir=")) {
                saw_std_dir_flag = true;
                const value = flag["--std-dir=".len..];
                if (value.len == 0) return error.InvalidArgs;
                opts.std_dir = value;
            } else if (std.mem.startsWith(u8, flag, "--profile=")) {
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
                saw_checks_flag = true;
                try opts.parseChecks(flag["--checks=".len..]);
            } else if (std.mem.eql(u8, flag, "--optimize")) {
                // Deprecated alias for `--checks=elide-proven`.
                saw_checks_flag = true;
                opts.checks.optimize = true;
            } else if (std.mem.eql(u8, flag, "--check")) {
                opts.check_fmt = true;
            } else if (std.mem.eql(u8, flag, "--stub-asm")) {
                saw_stub_asm_flag = true;
                opts.stub_asm = true;
            } else {
                return error.InvalidArgs;
            }
        }

        try opts.validate(command, .{
            .saw_profile_flag = saw_profile_flag,
            .saw_checks_flag = saw_checks_flag,
            .saw_arch_flag = saw_arch_flag,
            .saw_platform_flag = saw_platform_flag,
            .saw_stub_asm_flag = saw_stub_asm_flag,
            .saw_std_dir_flag = saw_std_dir_flag,
        });
        return opts;
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
        var tokens = std.mem.splitScalar(u8, value, ',');
        while (tokens.next()) |tok| {
            if (std.mem.eql(u8, tok, "all")) {
                self.checks.optimize = false;
            } else if (std.mem.eql(u8, tok, "elide-proven")) {
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

    const SeenFlags = struct {
        saw_profile_flag: bool,
        saw_checks_flag: bool,
        saw_arch_flag: bool,
        saw_platform_flag: bool,
        saw_stub_asm_flag: bool,
        saw_std_dir_flag: bool,
    };

    fn validate(self: Options, command: []const u8, seen: SeenFlags) !void {
        const is_c_artifact_command = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-map");
        const accepts_checks = std.mem.eql(u8, command, "verify") or std.mem.eql(u8, command, "lower-mir") or
            std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-llvm");
        const needs_structs = isEmitLayout(command) or isEmitCStruct(command);
        const is_emit_command = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-llvm");

        if (seen.saw_profile_flag and !is_c_artifact_command) return error.InvalidArgs;
        if (seen.saw_checks_flag and !accepts_checks) return error.InvalidArgs;
        if (seen.saw_stub_asm_flag and !is_emit_command) return error.InvalidArgs;
        if (seen.saw_arch_flag and !accepts_checks) return error.InvalidArgs;
        if (seen.saw_platform_flag and !accepts_checks) return error.InvalidArgs;
        if (seen.saw_std_dir_flag and !isSourceLoadingCommand(command)) return error.InvalidArgs;
        if (self.checks.csan and (self.checks.ksan or self.checks.msan)) {
            std.debug.print("error: --checks=csan cannot be combined with ksan/msan (a single raw access wraps one shadow protocol)\n", .{});
            return error.InvalidArgs;
        }
        if (self.check_fmt and !std.mem.eql(u8, command, "fmt")) return error.InvalidArgs;
        if (self.structs_flag != null and !needs_structs) return error.InvalidArgs;
        if (needs_structs and self.structs_flag == null) return error.InvalidArgs;
    }
};
