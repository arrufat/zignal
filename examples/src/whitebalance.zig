const std = @import("std");
const builtin = @import("builtin");

const Image = @import("zignal").Image;
const Rgba = @import("zignal").Rgba(u8);
const Rgb = @import("zignal").Rgb(u8);
const Xyz = @import("zignal").Xyz(f64);

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

const RgbGains = struct {
    r: f64,
    g: f64,
    b: f64,
};

fn estimateIlluminant(image: Image(Rgba), color: Rgb, fraction: f64) RgbGains {
    var sum_r: f64 = 0;
    var sum_g: f64 = 0;
    var sum_b: f64 = 0;
    // Compute the average color per channel
    const sep: usize = @intFromFloat(@as(f32, @floatFromInt(image.rows)) * fraction);
    const size: f64 = @floatFromInt(image.cols * image.rows);

    // Process original pixels up to separation point
    const sep_pixels = sep * image.cols;
    var i: usize = 0;
    while (i + 4 <= sep_pixels) : (i += 4) {
        const p0 = image.data[i];
        const p1 = image.data[i + 1];
        const p2 = image.data[i + 2];
        const p3 = image.data[i + 3];

        sum_r += @as(f64, @floatFromInt(p0.r)) + @as(f64, @floatFromInt(p1.r)) + @as(f64, @floatFromInt(p2.r)) + @as(f64, @floatFromInt(p3.r));
        sum_g += @as(f64, @floatFromInt(p0.g)) + @as(f64, @floatFromInt(p1.g)) + @as(f64, @floatFromInt(p2.g)) + @as(f64, @floatFromInt(p3.g));
        sum_b += @as(f64, @floatFromInt(p0.b)) + @as(f64, @floatFromInt(p1.b)) + @as(f64, @floatFromInt(p2.b)) + @as(f64, @floatFromInt(p3.b));
    }
    while (i < sep_pixels) : (i += 1) {
        const p = image.data[i];
        sum_r += @floatFromInt(p.r);
        sum_g += @floatFromInt(p.g);
        sum_b += @floatFromInt(p.b);
    }

    // Process remaining pixels with color replacement
    for (sep..image.rows) |r| {
        for (0..image.cols) |c| {
            const p = image.at(r, c);
            p.r = color.r;
            p.g = color.g;
            p.b = color.b;
            sum_r += @floatFromInt(p.r);
            sum_g += @floatFromInt(p.g);
            sum_b += @floatFromInt(p.b);
        }
    }
    sum_r /= size;
    sum_g /= size;
    sum_b /= size;
    const avg = (sum_r + sum_g + sum_b) / 3.0;
    return .{ .r = sum_r / avg, .g = sum_g / avg, .b = sum_b / avg };
}

fn chromaticAdaptation(xyz: Xyz, w: RgbGains) Xyz {
    // Target illuminant (D65): LMS = (0.9642, 1.0000, 0.8252) (approx.)
    var lms = xyz.to(.lms);
    lms.l *= 0.9642 / w.r;
    lms.m *= 1.0000 / w.g;
    lms.s *= 0.8252 / w.b;
    return lms.to(.xyz);
}

fn whitebalanceSimd(pixels: []Rgba, w: RgbGains) void {
    // Pre-calculate white balance factors
    const wr: f32 = @floatCast(0.9642 / w.r);
    const wg: f32 = @floatCast(1.0000 / w.g);
    const wb: f32 = @floatCast(0.8252 / w.b);

    var i: usize = 0;
    const simd_len = 4;

    // Process 4 pixels at a time with SIMD
    while (i + simd_len <= pixels.len) : (i += simd_len) {
        // Load 4 pixels as vectors
        var pixel_vecs: [4]@Vector(4, f32) = undefined;
        for (0..simd_len) |j| {
            const pixel = pixels[i + j];
            pixel_vecs[j] = @Vector(4, f32){
                @floatFromInt(pixel.r),
                @floatFromInt(pixel.g),
                @floatFromInt(pixel.b),
                @floatFromInt(pixel.a),
            };
        }

        // Process each pixel using vector operations
        for (0..simd_len) |j| {
            const rgb_vec = pixel_vecs[j] / @as(@Vector(4, f32), @splat(255.0));

            // RGB to XYZ conversion
            const x = rgb_vec[0] * 0.4124 + rgb_vec[1] * 0.3576 + rgb_vec[2] * 0.1805;
            const y = rgb_vec[0] * 0.2126 + rgb_vec[1] * 0.7152 + rgb_vec[2] * 0.0722;
            const z = rgb_vec[0] * 0.0193 + rgb_vec[1] * 0.1192 + rgb_vec[2] * 0.9505;

            // XYZ to LMS
            const l = x * 0.7328 + y * 0.4296 + z * (-0.1624);
            const m = x * (-0.7036) + y * 1.6975 + z * 0.0061;
            const s = x * 0.0030 + y * 0.0136 + z * 0.9834;

            // Apply white balance
            const l_wb = l * wr;
            const m_wb = m * wg;
            const s_wb = s * wb;

            // LMS back to XYZ
            const x_new = l_wb * 1.0961 + m_wb * (-0.2789) + s_wb * 0.1827;
            const y_new = l_wb * 0.4544 + m_wb * 0.4735 + s_wb * 0.0721;
            const z_new = l_wb * (-0.0096) + m_wb * (-0.0057) + s_wb * 1.0153;

            // XYZ back to RGB
            const r_new = x_new * 3.2406 + y_new * (-1.5372) + z_new * (-0.4986);
            const g_new = x_new * (-0.9689) + y_new * 1.8758 + z_new * 0.0415;
            const b_new = x_new * 0.0557 + y_new * (-0.2040) + z_new * 1.0570;

            // Clamp and convert back to u8
            const r_clamped = @max(0.0, @min(1.0, r_new));
            const g_clamped = @max(0.0, @min(1.0, g_new));
            const b_clamped = @max(0.0, @min(1.0, b_new));

            pixels[i + j].r = @intFromFloat(@round(r_clamped * 255.0));
            pixels[i + j].g = @intFromFloat(@round(g_clamped * 255.0));
            pixels[i + j].b = @intFromFloat(@round(b_clamped * 255.0));
        }
    }

    // Handle remaining pixels
    while (i < pixels.len) : (i += 1) {
        pixels[i] = chromaticAdaptation(pixels[i].as(f64).to(.xyz), w)
            .to(.rgb)
            .as(u8)
            .withAlpha(pixels[i].a);
    }
}

pub export fn whitebalance(rgba_ptr: [*]Rgba, rows: usize, cols: usize, r: u8, g: u8, b: u8) void {
    const color: Rgb = .{ .r = r, .g = g, .b = b };
    std.log.info("color: {}, {}, {}\n", color);
    const image: Image(Rgba) = .initFromSlice(rows, cols, rgba_ptr[0 .. rows * cols]);
    const w = estimateIlluminant(image, color, 0.7);
    whitebalanceSimd(image.data, w);
}
