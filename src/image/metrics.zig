//! Image quality metrics (PSNR and SSIM).

const std = @import("std");
const meta = @import("../meta.zig");
const conversions = @import("../color/conversions.zig");

const Image = @import("../image.zig").Image;

pub fn psnr(comptime T: type, image_a: anytype, image_b: anytype) !f64 {
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
                    const diff = getScalarValue(T, image_a.data[idx_a]) - getScalarValue(T, image_b.data[idx_b]);
                    mse += diff * diff;
                    component_count += 1;
                },
                .@"struct" => {
                    inline for (std.meta.fields(T)) |field| {
                        const diff = getScalarValue(field.type, @field(image_a.data[idx_a], field.name)) - getScalarValue(field.type, @field(image_b.data[idx_b], field.name));
                        mse += diff * diff;
                        component_count += 1;
                    }
                },
                .array => |arr_info| {
                    for (0..arr_info.len) |i| {
                        const diff = getScalarValue(arr_info.child, image_a.data[idx_a][i]) - getScalarValue(arr_info.child, image_b.data[idx_b][i]);
                        mse += diff * diff;
                        component_count += 1;
                    }
                },
                else => @compileError("Unsupported pixel type for PSNR: " ++ @typeName(T)),
            }
        }
    }

    mse /= @as(f64, @floatFromInt(component_count));
    if (mse == 0.0) return std.math.inf(f64);

    const max_val: f64 = switch (@typeInfo(componentType(T))) {
        .int => |info| if (info.signedness == .unsigned)
            @floatFromInt(std.math.maxInt(componentType(T)))
        else
            @compileError("Signed integers not supported for PSNR"),
        .float => 1.0,
        else => unreachable,
    };

    return 20.0 * std.math.log10(max_val) - 10.0 * std.math.log10(mse);
}

pub fn ssim(comptime T: type, image_a: anytype, image_b: anytype) !f64 {
    if (image_a.rows != image_b.rows or image_a.cols != image_b.cols) {
        return error.DimensionMismatch;
    }
    if (image_a.rows < 11 or image_a.cols < 11) {
        return error.ImageTooSmall;
    }

    const L: f64 = switch (@typeInfo(componentType(T))) {
        .int => |info| if (info.signedness == .unsigned)
            @floatFromInt(std.math.maxInt(componentType(T)))
        else
            @compileError("Signed integers not supported for SSIM"),
        .float => 1.0,
        else => unreachable,
    };
    const k1: f64 = 0.01;
    const k2: f64 = 0.03;
    const c1 = (k1 * L) * (k1 * L);
    const c2 = (k2 * L) * (k2 * L);

    var ssim_sum: f64 = 0.0;
    var weight_sum: f64 = 0.0;

    const window_size = 11;
    const window_radius = window_size / 2;
    const gaussian_window = comptime generateSsimWindow();

    for (window_radius..image_a.rows - window_radius) |row| {
        for (window_radius..image_a.cols - window_radius) |col| {
            var mu_x: f64 = 0.0;
            var mu_y: f64 = 0.0;
            var mu_x_sq: f64 = 0.0;
            var mu_y_sq: f64 = 0.0;
            var mu_xy: f64 = 0.0;

            for (0..window_size) |dy| {
                for (0..window_size) |dx| {
                    const r = row - window_radius + dy;
                    const c = col - window_radius + dx;
                    const weight = gaussian_window[dy * window_size + dx];
                    const val_x = getPixelScalar(T, image_a.data[r * image_a.stride + c]);
                    const val_y = getPixelScalar(T, image_b.data[r * image_b.stride + c]);
                    mu_x += weight * val_x;
                    mu_y += weight * val_y;
                    mu_x_sq += weight * val_x * val_x;
                    mu_y_sq += weight * val_y * val_y;
                    mu_xy += weight * val_x * val_y;
                }
            }

            const sigma_x_sq = @max(0.0, mu_x_sq - mu_x * mu_x);
            const sigma_y_sq = @max(0.0, mu_y_sq - mu_y * mu_y);
            const sigma_xy = mu_xy - mu_x * mu_y;

            const numerator = (2.0 * mu_x * mu_y + c1) * (2.0 * sigma_xy + c2);
            const denominator = (mu_x * mu_x + mu_y * mu_y + c1) * (sigma_x_sq + sigma_y_sq + c2);
            ssim_sum += numerator / denominator;
            weight_sum += 1.0;
        }
    }

    return ssim_sum / weight_sum;
}

inline fn componentType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int, .float => T,
        .@"struct" => std.meta.fields(T)[0].type,
        .array => |info| info.child,
        else => T,
    };
}

inline fn getScalarValue(comptime ScalarType: type, value: ScalarType) f64 {
    return switch (@typeInfo(ScalarType)) {
        .int => @floatFromInt(value),
        .float => @floatCast(value),
        else => 0.0,
    };
}

inline fn getPixelScalar(comptime PixelType: type, pixel: PixelType) f64 {
    switch (@typeInfo(PixelType)) {
        .int, .float => return getScalarValue(PixelType, pixel),
        .@"struct" => {
            if (comptime meta.isRgb(PixelType)) {
                return pixel.luma();
            }
            var sum: f64 = 0.0;
            var count: usize = 0;
            inline for (std.meta.fields(PixelType)) |field| {
                sum += getScalarValue(field.type, @field(pixel, field.name));
                count += 1;
            }
            return sum / @as(f64, @floatFromInt(count));
        },
        .array => |info| {
            if (info.len == 3 or info.len == 4) {
                const r: u8 = convertChannelToU8(info.child, pixel[0]);
                const g: u8 = convertChannelToU8(info.child, pixel[1]);
                const b: u8 = convertChannelToU8(info.child, pixel[2]);
                return conversions.rgbLuma(r, g, b);
            }
            var sum: f64 = 0.0;
            inline for (0..info.len) |i| {
                sum += getScalarValue(info.child, pixel[i]);
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

fn generateSsimWindow() [121]f64 {
    const window_size = 11;
    const window_radius = window_size / 2;
    const sigma: f64 = 1.5;

    var gaussian_window: [window_size * window_size]f64 = undefined;
    var gaussian_sum: f64 = 0.0;

    for (0..window_size) |dy| {
        for (0..window_size) |dx| {
            const y: f64 = @as(f64, @floatFromInt(dy)) - @as(f64, @floatFromInt(window_radius));
            const x: f64 = @as(f64, @floatFromInt(dx)) - @as(f64, @floatFromInt(window_radius));
            const gauss = @exp(-(x * x + y * y) / (2.0 * sigma * sigma));
            gaussian_window[dy * window_size + dx] = gauss;
            gaussian_sum += gauss;
        }
    }
    for (&gaussian_window) |*w| w.* /= gaussian_sum;
    return gaussian_window;
}
