//! Image interpolation and resizing algorithms
//!
//! This module provides various interpolation methods for image resizing and
//! sampling, including nearest neighbor, bilinear, bicubic, Catmull-Rom,
//! Lanczos, and Mitchell-Netravali filters.
//!
//! ## Usage Examples
//!
//! ### Basic interpolation:
//! ```zig
//! const pixel = image.interpolate(100.5, 50.3, .bilinear, .mirror);
//! ```
//!
//! ### Resize with different methods:
//! ```zig
//! var small = try Image(Rgba).load(io, allocator, "small.png");
//! var large = try Image(Rgba).init(allocator, 512, 512);
//! small.resize(io, allocator, large, .lanczos); // High quality upscaling
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const clamp = meta.clamp;
const border_ops = @import("border.zig");
const BorderMode = border_ops.BorderMode;
const resolveIndex = border_ops.resolveIndex;
const channel_ops = @import("channel_ops.zig");
const elementView = @import("convolution.zig").elementView;
const parallel = @import("../parallel.zig");

/// Interpolation method for image resizing and sampling
///
/// Performance and quality comparison:
/// | Method      | Quality | Speed | Best Use Case       | Overshoot |
/// |-------------|---------|-------|---------------------|-----------|
/// | Nearest     | ★☆☆☆☆   | ★★★★★ | Pixel art, masks    | No        |
/// | Bilinear    | ★★☆☆☆   | ★★★★☆ | Real-time, preview  | No        |
/// | Bicubic     | ★★★☆☆   | ★★★☆☆ | General purpose     | Yes       |
/// | Catmull-Rom | ★★★★☆   | ★★★☆☆ | Natural images      | No        |
/// | Mitchell    | ★★★★☆   | ★★☆☆☆ | Balanced quality    | Yes       |
/// | Lanczos3    | ★★★★★   | ★☆☆☆☆ | High-quality resize | Yes       |
pub const Interpolation = union(enum) {
    nearest,
    bilinear,
    bicubic,
    catmull_rom,
    mitchell: struct {
        /// Blur parameter (controls blur vs sharpness)
        /// Common values: 1/3 (Mitchell), 1 (B-spline), 0 (Catmull-Rom-like)
        b: f32,
        /// Ringing parameter (controls ringing vs blur)
        /// Common values: 1/3 (Mitchell), 0 (B-spline), 0.5 (Catmull-Rom)
        c: f32,
        pub const default: @This() = .{ .b = 1 / 3, .c = 1 / 3 };
    },
    lanczos,
};

/// Samples a single pixel at fractional coordinates using the given interpolation `method`.
/// Returns null when the coordinates are non-finite or out of bounds under `border`.
pub fn interpolate(comptime T: type, self: Image(T), x: f32, y: f32, method: Interpolation, border: BorderMode) ?T {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    const range_limit = @as(f32, @floatFromInt(std.math.maxInt(isize) / 2));
    if (@abs(x) > range_limit or @abs(y) > range_limit) return null;
    return switch (method) {
        .nearest => interpolateNearest(T, self, x, y, border),
        .bilinear => interpolateBilinear(T, self, x, y, border),
        .bicubic, .catmull_rom, .mitchell => interpolateWithKernel(T, self, x, y, comptime kernelTaps(.bicubic), method, border),
        .lanczos => interpolateWithKernel(T, self, x, y, comptime kernelTaps(.lanczos), method, border),
    };
}

/// Resizes `self` into the pre-allocated `out` image using the given interpolation `method`,
/// in row bands on `io`. u8, f32 and u8-struct images (views included) take the separable
/// passes and use `allocator` for the tap tables and the row rings, sampling per pixel if
/// that allocation fails; other pixel types sample per pixel and do not allocate.
pub fn resize(comptime T: type, io: Io, self: Image(T), out: Image(T), allocator: Allocator, method: Interpolation) void {
    if (self.rows == out.rows and self.cols == out.cols) return self.copy(out);

    // Planes take the separable resizers; u8 struct pixels run through them interleaved.
    const P = comptime if (T == u8 or T == f32) T else if (@typeInfo(T) == .@"struct" and meta.allFieldsAreU8(T)) u8 else void;
    if (P == void) {
        resizeGeneric(T, io, self, out, method);
    } else {
        const src = if (P == T) self else elementView(T, self);
        const dst = if (P == T) out else elementView(T, out);
        resizePlane(P, comptime Image(T).channels(), io, src, dst, allocator, method) catch resizeGeneric(T, io, self, out, method);
    }
}

