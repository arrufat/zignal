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

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    _ = io;
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help) {
        try args.printHelp(writer, help_text);
        return;
    }

    try writer.print("{s}\n", .{zignal.version});
    try writer.flush();
}
