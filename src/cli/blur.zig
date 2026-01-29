const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");

const Args = struct {
    type: ?[]const u8 = null,
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
    protocol: ?[]const u8 = null,

    pub const meta = .{
        .type = .{ .help = "Blur type: box, gaussian, median, motion-linear, motion-zoom, motion-spin (default: gaussian)", .metavar = "name" },
        .output = .{ .help = "Output file or directory path", .metavar = "path" },
        .display = .{ .help = "Display the result in the terminal (default if no output)" },
        .radius = .{ .help = "Radius for box/median blur (default: 1)", .metavar = "int" },
        .sigma = .{ .help = "Sigma for Gaussian blur (default: 1.0)", .metavar = "float" },
        .angle = .{ .help = "Angle in degrees for linear motion blur (default: 0)", .metavar = "deg" },
        .distance = .{ .help = "Distance in pixels for linear motion blur (default: 10)", .metavar = "px" },
        .center_x = .{ .help = "Center X (0.0-1.0) for radial motion blur (default: 0.5)", .metavar = "float" },
        .center_y = .{ .help = "Center Y (0.0-1.0) for radial motion blur (default: 0.5)", .metavar = "float" },
        .strength = .{ .help = "Strength (0.0-1.0) for radial motion blur (default: 0.5)", .metavar = "float" },
        .width = .{ .help = "Display width", .metavar = "N" },
        .height = .{ .help = "Display height", .metavar = "N" },
        .protocol = .{ .help = "Display protocol: kitty, sixel, sgr, braille, auto", .metavar = "p" },
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

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const type_map = std.StaticStringMap(BlurType).initComptime(.{
        .{ "box", .box },
        .{ "gaussian", .gaussian },
        .{ "median", .median },
        .{ "motion-linear", .motion_linear },
        .{ "motion-zoom", .motion_zoom },
        .{ "motion-spin", .motion_spin },
    });

    var blur_type: BlurType = .gaussian;
    if (parsed.options.type) |t| {
        blur_type = type_map.get(t) orelse {
            std.log.err("Unknown blur type: {s}", .{t});
            return error.InvalidArguments;
        };
    }

    const is_batch = parsed.positionals.len > 1;
    var target: ?common.OutputTarget = null;
    if (parsed.options.output) |out_arg| {
        target = try common.resolveOutputTarget(io, out_arg, is_batch);
    }

    const should_display = parsed.options.display or target == null;

    for (parsed.positionals) |input_path| {
        processImage(io, writer, gpa, input_path, target, should_display, blur_type, parsed.options) catch |err| {
            std.log.err("failed to blur '{s}': {t}", .{ input_path, err });
            if (!is_batch) return err;
        };
    }
}

fn processImage(
    io: Io,
    writer: *std.Io.Writer,
    gpa: Allocator,
    input_path: []const u8,
    target: ?common.OutputTarget,
    should_display: bool,
    blur_type: BlurType,
    options: Args,
) !void {
    std.log.debug("Loading {s}...", .{input_path});

    // Load image
    var img: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, input_path);
    defer img.deinit(gpa);

    var out: zignal.Image(zignal.Rgba(u8)) = try .init(gpa, img.rows, img.cols);
    defer out.deinit(gpa);

    std.log.info("Applying {s} blur...", .{@tagName(blur_type)});

    var timer = try std.time.Timer.start();

    switch (blur_type) {
        .box => {
            const radius = options.radius orelse 1;
            try img.boxBlur(gpa, radius, out);
        },
        .gaussian => {
            const sigma = options.sigma orelse 1.0;
            if (sigma < 0 or !std.math.isFinite(sigma)) {
                std.log.err("Sigma must be a non-negative finite number.", .{});
                return error.InvalidArguments;
            }
            try img.gaussianBlur(gpa, sigma, out);
        },
        .median => {
            const radius = options.radius orelse 1;
            if (radius > 256) {
                std.log.err("Median blur radius {d} exceeds maximum limit of 256.", .{radius});
                return error.InvalidArguments;
            }
            try img.medianBlur(gpa, radius, out);
        },
        .motion_linear => {
            const angle_deg = options.angle orelse 0.0;
            var dist = options.distance orelse 10.0;

            if (!std.math.isFinite(angle_deg) or !std.math.isFinite(dist)) {
                std.log.err("Angle and distance must be finite numbers.", .{});
                return error.InvalidArguments;
            }
            if (dist < 0) {
                std.log.err("Distance must be non-negative.", .{});
                return error.InvalidArguments;
            }

            const max_dim = @as(f32, @floatFromInt(@max(img.rows, img.cols)));

            if (dist > max_dim) {
                std.log.warn("Motion blur distance {d:.1} exceeds image dimensions. Clamping to {d:.1}.", .{ dist, max_dim });
                dist = max_dim;
            }

            const angle_rad = std.math.degreesToRadians(angle_deg);
            try img.motionBlur(gpa, .{ .linear = .{ .angle = angle_rad, .distance = @intFromFloat(dist) } }, out);
        },
        .motion_zoom, .motion_spin => {
            const cx = options.center_x orelse 0.5;
            const cy = options.center_y orelse 0.5;
            const strength = options.strength orelse 0.5;

            if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(strength)) {
                std.log.err("Radial blur parameters (center-x, center-y, strength) must be finite numbers.", .{});
                return error.InvalidArguments;
            }

            if (cx < 0 or cx > 1 or cy < 0 or cy > 1) {
                std.log.warn("Center coordinates ({d:.2}, {d:.2}) are outside the typical [0, 1] range.", .{ cx, cy });
            }

            if (strength < 0 or strength > 1) {
                std.log.err("Strength must be between 0.0 and 1.0.", .{});
                return error.InvalidArguments;
            }

            const motion: zignal.MotionBlur = if (blur_type == .motion_zoom)
                .{ .radial_zoom = .{ .center_x = cx, .center_y = cy, .strength = strength } }
            else
                .{ .radial_spin = .{ .center_x = cx, .center_y = cy, .strength = strength } };

            try img.motionBlur(gpa, motion, out);
        },
    }

    const blur_ns = timer.read();
    std.log.debug("Blur operation took {d:.3} ms", .{@as(f64, @floatFromInt(blur_ns)) / std.time.ns_per_ms});

    if (target) |tgt| {
        const output_path = if (tgt.is_directory) try blk_path: {
            const basename = std.fs.path.basename(input_path);
            break :blk_path std.fs.path.join(gpa, &[_][]const u8{ tgt.path, basename });
        } else tgt.path;
        defer if (tgt.is_directory) gpa.free(output_path);

        std.log.info("Saving to {s}...", .{output_path});
        try out.save(io, gpa, output_path);
    }

    if (should_display) {
        const display = @import("display.zig");
        const format = try display.resolveDisplayFormat(options.protocol, options.width, options.height);
        try display.displayCanvas(io, writer, out, format);
    }
}
