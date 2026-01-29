//! Sixel graphics protocol support for image rendering
//!
//! This module provides functionality to convert images to sixel format,
//! which is supported by various terminal emulators for displaying graphics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expect = std.testing.expect;
const clamp = std.math.clamp;

const convertColor = @import("color.zig").convertColor;
const Image = @import("image.zig").Image;
const Interpolation = @import("image/interpolation.zig").Interpolation;
const meta = @import("meta.zig");
const rle = @import("rle.zig");
const terminal = @import("terminal.zig");

const Rgb = @import("color.zig").Rgb(u8);
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
    /// Ordered dithering (Bayer 8x8 matrix), faster and parallelizable
    ordered,
    /// Automatic heuristics based on palette size and image dimensions
    auto,
};

/// Options for sixel encoding
pub const Options = struct {
    /// Palette generation mode
    palette: PaletteMode,
    /// Dithering algorithm to use
    dither: DitherMode,
    /// Target width (image will be scaled to fit, preserving aspect ratio)
    /// If null, original width is preserved
    width: ?u32,
    /// Target height (image will be scaled to fit, preserving aspect ratio)
    /// If null, original height is preserved
    height: ?u32,
    /// Interpolation method to use when scaling the image
    interpolation: Interpolation = .nearest_neighbor,

    /// Default options for automatic formatting
    pub const default: Options = .{
        .palette = .{ .adaptive = .{ .max_colors = 256 } },
        .dither = .auto,
        .width = null,
        .height = null,
        .interpolation = .nearest_neighbor,
    };
    /// Fallback options without dithering
    pub const fallback: Options = .{
        .palette = .{ .adaptive = .{ .max_colors = 256 } },
        .dither = .none,
        .width = null,
        .height = null,
        .interpolation = .nearest_neighbor,
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
    const instant = std.time.Instant.now() catch {
        return 0;
    };

    if (@TypeOf(instant.timestamp) == u64) {
        return instant.timestamp;
    }

    const ts = instant.timestamp;
    const seconds: u128 = @intCast(ts.sec);
    const nanoseconds: u128 = @intCast(ts.nsec);
    const total = seconds * @as(u128, std.time.ns_per_s) + nanoseconds;
    return @truncate(total);
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

    // Calculate scaling if needed
    var width = image.cols;
    var height = image.rows;
    const scale = terminal.aspectScale(options.width, options.height, image.rows, image.cols);
    if (@abs(scale - 1.0) > 1e-5) {
        width = @intFromFloat(@as(f32, @floatFromInt(width)) * scale);
        height = @intFromFloat(@as(f32, @floatFromInt(height)) * scale);
    }

    // Prepare palette based on mode
    var palette: [256]Rgb = undefined;
    var palette_size: usize = options.palette.size();

    var palette_start: u64 = 0;
    if (profiler != null) palette_start = monotonicNs();

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
            palette_size = generateAdaptivePalette(T, gpa, image, &palette, adaptive_opts.max_colors) catch blk: {
                generateFixed6x7x6Palette(&palette);
                break :blk 252;
            };
        },
    }

    if (profiler) |p| {
        p.palette_ns += monotonicNs() - palette_start;
    }

    // Build lookup table for all palettes
    var lut_start: u64 = 0;
    if (profiler != null) lut_start = monotonicNs();
    const color_lut = ColorLookupTable.cache.get(options.palette, palette[0..palette_size]);
    if (profiler) |p| {
        p.lut_ns += monotonicNs() - lut_start;
    }

    // Determine dithering mode
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

    // Prepare image for fast sampling and optional dithering
    const is_rgb = comptime std.meta.eql(@typeInfo(T), @typeInfo(Rgb));
    const need_prepared_image = dither_mode != .none or scale != 1.0 or !is_rgb;

    var prepared_img_opt: ?Image(Rgb) = null;
    var prepared_img_ptr: ?*Image(Rgb) = null;
    defer if (prepared_img_opt) |*img| img.deinit(gpa);

    if (need_prepared_image) {
        var convert_start: u64 = 0;
        if (profiler != null) convert_start = monotonicNs();

        if (scale == 1.0) {
            prepared_img_opt = try image.convert(Rgb, gpa);
        } else {
            var scaled_img = try Image(Rgb).init(gpa, height, width);
            const inv_scale = 1.0 / scale;

            for (0..height) |row_idx| {
                const src_y = @as(f32, @floatFromInt(row_idx)) * inv_scale;
                for (0..width) |col_idx| {
                    const src_x = @as(f32, @floatFromInt(col_idx)) * inv_scale;

                    const rgb_value = blk: {
                        if (image.interpolate(src_x, src_y, options.interpolation)) |pixel| {
                            break :blk convertColor(Rgb, pixel);
                        }

                        // Fallback to clamped nearest-neighbor sample to avoid leaving pixels uninitialized.
                        const clamped_col: isize = clamp(
                            @as(isize, @intFromFloat(@round(src_x))),
                            0,
                            @as(isize, @intCast(image.cols - 1)),
                        );
                        const clamped_row: isize = clamp(
                            @as(isize, @intFromFloat(@round(src_y))),
                            0,
                            @as(isize, @intCast(image.rows - 1)),
                        );
                        const fallback_pixel = image.at(@intCast(clamped_row), @intCast(clamped_col)).*;
                        break :blk convertColor(Rgb, fallback_pixel);
                    };

                    scaled_img.at(row_idx, col_idx).* = rgb_value;
                }
            }

            prepared_img_opt = scaled_img;
        }

        if (profiler) |p| {
            p.scale_convert_ns += monotonicNs() - convert_start;
        }

        if (prepared_img_opt) |*img| {
            prepared_img_ptr = img;
        }
    }

    if (dither_mode != .none) {
        var dither_start: u64 = 0;
        if (profiler != null) dither_start = monotonicNs();

        const working_img = prepared_img_ptr orelse unreachable;

        switch (dither_mode) {
            .floyd_steinberg => applyErrorDiffusion(working_img.*, palette[0..palette_size], color_lut, floyd_steinberg_config),
            .atkinson => applyErrorDiffusion(working_img.*, palette[0..palette_size], color_lut, atkinson_config),
            .ordered => applyOrderedDither(working_img.*, palette[0..palette_size], color_lut),
            else => {},
        }

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

    // Define palette - unified approach

    var palette_emit_start: u64 = 0;
    if (profiler != null) palette_emit_start = monotonicNs();

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
        try output.print(gpa, "#{d};2;{d};{d};{d}", .{ i, r_val, g_val, b_val });
    }

    if (profiler) |p| {
        p.palette_emit_ns += monotonicNs() - palette_emit_start;
    }

    // Encode pixels as sixels
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

        // Prepare row slices for fast access
        var row_slices: [6][]const Rgb = undefined;
        const limit = @min(6, height - row);

        for (0..limit) |i| {
            const r = row + i;
            if (prepared_img_ptr) |ptr| {
                const offset = r * ptr.stride;
                row_slices[i] = ptr.data[offset .. offset + ptr.cols];
            } else {
                if (comptime is_rgb) {
                    const offset = r * image.stride;
                    row_slices[i] = image.data[offset .. offset + image.cols];
                }
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

        var current_color: usize = std.math.maxInt(usize);
        for (0..palette_size) |c| {
            if (!colors_used[c]) continue;

            if (c != current_color) {
                current_color = c;
                try output.print(gpa, "#{d}", .{current_color});
            }

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

    // End sixel sequence with ST
    try output.appendSlice(gpa, "\x1b\\");

    if (profiler) |p| {
        p.encode_ns += monotonicNs() - encode_start;
        p.total_ns = monotonicNs() - total_start;
    }

    return output.toOwnedSlice(gpa);
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

    /// Creates and initializes a color lookup table for the given palette
    fn init(palette: []const Rgb) ColorLookupTable {
        var self: ColorLookupTable = undefined;
        const LUT_SIZE = @as(usize, 1) << color_quantize_bits;

        // Flatten palette for SIMD processing
        var pal_r: [256]i32 = undefined;
        var pal_g: [256]i32 = undefined;
        var pal_b: [256]i32 = undefined;

        for (palette, 0..) |c, i| {
            pal_r[i] = c.r;
            pal_g[i] = c.g;
            pal_b[i] = c.b;
        }

        for (0..LUT_SIZE) |r| {
            for (0..LUT_SIZE) |g| {
                for (0..LUT_SIZE) |b| {
                    const rgb = Rgb{
                        .r = @intCast(r << (8 - color_quantize_bits) | (r >> (2 * color_quantize_bits - 8))),
                        .g = @intCast(g << (8 - color_quantize_bits) | (g >> (2 * color_quantize_bits - 8))),
                        .b = @intCast(b << (8 - color_quantize_bits) | (b >> (2 * color_quantize_bits - 8))),
                    };
                    self.table[r][g][b] = findNearestColorSIMD(palette.len, &pal_r, &pal_g, &pal_b, rgb);
                }
            }
        }
        return self;
    }

    /// Finds the nearest color in a palette to the target color using SIMD
    fn findNearestColorSIMD(
        len: usize,
        pal_r: *const [256]i32,
        pal_g: *const [256]i32,
        pal_b: *const [256]i32,
        target: Rgb,
    ) u8 {
        const VecWidth = 16;
        const V = @Vector(VecWidth, i32);

        const tr = @as(i32, target.r);
        const tg = @as(i32, target.g);
        const tb = @as(i32, target.b);

        const v_tr: V = @splat(tr);
        const v_tg: V = @splat(tg);
        const v_tb: V = @splat(tb);

        // Track min distance and index.
        // We pack distance (upper bits) and index (lower 8 bits) into a u32 score.
        var best_score: u32 = std.math.maxInt(u32);

        // Pre-compute base indices: [0, 1, 2, ..., 15]
        const iota: V = blk: {
            var idxs: [VecWidth]i32 = undefined;
            for (0..VecWidth) |k| idxs[k] = @intCast(k);
            break :blk idxs;
        };

        var i: usize = 0;

        // Main SIMD loop
        while (i + VecWidth <= len) : (i += VecWidth) {
            const vr: V = pal_r[i..][0..VecWidth].*;
            const vg: V = pal_g[i..][0..VecWidth].*;
            const vb: V = pal_b[i..][0..VecWidth].*;

            const dr = vr - v_tr;
            const dg = vg - v_tg;
            const db = vb - v_tb;

            const dist = dr * dr + dg * dg + db * db;

            // Calculate current indices
            const indices: V = iota + @as(V, @splat(@intCast(i)));

            // Pack score: (dist << 8) | index
            const score = (@as(@Vector(VecWidth, u32), @bitCast(dist)) << @as(@Vector(VecWidth, u5), @splat(8))) | @as(@Vector(VecWidth, u32), @bitCast(indices));

            const min_vec_score = @reduce(.Min, score);
            if (min_vec_score < best_score) {
                best_score = min_vec_score;
            }
        }

        // Scalar tail loop
        while (i < len) : (i += 1) {
            const dr = pal_r[i] - tr;
            const dg = pal_g[i] - tg;
            const db = pal_b[i] - tb;
            const dist = dr * dr + dg * dg + db * db;
            const score = (@as(u32, @intCast(dist)) << 8) | @as(u32, @intCast(i));
            if (score < best_score) {
                best_score = score;
            }
        }

        return @intCast(best_score & 0xFF);
    }

    /// Looks up the palette index for the given RGB color.
    /// The color is quantized to 5-bit precision per channel before lookup.
    /// Returns the index of the nearest palette color that was precomputed during init.
    fn lookup(self: ColorLookupTable, rgb: Rgb) u8 {
        // Quantize to 5-bit per channel
        const r5 = rgb.r >> (8 - color_quantize_bits);
        const g5 = rgb.g >> (8 - color_quantize_bits);
        const b5 = rgb.b >> (8 - color_quantize_bits);
        return self.table[r5][g5][b5];
    }

    const cache = struct {
        var mutex = std.Thread.Mutex{};
        var fixed_6x7x6: ?ColorLookupTable = null;
        var fixed_vga16: ?ColorLookupTable = null;
        var fixed_web216: ?ColorLookupTable = null;

        fn getOrInit(cache_field: *?ColorLookupTable, palette: []const Rgb) ColorLookupTable {
            cache.mutex.lock();
            defer cache.mutex.unlock();

            if (cache_field.*) |cached| {
                return cached;
            }
            const lut: ColorLookupTable = .init(palette);
            cache_field.* = lut;
            return lut;
        }

        pub fn get(mode: PaletteMode, palette: []const Rgb) ColorLookupTable {
            return switch (mode) {
                .fixed_6x7x6 => getOrInit(&cache.fixed_6x7x6, palette),
                .fixed_vga16 => getOrInit(&cache.fixed_vga16, palette),
                .fixed_web216 => getOrInit(&cache.fixed_web216, palette),
                .adaptive => .init(palette),
            };
        }
    };
};

const AdaptiveHistogramPool = struct {
    const Node = struct {
        counts: []u32,
        stamps: []u32,
        generation: u32,
        next: ?*Node = null,
    };

    pub const Handle = struct {
        counts: []u32,
        stamps: []u32,
        generation: u32,
        /// Internal pointer used for pool management.
        node: *Node,
    };

    var mutex = std.Thread.Mutex{};
    var available: ?*Node = null;

    fn acquire() !Handle {
        mutex.lock();
        if (available) |node| {
            available = node.next;
            mutex.unlock();

            node.generation +%= 1;
            if (node.generation == 0) {
                @memset(node.stamps, 0);
                node.generation = 1;
            }

            return .{
                .counts = node.counts,
                .stamps = node.stamps,
                .generation = node.generation,
                .node = node,
            };
        }
        mutex.unlock();

        // Allocate new buffer
        const allocator = std.heap.page_allocator;
        const required_len: usize = @as(usize, 1) << (3 * color_quantize_bits);

        const counts = try allocator.alloc(u32, required_len);
        errdefer allocator.free(counts);
        const stamps = try allocator.alloc(u32, required_len);
        errdefer allocator.free(stamps);
        @memset(stamps, 0);

        const node = try allocator.create(Node);
        node.* = .{
            .counts = counts,
            .stamps = stamps,
            .generation = 1,
            .next = null,
        };

        return .{
            .counts = node.counts,
            .stamps = node.stamps,
            .generation = node.generation,
            .node = node,
        };
    }

    fn release(handle: Handle) void {
        mutex.lock();
        defer mutex.unlock();
        handle.node.next = available;
        available = handle.node;
    }
};

fn acquireAdaptiveHistogram() !AdaptiveHistogramPool.Handle {
    return AdaptiveHistogramPool.acquire();
}

fn releaseAdaptiveHistogram(handle: AdaptiveHistogramPool.Handle) void {
    AdaptiveHistogramPool.release(handle);
}

inline fn divTruncPow2(value: i32, shift: u3) i32 {
    if (shift == 0) return value;
    if (value >= 0) {
        return value >> shift;
    }
    const d: i32 = @as(i32, 1) << shift;
    return (value + d - 1) >> shift;
}

inline fn clampToU8(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

/// Error diffusion dithering configuration
const DitherEntry = struct {
    dx: i16,
    dy: i16,
    weight: i16,
    divisor_shift: u3,
};

const DitherConfig = struct {
    mode: DitherMode,
    distributions: []const DitherEntry,
};

// Floyd-Steinberg error distribution:
//          X   7/16
//  3/16  5/16  1/16
const floyd_steinberg_config = DitherConfig{
    .mode = .floyd_steinberg,
    .distributions = &[_]DitherEntry{
        .{ .dx = 1, .dy = 0, .weight = 7, .divisor_shift = 4 }, // right
        .{ .dx = -1, .dy = 1, .weight = 3, .divisor_shift = 4 }, // bottom-left
        .{ .dx = 0, .dy = 1, .weight = 5, .divisor_shift = 4 }, // bottom
        .{ .dx = 1, .dy = 1, .weight = 1, .divisor_shift = 4 }, // bottom-right
    },
};

// Atkinson error distribution (only 75% of error is diffused):
//          X   1/8  1/8
//   1/8   1/8  1/8
//         1/8
const atkinson_config = DitherConfig{
    .mode = .atkinson,
    .distributions = &[_]DitherEntry{
        .{ .dx = 1, .dy = 0, .weight = 1, .divisor_shift = 3 }, // right
        .{ .dx = 2, .dy = 0, .weight = 1, .divisor_shift = 3 }, // right+1
        .{ .dx = -1, .dy = 1, .weight = 1, .divisor_shift = 3 }, // bottom-left
        .{ .dx = 0, .dy = 1, .weight = 1, .divisor_shift = 3 }, // bottom
        .{ .dx = 1, .dy = 1, .weight = 1, .divisor_shift = 3 }, // bottom-right
        .{ .dx = 0, .dy = 2, .weight = 1, .divisor_shift = 3 }, // bottom+1
    },
};

/// Bayer 8x8 ordered dithering matrix
const bayer8x8 = [8][8]i32{
    .{ 0, 32, 8, 40, 2, 34, 10, 42 },
    .{ 48, 16, 56, 24, 50, 18, 58, 26 },
    .{ 12, 44, 4, 36, 14, 46, 6, 38 },
    .{ 60, 28, 52, 20, 62, 30, 54, 22 },
    .{ 3, 35, 11, 43, 1, 33, 9, 41 },
    .{ 51, 19, 59, 27, 49, 17, 57, 25 },
    .{ 15, 47, 7, 39, 13, 45, 5, 37 },
    .{ 63, 31, 55, 23, 61, 29, 53, 21 },
};

/// Applies ordered dithering using a Bayer matrix
fn applyOrderedDither(
    img: Image(Rgb),
    pal: []const Rgb,
    lut: ColorLookupTable,
) void {
    const rows = img.rows;
    const cols = img.cols;
    const stride = img.stride;

    const T = @TypeOf(img.data[0].r);
    comptime assert(T == u8); // Sixel pipeline is currently u8-only

    // Scale factor for dithering strength.
    // The matrix values are 0..63. We center them at 0 (-32..31) and scale.
    // A spread of ~16-32 is usually good for 8-bit color.
    // Optimized for spread=16 (shift by 1)

    // Check if we can use SIMD (Rgb must be 3 bytes packed)
    const can_simd = comptime @sizeOf(Rgb) == 3;

    for (0..rows) |r| {
        const row_offset = r * stride;
        const row_slice = img.data[row_offset .. row_offset + cols];
        const bayer_row = &bayer8x8[r & 7];

        // Pre-compute offsets for the current row to avoid repeated calculation
        var offsets: [8]i32 = undefined;
        for (0..8) |i| {
            offsets[i] = (bayer_row[i] - 32) >> 1;
        }

        var c: usize = 0;

        if (can_simd) {
            // Build SIMD offset vector (8 pixels * 3 channels = 24 values)
            // Offsets are broadcast to R, G, B components
            var offset_arr: [24]i16 = undefined;
            inline for (0..8) |i| {
                const val: i16 = @intCast(offsets[i]);
                offset_arr[i * 3] = val;
                offset_arr[i * 3 + 1] = val;
                offset_arr[i * 3 + 2] = val;
            }
            const offset_vec: @Vector(24, i16) = offset_arr;
            const min_vec: @Vector(24, i16) = @splat(0);
            const max_vec: @Vector(24, i16) = @splat(255);

            // SIMD Loop: Process 8 pixels (24 bytes) at a time
            while (cols >= 8 and c <= cols - 8) : (c += 8) {
                // 1. Load 8 pixels (24 bytes)
                const ptr = @as([*]const u8, @ptrCast(row_slice.ptr)) + c * 3;
                const pixels_u8: @Vector(24, u8) = ptr[0..24].*;

                // 2. Add offsets (widen to i16)
                const pixels_i16 = @as(@Vector(24, i16), pixels_u8);
                const result_i16 = pixels_i16 + offset_vec;

                // 3. Clamp
                const clamped = @min(@max(result_i16, min_vec), max_vec);

                // 4. Narrow back to u8 AND pre-quantize for lookup (shift right by 3)
                // We do the shift here in SIMD to save 24 shifts in the scalar loop
                const result_u8 = @as(@Vector(24, u8), @intCast(clamped));
                const quantized_vec = result_u8 >> @as(@Vector(24, u3), @splat(8 - color_quantize_bits));
                const q_arr: [24]u8 = quantized_vec;

                // 5. Lookup and store (scalar part) using pre-quantized values
                for (0..8) |k| {
                    const r5 = q_arr[k * 3];
                    const g5 = q_arr[k * 3 + 1];
                    const b5 = q_arr[k * 3 + 2];
                    const idx = lut.table[r5][g5][b5];
                    row_slice[c + k] = pal[idx];
                }
            }
        } else {
            // Scalar unrolled loop for non-packed structures
            while (cols >= 8 and c <= cols - 8) : (c += 8) {
                inline for (0..8) |k| {
                    var pixel = row_slice[c + k];
                    const offset = offsets[k];

                    const r5 = meta.clamp(u8, @as(i32, pixel.r) + offset) >> (8 - color_quantize_bits);
                    const g5 = meta.clamp(u8, @as(i32, pixel.g) + offset) >> (8 - color_quantize_bits);
                    const b5 = meta.clamp(u8, @as(i32, pixel.b) + offset) >> (8 - color_quantize_bits);

                    const idx = lut.table[r5][g5][b5];
                    row_slice[c + k] = pal[idx];
                }
            }
        }

        // Handle remaining pixels
        while (c < cols) : (c += 1) {
            var pixel = row_slice[c];
            const offset = offsets[c & 7];

            const r5 = meta.clamp(u8, @as(i32, pixel.r) + offset) >> (8 - color_quantize_bits);
            const g5 = meta.clamp(u8, @as(i32, pixel.g) + offset) >> (8 - color_quantize_bits);
            const b5 = meta.clamp(u8, @as(i32, pixel.b) + offset) >> (8 - color_quantize_bits);

            const idx = lut.table[r5][g5][b5];
            row_slice[c] = pal[idx];
        }
    }
}

/// Unified error diffusion dithering implementation
fn applyErrorDiffusion(
    img: Image(Rgb),
    pal: []const Rgb,
    lut: ColorLookupTable,
    config: DitherConfig,
) void {
    const rows = img.rows;
    const cols = img.cols;
    const stride = img.stride;
    const rows_isize: isize = @intCast(rows);
    const cols_isize: isize = @intCast(cols);

    const T = @TypeOf(img.data[0].r);
    comptime assert(T == u8); // Sixel pipeline is currently u8-only

    // Helper for updating a pixel
    const updatePixel = struct {
        inline fn call(ptr: *Rgb, r_err: i16, g_err: i16, b_err: i16, weight: i32, shift: u3) void {
            ptr.r = clampToU8(@as(i32, ptr.r) + divTruncPow2(@as(i32, r_err) * weight, shift));
            ptr.g = clampToU8(@as(i32, ptr.g) + divTruncPow2(@as(i32, g_err) * weight, shift));
            ptr.b = clampToU8(@as(i32, ptr.b) + divTruncPow2(@as(i32, b_err) * weight, shift));
        }
    }.call;

    switch (config.mode) {
        .floyd_steinberg => {
            // Optimized Floyd-Steinberg loop
            for (0..rows) |r| {
                const row_offset = r * stride;
                const row_slice = img.data[row_offset .. row_offset + cols];
                const is_safe_row = r < rows - 1;

                for (0..cols) |c| {
                    const current = row_slice[c];
                    const idx = lut.lookup(current);
                    const quantized = pal[idx];
                    row_slice[c] = quantized;

                    const r_err = @as(i16, current.r) - @as(i16, quantized.r);
                    const g_err = @as(i16, current.g) - @as(i16, quantized.g);
                    const b_err = @as(i16, current.b) - @as(i16, quantized.b);

                    // Safe path (center of image)
                    if (is_safe_row and c > 0 and c < cols - 1) {
                        const next_row_offset = (r + 1) * stride;
                        updatePixel(&img.data[row_offset + c + 1], r_err, g_err, b_err, 7, 4);
                        updatePixel(&img.data[next_row_offset + c - 1], r_err, g_err, b_err, 3, 4);
                        updatePixel(&img.data[next_row_offset + c], r_err, g_err, b_err, 5, 4);
                        updatePixel(&img.data[next_row_offset + c + 1], r_err, g_err, b_err, 1, 4);
                    } else {
                        // Boundary path
                        for (config.distributions) |dist| {
                            const nc_signed = @as(isize, @intCast(c)) + dist.dx;
                            const nr_signed = @as(isize, @intCast(r)) + dist.dy;
                            if (nr_signed >= 0 and nr_signed < rows_isize and nc_signed >= 0 and nc_signed < cols_isize) {
                                const neighbor_idx = @as(usize, @intCast(nr_signed)) * stride + @as(usize, @intCast(nc_signed));
                                updatePixel(&img.data[neighbor_idx], r_err, g_err, b_err, dist.weight, dist.divisor_shift);
                            }
                        }
                    }
                }
            }
        },
        .atkinson => {
            // Optimized Atkinson loop
            for (0..rows) |r| {
                const row_offset = r * stride;
                const row_slice = img.data[row_offset .. row_offset + cols];
                const is_safe_row = r < rows - 2;

                for (0..cols) |c| {
                    const current = row_slice[c];
                    const idx = lut.lookup(current);
                    const quantized = pal[idx];
                    row_slice[c] = quantized;

                    const r_err = @as(i16, current.r) - @as(i16, quantized.r);
                    const g_err = @as(i16, current.g) - @as(i16, quantized.g);
                    const b_err = @as(i16, current.b) - @as(i16, quantized.b);

                    if (is_safe_row and c > 0 and c < cols - 2) {
                        const r1_offset = (r + 1) * stride;
                        const r2_offset = (r + 2) * stride;
                        updatePixel(&img.data[row_offset + c + 1], r_err, g_err, b_err, 1, 3);
                        updatePixel(&img.data[row_offset + c + 2], r_err, g_err, b_err, 1, 3);
                        updatePixel(&img.data[r1_offset + c - 1], r_err, g_err, b_err, 1, 3);
                        updatePixel(&img.data[r1_offset + c], r_err, g_err, b_err, 1, 3);
                        updatePixel(&img.data[r1_offset + c + 1], r_err, g_err, b_err, 1, 3);
                        updatePixel(&img.data[r2_offset + c], r_err, g_err, b_err, 1, 3);
                    } else {
                        for (config.distributions) |dist| {
                            const nc_signed = @as(isize, @intCast(c)) + dist.dx;
                            const nr_signed = @as(isize, @intCast(r)) + dist.dy;
                            if (nr_signed >= 0 and nr_signed < rows_isize and nc_signed >= 0 and nc_signed < cols_isize) {
                                const neighbor_idx = @as(usize, @intCast(nr_signed)) * stride + @as(usize, @intCast(nc_signed));
                                updatePixel(&img.data[neighbor_idx], r_err, g_err, b_err, dist.weight, dist.divisor_shift);
                            }
                        }
                    }
                }
            }
        },
        else => {
            // Generic fallback
            for (0..rows) |r| {
                const row_offset = r * stride;
                const row_slice = img.data[row_offset .. row_offset + cols];
                for (0..cols) |c| {
                    const current = row_slice[c];
                    const idx = lut.lookup(current);
                    const quantized = pal[idx];
                    row_slice[c] = quantized;

                    const r_err = @as(i16, current.r) - @as(i16, quantized.r);
                    const g_err = @as(i16, current.g) - @as(i16, quantized.g);
                    const b_err = @as(i16, current.b) - @as(i16, quantized.b);

                    for (config.distributions) |dist| {
                        const nc_signed = @as(isize, @intCast(c)) + dist.dx;
                        const nr_signed = @as(isize, @intCast(r)) + dist.dy;
                        if (nr_signed >= 0 and nr_signed < rows_isize and nc_signed >= 0 and nc_signed < cols_isize) {
                            const neighbor_idx = @as(usize, @intCast(nr_signed)) * stride + @as(usize, @intCast(nc_signed));
                            updatePixel(&img.data[neighbor_idx], r_err, g_err, b_err, dist.weight, dist.divisor_shift);
                        }
                    }
                }
            }
        },
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
    gpa: Allocator,
    image: Image(T),
    palette: []Rgb,
    max_colors: u16,
) !usize {
    var color_list: std.ArrayList(ColorCount) = .empty;
    defer color_list.deinit(gpa);

    var touched_indices = try std.ArrayList(u16).initCapacity(gpa, 1024);
    defer touched_indices.deinit(gpa);

    const histogram_len = @as(usize, 1) << (3 * color_quantize_bits);
    const hist_handle_result = acquireAdaptiveHistogram();

    if (hist_handle_result) |hist_handle| {
        defer releaseAdaptiveHistogram(hist_handle);

        // Build histogram using reusable buffers with generation tracking
        if (image.stride == image.cols) {
            for (image.data) |pixel| {
                const rgb = convertColor(Rgb, pixel);

                const r5 = rgb.r >> (8 - color_quantize_bits);
                const g5 = rgb.g >> (8 - color_quantize_bits);
                const b5 = rgb.b >> (8 - color_quantize_bits);
                const key = (@as(u16, r5) << (2 * color_quantize_bits)) | (@as(u16, g5) << color_quantize_bits) | @as(u16, b5);
                const hist_index: usize = @intCast(key);

                if (hist_handle.stamps[hist_index] != hist_handle.generation) {
                    hist_handle.stamps[hist_index] = hist_handle.generation;
                    hist_handle.counts[hist_index] = 0;
                    try touched_indices.append(gpa, @intCast(hist_index));
                }
                hist_handle.counts[hist_index] += 1;
            }
        } else {
            for (0..image.rows) |r| {
                for (0..image.cols) |c| {
                    const pixel = image.at(r, c).*;
                    const rgb = convertColor(Rgb, pixel);

                    const r5 = rgb.r >> (8 - color_quantize_bits);
                    const g5 = rgb.g >> (8 - color_quantize_bits);
                    const b5 = rgb.b >> (8 - color_quantize_bits);
                    const key = (@as(u16, r5) << (2 * color_quantize_bits)) | (@as(u16, g5) << color_quantize_bits) | @as(u16, b5);
                    const hist_index: usize = @intCast(key);

                    if (hist_handle.stamps[hist_index] != hist_handle.generation) {
                        hist_handle.stamps[hist_index] = hist_handle.generation;
                        hist_handle.counts[hist_index] = 0;
                        try touched_indices.append(gpa, @intCast(hist_index));
                    }
                    hist_handle.counts[hist_index] += 1;
                }
            }
        }

        try color_list.ensureTotalCapacityPrecise(gpa, touched_indices.items.len);
        for (touched_indices.items) |key_u16| {
            const key = @as(usize, key_u16);
            const count = hist_handle.counts[key];
            if (count == 0) continue;

            const r5: u8 = @intCast((key >> (2 * color_quantize_bits)) & 0x1F);
            const g5: u8 = @intCast((key >> color_quantize_bits) & 0x1F);
            const b5: u8 = @intCast(key & 0x1F);

            const r8 = (r5 << (8 - color_quantize_bits)) | (r5 >> (2 * color_quantize_bits - 8));
            const g8 = (g5 << (8 - color_quantize_bits)) | (g5 >> (2 * color_quantize_bits - 8));
            const b8 = (b5 << (8 - color_quantize_bits)) | (b5 >> (2 * color_quantize_bits - 8));

            color_list.appendAssumeCapacity(.{
                .r = r8,
                .g = g8,
                .b = b8,
                .count = count,
            });
        }
    } else |_| {
        // Fallback: allocate temporary histogram and zero it
        var counts = try gpa.alloc(u32, histogram_len);
        defer gpa.free(counts);
        @memset(counts[0..histogram_len], 0);

        for (0..image.rows) |r| {
            for (0..image.cols) |c| {
                const pixel = image.at(r, c).*;
                const rgb = convertColor(Rgb, pixel);

                const r5 = rgb.r >> (8 - color_quantize_bits);
                const g5 = rgb.g >> (8 - color_quantize_bits);
                const b5 = rgb.b >> (8 - color_quantize_bits);
                const key = (@as(u16, r5) << (2 * color_quantize_bits)) | (@as(u16, g5) << color_quantize_bits) | @as(u16, b5);
                const hist_index: usize = @intCast(key);
                counts[hist_index] += 1;
            }
        }

        for (counts, 0..) |count, key_idx| {
            if (count == 0) continue;

            const key: u32 = @intCast(key_idx);
            const r5: u8 = @intCast((key >> (2 * color_quantize_bits)) & 0x1F);
            const g5: u8 = @intCast((key >> color_quantize_bits) & 0x1F);
            const b5: u8 = @intCast(key & 0x1F);

            const r8 = (r5 << (8 - color_quantize_bits)) | (r5 >> (2 * color_quantize_bits - 8));
            const g8 = (g5 << (8 - color_quantize_bits)) | (g5 >> (2 * color_quantize_bits - 8));
            const b8 = (b5 << (8 - color_quantize_bits)) | (b5 >> (2 * color_quantize_bits - 8));

            try color_list.append(gpa, .{
                .r = r8,
                .g = g8,
                .b = b8,
                .count = count,
            });
        }
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
    var boxes: std.ArrayList(ColorBox) = .empty;
    defer boxes.deinit(gpa);

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

    try boxes.append(gpa, initial_box);

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
            try boxes.append(gpa, box1);
        }

        if (box2.colors.len > 0 and box2.r_max >= box2.r_min) {
            try boxes.append(gpa, box2);
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
pub fn isSupported(io: std.Io) bool {
    // Check if we're connected to a terminal
    if (!terminal.isStdoutTty(io)) {
        // Not a TTY, allow sixel for file output
        return true;
    }

    // We're in a terminal, so perform actual detection
    return terminal.isSixelSupported(io) catch false;
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
