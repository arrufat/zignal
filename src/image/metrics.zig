//! Image quality metrics (PSNR and SSIM).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const meta = @import("../meta.zig");
const parallel = @import("../parallel.zig");
const convolution = @import("convolution.zig");
const color = @import("../color.zig");

const Image = @import("../image.zig").Image;
const testing = std.testing;

pub fn psnr(comptime T: type, image_a: Image(T), image_b: Image(T)) !f64 {
    if (image_a.rows != image_b.rows or image_a.cols != image_b.cols) {
        return error.DimensionMismatch;
    }

    var mse: f64 = 0.0;
    var component_count: usize = 0;
    for (0..image_a.rows) |r| {
        const row_offset_a = r * image_a.stride;
        const row_offset_b = r * image_b.stride;
        for (0..image_a.cols) |c| {
            const idx_a = row_offset_a + c;
            const idx_b = row_offset_b + c;
            switch (@typeInfo(T)) {
                .int, .float => {
                    const diff = meta.as(f64, image_a.data[idx_a]) - meta.as(f64, image_b.data[idx_b]);
                    mse += diff * diff;
                    component_count += 1;
                },
                .@"struct" => {
                    inline for (comptime meta.structFields(T)) |field| {
                        const diff = meta.as(f64, @field(image_a.data[idx_a], field.name)) - meta.as(f64, @field(image_b.data[idx_b], field.name));
                        mse += diff * diff;
                        component_count += 1;
                    }
                },
                .array => |arr_info| {
                    for (0..arr_info.len) |i| {
                        const diff = meta.as(f64, image_a.data[idx_a][i]) - meta.as(f64, image_b.data[idx_b][i]);
                        mse += diff * diff;
                        component_count += 1;
                    }
                },
                else => @compileError("Unsupported pixel type for PSNR: " ++ @typeName(T)),
            }
        }
    }

    if (component_count == 0) return error.ImageTooSmall;
    mse /= @as(f64, @floatFromInt(component_count));
    if (mse == 0.0) return std.math.inf(f64);

    const max_val = componentMaxValue(T);

    return 20.0 * std.math.log10(max_val) - 10.0 * std.math.log10(mse);
}

const ssim_window = 11;
/// Normalized 1D Gaussian (σ = 1.5); the 11×11 window of Wang et al. is its outer product.
const ssim_kernel: [ssim_window]f64 = blk: {
    var k: [ssim_window]f64 = undefined;
    convolution.fillGaussianKernel(f64, &k, 1.5);
    break :blk k;
};

/// `x` in every lane of `V`, which may also be plain `f64`.
inline fn splat(comptime V: type, x: f64) V {
    return if (V == f64) x else @splat(x);
}

/// SSIM of one window from its weighted moments E[x], E[y], E[x²], E[y²], E[xy].
inline fn ssimTerm(comptime T: type, comptime V: type, mu_x: V, mu_y: V, mu_xx: V, mu_yy: V, mu_xy: V) V {
    const l = componentMaxValue(T);
    const c1 = splat(V, (0.01 * l) * (0.01 * l));
    const c2 = splat(V, (0.03 * l) * (0.03 * l));
    const two = splat(V, 2);
    const zero = splat(V, 0);
    const sigma_x_sq = @max(zero, mu_xx - mu_x * mu_x);
    const sigma_y_sq = @max(zero, mu_yy - mu_y * mu_y);
    const sigma_xy = mu_xy - mu_x * mu_y;
    return (two * mu_x * mu_y + c1) * (two * sigma_xy + c2) / ((mu_x * mu_x + mu_y * mu_y + c1) * (sigma_x_sq + sigma_y_sq + c2));
}

