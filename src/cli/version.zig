//! Version subcommand: prints Zignal version and build details.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const zignal = @import("zignal");

const args = @import("args.zig");

pub const Args = struct {};

pub const description = "Display version information.";

pub const usage = "zignal version";

pub const positionals: args.Positionals = .{ .min = 0, .max = 0 };

pub fn run(_: Io, _: Allocator, writer: *Io.Writer, _: Args, _: []const []const u8) !void {
    std.log.debug("printing version info...", .{});
    try writer.print("{s}\n", .{zignal.version});
    try writer.flush();
}
