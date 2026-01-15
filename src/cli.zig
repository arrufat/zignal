const std = @import("std");
const Io = std.Io;

const zignal = @import("zignal");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "version")) {
            try version(init.io);
            return;
        }
    }
}

fn version(io: Io) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{s}\n", .{zignal.version});
    try stdout.interface.flush();
}
