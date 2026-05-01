//! Dithering algorithms shared by sixel, kitty, and GIF codecs.
//!
//! All algorithms operate in place on `Image(Rgb)` and quantize each pixel to the
//! nearest color in the supplied palette via the precomputed `ColorLookupTable`.

const std = @import("std");
const assert = std.debug.assert;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const quantize = @import("quantize.zig");

const Rgb = quantize.Rgb;
const ColorLookupTable = quantize.ColorLookupTable;
const color_quantize_bits = quantize.color_quantize_bits;

/// Dithering algorithm choice.
pub const Mode = enum {
    /// No dithering, direct color quantization.
    none,
    /// Floyd–Steinberg error diffusion dithering.
    floyd_steinberg,
    /// Atkinson dithering (used by the original Macintosh — only 75% of error is diffused).
    atkinson,
    /// Ordered dithering using an 8x8 Bayer matrix; faster and parallelizable.
    ordered,
    /// Automatic heuristic — caller must resolve to a concrete mode before invoking
    /// `apply` / `applyOrdered` / `applyErrorDiffusion`.
    auto,
};

/// In-place dither over `img`, replacing each pixel with the nearest palette entry.
/// Caller is expected to resolve `Mode.auto` to a concrete mode before calling.
pub fn apply(img: Image(Rgb), palette: []const Rgb, lut: ColorLookupTable, mode: Mode) void {
    switch (mode) {
        .none, .auto => {},
        .floyd_steinberg => applyErrorDiffusion(img, palette, lut, floyd_steinberg_config),
        .atkinson => applyErrorDiffusion(img, palette, lut, atkinson_config),
        .ordered => applyOrdered(img, palette, lut),
    }
}

/// Error diffusion dithering configuration.
const DitherEntry = struct {
    dx: i16,
    dy: i16,
    weight: i16,
    divisor_shift: u3,
};

const DitherConfig = struct {
    mode: Mode,
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
        .{ .dx = 1, .dy = 0, .weight = 1, .divisor_shift = 3 },
        .{ .dx = 2, .dy = 0, .weight = 1, .divisor_shift = 3 },
        .{ .dx = -1, .dy = 1, .weight = 1, .divisor_shift = 3 },
        .{ .dx = 0, .dy = 1, .weight = 1, .divisor_shift = 3 },
        .{ .dx = 1, .dy = 1, .weight = 1, .divisor_shift = 3 },
        .{ .dx = 0, .dy = 2, .weight = 1, .divisor_shift = 3 },
    },
};

/// Bayer 8x8 ordered dithering matrix.
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

/// Applies ordered dithering using a Bayer matrix.
pub fn applyOrdered(img: Image(Rgb), pal: []const Rgb, lut: ColorLookupTable) void {
    const rows = img.rows;
    const cols = img.cols;
    const stride = img.stride;

    const T = @TypeOf(img.data[0].r);
    comptime assert(T == u8);

    const can_simd = comptime @sizeOf(Rgb) == 3;

    for (0..rows) |r| {
        const row_offset = r * stride;
        const row_slice = img.data[row_offset .. row_offset + cols];
        const bayer_row = &bayer8x8[r & 7];

        var offsets: [8]i32 = undefined;
        for (0..8) |i| {
            offsets[i] = (bayer_row[i] - 32) >> 1;
        }

        var c: usize = 0;

        if (can_simd) {
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

            while (cols >= 8 and c <= cols - 8) : (c += 8) {
                const ptr = @as([*]const u8, @ptrCast(row_slice.ptr)) + c * 3;
                const pixels_u8: @Vector(24, u8) = ptr[0..24].*;

                const pixels_i16 = @as(@Vector(24, i16), pixels_u8);
                const result_i16 = pixels_i16 + offset_vec;

                const clamped = @min(@max(result_i16, min_vec), max_vec);

                const result_u8 = @as(@Vector(24, u8), @intCast(clamped));
                const quantized_vec = result_u8 >> @as(@Vector(24, u3), @splat(8 - color_quantize_bits));
                const q_arr: [24]u8 = quantized_vec;

                for (0..8) |k| {
                    const r5 = q_arr[k * 3];
                    const g5 = q_arr[k * 3 + 1];
                    const b5 = q_arr[k * 3 + 2];
                    const idx = lut.table[r5][g5][b5];
                    row_slice[c + k] = pal[idx];
                }
            }
        } else {
            while (cols >= 8 and c <= cols - 8) : (c += 8) {
                inline for (0..8) |k| {
                    const pixel = row_slice[c + k];
                    const offset = offsets[k];

                    const r5 = meta.clamp(u8, @as(i32, pixel.r) + offset) >> (8 - color_quantize_bits);
                    const g5 = meta.clamp(u8, @as(i32, pixel.g) + offset) >> (8 - color_quantize_bits);
                    const b5 = meta.clamp(u8, @as(i32, pixel.b) + offset) >> (8 - color_quantize_bits);

                    const idx = lut.table[r5][g5][b5];
                    row_slice[c + k] = pal[idx];
                }
            }
        }

        while (c < cols) : (c += 1) {
            const pixel = row_slice[c];
            const offset = offsets[c & 7];

            const r5 = meta.clamp(u8, @as(i32, pixel.r) + offset) >> (8 - color_quantize_bits);
            const g5 = meta.clamp(u8, @as(i32, pixel.g) + offset) >> (8 - color_quantize_bits);
            const b5 = meta.clamp(u8, @as(i32, pixel.b) + offset) >> (8 - color_quantize_bits);

            const idx = lut.table[r5][g5][b5];
            row_slice[c] = pal[idx];
        }
    }
}

/// Applies Floyd–Steinberg error-diffusion dithering.
pub fn applyFloydSteinberg(img: Image(Rgb), pal: []const Rgb, lut: ColorLookupTable) void {
    applyErrorDiffusion(img, pal, lut, floyd_steinberg_config);
}

/// Applies Atkinson error-diffusion dithering.
pub fn applyAtkinson(img: Image(Rgb), pal: []const Rgb, lut: ColorLookupTable) void {
    applyErrorDiffusion(img, pal, lut, atkinson_config);
}

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
    comptime assert(T == u8);

    const updatePixel = struct {
        inline fn call(ptr: *Rgb, r_err: i16, g_err: i16, b_err: i16, weight: i32, shift: u3) void {
            ptr.r = clampToU8(@as(i32, ptr.r) + divTruncPow2(@as(i32, r_err) * weight, shift));
            ptr.g = clampToU8(@as(i32, ptr.g) + divTruncPow2(@as(i32, g_err) * weight, shift));
            ptr.b = clampToU8(@as(i32, ptr.b) + divTruncPow2(@as(i32, b_err) * weight, shift));
        }
    }.call;

    switch (config.mode) {
        .floyd_steinberg => {
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

                    if (is_safe_row and c > 0 and c < cols - 1) {
                        const next_row_offset = (r + 1) * stride;
                        updatePixel(&img.data[row_offset + c + 1], r_err, g_err, b_err, 7, 4);
                        updatePixel(&img.data[next_row_offset + c - 1], r_err, g_err, b_err, 3, 4);
                        updatePixel(&img.data[next_row_offset + c], r_err, g_err, b_err, 5, 4);
                        updatePixel(&img.data[next_row_offset + c + 1], r_err, g_err, b_err, 1, 4);
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
        .atkinson => {
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
