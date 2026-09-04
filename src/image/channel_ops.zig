//! Channel separation and combination operations for image processing
//!
//! This module provides utilities for separating multi-channel images into
//! individual planes and recombining them. This enables optimized single-channel
//! processing using SIMD and integer arithmetic.

const std = @import("std");
const Io = std.Io;
const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const parallel = @import("../parallel.zig");
const resolveIndex = @import("border.zig").resolveIndex;
const quantizeKernel = @import("convolution.zig").quantizeKernel;

/// Find the uniform value of a channel if all values are the same.
/// Returns the uniform value if all elements are identical, null otherwise.
pub fn findUniformValue(comptime T: type, data: []const T) ?T {
    if (data.len == 0) return null;
    const first = data[0];

    // Use SIMD for faster checking on larger arrays
    const vec_len = std.simd.suggestVectorLength(T) orelse 1;
    if (vec_len > 1 and data.len >= vec_len * 4) {
        // SIMD path for faster uniformity check
        const first_vec: @Vector(vec_len, T) = @splat(first);
        var i: u32 = 0;
        while (i + vec_len <= data.len) : (i += vec_len) {
            const vec: @Vector(vec_len, T) = data[i..][0..vec_len].*;
            if (@reduce(.Or, vec != first_vec)) return null;
        }
        // Check remaining elements
        while (i < data.len) : (i += 1) {
            if (data[i] != first) return null;
        }
    } else {
        // Scalar path for small arrays or non-SIMD types
        for (data[1..]) |val| {
            if (val != first) return null;
        }
    }
    return first;
}

/// Get the common type of all fields in a struct, or compile error if not uniform
pub fn FieldTypeOf(comptime T: type) type {
    const fields = comptime meta.structFields(T);
    if (fields.len == 0) @compileError("Type " ++ @typeName(T) ++ " has no fields");

    const first_type = fields[0].type;
    inline for (fields[1..]) |field| {
        if (field.type != first_type) {
            @compileError("Fields of " ++ @typeName(T) ++ " are not all the same type");
        }
    }
    return first_type;
}

/// Allocate `N` planes of `plane_size` elements each, freeing the partial set if an
/// allocation fails mid-loop. The caller owns and frees the returned slices.
pub fn allocPlanes(comptime P: type, comptime N: usize, allocator: std.mem.Allocator, plane_size: usize) ![N][]P {
    var planes: [N][]P = undefined;
    var allocated: usize = 0;
    errdefer for (planes[0..allocated]) |plane| allocator.free(plane);
    for (&planes) |*plane| {
        plane.* = try allocator.alloc(P, plane_size);
        allocated += 1;
    }
    return planes;
}

/// Separate all channels from a struct image into individual planes while tracking uniform channels.
pub fn splitChannelsWithUniform(comptime T: type, io: Io, image: Image(T), allocator: std.mem.Allocator) !struct {
    channels: [Image(T).channels()][]FieldTypeOf(T),
    uniforms: [Image(T).channels()]?FieldTypeOf(T),
} {
    const num_channels = comptime Image(T).channels();
    const FieldType = FieldTypeOf(T);

    const channels = try splitChannels(T, io, image, allocator);
    errdefer for (channels) |plane| allocator.free(plane);

    // Detecting uniformity on the split planes (SIMD, early-exit) beats per-pixel flags in the deinterleave loop.
    const bands = parallel.bandCount(image.rows, image.cols);
    const band_uniforms = try allocator.alloc(?FieldType, bands * num_channels);
    defer allocator.free(band_uniforms);
    const Ctx = struct {
        channels: [num_channels][]FieldType,
        cols: usize,
        band_uniforms: []?FieldType,

        fn band(ctx: *const @This(), b: usize, r0: usize, r1: usize) void {
            for (ctx.channels, 0..) |plane, i| {
                ctx.band_uniforms[b * num_channels + i] = findUniformValue(FieldType, plane[r0 * ctx.cols .. r1 * ctx.cols]);
            }
        }
    };
    const ctx: Ctx = .{ .channels = channels, .cols = image.cols, .band_uniforms = band_uniforms };
    parallel.forRowBands(io, image.rows, bands, &ctx, Ctx.band);

    var uniforms: [num_channels]?FieldType = undefined;
    for (&uniforms, 0..) |*slot, i| {
        slot.* = band_uniforms[i];
        for (1..bands) |b| {
            if (slot.* == null or band_uniforms[b * num_channels + i] != slot.*) slot.* = null;
        }
    }
    return .{ .channels = channels, .uniforms = uniforms };
}

