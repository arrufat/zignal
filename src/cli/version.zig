const std = @import("std");
const zignal = @import("zignal");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli_args = @import("args.zig");

const Args = struct {};

pub const help_text = cli_args.generateHelp(
    Args,
    "zignal version",
    "Display version information.",
);

pub fn run(io: Io, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try cli_args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    if (parsed.help) {
        try stdout.interface.print("{s}", .{help_text});
        try stdout.interface.flush();
        return;
    }

    try stdout.interface.print("{s}\n", .{zignal.version});
    try stdout.interface.flush();
}
