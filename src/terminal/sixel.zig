//! Sixel graphics protocol support for image rendering
//!
//! This module provides functionality to convert images to sixel format,
//! which is supported by various terminal emulators for displaying graphics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;

const Image = @import("../image.zig").Image;
const Interpolation = @import("../image/interpolation.zig").Interpolation;
const dither = @import("../image/dither.zig");
const quantize = @import("../image/quantize.zig");
const rle = @import("../rle.zig");
const detect = @import("detect.zig");

const Rgb = quantize.Rgb;
const sixel_char_offset: u8 = '?'; // ASCII 63 - base for sixel characters
// Row buffers are stack-allocated, so widths past the aspectScale cap are rejected.
const max_supported_width: usize = detect.max_dimension;

/// An empty sixel sequence (DCS + ST), useful as a visual no-op.
pub const empty_sequence: []const u8 = "\x1bPq\x1b\\";

/// Dithering modes for color quantization (alias for the shared `dither.Mode`).
pub const DitherMode = dither.Mode;

/// Options for sixel encoding
pub const Options = struct {
    /// Palette generation mode
    palette: quantize.PaletteMode = .{ .adaptive = .{ .max_colors = 256 } },
    /// Dithering algorithm to use
    dither: DitherMode = .auto,
    /// Target width (null = original width preserved, scaling fits aspect ratio)
    width: ?u32 = null,
    /// Target height (null = original height preserved, scaling fits aspect ratio)
    height: ?u32 = null,
    /// Interpolation method to use when scaling the image
    interpolation: Interpolation = .nearest,

    /// Default options for automatic formatting
    pub const default: Options = .{};
    /// Fallback options without dithering
    pub const fallback: Options = .{ .dither = .none };
};

// ========== Main Entry Point ==========

