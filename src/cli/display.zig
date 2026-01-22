const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const terminal = zignal.terminal;

const args = @import("args.zig");

const Args = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?[]const u8 = null,
    filter: ?[]const u8 = null,

    pub const meta = .{
        .width = .{ .help = "Target width in pixels", .metavar = "N" },
        .height = .{ .help = "Target height in pixels", .metavar = "N" },
        .protocol = .{ .help = "Force protocol: kitty, sixel, sgr, braille, auto", .metavar = "p" },
        .filter = .{ .help = "Scaling filter: nearest, bilinear, bicubic, lanczos, catmull-rom", .metavar = "f" },
    };
};

pub const help_text = args.generateHelp(
    Args,
    "zignal display <image> [options]",
    "Display an image in the terminal using supported graphics protocols.",
);

pub fn run(io: Io, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(io, help_text);
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

    if (parsed.options.filter) |f| {
        filter = parseFilter(f) catch |err| {
            std.log.err("Unknown filter type: {s}", .{f});
            return err;
        };
    }

    applyOptions(&protocol, width, height, filter);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    for (parsed.positionals) |path| {
        if (parsed.positionals.len > 1) {
            try stdout.interface.print("File: {s}\n", .{path});
            try stdout.interface.flush();
        }
        var image: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, path);
        defer image.deinit(gpa);

        try stdout.interface.print("{f}\n", .{image.display(io, protocol)});
        try stdout.interface.flush();
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

pub fn parseFilter(name: []const u8) !zignal.Interpolation {
    const filter_map = std.StaticStringMap(zignal.Interpolation).initComptime(.{
        .{ "nearest", .nearest_neighbor },
        .{ "bilinear", .bilinear },
        .{ "bicubic", .bicubic },
        .{ "lanczos", .lanczos },
        .{ "catmull-rom", .catmull_rom },
    });
    if (filter_map.get(name)) |f_enum| {
        return f_enum;
    } else {
        return error.InvalidArguments;
    }
}

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

pub fn displayCanvas(
    io: Io,
    image: anytype,
    protocol_name: ?[]const u8,
    filter: zignal.Interpolation,
) !void {
    const max_display_width: u32 = 1800;
    const max_display_height: u32 = 1200;

    var display_w = @as(u32, @intCast(image.cols));
    var display_h = @as(u32, @intCast(image.rows));

    // Apply downscaling if needed, preserving aspect ratio
    if (display_w > max_display_width or display_h > max_display_height) {
        const scale_x = @as(f32, @floatFromInt(max_display_width)) / @as(f32, @floatFromInt(display_w));
        const scale_y = @as(f32, @floatFromInt(max_display_height)) / @as(f32, @floatFromInt(display_h));
        const scale = @min(scale_x, scale_y);

        display_w = @intFromFloat(@as(f32, @floatFromInt(display_w)) * scale);
        display_h = @intFromFloat(@as(f32, @floatFromInt(display_h)) * scale);
    }

    var protocol: zignal.DisplayFormat = .{ .auto = .default };

    if (protocol_name) |p| {
        protocol = parseProtocol(p) catch |err| {
            std.log.err("Unknown protocol type: {s}", .{p});
            return err;
        };
    }

    applyOptions(&protocol, display_w, display_h, filter);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    try stdout.interface.print("\n", .{});
    try stdout.interface.flush();
    try stdout.interface.print("{f}\n", .{image.display(io, protocol)});
    try stdout.interface.flush();
}
