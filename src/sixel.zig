//! Sixel graphics protocol support for image rendering
//!
//! This module provides functionality to convert images to sixel format,
//! which is supported by various terminal emulators for displaying graphics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const clamp = std.math.clamp;

const convertColor = @import("color.zig").convertColor;
const Image = @import("image.zig").Image;
const Rgb = @import("color.zig").Rgb;
const TerminalSupport = @import("TerminalSupport.zig");
const InterpolationMethod = @import("image/interpolation.zig").InterpolationMethod;

const sixel_char_offset: u8 = '?'; // ASCII 63 - base for sixel characters
const max_supported_width: usize = 2048;
const color_quantize_bits: u5 = 5; // For 32x32x32 color lookup table

/// Available palette modes for sixel encoding
pub const PaletteMode = union(enum) {
    /// Fixed 252-color palette with 6x7x6 RGB distribution
    fixed_6x7x6,
    /// Fixed 16-color VGA palette
    fixed_vga16,
    /// Fixed 216-color web-safe palette (6x6x6 RGB cube)
    fixed_web216,
    /// Adaptive palette using median cut algorithm
    adaptive: struct {
        /// Maximum colors for adaptive palette (1-256)
        max_colors: u16 = 256,
    },

    /// Get the palette size for this mode
    pub fn size(self: PaletteMode) usize {
        return switch (self) {
            .fixed_6x7x6 => 252, // 6*7*6 = 252 colors
            .fixed_vga16 => 16, // Standard VGA palette
            .fixed_web216 => 216, // 6*6*6 = 216 web-safe colors
            .adaptive => |opts| @min(opts.max_colors, 256),
        };
    }
};

/// Dithering modes for color quantization
pub const DitherMode = enum {
    /// No dithering, direct color quantization
    none,
    /// Floyd-Steinberg error diffusion dithering
    floyd_steinberg,
    /// Atkinson dithering (used by original Macintosh)
    atkinson,
    /// Automatic selection based on palette size
    auto,
};

/// Options for sixel encoding
pub const Options = struct {
    /// Palette generation mode
    palette: PaletteMode,
    /// Dithering algorithm to use
    dither: DitherMode,
    /// Maximum output width (image will be scaled if larger)
    max_width: u32,
    /// Maximum output height (image will be scaled if larger)
    max_height: u32,
    /// Interpolation method to use when scaling the image
    interpolation: InterpolationMethod = .nearest_neighbor,

    /// Default options for automatic formatting
    pub const default: Options = .{
        .palette = .{ .adaptive = .{ .max_colors = 256 } },
        .dither = .auto,
        .max_width = 800,
        .max_height = 600,
        .interpolation = .nearest_neighbor,
    };
    /// Fallback options without dithering
    pub const fallback: Options = .{
        .palette = .{ .adaptive = .{ .max_colors = 256 } },
        .dither = .none,
        .max_width = 800,
        .max_height = 600,
        .interpolation = .nearest_neighbor,
    };
};

// ========== Main Entry Point ==========