/// Converts an image to sixel format
pub fn fromImage(
    comptime T: type,
    io: std.Io,
    image: Image(T),
    gpa: Allocator,
    options: Options,
) ![]u8 {
    const is_rgb = T == Rgb;
    const scale = detect.aspectScale(options.width, options.height, image.rows, image.cols);

    // Scale/convert up front so quantization, dithering, and encoding all see
    // the pixels that are actually emitted.
    var prepared_img: ?Image(Rgb) = null;
    defer if (prepared_img) |*img| img.deinit(gpa);

    if (!detect.isIdentityScale(scale)) {
        if (comptime is_rgb) {
            prepared_img = try image.scale(io, gpa, scale, options.interpolation);
        } else {
            var scaled = try image.scale(io, gpa, scale, options.interpolation);
            defer scaled.deinit(gpa);
            prepared_img = try scaled.convert(gpa, Rgb);
        }
    } else if (!is_rgb) {
        prepared_img = try image.convert(gpa, Rgb);
    }

    const width: usize = if (prepared_img) |img| img.cols else image.cols;
    const height: usize = if (prepared_img) |img| img.rows else image.rows;
    if (width > max_supported_width) return error.ImageTooWide;

    var palette: [256]Rgb = undefined;
    const palette_size = if (prepared_img) |img|
        quantize.buildPalette(Rgb, gpa, img, options.palette, &palette)
    else
        quantize.buildPalette(T, gpa, image, options.palette, &palette);

    const color_lut = quantize.getPaletteLut(options.palette, palette[0..palette_size]);

    const dither_mode = switch (options.dither) {
        .auto => blk: {
            const total_pixels = std.math.mul(usize, width, height) catch std.math.maxInt(usize);
            if (palette_size >= 128 and total_pixels >= 512 * 512) {
                break :blk DitherMode.none;
            }
            if (palette_size <= 16) break :blk DitherMode.atkinson;
            break :blk DitherMode.ordered;
        },
        else => options.dither,
    };

    if (dither_mode != .none) {
        // Dithering mutates pixels, so an unscaled Rgb source needs a private copy.
        if (prepared_img == null) prepared_img = try image.convert(gpa, Rgb);
        dither.apply(prepared_img.?, palette[0..palette_size], color_lut, dither_mode);
    }

    // Pre-allocate output buffer with estimated size
    // Header: ~50 bytes
    // Palette definitions: palette_size * 20 bytes
    // Sixel data: (height/6 + 1) rows * width chars * avg 2 bytes per position
    // Control sequences: (height/6 + 1) rows * palette_size * 5 bytes
    const sixel_rows = (height + 5) / 6;
    const estimated_size = 50 +
        palette_size * 20 +
        sixel_rows * width * 2 +
        sixel_rows * palette_size * 5;

    var output: std.ArrayList(u8) = try .initCapacity(gpa, estimated_size);
    defer output.deinit(gpa);

    // Start sixel sequence with DCS, then add raster dimensions
    // Format: ESC P q " P1 ; P2 ; width ; height
    // P1=1 (aspect ratio 1:1), P2=1 (keep background)
    // Note: Some terminals don't respect the height parameter and will show
    // black padding for images whose height is not a multiple of 6
    try output.print(gpa, "\x1bPq\"1;1;{d};{d}", .{ width, height });

    for (palette[0..palette_size], 0..) |p, i| {
        const r_val = (@as(u32, p.r) * 100 + 127) / 255;
        const g_val = (@as(u32, p.g) * 100 + 127) / 255;
        const b_val = (@as(u32, p.b) * 100 + 127) / 255;
        try output.print(gpa, "#{d};2;{d};{d};{d}", .{ i, r_val, g_val, b_val });
    }

    const color_map_len = palette_size * width;
    var color_map_storage = try gpa.alloc(u8, color_map_len);
    defer gpa.free(color_map_storage);
    var color_map_generation = try gpa.alloc(u32, color_map_len);
    defer gpa.free(color_map_generation);
    @memset(color_map_generation[0..color_map_len], 0);
    var color_generation_counter: u32 = 1;

    var column_stamp: [256]u32 = undefined;
    @memset(&column_stamp, 0);
    var column_index: [256]u16 = undefined;
    var column_colors: [256]u8 = undefined;
    var column_bits: [256]u8 = undefined;
    var column_generation_counter: u32 = 1;

    var row: usize = 0;
    while (row < height) : (row += 6) {
        var colors_used: [256]bool = undefined;
        @memset(colors_used[0..palette_size], false);

        const row_generation = color_generation_counter;
        color_generation_counter += 1;
        if (color_generation_counter == 0) {
            @memset(color_map_generation, 0);
            color_generation_counter = 1;
        }

        var row_slices: [6][]const Rgb = undefined;
        const limit = @min(6, height - row);

        for (0..limit) |i| {
            const r = row + i;
            if (prepared_img) |*ptr| {
                const offset = r * ptr.stride;
                row_slices[i] = ptr.data[offset .. offset + ptr.cols];
            } else if (comptime is_rgb) {
                const offset = r * image.stride;
                row_slices[i] = image.data[offset .. offset + image.cols];
            }
        }

        const block_size = 128; // Fits widely in L1 with 256 colors
        var col_base: usize = 0;
        while (col_base < width) : (col_base += block_size) {
            const col_limit = @min(col_base + block_size, width);

            for (col_base..col_limit) |col| {
                const column_generation = column_generation_counter;
                column_generation_counter += 1;
                if (column_generation_counter == 0) {
                    @memset(&column_stamp, 0);
                    column_generation_counter = 1;
                }

                var column_len: usize = 0;

                for (0..limit) |bit| {
                    const rgb = row_slices[bit][col];
                    const color_idx = color_lut.lookup(rgb);

                    colors_used[color_idx] = true;

                    if (column_stamp[color_idx] != column_generation) {
                        column_stamp[color_idx] = column_generation;
                        column_index[color_idx] = @intCast(column_len);
                        column_colors[column_len] = @intCast(color_idx);
                        column_bits[column_len] = 0;
                        column_len += 1;
                    }

                    const idx = column_index[color_idx];
                    column_bits[idx] |= @as(u8, 1) << @intCast(bit);
                }

                for (0..column_len) |idx| {
                    const color_idx = column_colors[idx];
                    // A column entry is only created when a bit is about to be
                    // OR'd in, so column_bits is always nonzero here.
                    const offset = @as(usize, color_idx) * width + col;
                    color_map_storage[offset] = column_bits[idx] + sixel_char_offset;
                    color_map_generation[offset] = row_generation;
                }
            }
        }

        var first_color_in_band = true;
        for (0..palette_size) |c| {
            if (!colors_used[c]) continue;

            // Colors within a band are separated by `$` (carriage return).
            if (!first_color_in_band) try output.append(gpa, '$');
            first_color_in_band = false;

            try output.print(gpa, "#{d}", .{c});

            var row_buffer: [max_supported_width]u8 = undefined;
            @memset(row_buffer[0..width], sixel_char_offset);
            // colors_used[c] guarantees at least one stamped column, so the
            // last stamped column bounds the RLE run.
            var last_used_col: usize = 0;
            for (0..width) |col| {
                const offset = c * width + col;
                if (color_map_generation[offset] == row_generation) {
                    row_buffer[col] = color_map_storage[offset];
                    last_used_col = col;
                }
            }

            var compressor: rle.Compressor(u8) = .{ .data = row_buffer[0 .. last_used_col + 1] };
            while (compressor.next()) |entry| {
                if (entry.count > 3) {
                    try output.print(gpa, "!{d}{c}", .{ entry.count, entry.value });
                } else {
                    for (0..entry.count) |_| {
                        try output.append(gpa, entry.value);
                    }
                }
            }
        }

        if (row + 6 < height) {
            try output.appendSlice(gpa, "-");
        }
    }

    try output.appendSlice(gpa, "\x1b\\");

    return output.toOwnedSlice(gpa);
}

