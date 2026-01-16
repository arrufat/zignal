const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const png = zignal.png;
const jpeg = zignal.jpeg;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "version")) {
            try version(init.io);
            return;
        }
        if (std.mem.eql(u8, arg, "info")) {
            if (args.next()) |image_path| {
                info(init.io, init.gpa, image_path) catch |err| {
                    std.log.err("failed to get info for '{s}': {t}", .{ image_path, err });
                    return;
                };
            } else {
                std.log.err("Missing image path for 'info' command", .{});
            }
            return;
        }
    }
}

fn version(io: Io) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("{s}\n", .{zignal.version});
    try stdout.interface.flush();
}

fn info(io: Io, gpa: Allocator, image_path: []const u8) !void {
    const image_format = try zignal.ImageFormat.detectFromPath(io, gpa, image_path) orelse return error.UnsupportedImageFormat;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    var header_buf: [4096]u8 = undefined;
    const file_data = try std.Io.Dir.cwd().readFile(io, image_path, &header_buf);

    switch (image_format) {
        .png => {
            const png_info = try png.getInfo(file_data);

            try stdout.interface.print("Format: PNG\n", .{});
            try stdout.interface.print("Dimensions: {d}x{d}\n", .{ png_info.width, png_info.height });
            try stdout.interface.print("Bit Depth: {d}\n", .{png_info.bit_depth});
            try stdout.interface.print("Color Type: {s}\n", .{@tagName(png_info.color_type)});
            try stdout.interface.print("Channels: {d}\n", .{png_info.channels()});

            if (png_info.gamma) |g| {
                try stdout.interface.print("Gamma: {d}\n", .{g});
            }
            if (png_info.srgb_intent) |intent| {
                try stdout.interface.print("sRGB Intent: {s}\n", .{@tagName(intent)});
            }
        },
        .jpeg => {
            const header = try jpeg.getInfo(file_data);

            try stdout.interface.print("Format: JPEG\n", .{});
            try stdout.interface.print("Dimensions: {d}x{d}\n", .{ header.width, header.height });
            try stdout.interface.print("Precision: {d}-bit\n", .{header.precision});
            try stdout.interface.print("Components: {d}\n", .{header.num_components});
            try stdout.interface.print("Type: {s}\n", .{@tagName(header.frame_type)});
        },
    }
    try stdout.interface.flush();
}
