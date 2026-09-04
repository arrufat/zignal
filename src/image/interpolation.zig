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
//! small.resize(allocator, large, .lanczos); // High quality upscaling
//! ```
//!
//! ## Performance Guide
//!
//! Approximate performance on 512x512 RGBA images (Mpix/s):
//! - Nearest neighbor: ~400 Mpix/s
//! - Bilinear: ~100 Mpix/s
//! - Bicubic: ~25 Mpix/s
//! - Catmull-Rom: ~25 Mpix/s
//! - Lanczos: ~8.5 Mpix/s
//! - Mitchell: ~22 Mpix/s

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const clamp = meta.clamp;
const BorderMode = @import("border.zig").BorderMode;
const channel_ops = @import("channel_ops.zig");
const parallel = @import("../parallel.zig");
const resolveIndex = @import("border.zig").resolveIndex;

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
        .bicubic => interpolateBicubic(T, self, x, y, border),
        .catmull_rom => interpolateCatmullRom(T, self, x, y, border),
        .lanczos => interpolateLanczos(T, self, x, y, border),
        .mitchell => |m| interpolateMitchell(T, self, x, y, m.b, m.c, border),
    };
}

/// Resizes `self` into the pre-allocated `out` image using the given interpolation `method`,
/// in row bands on `io`. Contiguous u8, f32 and u8-struct images take the separable passes
/// and use `allocator` for the tap tables and the accumulator plane; other pixel types (and
/// strided views) sample per pixel and do not allocate.
pub fn resize(comptime T: type, io: Io, self: Image(T), out: Image(T), allocator: Allocator, method: Interpolation) void {
    // Check for scale = 1 (just copy)
    if (self.rows == out.rows and self.cols == out.cols) {
        if (self.data.ptr == out.data.ptr) return;

        if (self.isContiguous() and out.isContiguous()) {
            const total = @as(usize, self.rows) * self.cols;
            @memcpy(out.data[0..total], self.data[0..total]);
        } else {
            for (0..self.rows) |r| {
                const src_row_start = r * self.stride;
                const dst_row_start = r * out.stride;
                @memcpy(
                    out.data[dst_row_start .. dst_row_start + out.cols],
                    self.data[src_row_start .. src_row_start + self.cols],
                );
            }
        }
        return;
    }

    // Contiguous u8 and f32 planes take the separable resizers; struct pixels of u8 fields
    // run through them interleaved (every channel of a pixel is an element).
    if (self.isContiguous() and out.isContiguous()) {
        if (T == u8 or T == f32) {
            resizePlane(T, 1, io, self.data, out.data, self.rows, self.cols, out.rows, out.cols, allocator, method) catch {
                resizeGeneric(T, io, self, out, method);
            };
            return;
        } else if (comptime @typeInfo(T) == .@"struct" and meta.allFieldsAreU8(T)) {
            const n = comptime Image(T).channels();
            resizePlane(u8, n, io, std.mem.sliceAsBytes(self.data), std.mem.sliceAsBytes(out.data), self.rows, self.cols, out.rows, out.cols, allocator, method) catch {
                resizeGeneric(T, io, self, out, method);
            };
            return;
        }
    }

    // Fall back to generic implementation
    resizeGeneric(T, io, self, out, method);
}

