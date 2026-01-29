const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");

const zignal = @import("zignal");

const cli_args = @import("cli/args.zig");

pub const blur = @import("cli/blur.zig");
pub const diff = @import("cli/diff.zig");
pub const display = @import("cli/display.zig");
pub const edges = @import("cli/edges.zig");
pub const fdm = @import("cli/fdm.zig");
pub const info = @import("cli/info.zig");
pub const metrics = @import("cli/metrics.zig");
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
    if (@intFromEnum(level) > @intFromEnum(cli_args.runtime_log_level)) return;
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
    try cli.run(init.gpa, init.io, &stdout.interface, &args);
}

pub const Command = struct {
    name: []const u8,
    run: *const fn (Io, *Io.Writer, Allocator, *std.process.Args.Iterator) anyerror!void,
    description: []const u8,
    help: []const u8,
};

pub const Cli = struct {
    commands: []const Command,

    pub fn init() Cli {
        const cmds = comptime blk: {
            var items: []const Command = &.{};
            for (std.meta.declarations(root)) |decl| {
                const val = @field(root, decl.name);
                if (@TypeOf(val) == type and
                    @hasDecl(val, "run") and
                    @hasDecl(val, "description") and
                    @hasDecl(val, "help"))
                {
                    items = items ++ .{Command{
                        .name = decl.name,
                        .run = val.run,
                        .description = val.description,
                        .help = val.help,
                    }};
                }
            }

            var array: [items.len]Command = undefined;
            @memcpy(&array, items);

            std.sort.block(Command, &array, {}, struct {
                fn less(_: void, lhs: Command, rhs: Command) bool {
                    return std.mem.lessThan(u8, lhs.name, rhs.name);
                }
            }.less);

            break :blk array;
        };
        return .{ .commands = &cmds };
    }

    pub fn run(
        self: Cli,
        allocator: Allocator,
        io: Io,
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
                cmd.run(io, stdout, allocator, args) catch |err| {
                    std.log.err("{s} command failed: {t}", .{ cmd_name, err });
                    std.process.exit(1);
                };
                return;
            }

            if (std.mem.eql(u8, cmd_name, "help") or std.mem.eql(u8, cmd_name, "--help") or std.mem.eql(u8, cmd_name, "-h")) {
                try self.printHelp(stdout, args);
                return;
            }

            std.log.err("Unknown command: '{s}'", .{cmd_name});
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
        const level_names = comptime blk: {
            var names: []const u8 = "";
            const fields = std.meta.fields(std.log.Level);
            for (fields, 0..) |field, i| {
                names = names ++ field.name;
                if (i < fields.len - 1) names = names ++ ", ";
            }
            break :blk names;
        };
        try stdout.print(
            \\Usage: zignal [options] <command> [command-options]
            \\
            \\Global Options:
            \\  --log-level <level>   Set the logging level ({s})
            \\
            \\Commands:
            \\
        , .{level_names});

        var max_len: usize = 0;
        for (self.commands) |cmd| {
            if (cmd.name.len > max_len) max_len = cmd.name.len;
        }
        const help_len = "help".len;
        if (help_len > max_len) max_len = help_len;

        const padding_target = max_len + 2;

        for (self.commands) |cmd| {
            var desc_iter = std.mem.splitSequence(u8, cmd.description, "\n");
            const desc = desc_iter.first();

            try stdout.print("  {s}", .{cmd.name});
            var i: usize = 0;
            const pad_len = padding_target - cmd.name.len;
            while (i < pad_len) : (i += 1) try stdout.writeAll(" ");
            try stdout.print("{s}\n", .{desc});
        }

        try stdout.print("  help", .{});
        var i: usize = 0;
        const pad_len = padding_target - help_len;
        while (i < pad_len) : (i += 1) try stdout.writeAll(" ");
        try stdout.print("Display this help message\n", .{});

        try stdout.print(
            \\
            \\Run 'zignal help <command>' for more information on a specific command.
            \\
        , .{});
    }
};
