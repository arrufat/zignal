const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");

pub const Args = struct {
    scale: ?f32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    filter: ?[]const u8 = null,
    output: ?[]const u8 = null,

    pub const meta = .{
        .scale = .{ .help = "Scale factor (e.g. 0.5 for 50%, 2.0 for 200%)", .metavar = "float" },
        .width = .{ .help = "Target width in pixels", .metavar = "pixels" },
        .height = .{ .help = "Target height in pixels", .metavar = "pixels" },
        .filter = .{ .help = "Interpolation filter (" ++ common.joinFieldNames(zignal.Interpolation) ++ ")", .metavar = "name" },
        .output = .{ .help = "Output file or directory path (mandatory)", .metavar = "path", .short = 'o' },
    };
};

pub const description = "Resize an image using various interpolation methods.";

pub const help = args.generateHelp(
    Args,
    "zignal resize <image> --output <path> [options]",
    description,
);

pub fn run(io: Io, writer: *Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const output_arg = parsed.options.output orelse {
        std.log.err("missing mandatory option: --output <file_or_dir>", .{});
        return error.InvalidArguments;
    };

    const is_batch = parsed.positionals.len > 1;
    const target = try common.resolveOutputTarget(io, output_arg, is_batch);

    for (parsed.positionals) |input_path| {
        processImage(io, gpa, input_path, target, is_batch, parsed.options) catch |err| {
            std.log.err("failed to resize '{s}': {t}", .{ input_path, err });
            if (!is_batch) return err;
        };
    }
}

/// Resize `img` according to `options`, returning a freshly allocated image the
/// caller owns. Shared by the standalone command and the `pipeline` command.
pub fn apply(io: Io, gpa: Allocator, img: zignal.Image(zignal.Rgba(u8)), options: Args) !zignal.Image(zignal.Rgba(u8)) {
    if (img.rows == 0 or img.cols == 0) {
        std.log.err("input image has zero dimensions ({d}x{d})", .{ img.cols, img.rows });
        return error.InvalidDimensions;
    }

    if (options.scale != null and (options.width != null or options.height != null)) {
        std.log.err("cannot specify both scale and width/height", .{});
        return error.InvalidArguments;
    }
    if (options.scale == null and options.width == null and options.height == null) {
        std.log.err("must specify at least one of scale, width, or height", .{});
        return error.InvalidArguments;
    }

    const filter = try common.resolveFilter(options.filter);
    const dims = try computeTargetDimensions(img, options);

    std.log.info("resizing from {d}x{d} to {d}x{d} using {s}...", .{ img.cols, img.rows, dims.width, dims.height, @tagName(filter) });

    var out: zignal.Image(zignal.Rgba(u8)) = try .init(gpa, dims.height, dims.width);
    errdefer out.deinit(gpa);

    const timer = common.Timer.begin(io);
    img.resize(out, gpa, filter);
    timer.logElapsed("resize");

    return out;
}

fn processImage(
    io: Io,
    gpa: Allocator,
    input_path: []const u8,
    target: common.OutputTarget,
    is_batch: bool,
    options: Args,
) !void {
    std.log.debug("{s} {s}...", .{ if (is_batch) "processing" else "loading", input_path });

    const resolved = try target.resolveOutputPath(gpa, input_path);
    defer resolved.deinit(gpa);

    var img: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, input_path);
    defer img.deinit(gpa);

    var out = try apply(io, gpa, img, options);
    defer out.deinit(gpa);

    std.log.info("saving to {s}...", .{resolved.path});
    try out.save(io, gpa, resolved.path);
}

const Dimensions = struct { width: u32, height: u32 };

fn computeTargetDimensions(img: zignal.Image(zignal.Rgba(u8)), options: Args) !Dimensions {
    var width: u32 = 0;
    var height: u32 = 0;

    if (options.scale) |s| {
        if (s <= 0 or !std.math.isFinite(s)) {
            std.log.err("scale factor must be positive and finite", .{});
            return error.InvalidArguments;
        }
        width = zignal.meta.safeCast(u32, @as(f32, @floatFromInt(img.cols)) * s) catch return error.InvalidDimensions;
        height = zignal.meta.safeCast(u32, @as(f32, @floatFromInt(img.rows)) * s) catch return error.InvalidDimensions;
    } else if (options.width != null and options.height != null) {
        width = options.width.?;
        height = options.height.?;
    } else if (options.width) |w| {
        width = w;
        const aspect = @as(f32, @floatFromInt(img.rows)) / @as(f32, @floatFromInt(img.cols));
        height = zignal.meta.safeCast(u32, @as(f32, @floatFromInt(w)) * aspect) catch return error.InvalidDimensions;
    } else if (options.height) |h| {
        height = h;
        const aspect = @as(f32, @floatFromInt(img.cols)) / @as(f32, @floatFromInt(img.rows));
        width = zignal.meta.safeCast(u32, @as(f32, @floatFromInt(h)) * aspect) catch return error.InvalidDimensions;
    }

    return .{
        .width = @max(width, 1),
        .height = @max(height, 1),
    };
}
