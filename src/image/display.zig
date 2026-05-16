//! Terminal display formatting for images

const std = @import("std");
const Io = std.Io;

const color = @import("../color.zig");
const Image = @import("../image.zig").Image;
const Interpolation = @import("interpolation.zig").Interpolation;
const kitty = @import("../kitty.zig");
const sixel = @import("../sixel.zig");
const terminal = @import("../terminal.zig");

const Rgb = @import("../color.zig").Rgb(u8);

/// Display format options
pub const DisplayFormat = union(enum) {
    /// Automatically detect the best format (kitty -> sixel -> sgr)
    auto: struct {
        /// Optional target width in pixels
        width: ?u32 = null,
        /// Optional target height in pixels
        height: ?u32 = null,
        /// Interpolation method for scaling
        interpolation: ?@import("interpolation.zig").Interpolation = null,
        pub const default: @This() = .{};
    },
    /// Kitty graphics protocol with options
    kitty: kitty.Options,
    /// Force sixel output with specific options
    sixel: sixel.Options,
    /// SGR (Select Graphic Rendition) with Unicode half-block characters for 2x vertical resolution
    /// Requires a monospace font with Unicode block element support (U+2580)
    sgr: struct {
        /// Optional target width in pixels
        width: ?u32 = null,
        /// Optional target height in pixels
        height: ?u32 = null,
        pub const default: @This() = .{};
    },
    /// Braille patterns for 2x4 monochrome resolution
    /// Requires Unicode Braille pattern support (U+2800-U+28FF)
    /// Color images are binarized with threshold
    braille: struct {
        /// Brightness threshold for on/off (0.0-1.0)
        threshold: f32 = 0.5,
        /// Optional target width in pixels
        width: ?u32 = null,
        /// Optional target height in pixels
        height: ?u32 = null,
        pub const default: @This() = .{ .threshold = 0.5 };
    },

    /// Sets the target width and height on the active variant. Every variant
    /// carries these fields, so this works uniformly.
    pub fn setSize(self: *DisplayFormat, w: ?u32, h: ?u32) void {
        switch (self.*) {
            inline else => |*opts| {
                opts.width = w;
                opts.height = h;
            },
        }
    }

    /// Sets the interpolation method on variants that scale images
    /// (`kitty`, `sixel`, `auto`). No-op for `sgr` and `braille`, which do
    /// not resample.
    pub fn setInterpolation(self: *DisplayFormat, interp: Interpolation) void {
        switch (self.*) {
            inline .kitty, .sixel, .auto => |*opts| opts.interpolation = interp,
            .sgr, .braille => {},
        }
    }
};

