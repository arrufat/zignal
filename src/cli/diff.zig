//! Diff subcommand: computes and visualizes pixel differences between two images.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");
const display = @import("display.zig");

pub const Args = struct {
    output: ?[]const u8 = null,
    scale: ?f32 = null,
    threshold: ?u8 = null,
    binary: bool = false,
    display: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?display.ProtocolTag = null,

    pub const meta = .{
        .output = .{ .help = "Path to save the difference image", .metavar = "path", .short = 'o' },
        .scale = .{ .help = "Scale factor for difference visibility (default: 1.0)", .metavar = "float" },
        .threshold = .{ .help = "Ignore differences smaller than this value (0-255)", .metavar = "int" },
        .binary = .{ .help = "Produce a binary output (white for difference, black for match)" },
        .display = .{ .help = "Display the result in the terminal (default if no output file)", .short = 'd' },
        .width = .{ .help = "Width of each sub-image for display", .metavar = "N" },
        .height = .{ .help = "Height of each sub-image for display", .metavar = "N" },
        .protocol = .{ .help = display.protocol_help, .metavar = "p" },
    };
};

pub const description = "Compute the visual difference between two images.";

pub const usage = "zignal diff <image1> <image2> [options]";

pub const positionals: args.Positionals = .{ .min = 2, .max = 2 };

pub fn run(io: Io, gpa: Allocator, writer: *Io.Writer, options: Args, inputs: []const []const u8) !void {
    const path1 = inputs[0];
    const path2 = inputs[1];

    const should_display = options.display or options.output == null;

    std.log.debug("loading first image: {s}", .{path1});
    var img1 = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path1) catch |err| {
        std.log.err("failed to load image '{s}': {t}", .{ path1, err });
        return err;
    };
    defer img1.deinit(gpa);

    std.log.debug("loading second image: {s}", .{path2});
    var img2 = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path2) catch |err| {
        std.log.err("failed to load image '{s}': {t}", .{ path2, err });
        return err;
    };
    defer img2.deinit(gpa);

    if (img1.rows != img2.rows or img1.cols != img2.cols) {
        std.log.err("dimension mismatch: {d}x{d} vs {d}x{d}", .{
            img1.cols, img1.rows, img2.cols, img2.rows,
        });
        return error.DimensionMismatch;
    }

    const threshold = options.threshold orelse 0;

    var diff_img = try zignal.Image(zignal.Rgba(u8)).init(gpa, img1.rows, img1.cols);
    defer diff_img.deinit(gpa);

    const timer = common.Timer.begin(io);
    const result = try img1.diff(img2, diff_img, .{
        .threshold = threshold,
        .scale = options.scale orelse 1.0,
        .binary = options.binary,
        .force_opaque = true,
    });
    timer.logElapsed("diff");

    // `result.stats` describes the *visualized* diff image (after threshold/scale/binary),
    // not the raw per-pixel delta — so for binary mode max() is 0 or 255.
    try writer.print("max difference: {d}\n", .{@as(u32, @trunc(result.stats.max()))});
    try writer.print("pixels differing > {d}: {d}\n", .{ threshold, result.diff_count });
    try writer.flush();

    if (options.output) |output_path| {
        std.log.info("saving difference image to '{s}'...", .{output_path});
        try diff_img.save(io, gpa, output_path);
    }

    if (should_display) {
        const images = [_]zignal.Image(zignal.Rgba(u8)){ img1, img2, diff_img };

        var canvas = try display.createHorizontalComposite(
            zignal.Rgba(u8),
            io,
            gpa,
            &images,
            options.width,
            options.height,
        );
        defer canvas.deinit(gpa);

        const format = display.resolveDisplayFormat(options.protocol, null, null);
        try display.displayCanvas(io, writer, &canvas, format);
    }
}