/// SIMD lanes for (de)interleaving a padding-free struct row viewed as a flat field array;
/// null when the struct has padding and the row cannot be reinterpreted.
fn interleaveLanes(comptime T: type) ?usize {
    if (@sizeOf(T) != Image(T).channels() * @sizeOf(FieldTypeOf(T))) return null;
    return std.simd.suggestVectorLength(FieldTypeOf(T)) orelse null;
}

/// Position of each field inside the flat field array (fields may be laid out in any order).
fn fieldSlots(comptime T: type) [Image(T).channels()]usize {
    const fields = meta.structFields(T);
    var slots: [fields.len]usize = undefined;
    for (fields, &slots) |field, *slot| slot.* = @offsetOf(T, field.name) / @sizeOf(FieldTypeOf(T));
    return slots;
}

/// Separate all channels from a struct image into individual planes, in row bands on `io`.
/// Allocates and fills channel planes for all fields.
/// The caller is responsible for freeing the returned slices.
pub fn splitChannels(comptime T: type, io: Io, image: Image(T), allocator: std.mem.Allocator) ![Image(T).channels()][]FieldTypeOf(T) {
    const num_channels = comptime Image(T).channels();
    const plane_size = @as(usize, image.rows) * image.cols;
    const channels = try allocPlanes(FieldTypeOf(T), num_channels, allocator, plane_size);
    const ctx: PlaneBands(T, []FieldTypeOf(T)) = .{ .image = image, .channels = channels };
    parallel.forRowBands(io, image.rows, parallel.bandCount(image.rows, image.cols), &ctx, @TypeOf(ctx).split);
    return channels;
}

/// Combine channels back into a struct image, in row bands on `io`.
pub fn mergeChannels(comptime T: type, io: Io, channels: [Image(T).channels()][]const FieldTypeOf(T), out: Image(T)) void {
    const ctx: PlaneBands(T, []const FieldTypeOf(T)) = .{ .image = out, .channels = channels };
    parallel.forRowBands(io, out.rows, parallel.bandCount(out.rows, out.cols), &ctx, @TypeOf(ctx).merge);
}

/// Row bands of the (de)interleave passes: one contiguous row at a time (rows handle views),
/// SIMD (de)interleave, scalar tail. Plane index of row `r` is `r * cols`.
fn PlaneBands(comptime T: type, comptime Plane: type) type {
    return struct {
        const num_channels = Image(T).channels();
        const fields = meta.structFields(T);
        const FieldType = FieldTypeOf(T);

        image: Image(T),
        channels: [num_channels]Plane,

        fn split(ctx: *const @This(), _: usize, r0: usize, r1: usize) void {
            const image = ctx.image;
            const channels = ctx.channels;
            for (r0..r1) |r| {
                const idx = r * image.cols;
                const row = image.data[r * image.stride ..][0..image.cols];
                var c: usize = 0;
                if (comptime interleaveLanes(T)) |lanes| {
                    const slots = comptime fieldSlots(T);
                    const flat: [*]const FieldType = @ptrCast(row.ptr);
                    while (c + lanes <= row.len) : (c += lanes) {
                        const v: @Vector(num_channels * lanes, FieldType) = flat[c * num_channels ..][0 .. num_channels * lanes].*;
                        const planes = std.simd.deinterlace(num_channels, v);
                        inline for (slots, 0..) |slot, i| channels[i][idx + c ..][0..lanes].* = planes[slot];
                    }
                }
                for (row[c..], c..) |pixel, cc| {
                    inline for (fields, 0..) |field, i| {
                        channels[i][idx + cc] = @field(pixel, field.name);
                    }
                }
            }
        }

        fn merge(ctx: *const @This(), _: usize, r0: usize, r1: usize) void {
            const out = ctx.image;
            const channels = ctx.channels;
            for (r0..r1) |r| {
                const idx = r * out.cols;
                const row = out.data[r * out.stride ..][0..out.cols];
                var c: usize = 0;
                if (comptime interleaveLanes(T)) |lanes| {
                    const slots = comptime fieldSlots(T);
                    const flat: [*]FieldType = @ptrCast(row.ptr);
                    while (c + lanes <= row.len) : (c += lanes) {
                        var planes: [num_channels]@Vector(lanes, FieldType) = undefined;
                        inline for (slots, 0..) |slot, i| planes[slot] = channels[i][idx + c ..][0..lanes].*;
                        flat[c * num_channels ..][0 .. num_channels * lanes].* = std.simd.interlace(planes);
                    }
                }
                for (row[c..], c..) |*pixel, cc| {
                    var result_pixel: T = undefined;
                    inline for (fields, 0..) |field, i| {
                        @field(result_pixel, field.name) = channels[i][idx + cc];
                    }
                    pixel.* = result_pixel;
                }
            }
        }
    };
}