/// Checks if the terminal supports sixel graphics
pub fn isSupported(io: std.Io) bool {
    if (!detect.isStdoutTty(io)) return false;
    return detect.isSixelSupported(io) catch false;
}

test "basic sixel encoding - 2x2 image" {
    const allocator = std.testing.allocator;

    // Create a 2x2 test image with distinct colors
    var img = try Image(Rgb).init(allocator, 2, 2);
    defer img.deinit(allocator);

    img.at(0, 0).* = .{ .r = 255, .g = 0, .b = 0 }; // Red
    img.at(0, 1).* = .{ .r = 0, .g = 255, .b = 0 }; // Green
    img.at(1, 0).* = .{ .r = 0, .g = 0, .b = 255 }; // Blue
    img.at(1, 1).* = .{ .r = 255, .g = 255, .b = 0 }; // Yellow

    const sixel_data = try fromImage(Rgb, std.Io.Threaded.global_single_threaded.io(), img, allocator, .{
        .palette = .fixed_6x7x6,
        .dither = .none,
        .width = 100,
        .height = 100,
    });
    defer allocator.free(sixel_data);

    // Verify sixel starts with DCS sequence
    try expect(std.mem.startsWith(u8, sixel_data, "\x1bP"));

    // Verify sixel ends with ST sequence
    try expect(std.mem.endsWith(u8, sixel_data, "\x1b\\"));

    // Verify it contains raster attributes (width;height)
    try expect(std.mem.find(u8, sixel_data, "\"") != null);
}

test "basic sixel encoding - verify palette format" {
    const allocator = std.testing.allocator;

    // Create a 4x4 test image
    var img = try Image(Rgb).init(allocator, 4, 4);
    defer img.deinit(allocator);

    // Fill with a single color to ensure it appears in palette
    for (0..4) |r| {
        for (0..4) |c| {
            img.at(r, c).* = .{ .r = 128, .g = 64, .b = 192 };
        }
    }

    const sixel_data = try fromImage(Rgb, std.Io.Threaded.global_single_threaded.io(), img, allocator, .{
        .palette = .{ .adaptive = .{ .max_colors = 16 } },
        .dither = .none,
        .width = 100,
        .height = 100,
    });
    defer allocator.free(sixel_data);

    // Verify palette entry format #P;R;G;B
    try expect(std.mem.find(u8, sixel_data, "#") != null);
}

