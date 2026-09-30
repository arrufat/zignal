//! Blur subcommand: applies box, Gaussian, motion, and rank-filter blurs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");
const display = @import("display.zig");

pub const Args = struct {
    type: ?BlurType = null,
    output: ?[]const u8 = null,
    display: bool = false,

    // Common parameters
    radius: ?u32 = null,
    sigma: ?f32 = null,

    // Motion blur parameters
    angle: ?f32 = null,
    distance: ?u32 = null,
    center_x: ?f32 = null,
    center_y: ?f32 = null,
    strength: ?f32 = null,

    // Display options
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?display.ProtocolTag = null,

    pub const meta = .{
        .type = .{ .help = "Blur type: " ++ common.joinFieldNames(BlurType) ++ " (default: gaussian)", .metavar = "name" },
        .output = .{ .help = "Output file or directory path", .metavar = "path", .short = 'o' },
        .display = .{ .help = "Display the result in the terminal (default if no output)", .short = 'd' },
        .radius = .{ .help = "Radius for box/median blur (default: 1)", .metavar = "int" },
        .sigma = .{ .help = "Sigma for Gaussian blur (default: 1.0)", .metavar = "float" },
        .angle = .{ .help = "Angle in degrees for linear motion blur (default: 0)", .metavar = "deg" },
        .distance = .{ .help = "Distance in pixels for linear motion blur (default: 10)", .metavar = "px" },
        .center_x = .{ .help = "Center X (0.0-1.0) for radial motion blur (default: 0.5)", .metavar = "float" },
        .center_y = .{ .help = "Center Y (0.0-1.0) for radial motion blur (default: 0.5)", .metavar = "float" },
        .strength = .{ .help = "Strength (0.0-1.0) for radial motion blur (default: 0.5)", .metavar = "float" },
        .width = .{ .help = "Display width", .metavar = "N" },
        .height = .{ .help = "Display height", .metavar = "N" },
        .protocol = .{ .help = display.protocol_help, .metavar = "p" },
    };
};

pub const description = "Apply various blur effects to images.";

pub const usage = "zignal blur <image> [options]";

const BlurType = enum {
    box,
    gaussian,
    median,
    motion_linear,
    motion_zoom,
    motion_spin,
};

pub fn run(io: Io, gpa: Allocator, writer: *Io.Writer, options: Args, inputs: []const []const u8) !void {
    const target = if (options.output) |out| try common.resolveOutputTarget(io, out, inputs.len > 1) else null;
    const display_format = display.displayFormatFor(options, target);
    try display.processInputs(zignal.Rgba(u8), io, gpa, writer, inputs, target, display_format, options, apply);
}

/// Blur `img` according to `options`, returning a freshly allocated image the
/// caller owns. Shared by the standalone command and the `pipeline` command.
pub fn apply(io: Io, gpa: Allocator, img: zignal.Image(zignal.Rgba(u8)), options: Args) !zignal.Image(zignal.Rgba(u8)) {
    const blur_type = options.type orelse .gaussian;

    var out: zignal.Image(zignal.Rgba(u8)) = try .init(gpa, img.rows, img.cols);
    errdefer out.deinit(gpa);

    std.log.info("applying {s} blur...", .{@tagName(blur_type)});

    const timer = common.Timer.begin(io);

    switch (blur_type) {
        .box => {
            const radius = options.radius orelse 1;
            try img.boxBlur(io, gpa, out, radius);
        },
        .gaussian => try img.gaussianBlur(io, gpa, out, options.sigma orelse 1.0, .default),
        .median => try img.medianBlur(io, gpa, out, options.radius orelse 1),
        .motion_linear => {
            const angle = std.math.degreesToRadians(options.angle orelse 0.0);
            try img.motionBlur(io, gpa, out, .{ .linear = .{ .angle = angle, .distance = options.distance orelse 10 } });
        },
        .motion_zoom, .motion_spin => {
            const cx = options.center_x orelse 0.5;
            const cy = options.center_y orelse 0.5;
            const strength = options.strength orelse 0.5;
            if (cx < 0 or cx > 1 or cy < 0 or cy > 1) {
                std.log.warn("center coordinates ({d:.2}, {d:.2}) are outside the typical [0, 1] range.", .{ cx, cy });
            }

            const motion: zignal.image.MotionBlur = if (blur_type == .motion_zoom)
                .{ .radial_zoom = .{ .center_x = cx, .center_y = cy, .strength = strength } }
            else
                .{ .radial_spin = .{ .center_x = cx, .center_y = cy, .strength = strength } };

            try img.motionBlur(io, gpa, out, motion);
        },
    }

    timer.logElapsed("blur");
    return out;
}
