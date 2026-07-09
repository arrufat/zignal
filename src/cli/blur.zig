const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");
const display = @import("display.zig");
const displayCanvas = display.displayCanvas;
const resolveDisplayFormat = display.resolveDisplayFormat;

pub const Args = struct {
    type: ?BlurType = null,
    output: ?[]const u8 = null,
    display: bool = false,

    // Common parameters
    radius: ?u32 = null,
    sigma: ?f32 = null,

    // Motion blur parameters
    angle: ?f32 = null,
    distance: ?f32 = null,
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

pub const help = args.generateHelp(
    Args,
    "zignal blur <image> [options]",
    description,
);

const BlurType = enum {
    box,
    gaussian,
    median,
    motion_linear,
    motion_zoom,
    motion_spin,
};

pub fn run(io: Io, writer: *Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const is_batch = parsed.positionals.len > 1;
    var target: ?common.OutputTarget = null;
    if (parsed.options.output) |out_arg| {
        target = try common.resolveOutputTarget(io, out_arg, is_batch);
    }

    const should_display = parsed.options.display or target == null;

    var failed = false;
    for (parsed.positionals) |input_path| {
        processImage(io, writer, gpa, input_path, target, should_display, parsed.options) catch |err| {
            std.log.err("failed to blur '{s}': {t}", .{ input_path, err });
            if (!is_batch) return err;
            failed = true;
        };
    }
    if (failed) return error.BatchIncomplete;
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
            try img.boxBlur(out, gpa, radius);
        },
        .gaussian => {
            const sigma = options.sigma orelse 1.0;
            if (sigma < 0 or !std.math.isFinite(sigma)) {
                std.log.err("sigma must be a non-negative finite number.", .{});
                return error.InvalidArguments;
            }
            try img.gaussianBlur(out, gpa, sigma);
        },
        .median => {
            const radius = options.radius orelse 1;
            if (radius > 256) {
                std.log.err("median blur radius {d} exceeds maximum limit of 256.", .{radius});
                return error.InvalidArguments;
            }
            try img.medianBlur(out, gpa, radius);
        },
        .motion_linear => {
            const angle_deg = options.angle orelse 0.0;
            var dist = options.distance orelse 10.0;

            if (!std.math.isFinite(angle_deg) or !std.math.isFinite(dist)) {
                std.log.err("angle and distance must be finite numbers.", .{});
                return error.InvalidArguments;
            }
            if (dist < 0) {
                std.log.err("distance must be non-negative.", .{});
                return error.InvalidArguments;
            }

            const max_dim: f32 = @floatFromInt(@max(img.rows, img.cols));

            if (dist > max_dim) {
                std.log.warn("motion blur distance {d:.1} exceeds image dimensions. clamping to {d:.1}.", .{ dist, max_dim });
                dist = max_dim;
            }

            const angle_rad = std.math.degreesToRadians(angle_deg);
            try img.motionBlur(out, gpa, .{ .linear = .{ .angle = angle_rad, .distance = @trunc(dist) } });
        },
        .motion_zoom, .motion_spin => {
            const cx = options.center_x orelse 0.5;
            const cy = options.center_y orelse 0.5;
            const strength = options.strength orelse 0.5;

            if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(strength)) {
                std.log.err("radial blur parameters (center-x, center-y, strength) must be finite numbers.", .{});
                return error.InvalidArguments;
            }

            if (cx < 0 or cx > 1 or cy < 0 or cy > 1) {
                std.log.warn("center coordinates ({d:.2}, {d:.2}) are outside the typical [0, 1] range.", .{ cx, cy });
            }

            if (strength < 0 or strength > 1) {
                std.log.err("strength must be between 0.0 and 1.0.", .{});
                return error.InvalidArguments;
            }

            const motion: zignal.MotionBlur = if (blur_type == .motion_zoom)
                .{ .radial_zoom = .{ .center_x = cx, .center_y = cy, .strength = strength } }
            else
                .{ .radial_spin = .{ .center_x = cx, .center_y = cy, .strength = strength } };

            try img.motionBlur(out, gpa, motion);
        },
    }

    timer.logElapsed("blur");
    return out;
}

fn processImage(
    io: Io,
    writer: *Io.Writer,
    gpa: Allocator,
    input_path: []const u8,
    target: ?common.OutputTarget,
    should_display: bool,
    options: Args,
) !void {
    std.log.debug("loading {s}...", .{input_path});

    var img: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, input_path);
    defer img.deinit(gpa);

    var out = try apply(io, gpa, img, options);
    defer out.deinit(gpa);

    if (target) |tgt| {
        const resolved = try tgt.resolveOutputPath(gpa, input_path);
        defer resolved.deinit(gpa);

        std.log.info("saving to {s}...", .{resolved.path});
        try out.save(io, gpa, resolved.path);
    }

    if (should_display) {
        const format = resolveDisplayFormat(options.protocol, options.width, options.height);
        try displayCanvas(io, writer, out, format);
    }
}
