const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const display = @import("display.zig");
const common = @import("common.zig");

const Args = struct {
    output: ?[]const u8 = null,
    scale: ?f32 = null,
    threshold: ?u8 = null,
    binary: bool = false,
    display: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?[]const u8 = null,

    pub const meta = .{
        .output = .{ .help = "Path to save the difference image", .metavar = "path" },
        .scale = .{ .help = "Scale factor for difference visibility (default: 1.0)", .metavar = "float" },
        .threshold = .{ .help = "Ignore differences smaller than this value (0-255)", .metavar = "int" },
        .binary = .{ .help = "Produce a binary output (white for difference, black for match)" },
        .display = .{ .help = "Display the result in the terminal (default if no output file)" },
        .width = .{ .help = "Width of each sub-image for display", .metavar = "N" },
        .height = .{ .help = "Height of each sub-image for display", .metavar = "N" },
        .protocol = .{ .help = "Force display protocol: kitty, sixel, sgr, braille, auto", .metavar = "p" },
    };
};

pub const description = "Compute the visual difference between two images.";

pub const help = args.generateHelp(
    Args,
    "zignal diff <image1> <image2> [options]",
    description,
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help) {
        try args.printHelp(writer, help);
        return;
    }

    if (parsed.positionals.len != 2) {
        std.log.err("Expected exactly two input images.", .{});
        try args.printHelp(writer, help);
        return;
    }

    const path1 = parsed.positionals[0];
    const path2 = parsed.positionals[1];

    const should_display = parsed.options.display or parsed.options.output == null;

    // Load images
    std.log.debug("Loading first image: {s}", .{path1});
    var img1 = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path1) catch |err| {
        std.log.err("Failed to load image '{s}': {}", .{ path1, err });
        return;
    };
    defer img1.deinit(gpa);

    std.log.debug("Loading second image: {s}", .{path2});
    var img2 = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path2) catch |err| {
        std.log.err("Failed to load image '{s}': {}", .{ path2, err });
        return;
    };
    defer img2.deinit(gpa);

    if (img1.rows != img2.rows or img1.cols != img2.cols) {
        std.log.err("Dimension mismatch: {d}x{d} vs {d}x{d}", .{
            img1.cols, img1.rows, img2.cols, img2.rows,
        });
        return;
    }

    const scale = parsed.options.scale orelse 1.0;
    const threshold = parsed.options.threshold orelse 0;
    const binary = parsed.options.binary;

    std.log.debug("Computing difference...", .{});

    var diff_img = try zignal.Image(zignal.Rgba(u8)).init(gpa, img1.rows, img1.cols);
    defer diff_img.deinit(gpa);

    // Use DiffOptions to handle visualization logic inside the library
    const diff_opts = zignal.Image(zignal.Rgba(u8)).DiffOptions{
        .threshold = @floatFromInt(threshold),
        .scale = scale,
        .binary = binary,
        .force_opaque = true, // Force visual result to be opaque
    };

    var timer = try std.time.Timer.start();
    const result = try img1.diff(img2, diff_img, diff_opts);
    const diff_ns = timer.read();
    std.log.debug("Diff computation took {d:.3} ms", .{@as(f64, @floatFromInt(diff_ns)) / std.time.ns_per_ms});

    // If using binary mode, stats.max() will be 255 if any diff found, or 0.
    // If using absolute mode (with scaling), stats.max() will be the max visualization brightness.
    // However, users usually want to know the *raw* max difference, but we only have stats of the *processed* image.
    // For now, reporting the max pixel value in the diff image is consistent with what is shown.

    std.log.info("Max difference found: {d}", .{@as(u32, @intFromFloat(result.stats.max()))});
    std.log.info("Pixels differing > {d}: {d}", .{ threshold, result.diff_count });

    if (parsed.options.output) |output_path| {
        std.log.info("Saving difference image to '{s}'...", .{output_path});
        try diff_img.save(io, gpa, output_path);
    }

    if (should_display) {
        const images = [_]zignal.Image(zignal.Rgba(u8)){ img1, img2, diff_img };

        var canvas = try display.createHorizontalComposite(
            zignal.Rgba(u8),
            gpa,
            &images,
            parsed.options.width,
            parsed.options.height,
        );
        defer canvas.deinit(gpa);

        std.log.debug("Displaying result...", .{});
        const format = try display.resolveDisplayFormat(parsed.options.protocol, null, null);
        try display.displayCanvas(io, writer, &canvas, format);
    }
}