/// One plane of `P` whose columns are `channels` elements per pixel (`elementView`): nearest
/// samples directly in output-row bands; every other kernel runs separably in output-row
/// bands, each band resampling the source rows its output taps horizontally into a small
/// ring and blending them vertically from there.
fn resizePlane(comptime P: type, comptime channels: usize, io: Io, src: Image(P), dst: Image(P), allocator: Allocator, method: Interpolation) !void {
    const ch: u32 = channels;
    const src_cols = src.cols / ch;
    const dst_cols = dst.cols / ch;
    switch (method) {
        .nearest => {
            // One column table for every row; without it each row recomputes its columns.
            const col_idx: ?[]u32 = allocator.alloc(u32, dst_cols) catch null;
            defer if (col_idx) |cols| allocator.free(cols);
            if (col_idx) |cols| {
                const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
                for (cols, 0..) |*src_x, c| src_x.* = channel_ops.nearestIndex(c, src_cols, x_ratio);
            }
            const ctx: DirectPlane(P, channels) = .{ .src = src, .dst = dst, .col_idx = col_idx };
            parallel.forRowBands(io, dst.rows, parallel.bandCount(dst.rows, dst_cols), &ctx, DirectPlane(P, channels).band);
        },
        .bilinear, .bicubic, .catmull_rom, .mitchell, .lanczos => {
            const x_taps: channel_ops.AxisTaps(P) = try .init(allocator, src_cols, dst_cols, method);
            defer x_taps.deinit(allocator);
            const y_taps: channel_ops.AxisTaps(P) = try .init(allocator, src.rows, dst.rows, method);
            defer y_taps.deinit(allocator);
            // A window spans at most `taps` source rows, so `taps` slots keep every row the next
            // window still needs while the rows it adds overwrite only rows behind it.
            const ring_rows = y_taps.taps;
            const bands = parallel.bandCount(dst.rows, dst_cols);
            const rings = try allocator.alloc(channel_ops.Accum(P), bands * ring_rows * dst.cols);
            defer allocator.free(rings);

            const ctx: SeparablePlane(P, channels) = .{ .src = src, .dst = dst, .x_taps = x_taps, .y_taps = y_taps, .rings = rings, .ring_rows = ring_rows };
            parallel.forRowBands(io, dst.rows, bands, &ctx, SeparablePlane(P, channels).band);
        },
    }
}

fn DirectPlane(comptime P: type, comptime channels: usize) type {
    return struct {
        src: Image(P),
        dst: Image(P),
        col_idx: ?[]const u32,

        fn band(ctx: *const @This(), _: usize, r0: usize, r1: usize) void {
            const src = ctx.src;
            const dst = ctx.dst;
            const ch: u32 = channels;
            channel_ops.resizePlaneNearest(P, channels, src.data, src.stride, dst.data, dst.stride, src.rows, src.cols / ch, dst.rows, dst.cols / ch, ctx.col_idx, r0, r1);
        }
    };
}

