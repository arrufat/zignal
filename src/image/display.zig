//! Terminal display formatting for images

const std = @import("std");

const color = @import("../color.zig");
const Rgb = @import("../color.zig").Rgb;
const kitty = @import("../kitty.zig");
const sixel = @import("../sixel.zig");

// Import Image type directly - Zig's lazy compilation handles circular imports
const Image = @import("../image.zig").Image;

/// Display format options
pub const DisplayFormat = union(enum) {
    /// Automatically detect the best format (sixel if supported, ANSI otherwise)
    auto,
    /// Force ANSI escape codes output with spaces (universally compatible)
    ansi_basic,
    /// ANSI with Unicode half-block characters for 2x vertical resolution
    /// Requires a monospace font with Unicode block element support (U+2580)
    ansi_blocks,
    /// Braille patterns for 2x4 monochrome resolution
    /// Requires Unicode Braille pattern support (U+2800-U+28FF)
    /// Color images are binarized with threshold
    braille: struct {
        /// Brightness threshold for on/off (0.0-1.0)
        threshold: f32,
        pub const default: @This() = .{ .threshold = 0.5 };
    },
    /// Force sixel output with specific options
    sixel: sixel.Options,
    /// Kitty graphics protocol with options
    kitty: kitty.Options,
};

/// Formatter struct for terminal display with progressive degradation
pub fn DisplayFormatter(comptime T: type) type {
    return struct {
        image: *const Image(T),
        display_format: DisplayFormat,

        const Self = @This();

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {

            // Determine if we can fallback to ANSI
            const can_fallback = self.display_format == .auto;

            fmt: switch (self.display_format) {
                .ansi_basic => {
                    for (0..self.image.rows) |r| {
                        for (0..self.image.cols) |c| {
                            const pixel = self.image.at(r, c).*;
                            const rgb = color.convertColor(Rgb, pixel);
                            try writer.print("\x1b[48;2;{d};{d};{d}m \x1b[0m", .{ rgb.r, rgb.g, rgb.b });
                        }
                        if (r < self.image.rows - 1) {
                            try writer.print("\n", .{});
                        }
                    }
                },
                .ansi_blocks => {
                    // Process image in 2-row chunks for half-block characters
                    const row_pairs = (self.image.rows + 1) / 2;

                    for (0..row_pairs) |pair_idx| {
                        for (0..self.image.cols) |col| {
                            const row1 = pair_idx * 2;
                            const row2 = if (row1 + 1 < self.image.rows) row1 + 1 else row1;

                            const upper_pixel = self.image.at(row1, col).*;
                            const lower_pixel = self.image.at(row2, col).*;

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
                    // Braille pattern bit mapping
                    // Dots are numbered 1-8, bits are 0-7
                    const braille_bits = [4][2]u3{
                        .{ 0, 3 }, // dots 1, 4
                        .{ 1, 4 }, // dots 2, 5
                        .{ 2, 5 }, // dots 3, 6
                        .{ 6, 7 }, // dots 7, 8
                    };
                    // Process image in 2x4 blocks for Braille patterns
                    const block_rows = (self.image.rows + 3) / 4;
                    const block_cols = (self.image.cols + 1) / 2;

                    for (0..block_rows) |block_row| {
                        for (0..block_cols) |block_col| {
                            var pattern: u8 = 0;

                            // Check each dot position in the 4x2 block
                            for (0..4) |dy| {
                                for (0..2) |dx| {
                                    const y = block_row * 4 + dy;
                                    const x = block_col * 2 + dx;

                                    if (y < self.image.rows and x < self.image.cols) {
                                        const pixel = self.image.at(y, x).*;

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
                .auto => {
                    if (kitty.isSupported()) {
                        continue :fmt .{ .kitty = .default };
                    } else if (sixel.isSupported()) {
                        continue :fmt .{ .sixel = .default };
                    } else {
                        continue :fmt .ansi_blocks;
                    }
                },
                .sixel => |options| {
                    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                    defer arena.deinit();
                    const allocator = arena.allocator();

                    // Try to convert to sixel
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
                        continue :fmt .ansi_basic;
                    } else {
                        // Output minimal sixel sequence to indicate failure
                        // This ensures we always output valid sixel when explicitly requested
                        try writer.writeAll("\x1bPq\x1b\\");
                    }
                },
                .kitty => |options| {
                    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
                    defer arena.deinit();
                    const allocator = arena.allocator();

                    // Try to convert to Kitty format
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
                        continue :fmt .ansi_blocks;
                    } else {
                        // Output minimal Kitty sequence to indicate failure
                        // Empty image with delete command
                        try writer.writeAll("\x1b_Ga=d\x1b\\");
                    }
                },
            }
        }
    };
}