/// Converts an image to sixel format
pub fn fromImage(
    comptime T: type,
    image: Image(T),
    allocator: Allocator,
    options: Options,
) ![]u8 {

    // Calculate scaling if needed
    var width = image.cols;
    var height = image.rows;
    var scale_x: f32 = 1.0;
    var scale_y: f32 = 1.0;

    if (width > options.max_width) {
        scale_x = @as(f32, @floatFromInt(options.max_width)) / @as(f32, @floatFromInt(width));
    }
    if (height > options.max_height) {
        scale_y = @as(f32, @floatFromInt(options.max_height)) / @as(f32, @floatFromInt(height));
    }
    const scale = @min(scale_x, scale_y);

    if (scale < 1.0) {
        width = @intFromFloat(@as(f32, @floatFromInt(width)) * scale);
        height = @intFromFloat(@as(f32, @floatFromInt(height)) * scale);
    }

    // Prepare palette based on mode
    var palette: [256]Rgb = undefined;
    var palette_size: usize = options.palette.size();

    switch (options.palette) {
        .fixed_6x7x6 => {
            generateFixed6x7x6Palette(&palette);
        },
        .fixed_vga16 => {
            @memcpy(palette[0..16], &vga16_palette);
        },
        .fixed_web216 => {
            generateWeb216Palette(&palette);
        },
        .adaptive => |adaptive_opts| {
            palette_size = generateAdaptivePalette(T, allocator, image, &palette, adaptive_opts.max_colors) catch blk: {
                generateFixed6x7x6Palette(&palette);
                break :blk 252;
            };
        },
    }

    // Build lookup table for all palettes
    var color_lut: ColorLookupTable = undefined;
    color_lut.build(palette[0..], palette_size);

    // Determine dithering mode
    const dither_mode = switch (options.dither) {
        .auto => if (palette_size <= 16) DitherMode.atkinson else DitherMode.floyd_steinberg,
        else => options.dither,
    };

    // Prepare a scaled Rgb image for dithering if needed
    var scaled_rgb: ?Image(Rgb) = null;
    if (dither_mode != .none) {
        scaled_rgb = try Image(Rgb).initAlloc(allocator, height, width);

        // Copy scaled image data to working image
        for (0..height) |row| {
            for (0..width) |col| {
                const src_x = @as(f32, @floatFromInt(col)) / scale;
                const src_y = @as(f32, @floatFromInt(row)) / scale;

                if (image.interpolate(src_x, src_y, options.interpolation)) |pixel| {
                    scaled_rgb.?.at(row, col).* = convertColor(Rgb, pixel);
                }
            }
        }

        // Apply dithering
        switch (dither_mode) {
            .floyd_steinberg => applyErrorDiffusion(scaled_rgb.?, palette[0..palette_size], &color_lut, floyd_steinberg_config),
            .atkinson => applyErrorDiffusion(scaled_rgb.?, palette[0..palette_size], &color_lut, atkinson_config),
            else => {},
        }
    }
    defer if (scaled_rgb) |*img| img.deinit(allocator);

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

    var output = try std.ArrayList(u8).initCapacity(allocator, estimated_size);
    defer output.deinit();

    // Start sixel sequence with DCS, then add raster dimensions
    // Format: ESC P q " P1 ; P2 ; width ; height
    // P1=1 (aspect ratio 1:1), P2=1 (keep background)
    // Note: Some terminals don't respect the height parameter and will show
    // black padding for images whose height is not a multiple of 6
    try output.writer().print("\x1bPq\"1;1;{d};{d}", .{ width, height });

    // Define palette - unified approach
    var palette_buf: [64]u8 = undefined; // Buffer for building palette strings

    for (0..palette_size) |i| {
        const p = if (options.palette == .fixed_6x7x6) blk: {
            // Calculate 6x7x6 color directly
            const r_idx = i / 42;
            const g_idx = (i % 42) / 6;
            const b_idx = i % 6;
            break :blk Rgb{
                .r = @intCast((r_idx * 255 + 2) / 5),
                .g = @intCast((g_idx * 255 + 3) / 6),
                .b = @intCast((b_idx * 255 + 2) / 5),
            };
        } else palette[i];

        const r_val = (@as(u32, p.r) * 100 + 127) / 255;
        const g_val = (@as(u32, p.g) * 100 + 127) / 255;
        const b_val = (@as(u32, p.b) * 100 + 127) / 255;

        // Build palette definition
        palette_buf[0] = '#';
        var pos: usize = 1;
        pos += std.fmt.printInt(palette_buf[pos..], i, 10, .lower, .{});
        palette_buf[pos..][0..3].* = ";2;".*;
        pos += 3;
        pos += std.fmt.printInt(palette_buf[pos..], r_val, 10, .lower, .{});
        palette_buf[pos] = ';';
        pos += 1;
        pos += std.fmt.printInt(palette_buf[pos..], g_val, 10, .lower, .{});
        palette_buf[pos] = ';';
        pos += 1;
        pos += std.fmt.printInt(palette_buf[pos..], b_val, 10, .lower, .{});

        try output.appendSlice(palette_buf[0..pos]);
    }

    // Encode pixels as sixels
    var row: usize = 0;
    while (row < height) : (row += 6) {
        // Build a map of which colors are used in this sixel row
        var colors_used: [256]bool = undefined;
        @memset(colors_used[0..palette_size], false);

        // Use a flat array for color_map to avoid nested allocations
        if (width > max_supported_width) {
            return error.ImageTooWide;
        }

        var color_map_storage: [256 * max_supported_width]u8 = undefined;
        // Initialize only the portion we'll use
        @memset(color_map_storage[0..(palette_size * width)], 0);

        // First pass: build bitmaps for each color
        for (0..width) |col| {
            var sixel_bits: [256]u8 = undefined;
            @memset(sixel_bits[0..palette_size], 0);

            // Check all 6 pixels in this column
            for (0..6) |bit| {
                const pixel_row = row + bit;
                if (pixel_row < height) {
                    const color_idx = if (scaled_rgb) |img| blk: {
                        // Use dithered data
                        const rgb = img.at(pixel_row, col).*;
                        break :blk color_lut.lookup(rgb);
                    } else blk: {
                        // Use original data without dithering
                        const src_x = @as(f32, @floatFromInt(col)) / scale;
                        const src_y = @as(f32, @floatFromInt(pixel_row)) / scale;

                        if (image.interpolate(src_x, src_y, options.interpolation)) |pixel| {
                            const rgb = convertColor(Rgb, pixel);

                            // Use lookup table for all palettes
                            break :blk color_lut.lookup(rgb);
                        } else {
                            continue;
                        }
                    };

                    // Set the bit for this color
                    sixel_bits[color_idx] |= @as(u8, 1) << @intCast(bit);
                    colors_used[color_idx] = true;
                }
            }

            // Store the sixel characters for each color
            for (0..palette_size) |c| {
                if (sixel_bits[c] != 0) {
                    // Access flat array: color_map[c][col] becomes color_map_storage[c * width + col]
                    color_map_storage[c * width + col] = sixel_bits[c] + sixel_char_offset; // Add to '?' to get sixel char
                }
            }
        }

        // Second pass: output sixels for each color
        var current_color: usize = std.math.maxInt(usize); // Invalid color
        for (0..palette_size) |c| {
            if (!colors_used[c]) continue;

            // Select color if different
            if (c != current_color) {
                current_color = c;
                // Use fast integer conversion
                var color_select_buf: [16]u8 = undefined;
                color_select_buf[0] = '#';
                const len = std.fmt.printInt(color_select_buf[1..], current_color, 10, .lower, .{});
                try output.appendSlice(color_select_buf[0 .. len + 1]);
            }

            // Output all sixels for this color - build complete row first
            var row_buffer: [max_supported_width]u8 = undefined; // Stack buffer for row data
            if (width > row_buffer.len) {
                return error.ImageTooWide;
            }

            // Build the entire row in the buffer
            for (0..width) |col| {
                const char = color_map_storage[c * width + col];
                row_buffer[col] = if (char != 0) char else sixel_char_offset;
            }

            // Write the entire row at once
            try output.appendSlice(row_buffer[0..width]);

            // Carriage return to go back to start of line (except for last color)
            var more_colors = false;
            for (c + 1..palette_size) |nc| {
                if (colors_used[nc]) {
                    more_colors = true;
                    break;
                }
            }
            if (more_colors) {
                try output.writer().print("$", .{}); // Graphics carriage return
            }
        }

        // Move to next sixel row if not at end
        if (row + 6 < height) {
            try output.writer().print("-", .{}); // Graphics new line
        }
    }

    // End sixel sequence with ST
    try output.writer().print("\x1b\\", .{});

    return output.toOwnedSlice();
}

