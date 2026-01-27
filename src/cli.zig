const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const display = @import("cli/display.zig");
const fdm = @import("cli/fdm.zig");
const info = @import("cli/info.zig");
const metrics = @import("cli/metrics.zig");
const resize = @import("cli/resize.zig");
const stats = @import("cli/stats.zig");
const tile = @import("cli/tile.zig");
const version = @import("cli/version.zig");

const root = @This();

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const cli: Cli = .init(&.{ "display", "resize", "fdm", "tile", "info", "metrics", "stats", "version" });

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    try cli.run(init.gpa, init.io, &stdout.interface, &args);
}

pub const Command = struct {
    name: []const u8,
    run: *const fn (Io, *std.Io.Writer, Allocator, *std.process.Args.Iterator) anyerror!void,
    description: []const u8,
    help: []const u8,
};

pub const Cli = struct {
    commands: []const Command,

    pub fn init(comptime names: []const []const u8) Cli {
        const cmds = comptime blk: {
            var items: [names.len]Command = undefined;
            for (names, 0..) |name, i| {
                const module = @field(root, name);
                items[i] = Command{
                    .name = name,
                    .run = module.run,
                    .description = module.description,
                    .help = module.help,
                };
            }
            break :blk items;
        };
        return Cli{ .commands = &cmds };
    }

    pub fn run(self: Cli, allocator: Allocator, io: Io, stdout: *std.Io.Writer, args: *std.process.Args.Iterator) !void {
        if (args.next()) |arg| {
            if (self.getCommand(arg)) |cmd| {
                cmd.run(io, stdout, allocator, args) catch |err| {
                    std.log.err("{s} command failed: {t}", .{ arg, err });
                    std.process.exit(1);
                };
                return;
            }

            if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try self.printHelp(stdout, args);
                return;
            }

            std.log.err("Unknown command: '{s}'", .{arg});
            try self.printHelp(stdout, null);
            std.process.exit(1);
        }
        try self.printHelp(stdout, null);
    }

    fn getCommand(self: Cli, name: []const u8) ?Command {
        for (self.commands) |cmd| {
            if (std.mem.eql(u8, cmd.name, name)) return cmd;
        }
        return null;
    }

    fn printHelp(self: Cli, stdout: *std.Io.Writer, args: ?*std.process.Args.Iterator) !void {
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

    fn printGeneralHelp(self: Cli, stdout: *std.Io.Writer) !void {
        try stdout.print(
            \\Usage: zignal <command> [options]
            \\
            \\Commands:
            \\
        , .{});

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
