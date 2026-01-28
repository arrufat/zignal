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
        std.log.debug("Loading image: {s}", .{path});
        var image = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path) catch |err| {
            std.log.err("Failed to load image '{s}': {t}", .{ path, err });
            continue;
        };
        defer image.deinit(gpa);

        std.log.debug("Computing statistics...", .{});
        var timer = try std.time.Timer.start();
        var r_stats: zignal.RunningStats(f64) = .init();
        var g_stats: zignal.RunningStats(f64) = .init();
        var b_stats: zignal.RunningStats(f64) = .init();

        for (image.data) |pixel| {
            r_stats.add(pixel.r);
            g_stats.add(pixel.g);
            b_stats.add(pixel.b);
        }
        const stats_ns = timer.read();
        std.log.debug("Statistics computed in {d:.3} ms", .{@as(f64, @floatFromInt(stats_ns)) / std.time.ns_per_ms});

        try writer.print("{s: <8} {s: >8} {s: >8} {s: >10} {s: >10}\n", .{ "Channel", "Min", "Max", "Mean", "StdDev" });
        inline for (.{ .{ "Red", &r_stats }, .{ "Green", &g_stats }, .{ "Blue", &b_stats } }) |entry| {
            try writer.print("{s: <8} {d: >8} {d: >8} {d: >10.2} {d: >10.2}\n", .{
                entry[0],
                entry[1].min(),
                entry[1].max(),
                entry[1].mean(),
                entry[1].stdDev(),
            });
        }

        try writer.flush();
    }
}
