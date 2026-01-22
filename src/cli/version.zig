const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const zignal = @import("zignal");

const args = @import("args.zig");

const Args = struct {};

pub const help_text = args.generateHelp(
    Args,
    "zignal version",
    "Display version information.",
);

pub fn run(io: Io, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help) {
        try args.printHelp(io, help_text);
        return;
    }

    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    try stdout.interface.print("{s}\n", .{zignal.version});
}