/// Formatter struct for terminal display with progressive degradation
pub fn DisplayFormatter(comptime T: type) type {
    return struct {
        image: *const Image(T),
        display_format: DisplayFormat,
        io: Io,

        const Self = @This();

        // Caller owns `out_scaled` lifetime via defer in its scope.
        fn maybeScale(
            self: Self,
            allocator: std.mem.Allocator,
            w: ?u32,
            h: ?u32,
            out_scaled: *?Image(T),
        ) *const Image(T) {
            const scale_factor = terminal.aspectScale(w, h, self.image.rows, self.image.cols);
            if (@abs(scale_factor - 1.0) <= 0.001) return self.image;
            out_scaled.* = self.image.scale(allocator, scale_factor, .bilinear) catch return self.image;
            return &out_scaled.*.?;
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            // Auto degrades to sgr/sixel/kitty; scaling for sgr/braille happens inside
            // their arms so it also applies when reached via `continue :fmt`.
            const can_fallback = self.display_format == .auto;

            fmt: switch (self.display_format) {
                .auto => |options| {
                    if (kitty.isSupported(self.io)) {
                        continue :fmt .{ .kitty = .{
                            .quiet = 1,
                            .image_id = null,
                            .placement_id = null,
                            .delete_after = false,
                            .enable_chunking = false,
                            .width = options.width,
                            .height = options.height,
                            .interpolation = options.interpolation orelse .bilinear,
                        } };
                    } else if (sixel.isSupported(self.io)) {
                        continue :fmt .{ .sixel = .{
                            .palette = .{ .adaptive = .{ .max_colors = 256 } },
                            .dither = .auto,
                            .width = options.width,
                            .height = options.height,
                            .interpolation = options.interpolation orelse .nearest_neighbor,
                        } };
                    } else {
                        continue :fmt .{ .sgr = .{
                            .width = options.width,
                            .height = options.height,
                        } };
                    }
                },
                .kitty => |options| {
                    // Try to convert to Kitty format (uses original image, handles scaling internally)
                    const kitty_data = kitty.fromImage(T, self.image.*, allocator, options) catch |err| blk: {
                        // On error, try with default options
                        if (err == error.OutOfMemory) {
                            break :blk kitty.fromImage(T, self.image.*, allocator, .default) catch null;
                        } else {
                            break :blk null;
                        }
                    };

                    if (kitty_data) |data| {
                        try writer.writeAll(data);
                    } else if (can_fallback) {
                        continue :fmt .{ .sgr = .{ .width = options.width, .height = options.height } };
                    } else {
                        // Output minimal Kitty sequence to indicate failure
                        // Empty image with delete command
                        try writer.writeAll("\x1b_Ga=d\x1b\\");
                    }
                },
                .sixel => |options| {
                    // Try to convert to sixel (uses original image, handles scaling internally)
                    const sixel_data = sixel.fromImage(T, self.image.*, allocator, options) catch |err| blk: {
                        // On OutOfMemory, try without dithering
                        if (err == error.OutOfMemory) {
                            break :blk sixel.fromImage(T, self.image.*, allocator, .fallback) catch null;
                        } else {
                            break :blk null;
                        }
                    };

                    if (sixel_data) |data| {
                        try writer.writeAll(data);
                    } else if (can_fallback) {
                        continue :fmt .{ .sgr = .{ .width = options.width, .height = options.height } };
                    } else {
                        // Output minimal sixel sequence to indicate failure
                        // This ensures we always output valid sixel when explicitly requested
                        try writer.writeAll("\x1bPq\x1b\\");
                    }
                },
                .sgr => |options| {
                    var scaled_image: ?Image(T) = null;
                    defer if (scaled_image) |*img| img.deinit(allocator);
                    const image_to_display = self.maybeScale(allocator, options.width, options.height, &scaled_image);

                    // Process image in 2-row chunks for half-block characters
                    const row_pairs = (image_to_display.rows + 1) / 2;

                    for (0..row_pairs) |pair_idx| {
                        for (0..image_to_display.cols) |col| {
                            const row1 = pair_idx * 2;
                            const row2 = if (row1 + 1 < image_to_display.rows) row1 + 1 else row1;

                            const upper_pixel = image_to_display.at(row1, col).*;
                            const lower_pixel = image_to_display.at(row2, col).*;

                            const rgb_upper = color.convertColor(Rgb, upper_pixel);
                            const rgb_lower = color.convertColor(Rgb, lower_pixel);

                            // Use upper half block (▀) with foreground=upper, background=lower
                            try writer.print("\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m▀\x1b[0m", .{
                                rgb_upper.r, rgb_upper.g, rgb_upper.b,
                                rgb_lower.r, rgb_lower.g, rgb_lower.b,
                            });
                        }
                        if (pair_idx < row_pairs - 1) {
                            try writer.print("\n", .{});
                        }
                    }
                },
                .braille => |config| {
                    var scaled_image: ?Image(T) = null;
                    defer if (scaled_image) |*img| img.deinit(allocator);
                    const image_to_display = self.maybeScale(allocator, config.width, config.height, &scaled_image);

                    // Braille pattern bit mapping
                    // Dots are numbered 1-8, bits are 0-7
                    const braille_bits = [4][2]u3{
                        .{ 0, 3 }, // dots 1, 4
                        .{ 1, 4 }, // dots 2, 5
                        .{ 2, 5 }, // dots 3, 6
                        .{ 6, 7 }, // dots 7, 8
                    };
                    // Process image in 2x4 blocks for Braille patterns
                    const block_rows = (image_to_display.rows + 3) / 4;
                    const block_cols = (image_to_display.cols + 1) / 2;

                    for (0..block_rows) |block_row| {
                        for (0..block_cols) |block_col| {
                            var pattern: u8 = 0;

                            // Check each dot position in the 4x2 block
                            for (0..4) |dy| {
                                for (0..2) |dx| {
                                    const y = block_row * 4 + dy;
                                    const x = block_col * 2 + dx;

                                    if (y < image_to_display.rows and x < image_to_display.cols) {
                                        const pixel = image_to_display.at(y, x).*;

                                        // Convert to grayscale brightness
                                        const brightness: f32 = switch (@typeInfo(@TypeOf(pixel))) {
                                            .int, .float => blk: {
                                                // Already grayscale
                                                const val = switch (@typeInfo(@TypeOf(pixel))) {
                                                    .int => @as(f32, @floatFromInt(pixel)) / 255.0,
                                                    .float => @as(f32, pixel),
                                                    else => unreachable,
                                                };
                                                break :blk val;
                                            },
                                            .@"struct" => blk: {
                                                // Convert to RGB and use luma method
                                                const rgb = color.convertColor(Rgb, pixel);
                                                break :blk @floatCast(rgb.luma());
                                            },
                                            else => 0.5, // Default for unknown types
                                        };

                                        // Apply threshold
                                        if (brightness > config.threshold) {
                                            const bit_pos = braille_bits[dy][dx];
                                            pattern |= (@as(u8, 1) << bit_pos);
                                        }
                                    }
                                }
                            }

                            // Convert pattern to Unicode Braille character
                            const braille_char = @as(u21, 0x2800) + @as(u21, pattern);
                            try writer.print("{u}", .{braille_char});
                        }
                        if (block_row < block_rows - 1) {
                            try writer.print("\n", .{});
                        }
                    }
                },
            }
        }
    };
}
