const std = @import("std");
const zignal = @import("zignal");
const png = zignal.png;
const jpeg = zignal.jpeg;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cli_args = @import("args.zig");

const Args = struct {};

pub const help_text = cli_args.generateHelp(
    Args,
    "zignal info <image1> <image2> ...",
    "Display detailed information about one or more image files.",
);

pub fn run(io: Io, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try cli_args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.positionals.len == 0) {
        std.log.err("Missing image path for 'info' command", .{});
        return error.InvalidArguments;
    }

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    // Buffer for reading file data
    var read_buffer: [4096]u8 = undefined;

    for (parsed.positionals) |image_path| {
        if (parsed.positionals.len > 1) {
            try stdout.interface.print("File: {s}\n", .{image_path});
        }

        // Use a block to catch errors for individual files so we can continue to the next one
        const result = blk: {
            const image_format = zignal.ImageFormat.detectFromPath(io, gpa, image_path) catch |err| break :blk err;
            if (image_format) |fmt| {
                const file = std.Io.Dir.cwd().openFile(io, image_path, .{}) catch |err| break :blk err;
                defer file.close(io);

                var reader = file.reader(io, &read_buffer);

                switch (fmt) {
                    .png => {
                        const png_info = png.getInfo(&reader.interface, .{}) catch |err| break :blk err;

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
                        const header = jpeg.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                        try stdout.interface.print("Format: JPEG\n", .{});
                        try stdout.interface.print("Dimensions: {d}x{d}\n", .{ header.width, header.height });
                        try stdout.interface.print("Precision: {d}-bit\n", .{header.precision});
                        try stdout.interface.print("Components: {d}\n", .{header.num_components});
                        try stdout.interface.print("Type: {s}\n", .{@tagName(header.frame_type)});
                    },
                }
            } else {
                break :blk error.UnsupportedImageFormat;
            }
            break :blk void{};
        };

        if (result) |_| {
            // Success
        } else |err| {
            std.log.err("failed to get info for '{s}': {t}", .{ image_path, err });
        }

        if (parsed.positionals.len > 1) {
            try stdout.interface.print("\n", .{});
        }
    }
    try stdout.interface.flush();
}
