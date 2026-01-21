const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const terminal = zignal.terminal;

pub const help_text =
    \\Usage: zignal display <image> [options]
    \\
    \\Display an image in the terminal using supported graphics protocols.
    \\
    \\Options:
    \\  --width <N>      Target width in pixels
    \\  --height <N>     Target height in pixels
    \\  --protocol <p>   Force protocol: kitty, sixel, sgr, braille, auto
    \\  --filter <f>     Scaling filter: nearest, bilinear, bicubic, lanczos, catmull-rom
    \\
;

pub fn run(io: Io, gpa: Allocator, args: *std.process.Args.Iterator) !void {
    var image_paths: std.ArrayList([]const u8) = .empty;
    defer image_paths.deinit(gpa);

    var width: ?u32 = null;
    var height: ?u32 = null;
    var protocol: zignal.DisplayFormat = .{ .auto = .default };
    var filter: zignal.Interpolation = .bilinear;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--width")) {
            const w_arg = args.next() orelse {
                std.log.err("Missing value for --width", .{});
                return error.InvalidArguments;
            };
            width = std.fmt.parseInt(u32, w_arg, 10) catch {
                std.log.err("Invalid width: {s}", .{w_arg});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--height")) {
            const h_arg = args.next() orelse {
                std.log.err("Missing value for --height", .{});
                return error.InvalidArguments;
            };
            height = std.fmt.parseInt(u32, h_arg, 10) catch {
                std.log.err("Invalid height: {s}", .{h_arg});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            const p = args.next() orelse {
                std.log.err("Missing value for --protocol", .{});
                return error.InvalidArguments;
            };
            const protocol_map = std.StaticStringMap(zignal.DisplayFormat).initComptime(.{
                .{ "kitty", zignal.DisplayFormat{ .kitty = .default } },
                .{ "sixel", zignal.DisplayFormat{ .sixel = .default } },
                .{ "sgr", zignal.DisplayFormat{ .sgr = .default } },
                .{ "braille", zignal.DisplayFormat{ .braille = .default } },
                .{ "auto", zignal.DisplayFormat{ .auto = .default } },
            });
            if (protocol_map.get(p)) |p_enum| {
                protocol = p_enum;
            } else {
                std.log.err("Unknown protocol tpe: {s}", .{p});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--filter")) {
            const f = args.next() orelse {
                std.log.err("Missing value for --filter", .{});
                return error.InvalidArguments;
            };
            const filter_map = std.StaticStringMap(zignal.Interpolation).initComptime(.{
                .{ "nearest", .nearest_neighbor },
                .{ "bilinear", .bilinear },
                .{ "bicubic", .bicubic },
                .{ "lanczos", .lanczos },
                .{ "catmull-rom", .catmull_rom },
            });
            if (filter_map.get(f)) |f_enum| {
                filter = f_enum;
            } else {
                std.log.err("Unknown filter type: {s}", .{f});
                return error.InvalidArguments;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try image_paths.append(gpa, arg);
        } else {
            std.log.err("Unknown option: {s}", .{arg});
            return error.InvalidArguments;
        }
    }

    if (image_paths.items.len == 0) {
        std.log.err("Missing image path for 'display' command", .{});
        return error.InvalidArguments;
    }

    switch (protocol) {
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

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    for (image_paths.items) |path| {
        if (image_paths.items.len > 1) {
            try stdout.interface.print("File: {s}\n", .{path});
            try stdout.interface.flush();
        }
        var image: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, path);
        defer image.deinit(gpa);

        try stdout.interface.print("{f}\n", .{image.display(io, protocol)});
        try stdout.interface.flush();
    }
}
