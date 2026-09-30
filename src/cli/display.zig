//! Display subcommand: renders images directly in the terminal using graphics protocols.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");

/// Standard help line for the `--protocol` option, used by every subcommand
/// that supports terminal display.
pub const protocol_help: []const u8 = "Display protocol: " ++ common.joinFieldNames(zignal.image.DisplayFormat);

/// The tag enum of `zignal.image.DisplayFormat` — usable directly as a CLI/ZON option
/// field, since the tag names double as the accepted protocol names.
pub const ProtocolTag = @typeInfo(zignal.image.DisplayFormat).@"union".tag_type.?;

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

pub fn run(io: Io, gpa: Allocator, writer: *Io.Writer, iterator: *std.process.Args.Iterator) !void {
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

    var failed = false;
    for (parsed.positionals) |path| {
        std.log.debug("loading image: {s}", .{path});
        var image = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path) catch |err| {
            std.log.err("failed to load image '{s}': {t}", .{ path, err });
            failed = true;
            continue;
        };
        defer image.deinit(gpa);

        try displayCanvas(io, writer, image, display_fmt);
    }
    if (failed) return error.BatchIncomplete;
}

pub fn resolveDisplayFormat(
    protocol: ?ProtocolTag,
    width: ?u32,
    height: ?u32,
) zignal.image.DisplayFormat {
    var format: zignal.image.DisplayFormat = switch (protocol orelse .auto) {
        inline else => |t| @unionInit(zignal.image.DisplayFormat, @tagName(t), .default),
    };
    format.setSize(width, height);
    format.setInterpolation(.bilinear);
    return format;
}

pub fn displayCanvas(
    io: Io,
    writer: *Io.Writer,
    image: anytype,
    format: zignal.image.DisplayFormat,
) !void {
    try writer.print("{f}\n", .{image.display(io, format)});
    try writer.flush();
}

/// Resolve the terminal display format for a command that supports it, or null
/// when the result should only be saved. Display happens when `--display` is set
/// or no output target was given. `options` is any display-capable command's
/// `Args` (it must expose `display`/`protocol`/`width`/`height`).
pub fn displayFormatFor(options: anytype, target: ?common.OutputTarget) ?zignal.image.DisplayFormat {
    if (!options.display and target != null) return null;
    return resolveDisplayFormat(options.protocol, options.width, options.height);
}

/// Loads each input as `T`, maps it through `transform` and emits the result. A single
/// input's error propagates; a batch logs it, carries on and ends in `error.BatchIncomplete`.
pub fn processInputs(
    comptime T: type,
    io: Io,
    gpa: Allocator,
    writer: *Io.Writer,
    inputs: []const []const u8,
    target: ?common.OutputTarget,
    display_format: ?zignal.image.DisplayFormat,
    context: anytype,
    comptime transform: fn (Io, Allocator, zignal.Image(T), @TypeOf(context)) anyerror!zignal.Image(T),
) !void {
    var failed = false;
    for (inputs) |input_path| {
        processInput(T, io, gpa, writer, input_path, target, display_format, context, transform) catch |err| {
            std.log.err("failed to process '{s}': {t}", .{ input_path, err });
            if (inputs.len == 1) return err;
            failed = true;
        };
    }
    if (failed) return error.BatchIncomplete;
}

fn processInput(
    comptime T: type,
    io: Io,
    gpa: Allocator,
    writer: *Io.Writer,
    input_path: []const u8,
    target: ?common.OutputTarget,
    display_format: ?zignal.image.DisplayFormat,
    context: anytype,
    comptime transform: fn (Io, Allocator, zignal.Image(T), @TypeOf(context)) anyerror!zignal.Image(T),
) !void {
    std.log.debug("loading {s}...", .{input_path});
    var img: zignal.Image(T) = try .load(io, gpa, input_path);
    defer img.deinit(gpa);

    var out = try transform(io, gpa, img, context);
    defer out.deinit(gpa);

    try emit(io, gpa, writer, out, input_path, target, display_format);
}

/// Terminal step for a processed image: save it to `target` (when given) and
/// show it in the terminal when `display_format` is non-null.
pub fn emit(
    io: Io,
    gpa: Allocator,
    writer: *Io.Writer,
    img: anytype,
    input_path: []const u8,
    target: ?common.OutputTarget,
    display_format: ?zignal.image.DisplayFormat,
) !void {
    if (target) |tgt| {
        const resolved = try tgt.resolveOutputPath(gpa, input_path);
        defer resolved.deinit(gpa);
        std.log.info("saving to {s}...", .{resolved.path});
        try img.save(io, gpa, resolved.path);
    }

    if (display_format) |fmt| {
        try displayCanvas(io, writer, img, fmt);
    }
}

pub fn createHorizontalComposite(
    comptime T: type,
    io: Io,
    allocator: Allocator,
    images: []const zignal.Image(T),
    user_width: ?u32,
    user_height: ?u32,
) !zignal.Image(T) {
    const ref_img = images[0];
    const scale_factor = zignal.terminal.aspectScale(
        user_width,
        user_height,
        ref_img.rows,
        ref_img.cols,
    );

    const w = @max(1, @as(u32, @round(@as(f32, @floatFromInt(ref_img.cols)) * scale_factor)));
    const h = @max(1, @as(u32, @round(@as(f32, @floatFromInt(ref_img.rows)) * scale_factor)));

    var canvas = try zignal.Image(T).init(allocator, h, @as(u32, @intCast(images.len)) * w);

    if (@hasDecl(T, "black")) {
        canvas.fill(T.black);
    } else {
        @memset(canvas.asBytes(), 0);
    }

    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);

    for (images, 0..) |img, i| {
        const offset_x = @as(f32, @floatFromInt(i)) * wf;
        canvas.insert(io, img, .{ .l = offset_x, .t = 0, .r = offset_x + wf, .b = hf }, 0, .bilinear, .none);
    }

    return canvas;
}