/// One contiguous plane of `P` (`channels` elements per pixel when interleaved): nearest
/// samples directly in output-row bands; every other kernel runs separably, a horizontal
/// pass into an accumulator plane over the source rows and a vertical pass over the
/// output rows.
fn resizePlane(comptime P: type, comptime channels: usize, io: Io, src: []const P, dst: []P, src_rows: u32, src_cols: u32, dst_rows: u32, dst_cols: u32, allocator: Allocator, method: Interpolation) !void {
    switch (method) {
        .nearest => {
            const ctx: DirectPlane(P, channels) = .{ .src = src, .dst = dst, .src_rows = src_rows, .src_cols = src_cols, .dst_rows = dst_rows, .dst_cols = dst_cols };
            parallel.forRowBands(io, dst_rows, parallel.bandCount(dst_rows, dst_cols), &ctx, DirectPlane(P, channels).band);
        },
        .bilinear, .bicubic, .catmull_rom, .mitchell, .lanczos => {
            const x_taps: channel_ops.AxisTaps = try .init(allocator, src_cols, dst_cols, method);
            defer x_taps.deinit(allocator);
            const y_taps: channel_ops.AxisTaps = try .init(allocator, src_rows, dst_rows, method);
            defer y_taps.deinit(allocator);
            const mid = try allocator.alloc(channel_ops.Accum(P), @as(usize, src_rows) * dst_cols * channels);
            defer allocator.free(mid);

            const ctx: SeparablePlane(P, channels) = .{ .src = src, .mid = mid, .dst = dst, .src_cols = src_cols, .dst_cols = dst_cols, .x_taps = x_taps, .y_taps = y_taps };
            parallel.forRowBands(io, src_rows, parallel.bandCount(src_rows, dst_cols), &ctx, SeparablePlane(P, channels).rowsBand);
            parallel.forRowBands(io, dst_rows, parallel.bandCount(dst_rows, dst_cols), &ctx, SeparablePlane(P, channels).columnsBand);
        },
    }
}

fn DirectPlane(comptime P: type, comptime channels: usize) type {
    return struct {
        src: []const P,
        dst: []P,
        src_rows: u32,
        src_cols: u32,
        dst_rows: u32,
        dst_cols: u32,

        fn band(ctx: *const @This(), _: usize, r0: usize, r1: usize) void {
            channel_ops.resizePlaneNearest(P, channels, ctx.src, ctx.dst, ctx.src_rows, ctx.src_cols, ctx.dst_rows, ctx.dst_cols, r0, r1);
        }
    };
}

fn SeparablePlane(comptime P: type, comptime channels: usize) type {
    return struct {
        src: []const P,
        mid: []channel_ops.Accum(P),
        dst: []P,
        src_cols: u32,
        dst_cols: u32,
        x_taps: channel_ops.AxisTaps,
        y_taps: channel_ops.AxisTaps,

        fn rowsBand(ctx: *const @This(), _: usize, r0: usize, r1: usize) void {
            channel_ops.resizeRows(P, channels, ctx.src, ctx.src_cols, ctx.x_taps, ctx.mid, ctx.dst_cols, r0, r1);
        }

        fn columnsBand(ctx: *const @This(), _: usize, r0: usize, r1: usize) void {
            channel_ops.resizeColumns(P, ctx.mid, @as(usize, ctx.dst_cols) * channels, ctx.y_taps, ctx.dst, r0, r1);
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
                    if (interpolate(T, self, src_x, src_y, ctx.method, .mirror)) |val| {
                        out.at(r, c).* = val;
                    } else {
                        // Fallback for failed interpolation (e.g., boundary conditions)
                        out.at(r, c).* = switch (@typeInfo(T)) {
                            .int, .float => 0,
                            .@"struct" => std.mem.zeroes(T),
                            else => @compileError("Unsupported type for fallback in resizeGeneric: " ++ @typeName(T)),
                        };
                    }
                }
            }
        }
    };
}

// ============================================================================
// Kernel Functions
// ============================================================================

/// Bicubic kernel function
/// Classic bicubic interpolation kernel with a=-1.0
fn bicubicKernel(t: f32) f32 {
    const at = @abs(t);
    if (at <= 1) {
        return 1 - 2 * at * at + at * at * at;
    } else if (at <= 2) {
        return 4 - 8 * at + 5 * at * at - at * at * at;
    }
    return 0;
}