fn SeparablePlane(comptime P: type, comptime channels: usize) type {
    return struct {
        const A = channel_ops.Accum(P);

        src: Image(P),
        dst: Image(P),
        x_taps: channel_ops.AxisTaps(P),
        y_taps: channel_ops.AxisTaps(P),
        /// `ring_rows` horizontally resampled source rows per band, slot `row % ring_rows`.
        rings: []A,
        ring_rows: usize,

        /// Output rows `[r0, r1)`. The ring holds the contiguous source rows `[lo, hi)`; a
        /// window sliding forward extends it, anything else (a gap on a steep downscale, the
        /// mirrored bottom edge folding back) restarts it, so untapped source rows are never
        /// resampled and each band recomputes at most one window of halo.
        fn band(ctx: *const @This(), k: usize, r0: usize, r1: usize) void {
            const taps = ctx.x_taps.taps;
            const row_len: usize = ctx.dst.cols;
            const dst_cols = row_len / channels;
            const ring = ctx.rings[k * ctx.ring_rows * row_len ..][0 .. ctx.ring_rows * row_len];
            var lo: usize = 0;
            var hi: usize = 0;
            for (r0..r1) |r| {
                const rows = ctx.y_taps.indices[r * taps ..][0..taps];
                const need_lo: usize = std.mem.min(u32, rows);
                const need_hi: usize = std.mem.max(u32, rows) + 1;
                if (need_lo < lo or need_hi > hi) {
                    var from = need_lo;
                    if (need_lo >= lo and need_lo <= hi) from = hi else lo = need_lo;
                    for (from..need_hi) |sr| {
                        const src_row = ctx.src.data[sr * ctx.src.stride ..][0..ctx.src.cols];
                        channel_ops.resizeRow(P, channels, src_row, ctx.x_taps, ring[(sr % ctx.ring_rows) * row_len ..][0..row_len], dst_cols);
                    }
                    hi = need_hi;
                    lo = @max(lo, hi -| ctx.ring_rows);
                }
                var srcs: [max_taps][*]const A = undefined;
                for (rows, 0..) |sr, t| srcs[t] = ring[(sr % ctx.ring_rows) * row_len ..].ptr;
                channel_ops.blendRows(P, srcs[0..taps], ctx.y_taps.weightsAt(r), ctx.dst.data[r * ctx.dst.stride ..][0..row_len]);
            }
        }
    };
}

/// Generic per-pixel resize fallback, in output-row bands.
fn resizeGeneric(comptime T: type, io: Io, self: Image(T), out: Image(T), method: Interpolation) void {
    const ctx: GenericResize(T) = .{ .src = self, .out = out, .method = method };
    parallel.forRowBands(io, out.rows, parallel.bandCount(out.rows, out.cols), &ctx, GenericResize(T).band);
}

fn GenericResize(comptime T: type) type {
    return struct {
        src: Image(T),
        out: Image(T),
        method: Interpolation,

        fn band(ctx: *const @This(), _: usize, r0: usize, r1: usize) void {
            const self = ctx.src;
            const out = ctx.out;
            const scale_x = @as(f32, @floatFromInt(self.cols)) / @as(f32, @floatFromInt(out.cols));
            const scale_y = @as(f32, @floatFromInt(self.rows)) / @as(f32, @floatFromInt(out.rows));
            for (r0..r1) |r| {
                const src_y = (@as(f32, @floatFromInt(r)) + 0.5) * scale_y - 0.5;
                for (0..out.cols) |c| {
                    const src_x = (@as(f32, @floatFromInt(c)) + 0.5) * scale_x - 0.5;
                    out.at(r, c).* = interpolate(T, self, src_x, src_y, ctx.method, .mirror) orelse std.mem.zeroes(T);
                }
            }
        }
    };
}

