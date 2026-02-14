const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const zignal = @import("zignal");
const BitmapFont = zignal.font.BitmapFont;

fn usage() noreturn {
    std.debug.print("usage: zig run tools/bdf_to_pcf.zig -- <input.bdf> <output.pcf>\n", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    if (!args_iter.skip()) usage(); // Skip executable name

    const input_path = args_iter.next() orelse usage();
    const output_path = args_iter.next() orelse usage();

    if (args_iter.next() != null) usage(); // Too many arguments

    const io = init.io;

    var font = try zignal.font.bdf.load(io, allocator, input_path, .all);
    defer font.deinit(allocator);

    try font.save(io, allocator, output_path);
}
