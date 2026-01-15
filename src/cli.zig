const std = @import("std");

const zignal = @import("zignal");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var buffer: [256]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(init.io, &buffer);
            try stdout.interface.print("{s}\n", .{zignal.version});
            try stdout.interface.flush();
            return;
        }
    }
}
