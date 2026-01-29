const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const png = zignal.png;
const jpeg = zignal.jpeg;

const args = @import("args.zig");

const Args = struct {
    stats: bool = false,

    pub const meta = .{
        .stats = .{ .help = "Compute and display image statistics (min, max, mean, stdDev)" },
    };
};

pub const description = "Display detailed information about one or more image files.";

pub const help = args.generateHelp(
    Args,
    "zignal info [options] <image1> <image2> ...",
    description,
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    // Buffer for reading file data
    var read_buffer: [4096]u8 = undefined;

    for (parsed.positionals) |image_path| {
        if (parsed.positionals.len > 1) {
            try writer.print("File: {s}\n", .{image_path});
        }

        // Use a block to catch errors for individual files so we can continue to the next one
        const result = blk: {
            std.log.debug("Detecting format for: {s}", .{image_path});
            const image_format = zignal.ImageFormat.detectFromPath(io, gpa, image_path) catch |err| break :blk err;
            if (image_format) |fmt| {
                std.log.debug("Format detected: {s}", .{@tagName(fmt)});
                const file = std.Io.Dir.cwd().openFile(io, image_path, .{}) catch |err| break :blk err;
                defer file.close(io);

                var reader = file.reader(io, &read_buffer);

                switch (fmt) {
                    .png => {
                        const info = png.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                        try writer.print("Format:      PNG\n", .{});
                        try writer.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                        try writer.print("Bit Depth:   {d}\n", .{info.bit_depth});
                        try writer.print("Channels:    {d}\n", .{info.channels()});
                        try writer.print("Color Space: {s}\n", .{@tagName(info.color_type)});

                        if (info.gamma) |g| {
                            try writer.print("Gamma:       {d}\n", .{g});
                        }
                        if (info.srgb_intent) |intent| {
                            try writer.print("sRGB:        {s}\n", .{@tagName(intent)});
                        }
                    },
                    .jpeg => {
                        const info = jpeg.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                        try writer.print("Format:      JPEG\n", .{});
                        try writer.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                        try writer.print("Bit Depth:   {d}\n", .{info.precision});
                        try writer.print("Channels:    {d}\n", .{info.num_components});
                        try writer.print("Color Space: {s}\n", .{if (info.num_components == 1) "Grayscale" else "YCbCr"});
                        try writer.print("Frame Type:  {s}\n", .{@tagName(info.frame_type)});
                    },
                }
            } else {
                break :blk error.UnsupportedImageFormat;
            }

            if (parsed.options.stats) {
                // Load image as RGBA(u8)
                std.log.debug("Loading image for stats: {s}", .{image_path});
                var image = zignal.Image(zignal.Rgba(u8)).load(io, gpa, image_path) catch |err| break :blk err;
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

                try writer.print("\n{s: <8} {s: >8} {s: >8} {s: >10} {s: >10}\n", .{ "Channel", "Min", "Max", "Mean", "StdDev" });
                inline for (.{ .{ "Red", &r_stats }, .{ "Green", &g_stats }, .{ "Blue", &b_stats } }) |entry| {
                    try writer.print("{s: <8} {d: >8} {d: >8} {d: >10.2} {d: >10.2}\n", .{
                        entry[0],
                        entry[1].min(),
                        entry[1].max(),
                        entry[1].mean(),
                        entry[1].stdDev(),
                    });
                }
            }
            break :blk void{};
        };

        if (result) |_| {
            // Success
        } else |err| {
            std.log.err("failed to get info for '{s}': {t}", .{ image_path, err });
        }

        if (parsed.positionals.len > 1) {
            try writer.print("\n", .{});
        }
    }
    try writer.flush();
}