/// Color histogram entry for adaptive palette generation
const ColorCount = struct {
    r: u8,
    g: u8,
    b: u8,
    count: u32,
};

/// Box structure for median cut algorithm
const ColorBox = struct {
    colors: []ColorCount,
    r_min: u8,
    r_max: u8,
    g_min: u8,
    g_max: u8,
    b_min: u8,
    b_max: u8,
    population: u32,

    fn volume(self: ColorBox) u32 {
        if (self.r_max < self.r_min or self.g_max < self.g_min or self.b_max < self.b_min) {
            return 0;
        }
        const r_size = @as(u32, self.r_max) - @as(u32, self.r_min) + 1;
        const g_size = @as(u32, self.g_max) - @as(u32, self.g_min) + 1;
        const b_size = @as(u32, self.b_max) - @as(u32, self.b_min) + 1;
        return r_size * g_size * b_size;
    }

    fn largestDimension(self: ColorBox) u8 {
        const r_range = if (self.r_max >= self.r_min) self.r_max - self.r_min else 0;
        const g_range = if (self.g_max >= self.g_min) self.g_max - self.g_min else 0;
        const b_range = if (self.b_max >= self.b_min) self.b_max - self.b_min else 0;

        if (g_range >= r_range and g_range >= b_range) return 1; // green
        if (r_range >= b_range) return 0; // red
        return 2; // blue
    }
};