/// Repeated sampling of one image with one method and border mode, for the geometric
/// transforms. Built once per call: kernel weights come from a 256-entry table over the
/// fractional position, and taps whose whole window lies inside the image index the data
/// directly. Border pixels take the general `interpolate` path, so results there are unchanged.
pub fn Sampler(comptime T: type) type {
    return struct {
        const Self = @This();
        const Kind = enum { nearest, bilinear, cubic4, lanczos6 };
        const lut_size = 256;
        const max_taps = 6;

        image: Image(T),
        method: Interpolation,
        border: BorderMode,
        kind: Kind,
        /// Per-axis kernel weights for fractional position `i / lut_size`, normalized to unit
        /// gain; unused for nearest and bilinear.
        lut: [lut_size][max_taps]f32,

        pub fn init(image: Image(T), method: Interpolation, border: BorderMode) Self {
            var self: Self = .{
                .image = image,
                .method = method,
                .border = border,
                .kind = switch (method) {
                    .nearest => .nearest,
                    .bilinear => .bilinear,
                    .bicubic, .catmull_rom, .mitchell => .cubic4,
                    .lanczos => .lanczos6,
                },
                .lut = undefined,
            };
            if (self.kind == .cubic4 or self.kind == .lanczos6) {
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
            return switch (self.kind) {
                .nearest => self.sampleNearest(x, y),
                .bilinear => self.sampleBilinear(x, y),
                .cubic4 => self.sampleKernel(4, x, y),
                .lanczos6 => self.sampleKernel(6, x, y),
            };
        }

        inline fn fallback(self: *const Self, x: f32, y: f32) T {
            // A zero border and a window entirely outside the image is just zeroes; rotated
            // outputs have whole corners of those.
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
                const c: usize = @intFromFloat(rx);
                const r: usize = @intFromFloat(ry);
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
            const left: usize = @intFromFloat(fx_floor);
            const top: usize = @intFromFloat(fy_floor);
            const base = top * img.stride + left;
            const tl = img.data[base];
            const tr = img.data[base + 1];
            const bl = img.data[base + img.stride];
            const br = img.data[base + img.stride + 1];
            const lr_frac = x - fx_floor;
            const tb_frac = y - fy_floor;
            // Same fixed-point lerp as `interpolateBilinear`, so interior pixels are identical.
            const scale = 256;
            const fx: i32 = @round(lr_frac * scale);
            const fy: i32 = @round(tb_frac * scale);

            var out: T = undefined;
            switch (@typeInfo(T)) {
                .int, .float => out = lerpField(T, tl, tr, bl, br, fx, fy, lr_frac, tb_frac),
                .@"struct" => {
                    inline for (comptime meta.structFields(T)) |f| {
                        @field(out, f.name) = lerpField(f.type, @field(tl, f.name), @field(tr, f.name), @field(bl, f.name), @field(br, f.name), fx, fy, lr_frac, tb_frac);
                    }
                },
                else => @compileError("Unsupported type for bilinear sampling: " ++ @typeName(T)),
            }
            return out;
        }

        inline fn lerpField(comptime P: type, tl: P, tr: P, bl: P, br: P, fx: i32, fy: i32, lr_frac: f32, tb_frac: f32) P {
            const info = @typeInfo(P);
            if (info == .int and info.int.bits <= 16) {
                const scale = 256;
                const Intermediate = if (info.int.bits <= 8) i32 else i64;
                const top_val = @as(Intermediate, tl) * (scale - fx) + @as(Intermediate, tr) * fx;
                const bottom_val = @as(Intermediate, bl) * (scale - fx) + @as(Intermediate, br) * fx;
                return clamp(P, @divTrunc(top_val * (scale - fy) + bottom_val * fy + (scale * scale / 2), scale * scale));
            }
            return clamp(P, (1 - tb_frac) * ((1 - lr_frac) * as(f32, tl) + lr_frac * as(f32, tr)) +
                tb_frac * ((1 - lr_frac) * as(f32, bl) + lr_frac * as(f32, br)));
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
            const left: usize = @intFromFloat(fx_floor - lead);
            const top: usize = @intFromFloat(fy_floor - lead);
            const wx = self.lut[@intFromFloat((x - fx_floor) * lut_size)][0..taps];
            const wy = self.lut[@intFromFloat((y - fy_floor) * lut_size)][0..taps];

            var out: T = undefined;
            switch (@typeInfo(T)) {
                .int, .float => {
                    var sum: f32 = 0;
                    inline for (0..taps) |j| {
                        const row = img.data[(top + j) * img.stride + left ..][0..taps];
                        var row_sum: f32 = 0;
                        inline for (0..taps) |i| row_sum += as(f32, row[i]) * wx[i];
                        sum += row_sum * wy[j];
                    }
                    out = clamp(T, sum);
                },
                .@"struct" => {
                    const fields = comptime meta.structFields(T);
                    var sums: [fields.len]f32 = @splat(0);
                    inline for (0..taps) |j| {
                        const row = img.data[(top + j) * img.stride + left ..][0..taps];
                        var row_sums: [fields.len]f32 = @splat(0);
                        inline for (0..taps) |i| {
                            inline for (fields, 0..) |f, fi| row_sums[fi] += as(f32, @field(row[i], f.name)) * wx[i];
                        }
                        inline for (0..fields.len) |fi| sums[fi] += row_sums[fi] * wy[j];
                    }
                    inline for (fields, 0..) |f, fi| @field(out, f.name) = clamp(f.type, sums[fi]);
                },
                else => @compileError("Unsupported type for kernel sampling: " ++ @typeName(T)),
            }
            return out;
        }
    };
}

/// Support of a separable kernel along one axis, for the plane resizers.
pub fn kernelTaps(method: Interpolation) usize {
    return switch (method) {
        .bilinear => 2,
        .bicubic, .catmull_rom, .mitchell => 4,
        .lanczos => 6,
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

/// Catmull-Rom kernel function
/// Catmull-Rom spline - a special case of cubic interpolation
fn catmullRomKernel(x: f32) f32 {
    const ax = @abs(x);
    if (ax <= 1) {
        return 1.5 * ax * ax * ax - 2.5 * ax * ax + 1;
    } else if (ax <= 2) {
        return -0.5 * ax * ax * ax + 2.5 * ax * ax - 4 * ax + 2;
    }
    return 0;
}

/// Lanczos kernel function
/// Lanczos windowed sinc function with parameter a (typically 3)
fn lanczosKernel(x: f32, a: f32) f32 {
    if (x == 0) return 1;
    if (@abs(x) >= a) return 0;

    const pi_x = std.math.pi * x;
    const pi_x_over_a = pi_x / a;
    return (a * @sin(pi_x) * @sin(pi_x_over_a)) / (pi_x * pi_x);
}

/// Lanczos3 Look-Up Table for fast weight calculation
const lanczos3_lut: [1025]f32 = blk: {
    const size = 1024;
    const max_dist: f32 = 3.0;
    const step = size / max_dist;
    @setEvalBranchQuota(4000);
    var vals: [size + 1]f32 = undefined;
    for (0..1025) |i| {
        const x = @as(f32, @floatFromInt(i)) / step;
        vals[i] = lanczosKernel(x, 3.0);
    }
    break :blk vals;
};

/// Lanczos3 kernel function using a pre-calculated LUT
fn lanczos3KernelLut(x: f32) f32 {
    const ax = @abs(x);
    if (ax >= 3.0) return 0;

    const step = 1024.0 / 3.0;
    const pos = ax * step;
    const idx: usize = @trunc(pos);
    const frac = pos - @as(f32, @floatFromInt(idx));

    return lanczos3_lut[idx] * (1.0 - frac) + lanczos3_lut[idx + 1] * frac;
}

/// Mitchell-Netravali kernel function
/// Parameterized cubic filter with control over blur (m_b) and ringing (m_c)
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

// ============================================================================
// Generic Interpolation Functions
// ============================================================================

fn interpolateNearest(comptime T: type, self: Image(T), x: f32, y: f32, border: BorderMode) ?T {
    const col = resolveIndex(@round(x), @intCast(self.cols), border) orelse return null;
    const row = resolveIndex(@round(y), @intCast(self.rows), border) orelse return null;

    return self.at(row, col).*;
}

fn interpolateBilinear(comptime T: type, self: Image(T), x: f32, y: f32, border: BorderMode) ?T {
    const left: isize = @floor(x);
    const top: isize = @floor(y);
    const right = left + 1;
    const bottom = top + 1;

    const r0_opt = resolveIndex(top, @intCast(self.rows), border);
    const r1_opt = resolveIndex(bottom, @intCast(self.rows), border);
    const c0_opt = resolveIndex(left, @intCast(self.cols), border);
    const c1_opt = resolveIndex(right, @intCast(self.cols), border);

    const getPixel = struct {
        fn get(img: Image(T), r: ?usize, c: ?usize) T {
            if (r) |rr| {
                if (c) |cc| {
                    return img.at(rr, cc).*;
                }
            }
            return std.mem.zeroes(T);
        }
    }.get;

    // With .mirror any out-of-bounds neighbor yields null; .zero continues with zeroes.
    if (border == .mirror) {
        if (r0_opt == null or r1_opt == null or c0_opt == null or c1_opt == null) return null;
    }

    const tl: T = getPixel(self, r0_opt, c0_opt);
    const tr: T = getPixel(self, r0_opt, c1_opt);
    const bl: T = getPixel(self, r1_opt, c0_opt);
    const br: T = getPixel(self, r1_opt, c1_opt);

    const lr_frac: f32 = x - as(f32, left);
    const tb_frac: f32 = y - as(f32, top);

    const scale = 256;
    const fx: i32 = @round(lr_frac * scale);
    const fy: i32 = @round(tb_frac * scale);

    const lerpInt = struct {
        fn lerp(comptime P: type, p_tl: P, p_tr: P, p_bl: P, p_br: P, p_fx: i32, p_fy: i32) P {
            const info = @typeInfo(P).int;
            const Intermediate = if (info.bits <= 8) i32 else i64;

            const tl_i = @as(Intermediate, @intCast(p_tl));
            const tr_i = @as(Intermediate, @intCast(p_tr));
            const bl_i = @as(Intermediate, @intCast(p_bl));
            const br_i = @as(Intermediate, @intCast(p_br));

            const top_val = tl_i * (scale - p_fx) + tr_i * p_fx;
            const bottom_val = bl_i * (scale - p_fx) + br_i * p_fx;
            const result = @divTrunc(top_val * (scale - p_fy) + bottom_val * p_fy + (scale * scale / 2), scale * scale);
            return clamp(P, result);
        }
    }.lerp;

    const lerpFloat = struct {
        fn lerp(comptime P: type, p_tl: P, p_tr: P, p_bl: P, p_br: P, p_lr_frac: f32, p_tb_frac: f32) P {
            return clamp(P, (1 - p_tb_frac) * ((1 - p_lr_frac) * as(f32, p_tl) +
                p_lr_frac * as(f32, p_tr)) +
                p_tb_frac * ((1 - p_lr_frac) * as(f32, p_bl) +
                    p_lr_frac * as(f32, p_br)));
        }
    }.lerp;

    // Handle different pixel types
    var temp: T = undefined;
    switch (@typeInfo(T)) {
        .int => |info| {
            temp = if (info.bits <= 16)
                lerpInt(T, tl, tr, bl, br, fx, fy)
            else
                lerpFloat(T, tl, tr, bl, br, lr_frac, tb_frac);
        },
        .float => temp = lerpFloat(T, tl, tr, bl, br, lr_frac, tb_frac),
        .@"struct" => {
            inline for (comptime meta.structFields(T)) |f| {
                const f_tl = @field(tl, f.name);
                const f_tr = @field(tr, f.name);
                const f_bl = @field(bl, f.name);
                const f_br = @field(br, f.name);

                const info = @typeInfo(f.type);
                @field(temp, f.name) = if (info == .int and info.int.bits <= 16)
                    lerpInt(f.type, f_tl, f_tr, f_bl, f_br, fx, fy)
                else
                    lerpFloat(f.type, f_tl, f_tr, f_bl, f_br, lr_frac, tb_frac);
            }
        },
        else => @compileError("Unsupported type for bilinear interpolation: " ++ @typeName(T)),
    }

    return temp;
}

fn interpolateBicubic(comptime T: type, self: Image(T), x: f32, y: f32, border: BorderMode) ?T {
    return interpolateWithKernel(T, self, x, y, 2, bicubicKernel, .{}, border);
}

fn interpolateCatmullRom(comptime T: type, self: Image(T), x: f32, y: f32, border: BorderMode) ?T {
    return interpolateWithKernel(T, self, x, y, 2, catmullRomKernel, .{}, border);
}

fn interpolateLanczos(comptime T: type, self: Image(T), x: f32, y: f32, border: BorderMode) ?T {
    return interpolateWithKernel(T, self, x, y, 3, lanczos3KernelLut, .{}, border);
}

fn interpolateMitchell(comptime T: type, self: Image(T), x: f32, y: f32, m_b: f32, m_c: f32, border: BorderMode) ?T {
    return interpolateWithKernel(T, self, x, y, 2, mitchellKernel, .{ m_b, m_c }, border);
}

/// Generic kernel-based interpolation function
fn interpolateWithKernel(
    comptime T: type,
    self: Image(T),
    x: f32,
    y: f32,
    comptime window_radius: usize,
    kernel_fn: anytype,
    kernel_params: anytype,
    border: BorderMode,
) ?T {
    const ix: isize = @floor(x);
    const iy: isize = @floor(y);
    const fx = x - as(f32, ix);
    const fy = y - as(f32, iy);

    const window_size = window_radius * 2;

    // Calculate weights
    var x_weights: [6]f32 = undefined; // Max window size is 6 for Lanczos3
    var y_weights: [6]f32 = undefined;

    inline for (0..window_size) |i| {
        const offset = @as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fx;
        if (kernel_params.len == 0) {
            x_weights[i] = kernel_fn(offset);
            y_weights[i] = kernel_fn(@as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fy);
        } else if (kernel_params.len == 1) {
            x_weights[i] = kernel_fn(offset, kernel_params[0]);
            y_weights[i] = kernel_fn(@as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fy, kernel_params[0]);
        } else if (kernel_params.len == 2) {
            x_weights[i] = kernel_fn(offset, kernel_params[0], kernel_params[1]);
            y_weights[i] = kernel_fn(@as(f32, @floatFromInt(@as(isize, @intCast(i)) - @as(isize, @intCast(window_radius - 1)))) - fy, kernel_params[0], kernel_params[1]);
        } else {
            @compileError("Unsupported number of kernel parameters");
        }
    }

    // Apply kernel
    var result: T = undefined;
    switch (@typeInfo(T)) {
        .int, .float => {
            var sum: f32 = 0;
            var weight_sum: f32 = 0;

            inline for (0..window_size) |j| {
                const row_idx = iy - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(j));
                if (resolveIndex(row_idx, @intCast(self.rows), border)) |pixel_y| {
                    inline for (0..window_size) |i| {
                        const col_idx = ix - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(i));
                        if (resolveIndex(col_idx, @intCast(self.cols), border)) |pixel_x| {
                            const pixel = self.at(pixel_y, pixel_x).*;
                            const weight = x_weights[i] * y_weights[j];
                            sum += as(f32, pixel) * weight;
                            weight_sum += weight;
                        }
                    }
                }
            }

            const val = if (weight_sum != 0) sum / weight_sum else 0;
            result = clamp(T, val);
        },
        .@"struct" => {
            const fields = comptime meta.structFields(T);
            var sums: [fields.len]f32 = @splat(0);
            var weight_sum: f32 = 0;

            inline for (0..window_size) |j| {
                const row_idx = iy - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(j));
                if (resolveIndex(row_idx, @intCast(self.rows), border)) |pixel_y| {
                    inline for (0..window_size) |i| {
                        const col_idx = ix - @as(isize, @intCast(window_radius - 1)) + @as(isize, @intCast(i));
                        if (resolveIndex(col_idx, @intCast(self.cols), border)) |pixel_x| {
                            const pixel = self.at(pixel_y, pixel_x).*;
                            const weight = x_weights[i] * y_weights[j];
                            inline for (fields, 0..) |f, f_idx| {
                                sums[f_idx] += as(f32, @field(pixel, f.name)) * weight;
                            }
                            weight_sum += weight;
                        }
                    }
                }
            }

            inline for (fields, 0..) |f, f_idx| {
                const val = if (weight_sum != 0) sums[f_idx] / weight_sum else 0;
                @field(result, f.name) = clamp(f.type, val);
            }
        },
        else => @compileError("Unsupported type for kernel interpolation: " ++ @typeName(T)),
    }

    return result;
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