/// Repeated sampling of one image with one method and border mode, for the geometric
/// transforms. Built once per call: kernel weights come from a 256-entry table over the
/// fractional position, and taps whose whole window lies inside the image index the data
/// directly. Border pixels take the general `interpolate` path, so results there are unchanged.
pub fn Sampler(comptime T: type) type {
    return struct {
        const Self = @This();
        const lut_size = 256;

        image: Image(T),
        method: Interpolation,
        border: BorderMode,
        /// Per-axis kernel weights for fractional position `i / lut_size`, normalized to unit
        /// gain; unused for nearest and bilinear.
        lut: [lut_size][max_taps]f32,

        pub fn init(image: Image(T), method: Interpolation, border: BorderMode) Self {
            var self: Self = .{
                .image = image,
                .method = method,
                .border = border,
                .lut = undefined,
            };
            if (method != .nearest and method != .bilinear) {
                const taps = kernelTaps(method);
                for (&self.lut, 0..) |*row, i| {
                    const frac = @as(f32, @floatFromInt(i)) / lut_size;
                    var sum: f32 = 0;
                    for (row[0..taps], 0..) |*w, t| {
                        // Tap t sits at offset t - (taps/2 - 1) from the floor position.
                        const offset = @as(f32, @floatFromInt(t)) - @as(f32, @floatFromInt(taps / 2 - 1));
                        w.* = kernelWeight(method, offset - frac);
                        sum += w.*;
                    }
                    for (row[0..taps]) |*w| w.* /= sum;
                }
            }
            return self;
        }

        /// The pixel at (`x`, `y`); zeroes where `interpolate` would return null.
        pub inline fn sample(self: *const Self, x: f32, y: f32) T {
            return switch (self.method) {
                .nearest => self.sampleNearest(x, y),
                .bilinear => self.sampleBilinear(x, y),
                .bicubic, .catmull_rom, .mitchell => self.sampleKernel(comptime kernelTaps(.bicubic), x, y),
                .lanczos => self.sampleKernel(comptime kernelTaps(.lanczos), x, y),
            };
        }

        inline fn fallback(self: *const Self, x: f32, y: f32) T {
            // With a zero border, a window entirely outside the image is all zeroes (rotated corners).
            if (self.border == .zero) {
                const reach: f32 = max_taps;
                if (x < -reach or y < -reach or x > @as(f32, @floatFromInt(self.image.cols)) + reach or y > @as(f32, @floatFromInt(self.image.rows)) + reach) {
                    return std.mem.zeroes(T);
                }
            }
            return interpolate(T, self.image, x, y, self.method, self.border) orelse std.mem.zeroes(T);
        }

        inline fn sampleNearest(self: *const Self, x: f32, y: f32) T {
            const img = self.image;
            const rx = @round(x);
            const ry = @round(y);
            if (rx >= 0 and ry >= 0 and rx < @as(f32, @floatFromInt(img.cols)) and ry < @as(f32, @floatFromInt(img.rows))) {
                const c: usize = @trunc(rx);
                const r: usize = @trunc(ry);
                return img.data[r * img.stride + c];
            }
            return self.fallback(x, y);
        }

        inline fn sampleBilinear(self: *const Self, x: f32, y: f32) T {
            const img = self.image;
            const fx_floor = @floor(x);
            const fy_floor = @floor(y);
            // Interior: the 2x2 window lies inside the image.
            if (!(fx_floor >= 0 and fy_floor >= 0 and fx_floor + 1 < @as(f32, @floatFromInt(img.cols)) and fy_floor + 1 < @as(f32, @floatFromInt(img.rows)))) {
                return self.fallback(x, y);
            }
            const left: usize = @trunc(fx_floor);
            const top: usize = @trunc(fy_floor);
            const base = top * img.stride + left;
            return lerpPixel(T, img.data[base], img.data[base + 1], img.data[base + img.stride], img.data[base + img.stride + 1], x - fx_floor, y - fy_floor);
        }

        inline fn sampleKernel(self: *const Self, comptime taps: usize, x: f32, y: f32) T {
            const img = self.image;
            const fx_floor = @floor(x);
            const fy_floor = @floor(y);
            const lead: f32 = taps / 2 - 1;
            // Interior: the taps x taps window lies inside the image.
            if (!(fx_floor - lead >= 0 and fy_floor - lead >= 0 and fx_floor - lead + taps <= @as(f32, @floatFromInt(img.cols)) and fy_floor - lead + taps <= @as(f32, @floatFromInt(img.rows)))) {
                return self.fallback(x, y);
            }
            const left: usize = @trunc(fx_floor - lead);
            const top: usize = @trunc(fy_floor - lead);
            const wx = self.lut[@as(usize, @trunc((x - fx_floor) * lut_size))][0..taps];
            const wy = self.lut[@as(usize, @trunc((y - fy_floor) * lut_size))][0..taps];

            const n = comptime Image(T).channels();
            var sums: [n]f32 = @splat(0);
            inline for (0..taps) |j| {
                const row = img.data[(top + j) * img.stride + left ..][0..taps];
                var row_sums: [n]f32 = @splat(0);
                inline for (0..taps) |i| {
                    inline for (0..n) |ch| row_sums[ch] += channelOf(row[i], ch) * wx[i];
                }
                inline for (0..n) |ch| sums[ch] += row_sums[ch] * wy[j];
            }
            return fromChannels(T, sums);
        }
    };
}