/// 3D lookup table for fast color mapping
const ColorLookupTable = struct {
    table: [32][32][32]u8, // 5-bit per channel lookup

    /// Finds the nearest color in a palette to the target color
    fn findNearestColor(pal: []const Rgb, target: Rgb) u8 {
        var best_idx: u8 = 0;
        var best_dist: u32 = std.math.maxInt(u32);

        for (pal, 0..) |p, idx| {
            const dr = if (target.r > p.r) target.r - p.r else p.r - target.r;
            const dg = if (target.g > p.g) target.g - p.g else p.g - target.g;
            const db = if (target.b > p.b) target.b - p.b else p.b - target.b;
            const dist = @as(u32, dr) * @as(u32, dr) +
                @as(u32, dg) * @as(u32, dg) +
                @as(u32, db) * @as(u32, db);

            if (dist < best_dist) {
                best_dist = dist;
                best_idx = @intCast(idx);
            }
        }
        return best_idx;
    }

    fn build(self: *ColorLookupTable, palette: []const Rgb, palette_size: usize) void {
        const LUT_SIZE = @as(usize, 1) << color_quantize_bits;
        for (0..LUT_SIZE) |r| {
            for (0..LUT_SIZE) |g| {
                for (0..LUT_SIZE) |b| {
                    const rgb = Rgb{
                        .r = @intCast(r << (8 - color_quantize_bits) | (r >> (2 * color_quantize_bits - 8))),
                        .g = @intCast(g << (8 - color_quantize_bits) | (g >> (2 * color_quantize_bits - 8))),
                        .b = @intCast(b << (8 - color_quantize_bits) | (b >> (2 * color_quantize_bits - 8))),
                    };
                    self.table[r][g][b] = findNearestColor(palette[0..palette_size], rgb);
                }
            }
        }
    }

    fn lookup(self: *const ColorLookupTable, rgb: Rgb) u8 {
        // Quantize to 5-bit per channel
        const r5 = rgb.r >> (8 - color_quantize_bits);
        const g5 = rgb.g >> (8 - color_quantize_bits);
        const b5 = rgb.b >> (8 - color_quantize_bits);
        return self.table[r5][g5][b5];
    }
};

/// Error diffusion dithering configuration
const DitherConfig = struct {
    // Error distribution matrix offsets and weights
    // Format: {dx, dy, weight, divisor}
    distributions: []const [4]i16,
};

// Floyd-Steinberg error distribution:
//          X   7/16
//  3/16  5/16  1/16
const floyd_steinberg_config = DitherConfig{
    .distributions = &[_][4]i16{
        .{ 1, 0, 7, 16 }, // right
        .{ -1, 1, 3, 16 }, // bottom-left
        .{ 0, 1, 5, 16 }, // bottom
        .{ 1, 1, 1, 16 }, // bottom-right
    },
};

// Atkinson error distribution (only 75% of error is diffused):
//          X   1/8  1/8
//   1/8   1/8  1/8
//         1/8
const atkinson_config = DitherConfig{
    .distributions = &[_][4]i16{
        .{ 1, 0, 1, 8 }, // right
        .{ 2, 0, 1, 8 }, // right+1
        .{ -1, 1, 1, 8 }, // bottom-left
        .{ 0, 1, 1, 8 }, // bottom
        .{ 1, 1, 1, 8 }, // bottom-right
        .{ 0, 2, 1, 8 }, // bottom+1
    },
};

