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

pub const help_text = args.generateHelp(
    Args,
    "zignal display <image> [options]",
    description,
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help_text);
        return;
    }

    const width = parsed.options.width;
    const height = parsed.options.height;
    var protocol: zignal.DisplayFormat = .{ .auto = .default };
    var filter: zignal.Interpolation = .bilinear;

    if (parsed.options.protocol) |p| {
        protocol = parseProtocol(p) catch |err| {
            std.log.err("Unknown protocol type: {s}", .{p});
            return err;
        };
    }

    filter = try common.resolveFilter(parsed.options.filter);

    applyOptions(&protocol, width, height, filter);

    for (parsed.positionals) |path| {
        if (parsed.positionals.len > 1) {
            std.log.info("File: {s}", .{path});
        }
        var image: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, path);
        defer image.deinit(gpa);

        try writer.print("{f}\n", .{image.display(io, protocol)});
        try writer.flush();
    }
}

pub fn parseProtocol(name: []const u8) !zignal.DisplayFormat {
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
    protocol_name: ?[]const u8,
    filter: zignal.Interpolation,
) !void {
    var protocol: zignal.DisplayFormat = .{ .auto = .default };

    if (protocol_name) |p| {
        protocol = parseProtocol(p) catch |err| {
            std.log.err("Unknown protocol type: {s}", .{p});
            return err;
        };
    }

    applyOptions(&protocol, null, null, filter);

    try writer.print("{f}\n", .{image.display(io, protocol)});
    try writer.flush();
}
