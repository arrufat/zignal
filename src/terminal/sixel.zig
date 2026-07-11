//! Sixel graphics protocol support for image rendering
//!
//! This module provides functionality to convert images to sixel format,
//! which is supported by various terminal emulators for displaying graphics.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const clamp = std.math.clamp;

const convertColor = @import("../color.zig").convertColor;
const Image = @import("../image.zig").Image;
const Interpolation = @import("../image/interpolation.zig").Interpolation;
const dither = @import("../image/dither.zig");
const quantize = @import("../image/quantize.zig");
const rle = @import("../rle.zig");
const detect = @import("detect.zig");

const Rgb = quantize.Rgb;
const sixel_char_offset: u8 = '?'; // ASCII 63 - base for sixel characters
const max_supported_width: usize = 2048;

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
    pub const default: Options = .{
        .palette = .{ .adaptive = .{ .max_colors = 256 } },
        .dither = .auto,
        .width = null,
        .height = null,
        .interpolation = .nearest,
    };
    /// Fallback options without dithering
    pub const fallback: Options = .{
        .palette = .{ .adaptive = .{ .max_colors = 256 } },
        .dither = .none,
        .width = null,
        .height = null,
        .interpolation = .nearest,
    };
};

/// Profiling metrics for sixel encoding. All values are measured in nanoseconds.
pub const Profile = struct {
    total_ns: u64 = 0,
    scale_convert_ns: u64 = 0,
    palette_ns: u64 = 0,
    lut_ns: u64 = 0,
    dither_ns: u64 = 0,
    palette_emit_ns: u64 = 0,
    encode_ns: u64 = 0,

    pub fn reset(self: *Profile) void {
        self.* = .{};
    }
};

inline fn monotonicNs() u64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        },
        .windows => {
            const kernel32 = struct {
                extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
            };
            return kernel32.GetTickCount64() * std.time.ns_per_ms;
        },
        .macos => {
            const mach = struct {
                const mach_timebase_info_data_t = extern struct {
                    numer: u32,
                    denom: u32,
                };
                extern "c" fn mach_absolute_time() u64;
                extern "c" fn mach_timebase_info(info: *mach_timebase_info_data_t) c_int;
            };
            var info: mach.mach_timebase_info_data_t = undefined;
            _ = mach.mach_timebase_info(&info);
            const time = mach.mach_absolute_time();
            return (time * info.numer) / info.denom;
        },
        else => return 0,
    }
}

// ========== Main Entry Point ==========

/// Converts an image to sixel format
pub fn fromImage(
    comptime T: type,
    image: Image(T),
    gpa: Allocator,
    options: Options,
) ![]u8 {
    return fromImageProfiled(T, image, gpa, options, null);
}