/// Unified error diffusion dithering implementation
fn applyErrorDiffusion(
    img: Image(Rgb),
    pal: []const Rgb,
    lut: *const ColorLookupTable,
    config: DitherConfig,
) void {
    for (0..img.rows) |r| {
        for (0..img.cols) |c| {
            const original = img.at(r, c).*;

            // Find nearest palette color using LUT
            const idx = lut.lookup(original);
            const quantized = pal[idx];

            // Calculate error for each channel
            const r_error = @as(i16, original.r) - @as(i16, quantized.r);
            const g_error = @as(i16, original.g) - @as(i16, quantized.g);
            const b_error = @as(i16, original.b) - @as(i16, quantized.b);

            // Update pixel to quantized color
            img.at(r, c).* = quantized;

            // Distribute error to neighboring pixels
            for (config.distributions) |dist| {
                const nc = @as(isize, @intCast(c)) + dist[0];
                const nr = @as(isize, @intCast(r)) + dist[1];

                if (img.atOrNull(nr, nc)) |neighbor| {
                    neighbor.* = Rgb{
                        .r = @intCast(clamp(@as(i16, neighbor.r) + @divTrunc(r_error * dist[2], dist[3]), 0, 255)),
                        .g = @intCast(clamp(@as(i16, neighbor.g) + @divTrunc(g_error * dist[2], dist[3]), 0, 255)),
                        .b = @intCast(clamp(@as(i16, neighbor.b) + @divTrunc(b_error * dist[2], dist[3]), 0, 255)),
                    };
                }
            }
        }
    }
}

/// Standard VGA 16-color palette
const vga16_palette = [16]Rgb{
    Rgb{ .r = 0, .g = 0, .b = 0 }, // Black
    Rgb{ .r = 128, .g = 0, .b = 0 }, // Maroon
    Rgb{ .r = 0, .g = 128, .b = 0 }, // Green
    Rgb{ .r = 128, .g = 128, .b = 0 }, // Olive
    Rgb{ .r = 0, .g = 0, .b = 128 }, // Navy
    Rgb{ .r = 128, .g = 0, .b = 128 }, // Purple
    Rgb{ .r = 0, .g = 128, .b = 128 }, // Teal
    Rgb{ .r = 192, .g = 192, .b = 192 }, // Silver
    Rgb{ .r = 128, .g = 128, .b = 128 }, // Gray
    Rgb{ .r = 255, .g = 0, .b = 0 }, // Red
    Rgb{ .r = 0, .g = 255, .b = 0 }, // Lime
    Rgb{ .r = 255, .g = 255, .b = 0 }, // Yellow
    Rgb{ .r = 0, .g = 0, .b = 255 }, // Blue
    Rgb{ .r = 255, .g = 0, .b = 255 }, // Fuchsia
    Rgb{ .r = 0, .g = 255, .b = 255 }, // Cyan
    Rgb{ .r = 255, .g = 255, .b = 255 }, // White
};

/// Generates the fixed 6x7x6 palette (252 colors)
fn generateFixed6x7x6Palette(palette: []Rgb) void {
    var idx: usize = 0;
    for (0..6) |r| {
        for (0..7) |g| {
            for (0..6) |b| {
                // Evenly distribute colors across RGB space
                palette[idx] = Rgb{
                    .r = @intCast((r * 255 + 2) / 5),
                    .g = @intCast((g * 255 + 3) / 6),
                    .b = @intCast((b * 255 + 2) / 5),
                };
                idx += 1;
            }
        }
    }
}

/// Generates the web-safe 216-color palette
fn generateWeb216Palette(palette: []Rgb) void {
    var idx: usize = 0;
    for (0..6) |r| {
        for (0..6) |g| {
            for (0..6) |b| {
                palette[idx] = Rgb{
                    .r = @intCast(r * 51),
                    .g = @intCast(g * 51),
                    .b = @intCast(b * 51),
                };
                idx += 1;
            }
        }
    }
}

