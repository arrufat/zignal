const std = @import("std");
const build_options = @import("build_options");

pub fn main() !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try stdout.interface.print("{s}\n", .{build_options.version});
    try stdout.interface.flush();
}