/// Widest separable kernel: `kernelTaps(.lanczos)`.
pub const max_taps = 6;

/// Support of a separable kernel along one axis, for the plane resizers.
pub fn kernelTaps(method: Interpolation) usize {
    return switch (method) {
        .bilinear => 2,
        .bicubic, .catmull_rom, .mitchell => 4,
        .lanczos => max_taps,
        .nearest => unreachable,
    };
}

/// Weight of a separable kernel at distance `x` from the sample centre.
pub fn kernelWeight(method: Interpolation, x: f32) f32 {
    return switch (method) {
        .bilinear => @max(0, 1 - @abs(x)),
        .bicubic => bicubicKernel(x),
        .catmull_rom => catmullRomKernel(x),
        .mitchell => |m| mitchellKernel(x, m.b, m.c),
        .lanczos => lanczosKernel(x, 3),
        .nearest => unreachable,
    };
}

/// `kernelWeight` for the per-pixel path, where Lanczos reads its table instead of two sines per tap.
fn kernelWeightFast(method: Interpolation, x: f32) f32 {
    return if (method == .lanczos) lanczos3KernelLut(x) else kernelWeight(method, x);
}

/// Classic bicubic kernel with a = -1.
fn bicubicKernel(t: f32) f32 {
    const at = @abs(t);
    if (at <= 1) {
        return 1 - 2 * at * at + at * at * at;
    } else if (at <= 2) {
        return 4 - 8 * at + 5 * at * at - at * at * at;
    }
    return 0;
}

/// Catmull-Rom spline, a special case of cubic interpolation.
fn catmullRomKernel(x: f32) f32 {
    const ax = @abs(x);
    if (ax <= 1) {
        return 1.5 * ax * ax * ax - 2.5 * ax * ax + 1;
    } else if (ax <= 2) {
        return -0.5 * ax * ax * ax + 2.5 * ax * ax - 4 * ax + 2;
    }
    return 0;
}

/// Lanczos windowed sinc with parameter `a` (typically 3).
fn lanczosKernel(x: f32, a: f32) f32 {
    if (x == 0) return 1;
    if (@abs(x) >= a) return 0;

    const pi_x = std.math.pi * x;
    const pi_x_over_a = pi_x / a;
    return (a * @sin(pi_x) * @sin(pi_x_over_a)) / (pi_x * pi_x);
}

/// Lanczos3 over [0, 3) at `lanczos3_lut_step` entries per unit distance.
const lanczos3_lut_step = 1024.0 / 3.0;
const lanczos3_lut: [1025]f32 = blk: {
    @setEvalBranchQuota(4000);
    var vals: [1025]f32 = undefined;
    for (&vals, 0..) |*v, i| v.* = lanczosKernel(@as(f32, @floatFromInt(i)) / lanczos3_lut_step, 3);
    break :blk vals;
};

/// Lanczos3 kernel linearly interpolated from `lanczos3_lut`.
fn lanczos3KernelLut(x: f32) f32 {
    const ax = @abs(x);
    if (ax >= 3.0) return 0;

    const pos = ax * lanczos3_lut_step;
    const idx: usize = @trunc(pos);
    const frac = pos - @as(f32, @floatFromInt(idx));

    return lanczos3_lut[idx] * (1.0 - frac) + lanczos3_lut[idx + 1] * frac;
}

/// Mitchell-Netravali cubic with blur `m_b` and ringing `m_c` parameters.
fn mitchellKernel(x: f32, m_b: f32, m_c: f32) f32 {
    const ax = @abs(x);
    const ax2 = ax * ax;
    const ax3 = ax2 * ax;

    if (ax < 1) {
        return ((12 - 9 * m_b - 6 * m_c) * ax3 +
            (-18 + 12 * m_b + 6 * m_c) * ax2 +
            (6 - 2 * m_b)) / 6;
    } else if (ax < 2) {
        return ((-m_b - 6 * m_c) * ax3 +
            (6 * m_b + 30 * m_c) * ax2 +
            (-12 * m_b - 48 * m_c) * ax +
            (8 * m_b + 24 * m_c)) / 6;
    }
    return 0;
}

