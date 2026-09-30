//! Resize subcommand: resizes images using various interpolation filters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");
const display = @import("display.zig");

pub const Args = struct {
    scale: ?f32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    filter: ?common.InterpolationTag = null,
    output: ?[]const u8 = null,

    pub const meta = .{
        .scale = .{ .help = "Scale factor (e.g. 0.5 for 50%, 2.0 for 200%)", .metavar = "float" },
        .width = .{ .help = "Target width in pixels", .metavar = "pixels" },
        .height = .{ .help = "Target height in pixels", .metavar = "pixels" },
        .filter = .{ .help = "Interpolation filter (" ++ common.joinFieldNames(zignal.image.Interpolation) ++ ")", .metavar = "name" },
        .output = .{ .help = "Output file or directory path (mandatory)", .metavar = "path", .short = 'o' },
    };

    pub fn validate(self: Args) !void {
        if (self.scale != null and (self.width != null or self.height != null)) {
            std.log.err("cannot specify both scale and width/height", .{});
            return error.InvalidArguments;
        }
        if (self.scale == null and self.width == null and self.height == null) {
            std.log.err("must specify at least one of scale, width, or height", .{});
            return error.InvalidArguments;
        }
    }
};

pub const description = "Resize an image using various interpolation methods.";

pub const usage = "zignal resize <image> --output <path> [options]";

pub fn run(io: Io, gpa: Allocator, writer: *Io.Writer, options: Args, inputs: []const []const u8) !void {
    try options.validate();

    const output_arg = options.output orelse {
        std.log.err("missing mandatory option: --output <file_or_dir>", .{});
        return error.InvalidArguments;
    };

    const target = try common.resolveOutputTarget(io, output_arg, inputs.len > 1);
    try display.processInputs(zignal.Rgba(u8), io, gpa, writer, inputs, target, null, options, apply);
}

/// Resize `img` according to `options` (already validated), returning a freshly allocated
/// image the caller owns. Shared by the standalone command and the `pipeline` command.
pub fn apply(io: Io, gpa: Allocator, img: zignal.Image(zignal.Rgba(u8)), options: Args) !zignal.Image(zignal.Rgba(u8)) {
    if (img.rows == 0 or img.cols == 0) {
        std.log.err("input image has zero dimensions ({d}x{d})", .{ img.cols, img.rows });
        return error.InvalidDimensions;
    }

    const filter = common.resolveFilter(options.filter);
    const dims = try computeTargetDimensions(img, options);

    std.log.info("resizing from {d}x{d} to {d}x{d} using {s}...", .{ img.cols, img.rows, dims.width, dims.height, @tagName(filter) });

    var out: zignal.Image(zignal.Rgba(u8)) = try .init(gpa, dims.height, dims.width);
    errdefer out.deinit(gpa);

    const timer = common.Timer.begin(io);
    img.resize(io, gpa, out, filter);
    timer.logElapsed("resize");

    return out;
}

const Dimensions = struct { width: u32, height: u32 };

fn computeTargetDimensions(img: zignal.Image(zignal.Rgba(u8)), options: Args) !Dimensions {
    const cols: f32 = @floatFromInt(img.cols);
    const rows: f32 = @floatFromInt(img.rows);
    // `validate` guarantees either a scale or at least one side.
    const width: f32, const height: f32 = if (options.scale) |s| blk: {
        if (s <= 0 or !std.math.isFinite(s)) {
            std.log.err("scale factor must be positive and finite", .{});
            return error.InvalidArguments;
        }
        break :blk .{ cols * s, rows * s };
    } else if (options.width) |w| .{
        @floatFromInt(w),
        if (options.height) |h| @floatFromInt(h) else @as(f32, @floatFromInt(w)) * (rows / cols),
    } else .{ @as(f32, @floatFromInt(options.height.?)) * (cols / rows), @floatFromInt(options.height.?) };

    return .{
        .width = @max(1, zignal.meta.safeCast(u32, width) catch return error.InvalidDimensions),
        .height = @max(1, zignal.meta.safeCast(u32, height) catch return error.InvalidDimensions),
    };
}