/// Mean SSIM over every 11×11 window that fits (no padding), as separable vertical and
/// horizontal taps. Per-row sums are added in order, so the band count never changes the result.
pub fn ssim(comptime T: type, io: Io, allocator: Allocator, image_a: Image(T), image_b: Image(T)) !f64 {
    if (image_a.rows != image_b.rows or image_a.cols != image_b.cols) {
        return error.DimensionMismatch;
    }
    if (image_a.rows < ssim_window or image_a.cols < ssim_window) {
        return error.ImageTooSmall;
    }

    const cols = image_a.cols;
    const out_rows = image_a.rows - (ssim_window - 1);
    const out_cols = cols - (ssim_window - 1);
    // Each band reloads the 10 rows above its first window.
    const bands = parallel.bandCountFor(out_rows, cols, 4 * ssim_window);
    // Per band: a luma ring per image, then the five vertical moment rows.
    const scratch = try allocator.alloc(f64, out_rows + bands * (2 * ssim_window + 5) * cols);
    defer allocator.free(scratch);

    const Ctx = struct {
        a: Image(T),
        b: Image(T),
        row_sums: []f64,
        scratch: []f64,

        const lanes = std.simd.suggestVectorLength(f64) orelse 1;
        const V = @Vector(lanes, f64);

        fn band(c: *const @This(), index: usize, first: usize, last: usize) void {
            const n = c.a.cols;
            const buf = c.scratch[index * (2 * ssim_window + 5) * n ..];
            const xs = buf[0 .. ssim_window * n];
            const ys = buf[ssim_window * n ..][0 .. ssim_window * n];
            const m = buf[2 * ssim_window * n ..][0 .. 5 * n];

            for (first..first + ssim_window - 1) |r| c.loadRow(xs, ys, r);
            for (first..last) |o| {
                c.loadRow(xs, ys, o + ssim_window - 1);
                var slots: [ssim_window]usize = undefined;
                for (&slots, 0..) |*slot, dy| slot.* = ((o + dy) % ssim_window) * n;

                var col: usize = 0;
                while (col + lanes <= n) : (col += lanes) verticalTaps(V, xs, ys, m, n, slots, col);
                while (col < n) : (col += 1) verticalTaps(f64, xs, ys, m, n, slots, col);

                const windows = n - (ssim_window - 1);
                var acc: V = @splat(0);
                col = 0;
                while (col + lanes <= windows) : (col += lanes) acc += horizontalTaps(V, m, n, col);
                var sum = @reduce(.Add, acc);
                while (col < windows) : (col += 1) sum += horizontalTaps(f64, m, n, col);
                c.row_sums[o] = sum;
            }
        }

        fn load(comptime W: type, s: []const f64, i: usize) W {
            return if (W == f64) s[i] else s[i..][0..lanes].*;
        }

        fn store(comptime W: type, s: []f64, i: usize, v: W) void {
            if (W == f64) s[i] = v else s[i..][0..lanes].* = v;
        }

        inline fn verticalTaps(comptime W: type, xs: []const f64, ys: []const f64, m: []f64, n: usize, slots: [ssim_window]usize, col: usize) void {
            var sx = splat(W, 0);
            var sy = splat(W, 0);
            var sxx = splat(W, 0);
            var syy = splat(W, 0);
            var sxy = splat(W, 0);
            inline for (ssim_kernel, slots) |w, slot| {
                const x = load(W, xs, slot + col);
                const y = load(W, ys, slot + col);
                const wx = splat(W, w) * x;
                const wy = splat(W, w) * y;
                sx += wx;
                sy += wy;
                sxx += wx * x;
                syy += wy * y;
                sxy += wx * y;
            }
            store(W, m, col, sx);
            store(W, m, n + col, sy);
            store(W, m, 2 * n + col, sxx);
            store(W, m, 3 * n + col, syy);
            store(W, m, 4 * n + col, sxy);
        }

        inline fn horizontalTaps(comptime W: type, m: []const f64, n: usize, col: usize) W {
            var mu: [5]W = @splat(splat(W, 0));
            inline for (ssim_kernel, 0..) |w, dx| {
                inline for (&mu, 0..) |*acc, k| acc.* += splat(W, w) * load(W, m, k * n + col + dx);
            }
            return ssimTerm(T, W, mu[0], mu[1], mu[2], mu[3], mu[4]);
        }

        /// Luma of source row `r` into its ring slot.
        fn loadRow(c: *const @This(), xs: []f64, ys: []f64, r: usize) void {
            const n = c.a.cols;
            const slot = (r % ssim_window) * n;
            const row_a = c.a.data[r * c.a.stride ..][0..n];
            const row_b = c.b.data[r * c.b.stride ..][0..n];
            for (xs[slot..][0..n], ys[slot..][0..n], row_a, row_b) |*x, *y, pa, pb| {
                x.* = getPixelScalar(T, pa);
                y.* = getPixelScalar(T, pb);
            }
        }
    };
    const ctx: Ctx = .{ .a = image_a, .b = image_b, .row_sums = scratch[0..out_rows], .scratch = scratch[out_rows..] };
    parallel.forRowBands(io, out_rows, bands, &ctx, Ctx.band);

    var total: f64 = 0;
    for (ctx.row_sums) |s| total += s;
    return total / @as(f64, @floatFromInt(out_rows * out_cols));
}