/// Channel `i` of a scalar or struct pixel as f32.
inline fn channelOf(px: anytype, comptime i: usize) f32 {
    return switch (@typeInfo(@TypeOf(px))) {
        .@"struct" => |s| as(f32, @field(px, s.field_names[i])),
        else => as(f32, px),
    };
}

/// A pixel from per-channel values, clamped to each channel's type.
inline fn fromChannels(comptime T: type, values: [Image(T).channels()]f32) T {
    switch (@typeInfo(T)) {
        .int, .float => return clamp(T, values[0]),
        .@"struct" => {
            var out: T = undefined;
            inline for (comptime meta.structFields(T), 0..) |f, i| @field(out, f.name) = clamp(f.type, values[i]);
            return out;
        },
        else => @compileError("Unsupported pixel type for interpolation: " ++ @typeName(T)),
    }
}

/// Fixed-point precision of the bilinear lerp for integer channels.
const lerp_scale = 256;

/// Bilinear blend of a 2x2 window at fractional offsets (`lr`, `tb`) from the top-left.
inline fn lerpPixel(comptime T: type, tl: T, tr: T, bl: T, br: T, lr: f32, tb: f32) T {
    const fx: i32 = @round(lr * lerp_scale);
    const fy: i32 = @round(tb * lerp_scale);
    switch (@typeInfo(T)) {
        .int, .float => return lerpField(T, tl, tr, bl, br, fx, fy, lr, tb),
        .@"struct" => {
            var out: T = undefined;
            inline for (comptime meta.structFields(T)) |f| {
                @field(out, f.name) = lerpField(f.type, @field(tl, f.name), @field(tr, f.name), @field(bl, f.name), @field(br, f.name), fx, fy, lr, tb);
            }
            return out;
        },
        else => @compileError("Unsupported pixel type for bilinear interpolation: " ++ @typeName(T)),
    }
}

/// One channel of `lerpPixel`: fixed point up to 16-bit integers, float otherwise.
inline fn lerpField(comptime P: type, tl: P, tr: P, bl: P, br: P, fx: i32, fy: i32, lr: f32, tb: f32) P {
    const info = @typeInfo(P);
    if (info == .int and info.int.bits <= 16) {
        const Intermediate = if (info.int.bits <= 8) i32 else i64;
        const top_val = @as(Intermediate, tl) * (lerp_scale - fx) + @as(Intermediate, tr) * fx;
        const bottom_val = @as(Intermediate, bl) * (lerp_scale - fx) + @as(Intermediate, br) * fx;
        return clamp(P, @divTrunc(top_val * (lerp_scale - fy) + bottom_val * fy + (lerp_scale * lerp_scale / 2), lerp_scale * lerp_scale));
    }
    return clamp(P, (1 - tb) * ((1 - lr) * as(f32, tl) + lr * as(f32, tr)) +
        tb * ((1 - lr) * as(f32, bl) + lr * as(f32, br)));
}

fn interpolateNearest(comptime T: type, self: Image(T), x: f32, y: f32, border: BorderMode) ?T {
    const at = border_ops.computeCoords(@round(y), @round(x), @intCast(self.rows), @intCast(self.cols), border) orelse return null;
    return self.at(at.row, at.col).*;
}

fn interpolateBilinear(comptime T: type, self: Image(T), x: f32, y: f32, border: BorderMode) ?T {
    const left: isize = @floor(x);
    const top: isize = @floor(y);
    const r0 = resolveIndex(top, @intCast(self.rows), border);
    const r1 = resolveIndex(top + 1, @intCast(self.rows), border);
    const c0 = resolveIndex(left, @intCast(self.cols), border);
    const c1 = resolveIndex(left + 1, @intCast(self.cols), border);

    // With .mirror any out-of-bounds neighbor yields null; .zero continues with zeroes.
    if (border == .mirror and (r0 == null or r1 == null or c0 == null or c1 == null)) return null;

    return lerpPixel(
        T,
        pixelOrZero(T, self, r0, c0),
        pixelOrZero(T, self, r0, c1),
        pixelOrZero(T, self, r1, c0),
        pixelOrZero(T, self, r1, c1),
        x - as(f32, left),
        y - as(f32, top),
    );
}

