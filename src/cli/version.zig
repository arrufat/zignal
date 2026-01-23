const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const zignal = @import("zignal");

const args = @import("args.zig");

const Args = struct {};

pub const description = "Display version information.";

pub const help = args.generateHelp(
    Args,
    "zignal version",
    description,
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    _ = io;
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help) {
        try args.printHelp(writer, help);
        return;
    }

    try writer.print("{s}\n", .{zignal.version});
    try writer.flush();
}
