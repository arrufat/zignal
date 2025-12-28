const std = @import("std");
const build_options = @import("build_options");

pub fn main() !void {
    var buffer: [256]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.ioBasic();
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{s}\n", .{build_options.version});
    try stdout.interface.flush();
}