// ============================================================================
// Direct plane resize: output rows [r_start, r_end) of a dst_rows x dst_cols plane
// ============================================================================

/// Nearest neighbor resize of a contiguous plane; `channels` > 1 means interleaved pixels
/// of `channels` elements each (dimensions count pixels).
pub fn resizePlaneNearest(
    comptime P: type,
    comptime channels: usize,
    src: []const P,
    dst: []P,
    src_rows: u32,
    src_cols: u32,
    dst_rows: u32,
    dst_cols: u32,
    r_start: usize,
    r_end: usize,
) void {
    const x_ratio = @as(f32, @floatFromInt(src_cols)) / @as(f32, @floatFromInt(dst_cols));
    const y_ratio = @as(f32, @floatFromInt(src_rows)) / @as(f32, @floatFromInt(dst_rows));

    for (r_start..r_end) |r| {
        const src_y_f = (@as(f32, @floatFromInt(r)) + 0.5) * y_ratio - 0.5;
        const src_y = @max(0, @min(src_rows - 1, @as(u32, @round(src_y_f))));

        for (0..dst_cols) |c| {
            const src_x_f = (@as(f32, @floatFromInt(c)) + 0.5) * x_ratio - 0.5;
            const src_x = @max(0, @min(src_cols - 1, @as(u32, @round(src_x_f))));
            dst[(r * dst_cols + c) * channels ..][0..channels].* = src[(@as(usize, src_y) * src_cols + src_x) * channels ..][0..channels].*;
        }
    }
}

// ============================================================================
// Separable plane resize (bilinear, bicubic, Catmull-Rom, Mitchell, Lanczos)
// ============================================================================

const interpolation = @import("interpolation.zig");
const Interpolation = interpolation.Interpolation;

/// Fixed-point weight precision; two passes leave 2·weight_shift bits of headroom in an i32
/// (255 · 1.4 · 1024 per pass with the negative lobes).
pub const weight_shift = 10;
pub const weight_scale = 1 << weight_shift;
pub const max_taps = 6;

/// Mirror-resolved source indices and weights for every output position along one axis,
/// as fixed point for u8 planes (each position sums to exactly `weight_scale`) and as unit
/// gain floats for f32 planes, so the passes need no per-pixel normalization; the kernel is
/// evaluated `taps` times per output position instead of `taps²` per pixel.
pub fn AxisTaps(comptime P: type) type {
    return struct {
        const Self = @This();

        taps: usize,
        indices: []u32,
        weights: []Accum(P),

        pub fn init(allocator: std.mem.Allocator, src_len: u32, dst_len: u32, method: Interpolation) !Self {
            const taps = interpolation.kernelTaps(method);
            const indices = try allocator.alloc(u32, @as(usize, dst_len) * taps);
            errdefer allocator.free(indices);
            const weights = try allocator.alloc(Accum(P), @as(usize, dst_len) * taps);
            const ratio = @as(f32, @floatFromInt(src_len)) / @as(f32, @floatFromInt(dst_len));

            for (0..dst_len) |i| {
                const center = (@as(f32, @floatFromInt(i)) + 0.5) * ratio - 0.5;
                const base: isize = @as(isize, @floor(center)) - @as(isize, @intCast(taps / 2 - 1));
                var raw: [max_taps]f32 = undefined;
                var sum: f32 = 0;
                for (0..taps) |t| {
                    const x = base + @as(isize, @intCast(t));
                    raw[t] = interpolation.kernelWeight(method, center - @as(f32, @floatFromInt(x)));
                    sum += raw[t];
                    indices[i * taps + t] = @intCast(resolveIndex(x, @intCast(src_len), .mirror).?);
                }
                for (raw[0..taps]) |*r| r.* /= sum;
                const w = weights[i * taps ..][0..taps];
                if (P == u8) quantizeKernel(w, raw[0..taps], weight_scale) else @memcpy(w, raw[0..taps]);
            }
            return .{ .taps = taps, .indices = indices, .weights = weights };
        }

        pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
            allocator.free(self.indices);
            allocator.free(self.weights);
        }

        fn weightsAt(self: Self, pos: usize) []const Accum(P) {
            return self.weights[pos * self.taps ..][0..self.taps];
        }
    };
}

