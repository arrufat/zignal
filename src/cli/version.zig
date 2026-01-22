const std = @import("std");
const zignal = @import("zignal");
const Io = std.Io;
const cli_args = @import("args.zig");

const Args = struct {};

pub const help_text = cli_args.generateHelp(
    Args,
    "zignal version",
    "Display version information.",
);

pub fn run(io: Io) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{s}\n", .{zignal.version});
    try stdout.interface.flush();
}
