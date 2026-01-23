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

    std.log.info("Source: {s}", .{source_path});
    std.log.info("Target: {s}", .{target_path});

    // Use Rgb(u8) for style transfer
    const Pixel = zignal.Rgb(u8);

    // Load source image
    var source_img: zignal.Image(Pixel) = try .load(io, gpa, source_path);
    defer source_img.deinit(gpa);

    // Keep a copy of the original for display if needed
    var original_source: ?zignal.Image(Pixel) = null;
    if (should_display) {
        original_source = try source_img.dupe(gpa);
    }
    defer if (original_source) |*img| img.deinit(gpa);

    // Load target image
    var target_img: zignal.Image(Pixel) = try .load(io, gpa, target_path);
    defer target_img.deinit(gpa);

    // Initialize FDM
    var fdm: zignal.FeatureDistributionMatching(Pixel) = .init(gpa);
    defer fdm.deinit();

    std.log.info("Applying FDM style transfer...", .{});

    // Apply match
    try fdm.match(source_img, target_img);

    if (output_path) |out_path| {
        std.log.info("Saving result to {s}...", .{out_path});
        try source_img.save(io, gpa, out_path);
    }

    if (should_display) {
        // Calculate proportional scale factor for a single sub-image based on user constraints
        const user_scale = zignal.terminal.aspectScale(
            parsed.options.width,
            parsed.options.height,
            source_img.rows,
            source_img.cols,
        );

        const w = @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(source_img.cols)) * user_scale)));
        const h = @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(source_img.rows)) * user_scale)));

        const filter = try common.resolveFilter(parsed.options.filter);

        const canvas_w = 3 * w;
        const canvas_h = h;

        var canvas = try zignal.Image(Pixel).init(gpa, canvas_h, canvas_w);
        defer canvas.deinit(gpa);
        canvas.fill(.{ .r = 0, .g = 0, .b = 0 });

        const wf = @as(f32, @floatFromInt(w));
        const hf = @as(f32, @floatFromInt(h));

        // Insert original source
        if (original_source) |img| {
            canvas.insert(img, .{ .l = 0, .t = 0, .r = wf, .b = hf }, 0, filter, .none);
        }

        // Insert target
        canvas.insert(target_img, .{ .l = wf, .t = 0, .r = 2 * wf, .b = hf }, 0, filter, .none);

        // Insert result
        canvas.insert(source_img, .{ .l = 2 * wf, .t = 0, .r = 3 * wf, .b = hf }, 0, filter, .none);

        try display.displayCanvas(io, writer, &canvas, parsed.options.protocol, filter);
    }

    std.log.info("Done.", .{});
}
