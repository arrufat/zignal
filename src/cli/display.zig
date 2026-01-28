const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const terminal = zignal.terminal;

const args = @import("args.zig");
const common = @import("common.zig");

const Args = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?[]const u8 = null,
    filter: ?[]const u8 = null,

    pub const meta = .{
        .width = .{ .help = "Target width in pixels", .metavar = "N" },
        .height = .{ .help = "Target height in pixels", .metavar = "N" },
        .protocol = .{ .help = "Force protocol: kitty, sixel, sgr, braille, auto", .metavar = "p" },
        .filter = .{ .help = "Interpolation filter (nearest, bilinear, bicubic, catmull-rom, mitchell, lanczos)", .metavar = "name" },
    };
};

pub const description = "Display an image in the terminal using supported graphics protocols.";

pub const help = args.generateHelp(
    Args,
    "zignal display <image> [options]",
    description,
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const width = parsed.options.width;
    const height = parsed.options.height;
    const filter = try common.resolveFilter(parsed.options.filter);

    const display_fmt = try resolveDisplayFormat(parsed.options.protocol, width, height, filter);

    for (parsed.positionals) |path| {
        if (parsed.positionals.len > 1) {
            std.log.debug("File: {s}", .{path});
        }
        std.log.debug("Loading image: {s}", .{path});
        var image: zignal.Image(zignal.Rgba(u8)) = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path) catch |err| {
            std.log.err("Failed to load image '{s}': {}", .{ path, err });
            continue;
        };
        defer image.deinit(gpa);

        std.log.debug("Displaying image...", .{});
        try displayCanvas(io, writer, image, display_fmt);
    }
}

pub fn resolveDisplayFormat(
    protocol_name: ?[]const u8,
    width: ?u32,
    height: ?u32,
    filter: zignal.Interpolation,
) !zignal.DisplayFormat {
    var protocol: zignal.DisplayFormat = .{ .auto = .default };
    if (protocol_name) |p| {
        protocol = parseProtocol(p) catch |err| {
            std.log.err("Unknown protocol type: {s}", .{p});
            return err;
        };
    }
    applyOptions(&protocol, width, height, filter);
    return protocol;
}

pub fn parseProtocol(name: []const u8) !zignal.DisplayFormat {
    std.log.debug("Parsing protocol: {s}", .{name});
    const protocol_map = std.StaticStringMap(zignal.DisplayFormat).initComptime(.{
        .{ "kitty", zignal.DisplayFormat{ .kitty = .default } },
        .{ "sixel", zignal.DisplayFormat{ .sixel = .default } },
        .{ "sgr", zignal.DisplayFormat{ .sgr = .default } },
        .{ "braille", zignal.DisplayFormat{ .braille = .default } },
        .{ "auto", zignal.DisplayFormat{ .auto = .default } },
    });
    if (protocol_map.get(name)) |p_enum| {
        return p_enum;
    } else {
        return error.InvalidArguments;
    }
}

/// Applies user-provided scaling and filter options to a display protocol.
/// Note: If width and height are null, the protocol will automatically enforce
/// the global 2048x2048 dimension cap during rendering.
pub fn applyOptions(protocol: *zignal.DisplayFormat, width: ?u32, height: ?u32, filter: zignal.Interpolation) void {
    switch (protocol.*) {
        .kitty => |*opts| {
            opts.width = width;
            opts.height = height;
            opts.interpolation = filter;
        },
        .sixel => |*opts| {
            opts.width = width;
            opts.height = height;
            opts.interpolation = filter;
        },
        .sgr => |*opts| {
            opts.width = width;
            opts.height = height;
        },
        .braille => |*opts| {
            opts.width = width;
            opts.height = height;
        },
        .auto => |*opts| {
            opts.width = width;
            opts.height = height;
            opts.interpolation = filter;
        },
    }
}

/// Helper function to display an image canvas in the terminal.
/// Automatically handles protocol selection and scaling options.
/// Note: Implicitly caps image dimensions to 2048x2048 via aspectScale to prevent
/// excessive memory usage in the terminal.
pub fn displayCanvas(
    io: Io,
    writer: *std.Io.Writer,
    image: anytype,
    format: zignal.DisplayFormat,
) !void {
    try writer.print("{f}\n", .{image.display(io, format)});
    try writer.flush();
}

pub fn createHorizontalComposite(
    comptime T: type,
    allocator: Allocator,
    images: []const zignal.Image(T),
    user_width: ?u32,
    user_height: ?u32,
    filter: zignal.Interpolation,
) !zignal.Image(T) {
    if (images.len == 0) return zignal.Image(T).init(allocator, 1, 1);

    // Use the first image as reference for aspect ratio scaling
    const ref_img = images[0];

    // Calculate scale based on user constraints relative to the first image
    const scale_factor = zignal.terminal.aspectScale(
        user_width,
        user_height,
        ref_img.rows,
        ref_img.cols,
    );

    // Calculate dimensions for each sub-image
    const w = @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(ref_img.cols)) * scale_factor)));
    const h = @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(ref_img.rows)) * scale_factor)));

    // Safety check for zero dimensions
    const final_w = if (w == 0) 1 else w;
    const final_h = if (h == 0) 1 else h;

    const canvas_w = @as(u32, @intCast(images.len)) * final_w;
    const canvas_h = final_h;

    var canvas = try zignal.Image(T).init(allocator, canvas_h, canvas_w);

    // Fill background
    if (@hasDecl(T, "black")) {
        canvas.fill(T.black);
    } else {
        @memset(canvas.asBytes(), 0);
    }

    const wf = @as(f32, @floatFromInt(final_w));
    const hf = @as(f32, @floatFromInt(final_h));

    for (images, 0..) |img, i| {
        const offset_x = @as(f32, @floatFromInt(i)) * wf;
        // Use .none blend mode to overwrite (copy) pixels directly
        canvas.insert(img, .{ .l = offset_x, .t = 0, .r = offset_x + wf, .b = hf }, 0, filter, .none);
    }

    return canvas;
}
