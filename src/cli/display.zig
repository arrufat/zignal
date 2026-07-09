const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");

/// Comma-separated list of supported display protocols, in CLI-menu order.
/// Derived from `zignal.DisplayFormat`'s union fields so help text cannot
/// drift from the type definition.
pub const protocol_names: []const u8 = common.joinFieldNames(zignal.DisplayFormat);

/// Standard help line for the `--protocol` option, used by every subcommand
/// that supports terminal display.
pub const protocol_help: []const u8 = "Display protocol: " ++ protocol_names;

/// The tag enum of `zignal.DisplayFormat` — usable directly as a CLI/ZON option
/// field, since the tag names double as the accepted protocol names.
pub const ProtocolTag = std.meta.Tag(zignal.DisplayFormat);

const Args = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?ProtocolTag = null,

    pub const meta = .{
        .width = .{ .help = "Target width in pixels", .metavar = "N" },
        .height = .{ .help = "Target height in pixels", .metavar = "N" },
        .protocol = .{ .help = protocol_help, .metavar = "p" },
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

    const display_fmt = resolveDisplayFormat(
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
    protocol: ?ProtocolTag,
    width: ?u32,
    height: ?u32,
) zignal.DisplayFormat {
    var format: zignal.DisplayFormat = switch (protocol orelse .auto) {
        inline else => |t| @unionInit(zignal.DisplayFormat, @tagName(t), .default),
    };
    applyOptions(&format, width, height);
    return format;
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

    const wf: f32 = @floatFromInt(final_w);
    const hf: f32 = @floatFromInt(final_h);

    for (images, 0..) |img, i| {
        const offset_x = @as(f32, @floatFromInt(i)) * wf;
        canvas.insert(img, .{ .l = offset_x, .t = 0, .r = offset_x + wf, .b = hf }, 0, .bilinear, .none);
    }

    return canvas;
}
