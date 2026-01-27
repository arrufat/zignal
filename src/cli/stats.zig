const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");

const Args = struct {};

pub const description = "Compute and display statistics for one or more images.";

pub const help = args.generateHelp(
    Args,
    "zignal stats <image1> <image2> ...",
    description,
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    for (parsed.positionals) |path| {
        if (parsed.positionals.len > 1) {
            try writer.print("\nFile: {s}\n", .{path});
        }

        // Load image as RGBA(u8)
        var image = try zignal.Image(zignal.Rgba(u8)).load(io, gpa, path);
        defer image.deinit(gpa);

        var r_stats = zignal.RunningStats(f64).init();
        var g_stats = zignal.RunningStats(f64).init();
        var b_stats = zignal.RunningStats(f64).init();
        var a_stats = zignal.RunningStats(f64).init();
        var l_stats = zignal.RunningStats(f64).init();

        for (image.data) |pixel| {
            r_stats.add(@floatFromInt(pixel.r));
            g_stats.add(@floatFromInt(pixel.g));
            b_stats.add(@floatFromInt(pixel.b));
            a_stats.add(@floatFromInt(pixel.a));

            // Luma returns 0..1, scale to 0..255 for consistency
            l_stats.add(pixel.luma() * 255.0);
        }

        try writer.print("{s: <8} {s: >8} {s: >8} {s: >10} {s: >10}\n", .{ "Channel", "Min", "Max", "Mean", "StdDev" });
        inline for (.{ .{ "Red", &r_stats }, .{ "Green", &g_stats }, .{ "Blue", &b_stats }, .{ "Alpha", &a_stats }, .{ "Luma", &l_stats } }) |entry| {
            try writer.print("{s: <8} {d: >8} {d: >8} {d: >10.2} {d: >10.2}\n", .{
                entry[0],
                @as(u32, @intFromFloat(entry[1].min())),
                @as(u32, @intFromFloat(entry[1].max())),
                entry[1].mean(),
                entry[1].stdDev(),
            });
        }

        try writer.flush();
    }
}
