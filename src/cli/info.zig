const std = @import("std");
const zignal = @import("zignal");
const png = zignal.png;
const jpeg = zignal.jpeg;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const help_text =
    \\Usage: zignal info <image>
    \\
    \\Display detailed information about an image file.
    \\
;

pub fn run(io: Io, gpa: Allocator, image_path: []const u8) !void {
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
