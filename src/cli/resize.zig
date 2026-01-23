const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const display = @import("display.zig");
const common = @import("common.zig");

const Args = struct {
    scale: ?f32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    filter: ?[]const u8 = null,
    output: ?[]const u8 = null,

    pub const meta = .{
        .scale = .{ .help = "Scale factor (e.g. 0.5 for 50%, 2.0 for 200%)", .metavar = "float" },
        .width = .{ .help = "Target width in pixels", .metavar = "pixels" },
        .height = .{ .help = "Target height in pixels", .metavar = "pixels" },
        .filter = .{ .help = "Interpolation filter (nearest, bilinear, bicubic, catmull-rom, mitchell, lanczos)", .metavar = "name" },
        .output = .{ .help = "Output file or directory path (mandatory)", .metavar = "path" },
    };
};

pub const help_text = args.generateHelp(
    Args,
    "zignal resize <image> --output <path> [options]",
    "Resize an image using various interpolation methods.",
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help_text);
        return;
    }

    if (parsed.options.output == null) {
        std.log.err("Missing mandatory option: --output <file_or_dir>", .{});
        return error.InvalidArguments;
    }

    // Validate conflicting options
    if (parsed.options.scale != null and (parsed.options.width != null or parsed.options.height != null)) {
        std.log.err("Cannot specify both --scale and --width/--height", .{});
        return error.InvalidArguments;
    }

    if (parsed.options.scale == null and parsed.options.width == null and parsed.options.height == null) {
        std.log.err("Must specify at least one of --scale, --width, or --height", .{});
        return error.InvalidArguments;
    }

    // Parse filter once
    var filter: zignal.Interpolation = .bilinear;
    if (parsed.options.filter) |f| {
        filter = common.parseFilter(f) catch |err| {
            std.log.err("Unknown filter type: {s}", .{f});
            return err;
        };
    }

    const is_batch = parsed.positionals.len > 1;

    for (parsed.positionals) |input_path| {
        processImage(io, gpa, input_path, parsed.options, is_batch, filter) catch |err| {
            std.log.err("failed to resize '{s}': {t}", .{ input_path, err });
            if (!is_batch) return err;
        };
    }
}

fn processImage(
    io: Io,
    gpa: Allocator,
    input_path: []const u8,
    options: Args,
    is_batch: bool,
    filter: zignal.Interpolation,
) !void {
    if (is_batch) {
        std.log.info("Processing {s}...", .{input_path});
    } else {
        std.log.info("Loading {s}...", .{input_path});
    }

    const output_arg = options.output.?;

    // Determine output path
    // If batching, treat output_arg as a directory.
    // If single file, use output_arg as the filename unless it ends in a separator.
    const ends_with_sep = std.mem.endsWith(u8, output_arg, "/") or std.mem.endsWith(u8, output_arg, "\\");
    const use_as_dir = is_batch or ends_with_sep;

    const output_path = if (use_as_dir) try blk_path: {
        const basename = std.fs.path.basename(input_path);
        break :blk_path std.fs.path.join(gpa, &[_][]const u8{ output_arg, basename });
    } else output_arg;
    defer if (use_as_dir) gpa.free(output_path);

    // Load image
    var img: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, input_path);
    defer img.deinit(gpa);

    if (img.rows == 0 or img.cols == 0) {
        std.log.err("Input image has zero dimensions ({d}x{d})", .{ img.cols, img.rows });
        return error.InvalidDimensions;
    }

    // Calculate new dimensions
    var new_width: u32 = 0;
    var new_height: u32 = 0;

    if (options.scale) |s| {
        if (s <= 0 or !std.math.isFinite(s)) {
            std.log.err("Scale factor must be positive and finite", .{});
            return error.InvalidArguments;
        }
        new_width = zignal.meta.safeCast(u32, @as(f32, @floatFromInt(img.cols)) * s) catch return error.InvalidDimensions;
        new_height = zignal.meta.safeCast(u32, @as(f32, @floatFromInt(img.rows)) * s) catch return error.InvalidDimensions;
    } else {
        if (options.width != null and options.height != null) {
            new_width = options.width.?;
            new_height = options.height.?;
        } else if (options.width) |w| {
            new_width = w;
            const aspect = @as(f32, @floatFromInt(img.rows)) / @as(f32, @floatFromInt(img.cols));
            new_height = zignal.meta.safeCast(u32, @as(f32, @floatFromInt(w)) * aspect) catch return error.InvalidDimensions;
        } else if (options.height) |h| {
            new_height = h;
            const aspect = @as(f32, @floatFromInt(img.cols)) / @as(f32, @floatFromInt(img.rows));
            new_width = zignal.meta.safeCast(u32, @as(f32, @floatFromInt(h)) * aspect) catch return error.InvalidDimensions;
        }
    }

    if (new_width == 0) new_width = 1;
    if (new_height == 0) new_height = 1;

    if (is_batch) {
        std.log.info("  Resizing from {d}x{d} to {d}x{d} using {s}...", .{ img.cols, img.rows, new_width, new_height, @tagName(filter) });
    } else {
        std.log.info("Resizing from {d}x{d} to {d}x{d} using {s}...", .{ img.cols, img.rows, new_width, new_height, @tagName(filter) });
    }

    // Perform resize
    var out: zignal.Image(zignal.Rgba(u8)) = try .init(gpa, new_height, new_width);
    defer out.deinit(gpa);

    try img.resize(gpa, out, filter);

    // Save output
    if (is_batch) {
        std.log.info("  Saving to {s}...", .{output_path});
    } else {
        std.log.info("Saving to {s}...", .{output_path});
    }
    try out.save(io, gpa, output_path);
}