/// Generates an adaptive palette using median cut algorithm
fn generateAdaptivePalette(
    comptime T: type,
    allocator: Allocator,
    image: Image(T),
    palette: []Rgb,
    max_colors: u16,
) !usize {
    const HashMap = std.hash_map.HashMap(u16, u32, std.hash_map.AutoContext(u16), 80);
    var histogram = HashMap.init(allocator);
    defer histogram.deinit();

    // Build color histogram (quantized to 5-bit per channel for efficiency)
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const pixel = image.at(r, c).*;
            const rgb = convertColor(Rgb, pixel);

            // Quantize to 5-bit per channel for histogram
            const r5 = rgb.r >> (8 - color_quantize_bits);
            const g5 = rgb.g >> (8 - color_quantize_bits);
            const b5 = rgb.b >> (8 - color_quantize_bits);
            const key = (@as(u16, r5) << (2 * color_quantize_bits)) | (@as(u16, g5) << color_quantize_bits) | @as(u16, b5);

            const result = try histogram.getOrPut(key);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }
    }

    // Convert histogram to array for median cut
    var color_list = std.ArrayList(ColorCount).init(allocator);
    defer color_list.deinit();

    var iter = histogram.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const count = entry.value_ptr.*;

        const r5 = @as(u8, @intCast((key >> (2 * color_quantize_bits)) & 0x1F));
        const g5 = @as(u8, @intCast((key >> color_quantize_bits) & 0x1F));
        const b5 = @as(u8, @intCast(key & 0x1F));

        // Convert back to 8-bit with proper scaling
        const r8 = (r5 << (8 - color_quantize_bits)) | (r5 >> (2 * color_quantize_bits - 8));
        const g8 = (g5 << (8 - color_quantize_bits)) | (g5 >> (2 * color_quantize_bits - 8));
        const b8 = (b5 << (8 - color_quantize_bits)) | (b5 >> (2 * color_quantize_bits - 8));

        try color_list.append(.{
            .r = r8,
            .g = g8,
            .b = b8,
            .count = count,
        });
    }

    const palette_size = @min(@min(color_list.items.len, max_colors), palette.len);

    if (palette_size == 0) {
        return error.NoPaletteColors;
    }

    // Special case: if we only have one color, just return it
    if (color_list.items.len == 1) {
        palette[0] = .{
            .r = color_list.items[0].r,
            .g = color_list.items[0].g,
            .b = color_list.items[0].b,
        };
        return 1;
    }

    // Initialize first box with all colors
    var boxes = std.ArrayList(ColorBox).init(allocator);
    defer boxes.deinit();

    var initial_box = ColorBox{
        .colors = color_list.items,
        .r_min = 255,
        .r_max = 0,
        .g_min = 255,
        .g_max = 0,
        .b_min = 255,
        .b_max = 0,
        .population = 0,
    };

    // Find bounds of initial box
    for (color_list.items) |c| {
        initial_box.r_min = @min(initial_box.r_min, c.r);
        initial_box.r_max = @max(initial_box.r_max, c.r);
        initial_box.g_min = @min(initial_box.g_min, c.g);
        initial_box.g_max = @max(initial_box.g_max, c.g);
        initial_box.b_min = @min(initial_box.b_min, c.b);
        initial_box.b_max = @max(initial_box.b_max, c.b);
        initial_box.population += c.count;
    }

    try boxes.append(initial_box);

    // Median cut algorithm
    while (boxes.items.len < palette_size) {

        // Find box with largest volume * population that can be split
        var largest_idx: ?usize = null;
        var largest_score: u64 = 0;

        for (boxes.items, 0..) |box, i| {
            // Skip boxes that can't be split (no range in any dimension)
            if (box.colors.len <= 1) continue;
            if (box.r_max <= box.r_min and box.g_max <= box.g_min and box.b_max <= box.b_min) continue;

            const score = @as(u64, box.volume()) * @as(u64, box.population);
            if (score > largest_score) {
                largest_score = score;
                largest_idx = i;
            }
        }

        if (largest_idx == null) {
            break; // No more splittable boxes
        }

        // Split the largest box
        var box_to_split = boxes.orderedRemove(largest_idx.?);

        const dim = box_to_split.largestDimension();

        // Sort colors along the chosen dimension
        const SortContext = struct {
            dim: u8,
            pub fn lessThan(ctx: @This(), a: ColorCount, b: ColorCount) bool {
                return switch (ctx.dim) {
                    0 => a.r < b.r,
                    1 => a.g < b.g,
                    else => a.b < b.b,
                };
            }
        };

        std.sort.heap(ColorCount, box_to_split.colors, SortContext{ .dim = dim }, SortContext.lessThan);

        // Find median cut point (weighted by pixel count)
        var total_weight: u64 = 0;
        for (box_to_split.colors) |c| {
            total_weight += c.count;
        }

        const half_weight = total_weight / 2;
        var accumulated_weight: u64 = 0;
        var cut_point: usize = 0;

        for (box_to_split.colors, 0..) |c, i| {
            accumulated_weight += c.count;
            if (accumulated_weight >= half_weight) {
                cut_point = @max(1, @min(i + 1, box_to_split.colors.len - 1));
                break;
            }
        }

        // Create two new boxes
        var box1 = ColorBox{
            .colors = box_to_split.colors[0..cut_point],
            .r_min = 255,
            .r_max = 0,
            .g_min = 255,
            .g_max = 0,
            .b_min = 255,
            .b_max = 0,
            .population = 0,
        };

        var box2 = ColorBox{
            .colors = box_to_split.colors[cut_point..],
            .r_min = 255,
            .r_max = 0,
            .g_min = 255,
            .g_max = 0,
            .b_min = 255,
            .b_max = 0,
            .population = 0,
        };

        // Recalculate bounds for both boxes
        for (box1.colors) |c| {
            box1.r_min = @min(box1.r_min, c.r);
            box1.r_max = @max(box1.r_max, c.r);
            box1.g_min = @min(box1.g_min, c.g);
            box1.g_max = @max(box1.g_max, c.g);
            box1.b_min = @min(box1.b_min, c.b);
            box1.b_max = @max(box1.b_max, c.b);
            box1.population += c.count;
        }

        for (box2.colors) |c| {
            box2.r_min = @min(box2.r_min, c.r);
            box2.r_max = @max(box2.r_max, c.r);
            box2.g_min = @min(box2.g_min, c.g);
            box2.g_max = @max(box2.g_max, c.g);
            box2.b_min = @min(box2.b_min, c.b);
            box2.b_max = @max(box2.b_max, c.b);
            box2.population += c.count;
        }

        if (box1.colors.len > 0 and box1.r_max >= box1.r_min) {
            try boxes.append(box1);
        }

        if (box2.colors.len > 0 and box2.r_max >= box2.r_min) {
            try boxes.append(box2);
        }
    }

    // Generate final palette from boxes (weighted average)
    const actual_size = @min(boxes.items.len, palette.len);
    for (boxes.items[0..actual_size], 0..) |box, i| {
        var r_sum: u64 = 0;
        var g_sum: u64 = 0;
        var b_sum: u64 = 0;
        var weight_sum: u64 = 0;

        for (box.colors) |c| {
            r_sum += @as(u64, c.r) * @as(u64, c.count);
            g_sum += @as(u64, c.g) * @as(u64, c.count);
            b_sum += @as(u64, c.b) * @as(u64, c.count);
            weight_sum += c.count;
        }

        if (weight_sum > 0) {
            palette[i] = .{
                .r = @intCast(@divTrunc(r_sum, weight_sum)),
                .g = @intCast(@divTrunc(g_sum, weight_sum)),
                .b = @intCast(@divTrunc(b_sum, weight_sum)),
            };
        } else {
            // Fallback to center of box if no weight
            palette[i] = .{
                .r = (box.r_min + box.r_max) / 2,
                .g = (box.g_min + box.g_max) / 2,
                .b = (box.b_min + box.b_max) / 2,
            };
        }
    }

    return actual_size;
}

