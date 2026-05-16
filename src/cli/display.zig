const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");

const Args = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?[]const u8 = null,

    pub const meta = .{
        .width = .{ .help = "Target width in pixels", .metavar = "N" },
        .height = .{ .help = "Target height in pixels", .metavar = "N" },
        .protocol = .{ .help = "Force protocol: kitty, sixel, sgr, braille, auto", .metavar = "p" },
    };
};

pub const description = "Display an image in the terminal using supported graphics protocols.";

pub const help = args.generateHelp(
    Args,
    "zignal display <image> [options]",
    description,
);

pub fn run(io: Io, writer: *Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const display_fmt = try resolveDisplayFormat(
        parsed.options.protocol,
        parsed.options.width,
        parsed.options.height,
    );

    for (parsed.positionals) |path| {
        if (parsed.positionals.len > 1) {
            std.log.debug("file: {s}", .{path});
        }
        std.log.debug("loading image: {s}", .{path});
        var image: zignal.Image(zignal.Rgba(u8)) = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path) catch |err| {
            std.log.err("failed to load image '{s}': {}", .{ path, err });
            continue;
        };
        defer image.deinit(gpa);

        try displayCanvas(io, writer, image, display_fmt);
    }
}

pub fn resolveDisplayFormat(
    protocol_name: ?[]const u8,
    width: ?u32,
    height: ?u32,
) !zignal.DisplayFormat {
    var protocol: zignal.DisplayFormat = .{ .auto = .default };
    if (protocol_name) |p| {
        protocol = parseProtocol(p) catch |err| {
            std.log.err("unknown protocol type: {s}", .{p});
            return err;
        };
    }
    applyOptions(&protocol, width, height);
    return protocol;
}

pub fn parseProtocol(name: []const u8) !zignal.DisplayFormat {
    const protocol_map = std.StaticStringMap(zignal.DisplayFormat).initComptime(.{
        .{ "kitty", zignal.DisplayFormat{ .kitty = .default } },
        .{ "sixel", zignal.DisplayFormat{ .sixel = .default } },
        .{ "sgr", zignal.DisplayFormat{ .sgr = .default } },
        .{ "braille", zignal.DisplayFormat{ .braille = .default } },
        .{ "auto", zignal.DisplayFormat{ .auto = .default } },
    });
    return protocol_map.get(name) orelse error.InvalidArguments;
}

pub fn applyOptions(protocol: *zignal.DisplayFormat, width: ?u32, height: ?u32) void {
    protocol.setSize(width, height);
    protocol.setInterpolation(.bilinear);
}

pub fn displayCanvas(
    io: Io,
    writer: *Io.Writer,
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
) !zignal.Image(T) {
    if (images.len == 0) return zignal.Image(T).init(allocator, 1, 1);

    const ref_img = images[0];
    const scale_factor = zignal.terminal.aspectScale(
        user_width,
        user_height,
        ref_img.rows,
        ref_img.cols,
    );

    const w: u32 = @round(@as(f32, @floatFromInt(ref_img.cols)) * scale_factor);
    const h: u32 = @round(@as(f32, @floatFromInt(ref_img.rows)) * scale_factor);
    const final_w = @max(w, 1);
    const final_h = @max(h, 1);

    const canvas_w = @as(u32, @intCast(images.len)) * final_w;
    const canvas_h = final_h;

    var canvas = try zignal.Image(T).init(allocator, canvas_h, canvas_w);

    if (@hasDecl(T, "black")) {
        canvas.fill(T.black);
    } else {
        @memset(canvas.asBytes(), 0);
    }

    const wf = @as(f32, @floatFromInt(final_w));
    const hf = @as(f32, @floatFromInt(final_h));

    for (images, 0..) |img, i| {
        const offset_x = @as(f32, @floatFromInt(i)) * wf;
        canvas.insert(img, .{ .l = offset_x, .t = 0, .r = offset_x + wf, .b = hf }, 0, .bilinear, .none);
    }

    return canvas;
}
