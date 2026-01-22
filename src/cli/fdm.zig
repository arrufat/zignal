const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");

const display_cmd = @import("display.zig");

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
        .filter = .{ .help = "Scaling filter: nearest, bilinear, bicubic, lanczos, catmull-rom", .metavar = "f" },
    };
};

pub const help_text = args.generateHelp(
    Args,
    "zignal fdm <source> <target> [output] [options]",
    "Apply Feature Distribution Matching (style transfer) from target to source image.\nIf output is omitted, the result is displayed in the terminal.",
);

pub fn run(io: Io, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len < 2 or parsed.positionals.len > 3) {
        try args.printHelp(io, help_text);
        return;
    }

    const source_path = parsed.positionals[0];
    const target_path = parsed.positionals[1];
    const output_path = if (parsed.positionals.len == 3) parsed.positionals[2] else null;

    // Display if requested OR if no output file is specified
    const should_display = parsed.options.display or output_path == null;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    try stdout.interface.print("Source: {s}\n", .{source_path});
    try stdout.interface.print("Target: {s}\n", .{target_path});
    try stdout.interface.flush();

    // Use Rgb(u8) for style transfer
    const Pixel = zignal.Rgb(u8);

    // Load source image
    var source_img = try zignal.Image(Pixel).load(io, gpa, source_path);
    defer source_img.deinit(gpa);

    // Keep a copy of the original for display if needed
    var original_source: ?zignal.Image(Pixel) = null;
    if (should_display) {
        original_source = try source_img.dupe(gpa);
    }
    defer if (original_source) |*img| img.deinit(gpa);

    // Load target image
    var target_img = try zignal.Image(Pixel).load(io, gpa, target_path);
    defer target_img.deinit(gpa);

    // Initialize FDM
    var fdm = zignal.FeatureDistributionMatching(Pixel).init(gpa);
    defer fdm.deinit();

    try stdout.interface.print("Applying FDM style transfer...\n", .{});
    try stdout.interface.flush();

    // Apply match
    try fdm.match(source_img, target_img);

    if (output_path) |out_path| {
        try stdout.interface.print("Saving result to {s}...\n", .{out_path});
        try stdout.interface.flush();
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

        // Limit maximum display size to avoid protocol limits (e.g. Sixel 2048 width)
        // and excessive terminal scrolling.
        const max_display_width: u32 = 1800; // Leave some margin for 2048 limit
        const max_display_height: u32 = 1200;

        const total_width = 3 * w;
        var display_w = total_width;
        var display_h = h;

        // Apply further downscaling if the combined canvas exceeds hard limits,
        // preserving the aspect ratio.
        if (display_w > max_display_width or display_h > max_display_height) {
            const scale_x = @as(f32, @floatFromInt(max_display_width)) / @as(f32, @floatFromInt(display_w));
            const scale_y = @as(f32, @floatFromInt(max_display_height)) / @as(f32, @floatFromInt(display_h));
            const scale = @min(scale_x, scale_y);

            display_w = @intFromFloat(@as(f32, @floatFromInt(display_w)) * scale);
            display_h = @intFromFloat(@as(f32, @floatFromInt(display_h)) * scale);
        }

        var protocol: zignal.DisplayFormat = .{ .auto = .default };
        var filter: zignal.Interpolation = .bilinear;

        if (parsed.options.protocol) |p| {
            protocol = display_cmd.parseProtocol(p) catch |err| {
                std.log.err("Unknown protocol type: {s}", .{p});
                return err;
            };
        }

        if (parsed.options.filter) |f| {
            filter = display_cmd.parseFilter(f) catch |err| {
                std.log.err("Unknown filter type: {s}", .{f});
                return err;
            };
        }

        // Pass the calculated display dimensions to the protocol options
        display_cmd.applyOptions(&protocol, display_w, display_h, filter);

        var canvas = try zignal.Image(Pixel).init(gpa, display_h, display_w);
        defer canvas.deinit(gpa);
        canvas.fill(.{ .r = 0, .g = 0, .b = 0 });

        const wf = @as(f32, @floatFromInt(display_w)) / 3.0;
        const hf = @as(f32, @floatFromInt(display_h));

        // Insert original source
        if (original_source) |img| {
            canvas.insert(img, .{ .l = 0, .t = 0, .r = wf, .b = hf }, 0, filter, .none);
        }

        // Insert target
        canvas.insert(target_img, .{ .l = wf, .t = 0, .r = 2 * wf, .b = hf }, 0, filter, .none);

        // Insert result
        canvas.insert(source_img, .{ .l = 2 * wf, .t = 0, .r = 3 * wf, .b = hf }, 0, filter, .none);

        try stdout.interface.print("\n", .{});
        try stdout.interface.flush();
        try stdout.interface.print("{f}\n", .{canvas.display(io, protocol)});
        try stdout.interface.flush();
    }

    try stdout.interface.print("Done.\n", .{});
    try stdout.interface.flush();
}
