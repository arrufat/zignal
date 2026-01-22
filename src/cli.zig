const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const info = @import("cli/info.zig");
const version = @import("cli/version.zig");
const display = @import("cli/display.zig");
const fdm = @import("cli/fdm.zig");

const general_help =
    \\Usage: zignal <command> [options]
    \\
    \\Commands:
    \\  display  Display an image in the terminal
    \\  fdm      Apply Feature Distribution Matching (style transfer)
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
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "display")) {
            display.run(init.io, init.gpa, &args) catch |err| {
                std.log.err("display command failed: {t}", .{err});
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, arg, "fdm")) {
            fdm.run(init.io, init.gpa, &args) catch |err| {
                std.log.err("fdm command failed: {t}", .{err});
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, arg, "version")) {
            try version.run(init.io, init.gpa, &args);
            return;
        }
        if (std.mem.eql(u8, arg, "info")) {
            info.run(init.io, init.gpa, &args) catch |err| {
                std.log.err("info command failed: {t}", .{err});
                std.process.exit(1);
            };
            return;
        }
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try help(init.io, &args);
            return;
        }

        std.log.err("Unknown command: '{s}'", .{arg});
        try help(init.io, null);
        std.process.exit(1);
    }
    try help(init.io, null);
}

fn help(io: Io, args: ?*std.process.Args.Iterator) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    if (args) |commands| {
        if (commands.next()) |subcmd| {
            const help_map = std.StaticStringMap([]const u8).initComptime(.{
                .{ "display", display.help_text },
                .{ "fdm", fdm.help_text },
                .{ "info", info.help_text },
                .{ "version", version.help_text },
                .{ "help", general_help },
            });

            if (help_map.get(subcmd)) |text| {
                try stdout.interface.print("{s}", .{text});
            } else {
                try stdout.interface.print("Unknown command: \"{s}\"\n\n{s}", .{ subcmd, general_help });
                try stdout.interface.flush();
                std.process.exit(1);
            }
            try stdout.interface.flush();
            return;
        }
    }
    try stdout.interface.print("{s}", .{general_help});
    try stdout.interface.flush();
}