/// Intermediate plane and accumulator type of the separable passes for plane type `P`.
pub fn Accum(comptime P: type) type {
    return switch (P) {
        u8 => i32,
        f32 => f32,
        else => @compileError("separable resize supports u8 and f32 planes, not " ++ @typeName(P)),
    };
}

/// Horizontal pass: source rows `[r_start, r_end)` of `src` (`src_cols` pixels wide)
/// resampled through `x_taps` into `mid` (`dst_cols` pixels wide) as unnormalized sums.
/// `channels` > 1 means interleaved pixels; the taps index pixels, every channel of each.
pub fn resizeRows(comptime P: type, comptime channels: usize, src: []const P, src_cols: u32, x_taps: AxisTaps(P), mid: []Accum(P), dst_cols: u32, r_start: usize, r_end: usize) void {
    const A = Accum(P);
    const taps = x_taps.taps;
    for (r_start..r_end) |r| {
        const row = src[r * src_cols * channels ..][0 .. src_cols * channels];
        const out = mid[r * dst_cols * channels ..][0 .. dst_cols * channels];
        for (0..dst_cols) |c| {
            var acc: [channels]A = @splat(0);
            for (x_taps.indices[c * taps ..][0..taps], x_taps.weightsAt(c)) |idx, w| {
                inline for (0..channels) |ch| acc[ch] += w * @as(A, row[idx * channels + ch]);
            }
            out[c * channels ..][0..channels].* = acc;
        }
    }
}

/// Vertical pass: output rows `[r_start, r_end)` of `dst` (`cols` elements wide) from `mid`
/// through `y_taps`; u8 planes are rounded and clamped, f32 planes stored as is.
pub fn resizeColumns(comptime P: type, mid: []const Accum(P), cols: usize, y_taps: AxisTaps(P), dst: []P, r_start: usize, r_end: usize) void {
    const A = Accum(P);
    const vec_len = std.simd.suggestVectorLength(A) orelse 1;
    const V = @Vector(vec_len, A);
    const taps = y_taps.taps;
    const shift = 2 * weight_shift;
    const half: A = if (P == u8) 1 << (shift - 1) else 0;

    for (r_start..r_end) |r| {
        const rows = y_taps.indices[r * taps ..][0..taps];
        const weights = y_taps.weightsAt(r);
        const out = dst[r * cols ..][0..cols];
        var c: usize = 0;
        while (c + vec_len <= cols) : (c += vec_len) {
            var acc: V = @splat(half);
            for (rows, weights) |row, w| {
                acc += @as(V, @splat(w)) * @as(V, mid[row * cols + c ..][0..vec_len].*);
            }
            if (P == u8) {
                const scaled = acc >> @splat(shift);
                out[c..][0..vec_len].* = meta.narrowToBytes(std.math.clamp(scaled, @as(V, @splat(0)), @as(V, @splat(255))));
            } else {
                out[c..][0..vec_len].* = acc;
            }
        }
        while (c < cols) : (c += 1) {
            var acc: A = half;
            for (rows, weights) |row, w| acc += w * mid[row * cols + c];
            out[c] = if (P == u8) meta.clamp(u8, acc >> shift) else acc;
        }
    }
}

test "axis taps sum to unit gain and stay in bounds" {
    const allocator = std.testing.allocator;
    for ([_]Interpolation{ .bilinear, .bicubic, .catmull_rom, .{ .mitchell = .default }, .lanczos }) |method| {
        for ([_][2]u32{ .{ 640, 97 }, .{ 13, 401 }, .{ 5, 5 } }) |lens| {
            const taps: AxisTaps(u8) = try .init(allocator, lens[0], lens[1], method);
            defer taps.deinit(allocator);
            for (0..lens[1]) |i| {
                var sum: i32 = 0;
                for (taps.weights[i * taps.taps ..][0..taps.taps]) |w| sum += w;
                try std.testing.expectEqual(weight_scale, sum);
                for (taps.indices[i * taps.taps ..][0..taps.taps]) |idx| try std.testing.expect(idx < lens[0]);
            }
        }
    }
}