test "palette mode - fixed 6x7x6 color mapping" {
    const allocator = std.testing.allocator;

    // Create image with colors that map to specific palette indices
    var img = try Image(Rgb).init(allocator, 1, 3);
    defer img.deinit(allocator);

    // Colors chosen to map to specific 6x7x6 palette entries
    img.at(0, 0).* = .{ .r = 0, .g = 0, .b = 0 }; // Black - index 0
    img.at(0, 1).* = .{ .r = 255, .g = 255, .b = 255 }; // White - last index
    img.at(0, 2).* = .{ .r = 255, .g = 0, .b = 0 }; // Red

    const sixel_data = try fromImage(Rgb, std.Io.Threaded.global_single_threaded.io(), img, allocator, .{
        .palette = .fixed_6x7x6,
        .dither = .none,
        .width = 100,
        .height = 100,
    });
    defer allocator.free(sixel_data);

    // Basic validation - should have palette entries
    try expect(sixel_data.len > 0);
    try expect(std.mem.find(u8, sixel_data, "#0;2;0;0;0") != null); // Black
}

test "palette mode - adaptive with color reduction" {
    const allocator = std.testing.allocator;

    // Create image with 8 distinct colors
    var img = try Image(Rgb).init(allocator, 4, 4);
    defer img.deinit(allocator);

    const colors = [_]Rgb{
        .{ .r = 255, .g = 0, .b = 0 }, // Red
        .{ .r = 0, .g = 255, .b = 0 }, // Green
        .{ .r = 0, .g = 0, .b = 255 }, // Blue
        .{ .r = 255, .g = 255, .b = 0 }, // Yellow
        .{ .r = 255, .g = 0, .b = 255 }, // Magenta
        .{ .r = 0, .g = 255, .b = 255 }, // Cyan
        .{ .r = 128, .g = 128, .b = 128 }, // Gray
        .{ .r = 255, .g = 128, .b = 0 }, // Orange
    };

    // Fill image with 8 colors (2x2 blocks for each color)
    var color_idx: usize = 0;
    for (0..4) |r| {
        for (0..4) |c| {
            img.at(r, c).* = colors[color_idx];
            if ((r * 4 + c + 1) % 2 == 0) {
                color_idx = (color_idx + 1) % 8;
            }
        }
    }

    // Test with max_colors = 4 (force color reduction)
    const sixel_data = try fromImage(Rgb, std.Io.Threaded.global_single_threaded.io(), img, allocator, .{
        .palette = .{ .adaptive = .{ .max_colors = 4 } },
        .dither = .none,
        .width = 100,
        .height = 100,
    });
    defer allocator.free(sixel_data);

    // Should have at most 4 colors in palette (0-3)
    try expect(std.mem.find(u8, sixel_data, "#0;") != null);
    // Should not have color index 4 or higher
    try expect(std.mem.find(u8, sixel_data, "#4;") == null);
}

test "edge case - single pixel image" {
    const allocator = std.testing.allocator;

    var img = try Image(Rgb).init(allocator, 1, 1);
    defer img.deinit(allocator);

    img.at(0, 0).* = .{ .r = 128, .g = 128, .b = 128 };

    const sixel_data = try fromImage(Rgb, std.Io.Threaded.global_single_threaded.io(), img, allocator, .{
        .palette = .fixed_web216,
        .dither = .none,
        .width = 100,
        .height = 100,
    });
    defer allocator.free(sixel_data);

    // Should produce valid sixel with proper structure
    try expect(std.mem.startsWith(u8, sixel_data, "\x1bP"));
    try expect(std.mem.endsWith(u8, sixel_data, "\x1b\\"));
    try expect(std.mem.find(u8, sixel_data, "\"1;1;") != null);
}

test "edge case - uniform color image" {
    const allocator = std.testing.allocator;

    var img = try Image(Rgb).init(allocator, 8, 8);
    defer img.deinit(allocator);

    // Fill entire image with same color
    const uniform_color = Rgb{ .r = 64, .g = 128, .b = 192 };
    for (0..img.rows) |r| {
        for (0..img.cols) |c| {
            img.at(r, c).* = uniform_color;
        }
    }

    const sixel_data = try fromImage(Rgb, std.Io.Threaded.global_single_threaded.io(), img, allocator, .{
        .palette = .{ .adaptive = .{ .max_colors = 256 } },
        .dither = .none,
        .width = 100,
        .height = 100,
    });
    defer allocator.free(sixel_data);

    // Should have only one color in adaptive palette
    try expect(std.mem.find(u8, sixel_data, "#0;") != null);
    try expect(std.mem.find(u8, sixel_data, "#1;") == null);
}
