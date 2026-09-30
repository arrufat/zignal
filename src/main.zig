//! Zignal command-line interface entry point and subcommand dispatcher.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const cli_args = @import("cli/args.zig");

// Subcommands are automatically discovered from public declarations that
// have 'run', 'description', and 'help'. They are marked 'pub' so that
// the compiler and linters don't complain about them being unused.
pub const blur = @import("cli/blur.zig");
pub const diff = @import("cli/diff.zig");
pub const display = @import("cli/display.zig");
pub const edges = @import("cli/edges.zig");
pub const fdm = @import("cli/fdm.zig");
pub const info = @import("cli/info.zig");
pub const metrics = @import("cli/metrics.zig");
pub const pipeline = @import("cli/pipeline.zig");
pub const qr = @import("cli/qr.zig");
pub const resize = @import("cli/resize.zig");
pub const tile = @import("cli/tile.zig");
pub const version = @import("cli/version.zig");

const root = @This();

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.default),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) > @backingInt(cli_args.runtime_log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &buffer);

    const cli: Cli = .init();
    try cli.run(init.io, init.gpa, &stdout.interface, &args);
}

/// CLI subcommand definition with execution handler and help text.
pub const Command = struct {
    name: []const u8,
    run: *const fn (Io, Allocator, *Io.Writer, *std.process.Args.Iterator) anyerror!void,
    description: []const u8,
    help: []const u8,
};

/// Command-line interface dispatcher that auto-discovers subcommands.
pub const Cli = struct {
    commands: []const Command,

    pub fn init() Cli {
        const cmds = comptime blk: {
            var found: []const Command = &.{};
            for (@typeInfo(root).@"struct".decl_names) |decl| {
                if (getCommandModule(decl)) |M| {
                    found = found ++ .{Command{ .name = decl, .run = runner(M), .description = M.description, .help = helpText(M) }};
                }
            }

            var array = found[0..found.len].*;
            std.sort.block(Command, &array, {}, struct {
                fn lessThan(_: void, lhs: Command, rhs: Command) bool {
                    return std.mem.lessThan(u8, lhs.name, rhs.name);
                }
            }.lessThan);

            break :blk array;
        };
        return .{ .commands = &cmds };
    }

    fn getCommandModule(comptime decl: anytype) ?type {
        const val = @field(root, decl);
        return if (@TypeOf(val) == type and
            @hasDecl(val, "run") and
            @hasDecl(val, "Args") and
            @hasDecl(val, "usage") and
            @hasDecl(val, "description"))
            val
        else
            null;
    }

    fn helpText(comptime M: type) []const u8 {
        return comptime cli_args.generateHelp(M.Args, M.usage, M.description);
    }

    /// Parses `M.Args`, handles `--help` and the positional count, then runs `M`.
    fn runner(comptime M: type) *const fn (Io, Allocator, *Io.Writer, *std.process.Args.Iterator) anyerror!void {
        return struct {
            fn run(io: Io, gpa: Allocator, writer: *Io.Writer, iterator: *std.process.Args.Iterator) anyerror!void {
                const parsed = try cli_args.parse(M.Args, gpa, iterator);
                defer parsed.deinit(gpa);
                if (parsed.help) return cli_args.printHelp(writer, helpText(M));

                const range: cli_args.Positionals = if (@hasDecl(M, "positionals")) M.positionals else .default;
                const n = parsed.positionals.len;
                if (!range.contains(n)) {
                    if (range.max) |max| {
                        if (max == range.min)
                            std.log.err("expected {d} argument(s), got {d}", .{ max, n })
                        else
                            std.log.err("expected {d} to {d} arguments, got {d}", .{ range.min, max, n });
                    } else std.log.err("expected at least {d} argument(s), got {d}", .{ range.min, n });
                    try cli_args.printHelp(writer, helpText(M));
                    return error.InvalidArguments;
                }
                return M.run(io, gpa, writer, parsed.options, parsed.positionals);
            }
        }.run;
    }

    pub fn run(
        self: Cli,
        io: Io,
        allocator: Allocator,
        stdout: *Io.Writer,
        args: *std.process.Args.Iterator,
    ) !void {
        var arg = args.next();

        // Handle global flags
        while (arg) |a| {
            if (try cli_args.parseLogLevel(a, args)) {
                arg = args.next();
            } else {
                break;
            }
        }

        if (arg) |cmd_name| {
            if (self.getCommand(cmd_name)) |cmd| {
                cmd.run(io, allocator, stdout, args) catch |err| {
                    // These were already reported where they happened.
                    if (err != error.BatchIncomplete and err != error.InvalidArguments) {
                        std.log.err("{s} command failed: {t}", .{ cmd_name, err });
                    }
                    stdout.flush() catch {};
                    std.process.exit(1);
                };
                return;
            }

            if (std.mem.eql(u8, cmd_name, "help") or std.mem.eql(u8, cmd_name, "--help") or std.mem.eql(u8, cmd_name, "-h")) {
                try self.printHelp(stdout, args);
                return;
            }

            std.log.err("unknown command: '{s}'", .{cmd_name});
            try self.printHelp(stdout, null);
            std.process.exit(1);
        }
        try self.printHelp(stdout, null);
    }

    fn getCommand(self: Cli, name: []const u8) ?Command {
        return for (self.commands) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) break cmd;
        } else null;
    }

    fn printHelp(self: Cli, stdout: *Io.Writer, args: ?*std.process.Args.Iterator) !void {
        if (args) |iterator| {
            if (iterator.next()) |subcmd| {
                if (self.getCommand(subcmd)) |cmd| {
                    try stdout.print("{s}", .{cmd.help});
                } else if (std.mem.eql(u8, subcmd, "help")) {
                    try self.printGeneralHelp(stdout);
                } else {
                    try stdout.print("Unknown command: \"{s}\"\n\n", .{subcmd});
                    try self.printGeneralHelp(stdout);
                    try stdout.flush();
                    std.process.exit(1);
                }
                try stdout.flush();
                return;
            }
        }
        try self.printGeneralHelp(stdout);
        try stdout.flush();
    }

    fn printGeneralHelp(self: Cli, stdout: *Io.Writer) !void {
        try stdout.print(
            \\Usage: zignal [options] <command> [command-options]
            \\
            \\Global Options:
            \\  --log-level <level>   Set the logging level ({s})
            \\
            \\Commands:
            \\
        , .{cli_args.log_level_names});

        var max_len: usize = "help".len;
        for (self.commands) |cmd| max_len = @max(max_len, cmd.name.len);

        for (self.commands) |cmd| {
            const desc = std.mem.sliceTo(cmd.description, '\n');
            try stdout.print("  {s}", .{cmd.name});
            try stdout.splatByteAll(' ', max_len + 2 - cmd.name.len);
            try stdout.print("{s}\n", .{desc});
        }

        try stdout.writeAll("  help");
        try stdout.splatByteAll(' ', max_len + 2 - "help".len);
        try stdout.writeAll("Display this help message\n");

        try stdout.print(
            \\
            \\Run 'zignal help <command>' for more information on a specific command.
            \\
        , .{});
    }
};