/// Converts an image to sixel format while capturing optional profiling data.
pub fn fromImageProfiled(
    comptime T: type,
    image: Image(T),
    gpa: Allocator,
    options: Options,
    profiler: ?*Profile,
) ![]u8 {
    var total_start: u64 = 0;
    if (profiler) |p| {
        p.reset();
        total_start = monotonicNs();
    }

    var width = image.cols;
    var height = image.rows;
    const scale = detect.aspectScale(options.width, options.height, image.rows, image.cols);
    if (@abs(scale - 1.0) > 1e-5) {
        width = @trunc(@as(f32, @floatFromInt(width)) * scale);
        height = @trunc(@as(f32, @floatFromInt(height)) * scale);
    }

    var palette: [256]Rgb = undefined;

    var palette_start: u64 = 0;
    if (profiler != null) palette_start = monotonicNs();

    const palette_size = quantize.buildPalette(T, gpa, image, options.palette, &palette);

    if (profiler) |p| {
        p.palette_ns += monotonicNs() - palette_start;
    }

    var lut_start: u64 = 0;
    if (profiler != null) lut_start = monotonicNs();
    const color_lut = quantize.getPaletteLut(options.palette, palette[0..palette_size]);
    if (profiler) |p| {
        p.lut_ns += monotonicNs() - lut_start;
    }

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

    const is_rgb = T == Rgb;
    const need_prepared_image = dither_mode != .none or scale != 1.0 or !is_rgb;

    var prepared_img: ?Image(Rgb) = null;
    defer if (prepared_img) |*img| img.deinit(gpa);

    if (need_prepared_image) {
        var convert_start: u64 = 0;
        if (profiler != null) convert_start = monotonicNs();

        if (scale == 1.0) {
            prepared_img = try image.convert(gpa, Rgb);
        } else {
            var scaled_img = try Image(Rgb).init(gpa, height, width);
            const inv_scale = 1.0 / scale;

            for (0..height) |row_idx| {
                const src_y = @as(f32, @floatFromInt(row_idx)) * inv_scale;
                for (0..width) |col_idx| {
                    const src_x = @as(f32, @floatFromInt(col_idx)) * inv_scale;

                    const rgb_value = blk: {
                        if (image.interpolate(src_x, src_y, options.interpolation, .mirror)) |pixel| {
                            break :blk convertColor(Rgb, pixel);
                        }

                        // Fallback to clamped nearest sample: interpolate can return null
                        // for non-finite or out-of-range coords beyond what `.mirror` covers.
                        const clamped_col: isize = clamp(
                            @as(isize, @round(src_x)),
                            0,
                            @as(isize, @intCast(image.cols - 1)),
                        );
                        const clamped_row: isize = clamp(
                            @as(isize, @round(src_y)),
                            0,
                            @as(isize, @intCast(image.rows - 1)),
                        );
                        const fallback_pixel = image.at(@intCast(clamped_row), @intCast(clamped_col)).*;
                        break :blk convertColor(Rgb, fallback_pixel);
                    };

                    scaled_img.at(row_idx, col_idx).* = rgb_value;
                }
            }

            prepared_img = scaled_img;
        }

        if (profiler) |p| {
            p.scale_convert_ns += monotonicNs() - convert_start;
        }
    }

    if (dither_mode != .none) {
        var dither_start: u64 = 0;
        if (profiler != null) dither_start = monotonicNs();

        if (prepared_img) |*working_img| {
            dither.apply(working_img.*, palette[0..palette_size], color_lut, dither_mode);
        } else unreachable;

        if (profiler) |p| {
            p.dither_ns += monotonicNs() - dither_start;
        }
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

    var palette_emit_start: u64 = 0;
    if (profiler != null) palette_emit_start = monotonicNs();

    for (palette[0..palette_size], 0..) |p, i| {
        const r_val = (@as(u32, p.r) * 100 + 127) / 255;
        const g_val = (@as(u32, p.g) * 100 + 127) / 255;
        const b_val = (@as(u32, p.b) * 100 + 127) / 255;
        try output.print(gpa, "#{d};2;{d};{d};{d}", .{ i, r_val, g_val, b_val });
    }

    if (profiler) |p| {
        p.palette_emit_ns += monotonicNs() - palette_emit_start;
    }

    var encode_start: u64 = 0;
    if (profiler != null) encode_start = monotonicNs();

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
        if (width > max_supported_width) {
            return error.ImageTooWide;
        }

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

                    if (!colors_used[color_idx]) {
                        colors_used[color_idx] = true;
                    }

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
                    const bits = column_bits[idx];
                    const offset = @as(usize, color_idx) * width + col;
                    color_map_storage[offset] = if (bits != 0) bits + sixel_char_offset else sixel_char_offset;
                    color_map_generation[offset] = row_generation;
                }
            }
        }

        for (0..palette_size) |c| {
            if (!colors_used[c]) continue;

            try output.print(gpa, "#{d}", .{c});

            var row_buffer: [max_supported_width]u8 = undefined;
            if (width > row_buffer.len) return error.ImageTooWide;

            @memset(row_buffer[0..width], sixel_char_offset);
            var effective_compression_end: usize = 0;
            if (width > 0) {
                var current_last_used_col: usize = 0;
                for (0..width) |col| {
                    const offset = c * width + col;
                    if (color_map_generation[offset] == row_generation) {
                        row_buffer[col] = color_map_storage[offset];
                        current_last_used_col = col;
                    }
                }
                if (current_last_used_col == 0 and row_buffer[0] == sixel_char_offset) {
                    effective_compression_end = 0;
                } else {
                    effective_compression_end = current_last_used_col + 1;
                }
            }

            var compressor: rle.Compressor(u8) = .{ .data = row_buffer[0..effective_compression_end] };
            while (compressor.next()) |entry| {
                if (entry.count > 3) {
                    try output.print(gpa, "!{d}{c}", .{ entry.count, entry.value });
                } else {
                    for (0..entry.count) |_| {
                        try output.append(gpa, entry.value);
                    }
                }
            }

            var more_colors = false;
            for (c + 1..palette_size) |nc| {
                if (colors_used[nc]) {
                    more_colors = true;
                    break;
                }
            }
            if (more_colors) {
                try output.appendSlice(gpa, "$");
            }
        }

        if (row + 6 < height) {
            try output.appendSlice(gpa, "-");
        }
    }

    try output.appendSlice(gpa, "\x1b\\");

    if (profiler) |p| {
        p.encode_ns += monotonicNs() - encode_start;
        p.total_ns = monotonicNs() - total_start;
    }

    return output.toOwnedSlice(gpa);
}

/// Checks if the terminal supports sixel graphics
pub fn isSupported(io: std.Io) bool {
    // Not a TTY → assume sixel is fine (file output, e.g. piping to a sixel viewer).
    if (!detect.isStdoutTty(io)) return true;
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

    const sixel_data = try fromImage(Rgb, img, allocator, .{
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

    const sixel_data = try fromImage(Rgb, img, allocator, .{
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

    const sixel_data = try fromImage(Rgb, img, allocator, .{
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
    const sixel_data = try fromImage(Rgb, img, allocator, .{
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

    const sixel_data = try fromImage(Rgb, img, allocator, .{
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

    const sixel_data = try fromImage(Rgb, img, allocator, .{
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