pub fn meanPixelError(comptime T: type, image_a: Image(T), image_b: Image(T)) !f64 {
    if (image_a.rows != image_b.rows or image_a.cols != image_b.cols) {
        return error.DimensionMismatch;
    }

    var total_abs: f64 = 0.0;
    var component_count: usize = 0;

    for (0..image_a.rows) |r| {
        const row_offset_a = r * image_a.stride;
        const row_offset_b = r * image_b.stride;
        for (0..image_a.cols) |c| {
            const idx_a = row_offset_a + c;
            const idx_b = row_offset_b + c;
            switch (@typeInfo(T)) {
                .int, .float => {
                    const diff = @abs(meta.as(f64, image_a.data[idx_a]) - meta.as(f64, image_b.data[idx_b]));
                    total_abs += diff;
                    component_count += 1;
                },
                .@"struct" => {
                    inline for (comptime meta.structFields(T)) |field| {
                        const diff = @abs(
                            meta.as(f64, @field(image_a.data[idx_a], field.name)) -
                                meta.as(f64, @field(image_b.data[idx_b], field.name)),
                        );
                        total_abs += diff;
                        component_count += 1;
                    }
                },
                .array => |arr_info| {
                    for (0..arr_info.len) |i| {
                        const diff = @abs(
                            meta.as(f64, image_a.data[idx_a][i]) -
                                meta.as(f64, image_b.data[idx_b][i]),
                        );
                        total_abs += diff;
                        component_count += 1;
                    }
                },
                else => @compileError("Unsupported pixel type for meanPixelError: " ++ @typeName(T)),
            }
        }
    }

    if (component_count == 0) return 0.0;
    const mean_abs = total_abs / @as(f64, @floatFromInt(component_count));

    const max_val = componentMaxValue(T);
    if (max_val == 0) return 0.0;

    return mean_abs / max_val;
}

inline fn componentType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int, .float => T,
        .@"struct" => |info| info.field_types[0],
        .array => |info| info.child,
        else => T,
    };
}

inline fn componentMaxValue(comptime T: type) f64 {
    return switch (@typeInfo(componentType(T))) {
        .int => |info| if (info.signedness == .unsigned)
            @floatFromInt(std.math.maxInt(componentType(T)))
        else
            @compileError("Signed integers not supported for image metrics"),
        .float => 1.0,
        else => unreachable,
    };
}

inline fn getPixelScalar(comptime PixelType: type, pixel: PixelType) f64 {
    switch (@typeInfo(PixelType)) {
        .int, .float => return meta.as(f64, pixel),
        .@"struct" => {
            if (comptime meta.isRgb(PixelType)) {
                const max_val = componentMaxValue(PixelType);
                return color.rgbLuma(pixel.r, pixel.g, pixel.b) * max_val;
            }
            var sum: f64 = 0.0;
            var count: usize = 0;
            inline for (comptime meta.structFields(PixelType)) |field| {
                sum += meta.as(f64, @field(pixel, field.name));
                count += 1;
            }
            return sum / @as(f64, @floatFromInt(count));
        },
        .array => |info| {
            if (info.len == 3 or info.len == 4) {
                const r: u8 = convertChannelToU8(info.child, pixel[0]);
                const g: u8 = convertChannelToU8(info.child, pixel[1]);
                const b: u8 = convertChannelToU8(info.child, pixel[2]);
                const max_val = componentMaxValue(PixelType);
                return color.rgbLuma(r, g, b) * max_val;
            }
            var sum: f64 = 0.0;
            inline for (0..info.len) |i| {
                sum += meta.as(f64, pixel[i]);
            }
            return sum / @as(f64, @floatFromInt(info.len));
        },
        else => return 0.0,
    }
}

inline fn convertChannelToU8(comptime ChannelType: type, value: ChannelType) u8 {
    return switch (@typeInfo(ChannelType)) {
        .int => meta.clamp(u8, value),
        .float => meta.clamp(u8, value * 255.0),
        else => 0,
    };
}

