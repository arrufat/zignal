const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const display = @import("display.zig");
const common = @import("common.zig");

const Args = struct {
    display: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?[]const u8 = null,
    filter: ?[]const u8 = null,

    pub const meta = .{
        .display = .{ .help = "Display the result in the terminal" },
        .width = .{ .help = "Width of each sub-image", .metavar = "N" },
        .height = .{ .help = "Height of each sub-image", .metavar = "N" },
        .protocol = .{ .help = "Force protocol: kitty, sixel, sgr, braille, auto", .metavar = "p" },
        .filter = .{ .help = "Interpolation filter (nearest, bilinear, bicubic, catmull-rom, mitchell, lanczos)", .metavar = "name" },
    };
};

pub const description = "Apply Feature Distribution Matching (style transfer) from target to source image.\nIf output is omitted, the result is displayed in the terminal.";

pub const help = args.generateHelp(
    Args,
    "zignal fdm <source> <target> [output] [options]",
    description,
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len < 2 or parsed.positionals.len > 3) {
        try args.printHelp(writer, help);
        return;
    }

    const source_path = parsed.positionals[0];
    const target_path = parsed.positionals[1];
    const output_path = if (parsed.positionals.len == 3) parsed.positionals[2] else null;

    // Display if requested OR if no output file is specified
    const should_display = parsed.options.display or output_path == null;

    // Use Rgb(u8) for style transfer
    const Pixel = zignal.Rgb(u8);

    // Load source image
    std.log.debug("Loading source image: {s}", .{source_path});
    var source_img: zignal.Image(Pixel) = try .load(io, gpa, source_path);
    defer source_img.deinit(gpa);

    // Keep a copy of the original for display if needed
    var original_source: ?zignal.Image(Pixel) = null;
    if (should_display) {
        original_source = try source_img.dupe(gpa);
    }
    defer if (original_source) |*img| img.deinit(gpa);

    // Load target image
    std.log.debug("Loading target image: {s}", .{target_path});
    var target_img: zignal.Image(Pixel) = try .load(io, gpa, target_path);
    defer target_img.deinit(gpa);

    // Initialize FDM
    var fdm: zignal.FeatureDistributionMatching(Pixel) = .init(gpa);
    defer fdm.deinit();

    std.log.debug("Applying FDM style transfer...", .{});

    var timer = try std.time.Timer.start();
    // Apply match
    try fdm.match(source_img, target_img);
    const fdm_ns = timer.read();
    std.log.debug("FDM took {d:.3} ms", .{@as(f64, @floatFromInt(fdm_ns)) / std.time.ns_per_ms});

    if (output_path) |out_path| {
        std.log.info("Saving result to {s}...", .{out_path});
        try source_img.save(io, gpa, out_path);
    }

    if (should_display) {
        const filter = try common.resolveFilter(parsed.options.filter);

        // We know original_source is not null because we initialized it if should_display is true
        // provided source_img.dupe didn't fail (which would have returned error).
        const images = [_]zignal.Image(Pixel){ original_source.?, target_img, source_img };

        var canvas = try display.createHorizontalComposite(
            Pixel,
            gpa,
            &images,
            parsed.options.width,
            parsed.options.height,
            filter,
        );
        defer canvas.deinit(gpa);

        try display.displayCanvas(io, writer, &canvas, parsed.options.protocol, filter);
    }
}
