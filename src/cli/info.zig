const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const png = zignal.png;
const jpeg = zignal.jpeg;

const args = @import("args.zig");

const Args = struct {};

pub const help_text = args.generateHelp(
    Args,
    "zignal info <image1> <image2> ...",
    "Display detailed information about one or more image files.",
);

pub fn run(io: Io, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(io, help_text);
        return;
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
                        const info = png.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                        try stdout.interface.print("Format:      PNG\n", .{});
                        try stdout.interface.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                        try stdout.interface.print("Bit Depth:   {d}\n", .{info.bit_depth});
                        try stdout.interface.print("Channels:    {d}\n", .{info.channels()});
                        try stdout.interface.print("Color Space: {s}\n", .{@tagName(info.color_type)});

                        if (info.gamma) |g| {
                            try stdout.interface.print("Gamma:       {d}\n", .{g});
                        }
                        if (info.srgb_intent) |intent| {
                            try stdout.interface.print("sRGB:        {s}\n", .{@tagName(intent)});
                        }
                    },
                    .jpeg => {
                        const info = jpeg.getInfo(&reader.interface, .{}) catch |err| break :blk err;

                        try stdout.interface.print("Format:      JPEG\n", .{});
                        try stdout.interface.print("Dimensions:  {d}x{d}\n", .{ info.width, info.height });
                        try stdout.interface.print("Bit Depth:   {d}\n", .{info.precision});
                        try stdout.interface.print("Channels:    {d}\n", .{info.num_components});
                        try stdout.interface.print("Color Space: {s}\n", .{if (info.num_components == 1) "Grayscale" else "YCbCr"});
                        try stdout.interface.print("Frame Type:  {s}\n", .{@tagName(info.frame_type)});
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