test "meanPixelError: RGB example" {
    const Pixel = struct { r: u8, g: u8, b: u8 };

    var data_a = [_]Pixel{.{ .r = 255, .g = 0, .b = 0 }};
    var data_b = [_]Pixel{.{ .r = 0, .g = 0, .b = 0 }};

    const image_a: Image(Pixel) = .{
        .rows = 1,
        .cols = 1,
        .stride = 1,
        .data = &data_a,
    };
    const image_b: Image(Pixel) = .{
        .rows = 1,
        .cols = 1,
        .stride = 1,
        .data = &data_b,
    };

    const percent = try meanPixelError(Pixel, image_a, image_b);
    try testing.expectApproxEqAbs(1.0 / 3.0, percent, 1e-9);
}

test "ssim: rgb scales with luminance" {
    const Pixel = struct { r: u8, g: u8, b: u8 };
    const width = 12;
    const height = 12;
    var a_data: [width * height]Pixel = @splat(.{ .r = 0, .g = 0, .b = 0 });
    var b_data: [width * height]Pixel = @splat(.{ .r = 0, .g = 0, .b = 0 });

    for (0..height) |r| {
        for (0..width) |c| {
            const idx = r * width + c;
            a_data[idx] = if ((r + c) % 2 == 0) .{ .r = 255, .g = 0, .b = 0 } else .{ .r = 0, .g = 255, .b = 0 };
        }
    }

    const img_a: Image(Pixel) = .initFromSlice(height, width, &a_data);
    const img_b: Image(Pixel) = .initFromSlice(height, width, &b_data);

    const result = try ssim(Pixel, std.testing.io, testing.allocator, img_a, img_b);
    try testing.expect(result < 0.99);
}

test "ssim: matches the direct 11x11 window" {
    const Pixel = struct { r: u8, g: u8, b: u8 };
    const rows = 97;
    const cols = 83;
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    var a_data: [rows * cols]Pixel = undefined;
    var b_data: [rows * cols]Pixel = undefined;
    for (&a_data, &b_data) |*a, *b| {
        a.* = .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) };
        b.* = .{ .r = a.r / 2 + random.int(u8) / 4, .g = a.g, .b = a.b / 3 };
    }
    const img_a: Image(Pixel) = .initFromSlice(rows, cols, &a_data);
    const img_b: Image(Pixel) = .initFromSlice(rows, cols, &b_data);

    // Direct 2D window.
    const out_rows = rows - (ssim_window - 1);
    const out_cols = cols - (ssim_window - 1);
    var expected: f64 = 0;
    for (0..out_rows) |r| {
        for (0..out_cols) |c| {
            var mu: [5]f64 = @splat(0);
            for (0..ssim_window) |dy| {
                for (0..ssim_window) |dx| {
                    const w = ssim_kernel[dy] * ssim_kernel[dx];
                    const x = getPixelScalar(Pixel, img_a.at(r + dy, c + dx).*);
                    const y = getPixelScalar(Pixel, img_b.at(r + dy, c + dx).*);
                    mu[0] += w * x;
                    mu[1] += w * y;
                    mu[2] += w * x * x;
                    mu[3] += w * y * y;
                    mu[4] += w * x * y;
                }
            }
            expected += ssimTerm(Pixel, f64, mu[0], mu[1], mu[2], mu[3], mu[4]);
        }
    }
    expected /= out_rows * out_cols;

    const result = try ssim(Pixel, testing.io, testing.allocator, img_a, img_b);
    try testing.expectApproxEqRel(expected, result, 1e-12);
}

test "ssim: banded result equals the serial one" {
    // Large enough for several bands.
    const rows = 480;
    const cols = 320;
    const a_data = try testing.allocator.alloc(u8, rows * cols);
    defer testing.allocator.free(a_data);
    const b_data = try testing.allocator.alloc(u8, rows * cols);
    defer testing.allocator.free(b_data);
    var prng: std.Random.DefaultPrng = .init(11);
    const random = prng.random();
    for (a_data, b_data) |*a, *b| {
        a.* = random.int(u8);
        b.* = a.* / 2 + random.int(u8) / 2;
    }
    const img_a: Image(u8) = .initFromSlice(rows, cols, a_data);
    const img_b: Image(u8) = .initFromSlice(rows, cols, b_data);

    const serial = try ssim(u8, parallel.inline_io, testing.allocator, img_a, img_b);
    const banded = try ssim(u8, testing.io, testing.allocator, img_a, img_b);
    try testing.expectEqual(serial, banded);
}
