const std = @import("std");
const builtin = @import("builtin");

const Rgba = @import("zignal").Rgba(u8);
const Rgb = @import("zignal").Rgb(u8);
const Xyz = @import("zignal").Xyz(f64);

const js = @import("js.zig");

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

comptime {
    _ = js.alloc;
    _ = js.free;
}

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

fn illuminantFromReference(color: Rgb) RgbGains {
    // Custom white balance: treat the picked color as the illuminant — the color
    // a neutral surface takes under the current light. Normalizing it to unit
    // average yields the per-channel gains that map it back to neutral, which the
    // adaptation then applies to the whole frame. Clamp channels to one 8-bit step
    // so a saturated pick can't divide by zero.
    const c = color.as(f64);
    const eps = 1.0 / 255.0;
    const r = @max(c.r, eps);
    const g = @max(c.g, eps);
    const b = @max(c.b, eps);
    const avg = (r + g + b) / 3.0;
    return .{ .r = r / avg, .g = g / avg, .b = b / avg };
}

fn illuminantFromScene(pixels: []const Rgba) RgbGains {
    // Auto white balance: gray-world assumes the scene averages to neutral, so the
    // per-channel average is the illuminant. Normalizing to unit average gives the
    // gains — no reference color needed.
    var sum_r: f64 = 0;
    var sum_g: f64 = 0;
    var sum_b: f64 = 0;
    for (pixels) |p| {
        const c = p.as(f64);
        sum_r += c.r;
        sum_g += c.g;
        sum_b += c.b;
    }
    const avg = (sum_r + sum_g + sum_b) / 3.0;
    if (avg <= 0) return .{ .r = 1, .g = 1, .b = 1 };
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

            pixels[i + j].r = @round(r_clamped * 255.0);
            pixels[i + j].g = @round(g_clamped * 255.0);
            pixels[i + j].b = @round(b_clamped * 255.0);
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

pub export fn whitebalance(rgba_ptr: [*]Rgba, rows: u32, cols: u32, r: u8, g: u8, b: u8, gray_world: bool) void {
    const pixels = rgba_ptr[0 .. @as(usize, rows) * cols];
    const w = if (gray_world)
        illuminantFromScene(pixels)
    else
        illuminantFromReference(.{ .r = r, .g = g, .b = b });
    whitebalanceSimd(pixels, w);
}