fn pixelOrZero(comptime T: type, img: Image(T), r: ?usize, c: ?usize) T {
    return if (r != null and c != null) img.at(r.?, c.?).* else std.mem.zeroes(T);
}

/// Separable `taps` x `taps` kernel window around (`x`, `y`), normalized over the taps that
/// resolve inside the image under `border`.
fn interpolateWithKernel(comptime T: type, self: Image(T), x: f32, y: f32, comptime taps: usize, method: Interpolation, border: BorderMode) ?T {
    const ix: isize = @floor(x);
    const iy: isize = @floor(y);
    const fx = x - as(f32, ix);
    const fy = y - as(f32, iy);
    const lead: isize = taps / 2 - 1;

    // Per-axis taps and weights, resolved once instead of once per window cell.
    var cols: [taps]?usize = undefined;
    var rows: [taps]?usize = undefined;
    var wx: [taps]f32 = undefined;
    var wy: [taps]f32 = undefined;
    inline for (0..taps) |t| {
        const offset: isize = @as(isize, t) - lead;
        const d: f32 = @floatFromInt(offset);
        wx[t] = kernelWeightFast(method, d - fx);
        wy[t] = kernelWeightFast(method, d - fy);
        cols[t] = resolveIndex(ix + offset, @intCast(self.cols), border);
        rows[t] = resolveIndex(iy + offset, @intCast(self.rows), border);
    }

    const n = comptime Image(T).channels();
    var sums: [n]f32 = @splat(0);
    var weight_sum: f32 = 0;
    inline for (0..taps) |j| {
        if (rows[j]) |r| {
            inline for (0..taps) |i| {
                if (cols[i]) |c| {
                    const px = self.at(r, c).*;
                    const w = wx[i] * wy[j];
                    inline for (0..n) |ch| sums[ch] += channelOf(px, ch) * w;
                    weight_sum += w;
                }
            }
        }
    }
    for (&sums) |*s| s.* = if (weight_sum != 0) s.* / weight_sum else 0;
    return fromChannels(T, sums);
}

test "sampler matches interpolate away from the borders" {
    const allocator = std.testing.allocator;
    const Rgb = @import("../color.zig").Rgb(u8);
    var prng = std.Random.DefaultPrng.init(0x5a);
    const random = prng.random();

    inline for ([_]type{ u8, f32, Rgb }) |T| {
        var img: Image(T) = try .init(allocator, 40, 50);
        defer img.deinit(allocator);
        for (img.data) |*px| px.* = switch (T) {
            u8 => random.int(u8),
            f32 => 255 * random.float(f32),
            else => .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) },
        };
        const methods = [_]Interpolation{ .nearest, .bilinear, .bicubic, .catmull_rom, .{ .mitchell = .default }, .lanczos };
        for (methods) |method| {
            for ([_]BorderMode{ .zero, .mirror, .replicate }) |border| {
                const sampler: Sampler(T) = .init(img, method, border);
                for (0..300) |_| {
                    // Anywhere from just outside to well inside: border pixels share the general path.
                    const x = random.float(f32) * 56 - 3;
                    const y = random.float(f32) * 46 - 3;
                    const expected = interpolate(T, img, x, y, method, border) orelse std.mem.zeroes(T);
                    const got = sampler.sample(x, y);
                    const exact = method == .nearest or method == .bilinear;
                    switch (T) {
                        u8 => try std.testing.expect(if (exact) got == expected else @abs(@as(i32, got) - @as(i32, expected)) <= 2),
                        f32 => try std.testing.expect(if (exact) got == expected else @abs(got - expected) <= 0.02 * 255),
                        else => {
                            inline for (.{ "r", "g", "b" }) |f| {
                                const g = @field(got, f);
                                const e = @field(expected, f);
                                try std.testing.expect(if (exact) g == e else @abs(@as(i32, g) - @as(i32, e)) <= 2);
                            }
                        },
                    }
                }
            }
        }
    }
}