/// Checks if the terminal supports sixel graphics
pub fn isSupported() bool {
    // Check if we're connected to a terminal
    if (!TerminalSupport.isStdoutTty()) {
        // Not a TTY, allow sixel for file output
        return true;
    }

    // We're in a terminal, so perform actual detection
    var terminal = TerminalSupport.init() catch return false;
    defer terminal.deinit();

    return terminal.detectSixelSupport() catch false;
}

test "basic sixel encoding - 2x2 image" {
    const allocator = std.testing.allocator;

    // Create a 2x2 test image with distinct colors
    var img = try Image(Rgb).initAlloc(allocator, 2, 2);
    defer img.deinit(allocator);

    img.at(0, 0).* = .{ .r = 255, .g = 0, .b = 0 }; // Red
    img.at(0, 1).* = .{ .r = 0, .g = 255, .b = 0 }; // Green
    img.at(1, 0).* = .{ .r = 0, .g = 0, .b = 255 }; // Blue
    img.at(1, 1).* = .{ .r = 255, .g = 255, .b = 0 }; // Yellow

    const sixel_data = try fromImage(Rgb, img, allocator, .{
        .palette = .fixed_6x7x6,
        .dither = .none,
        .max_width = 100,
        .max_height = 100,
    });
    defer allocator.free(sixel_data);

    // Verify sixel starts with DCS sequence
    try expect(std.mem.startsWith(u8, sixel_data, "\x1bP"));

    // Verify sixel ends with ST sequence
    try expect(std.mem.endsWith(u8, sixel_data, "\x1b\\"));

    // Verify it contains raster attributes (width;height)
    try expect(std.mem.indexOf(u8, sixel_data, "\"") != null);
}

