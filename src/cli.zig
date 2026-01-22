const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const display = @import("cli/display.zig");
const fdm = @import("cli/fdm.zig");
const info = @import("cli/info.zig");
const tile = @import("cli/tile.zig");
const version = @import("cli/version.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const general_help =
    \\Usage: zignal <command> [options]
    \\
    \\Commands:
    \\  display  Display an image in the terminal
    \\  fdm      Apply Feature Distribution Matching (style transfer)
    \\  tile     Combine multiple images into a grid
    \\  info     Display image information
    \\  version  Display version information
    \\  help     Display this help message
    \\
    \\Run 'zignal help <command>' for more information on a specific command.
    \\
;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "display")) {
            display.run(init.io, &stdout.interface, init.gpa, &args) catch |err| {
                std.log.err("display command failed: {t}", .{err});
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, arg, "fdm")) {
            fdm.run(init.io, &stdout.interface, init.gpa, &args) catch |err| {
                std.log.err("fdm command failed: {t}", .{err});
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, arg, "tile")) {
            tile.run(init.io, &stdout.interface, init.gpa, &args) catch |err| {
                std.log.err("tile command failed: {t}", .{err});
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, arg, "info")) {
            info.run(init.io, &stdout.interface, init.gpa, &args) catch |err| {
                std.log.err("info command failed: {t}", .{err});
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, arg, "version")) {
            try version.run(init.io, &stdout.interface, init.gpa, &args);
            return;
        }
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try help(&stdout.interface, &args);
            return;
        }

        std.log.err("Unknown command: '{s}'", .{arg});
        try help(&stdout.interface, null);
        std.process.exit(1);
    }
    try help(&stdout.interface, null);
}

fn help(stdout: *std.Io.Writer, args: ?*std.process.Args.Iterator) !void {
    if (args) |commands| {
        if (commands.next()) |subcmd| {
            const help_map = std.StaticStringMap([]const u8).initComptime(.{
                .{ "display", display.help_text },
                .{ "fdm", fdm.help_text },
                .{ "tile", tile.help_text },
                .{ "info", info.help_text },
                .{ "version", version.help_text },
                .{ "help", general_help },
            });

            if (help_map.get(subcmd)) |text| {
                try stdout.print("{s}", .{text});
            } else {
                try stdout.print("Unknown command: \"{s}\"\n\n{s}", .{ subcmd, general_help });
                try stdout.flush();
                std.process.exit(1);
            }
            try stdout.flush();
            return;
        }
    }
    try stdout.print("{s}", .{general_help});
    try stdout.flush();
}