test "basic sixel encoding - verify palette format" {
    const allocator = std.testing.allocator;

    // Create a 4x4 test image
    var img = try Image(Rgb).initAlloc(allocator, 4, 4);
    defer img.deinit(allocator);

    // Fill with a single color to ensure it appears in palette
    for (0..4) |r| {
        for (0..4) |c| {
            img.at(r, c).* = .{ .r = 128, .g = 64, .b = 192 };
        }
    }

    const sixel_data = try fromImage(Rgb, img, allocator, .{
        .palette = .{ .adaptive = .{ .max_colors = 16 } },
        .dither = .none,
        .max_width = 100,
        .max_height = 100,
    });
    defer allocator.free(sixel_data);

    // Verify palette entry format #P;R;G;B
    try expect(std.mem.indexOf(u8, sixel_data, "#") != null);
}

test "palette mode - fixed 6x7x6 color mapping" {
    const allocator = std.testing.allocator;

    // Create image with colors that map to specific palette indices
    var img = try Image(Rgb).initAlloc(allocator, 1, 3);
    defer img.deinit(allocator);

    // Colors chosen to map to specific 6x7x6 palette entries
    img.at(0, 0).* = .{ .r = 0, .g = 0, .b = 0 }; // Black - index 0
    img.at(0, 1).* = .{ .r = 255, .g = 255, .b = 255 }; // White - last index
    img.at(0, 2).* = .{ .r = 255, .g = 0, .b = 0 }; // Red

    const sixel_data = try fromImage(Rgb, img, allocator, .{
        .palette = .fixed_6x7x6,
        .dither = .none,
        .max_width = 100,
        .max_height = 100,
    });
    defer allocator.free(sixel_data);

    // Basic validation - should have palette entries
    try expect(sixel_data.len > 0);
    try expect(std.mem.indexOf(u8, sixel_data, "#0;2;0;0;0") != null); // Black
}

test "palette mode - adaptive with color reduction" {
    const allocator = std.testing.allocator;

    // Create image with 8 distinct colors
    var img = try Image(Rgb).initAlloc(allocator, 4, 4);
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
    const sixel_data = try fromImage(Rgb, img, allocator, .{
        .palette = .{ .adaptive = .{ .max_colors = 4 } },
        .dither = .none,
        .max_width = 100,
        .max_height = 100,
    });
    defer allocator.free(sixel_data);

    // Should have at most 4 colors in palette (0-3)
    try expect(std.mem.indexOf(u8, sixel_data, "#0;") != null);
    // Should not have color index 4 or higher
    try expect(std.mem.indexOf(u8, sixel_data, "#4;") == null);
}

test "edge case - single pixel image" {
    const allocator = std.testing.allocator;

    var img = try Image(Rgb).initAlloc(allocator, 1, 1);
    defer img.deinit(allocator);

    img.at(0, 0).* = .{ .r = 128, .g = 128, .b = 128 };

    const sixel_data = try fromImage(Rgb, img, allocator, .{
        .palette = .fixed_web216,
        .dither = .none,
        .max_width = 100,
        .max_height = 100,
    });
    defer allocator.free(sixel_data);

    // Should produce valid sixel with proper structure
    try expect(std.mem.startsWith(u8, sixel_data, "\x1bP"));
    try expect(std.mem.endsWith(u8, sixel_data, "\x1b\\"));
    try expect(std.mem.indexOf(u8, sixel_data, "\"1;1;") != null);
}

test "edge case - uniform color image" {
    const allocator = std.testing.allocator;

    var img = try Image(Rgb).initAlloc(allocator, 8, 8);
    defer img.deinit(allocator);

    // Fill entire image with same color
    const uniform_color = Rgb{ .r = 64, .g = 128, .b = 192 };
    for (0..img.rows) |r| {
        for (0..img.cols) |c| {
            img.at(r, c).* = uniform_color;
        }
    }

    const sixel_data = try fromImage(Rgb, img, allocator, .{
        .palette = .{ .adaptive = .{ .max_colors = 256 } },
        .dither = .none,
        .max_width = 100,
        .max_height = 100,
    });
    defer allocator.free(sixel_data);

    // Should have only one color in adaptive palette
    try expect(std.mem.indexOf(u8, sixel_data, "#0;") != null);
    try expect(std.mem.indexOf(u8, sixel_data, "#1;") == null);
}
