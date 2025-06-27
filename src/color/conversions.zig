//! Color space conversion utilities and functions.
//!
//! This module provides comprehensive conversion functions between all supported color spaces,
//! a generic `convert()` function, and color type validation utilities.

const std = @import("std");
const assert = std.debug.assert;
const lerp = std.math.lerp;
const pow = std.math.pow;

const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");

/// Returns true if, and only if, `T` is a known color.
pub fn isColor(comptime T: type) bool {
    return switch (T) {
        u8, Rgb, Rgba, Hsl, Hsv, Lab, Xyz, Lms, Oklab, Xyb => true,
        else => false,
    };
}

/// Generic function to convert `color` into colorspace `T`.
pub fn convert(comptime T: type, color: anytype) T {
    const ColorType: type = @TypeOf(color);
    comptime assert(isColor(T));
    comptime assert(isColor(ColorType));

    return switch (T) {
        u8 => switch (ColorType) {
            u8 => color,
            inline else => color.toGray(),
        },
        Rgb => switch (ColorType) {
            Rgb => color,
            u8 => .{ .r = color, .g = color, .b = color },
            inline else => color.toRgb(),
        },
        Rgba => switch (ColorType) {
            Rgba => color,
            u8 => .{ .r = color, .g = color, .b = color, .a = 255 },
            inline else => color.toRgba(255),
        },
        Hsl => switch (ColorType) {
            Hsl => color,
            u8 => .{ .h = 0, .s = 0, .l = @as(f64, @floatFromInt(color)) / 255 * 100 },
            inline else => color.toHsl(),
        },
        Hsv => switch (ColorType) {
            Hsv => color,
            u8 => .{ .h = 0, .s = 0, .v = @as(f64, @floatFromInt(color)) / 255 * 100 },
            inline else => color.toHsv(),
        },
        Lab => switch (ColorType) {
            Lab => color,
            u8 => .{ .l = @as(f64, @floatFromInt(color)) / 255 * 100, .a = 0, .b = 0 },
            inline else => color.toLab(),
        },
        Xyz => switch (ColorType) {
            Xyz => color,
            u8 => Rgb.fromGray(color).toXyz(),
            inline else => color.toXyz(),
        },
        Lms => switch (ColorType) {
            Lms => color,
            u8 => Rgb.fromGray(color).toLms(),
            inline else => color.toLms(),
        },
        Oklab => switch (ColorType) {
            Oklab => color,
            u8 => Rgb.fromGray(color).toOklab(),
            inline else => color.toOklab(),
        },
        Xyb => switch (ColorType) {
            Xyb => color,
            u8 => Rgb.fromGray(color).toXyb(),
            inline else => color.toXyb(),
        },
        else => @compileError("Unsupported color " ++ @typeName(T)),
    };
}

inline fn linearToGamma(x: f64) f64 {
    return if (x > 0.0031308) 1.055 * pow(f64, x, (1.0 / 2.4)) - 0.055 else x * 12.92;
}

inline fn gammaToLinear(x: f64) f64 {
    return if (x > 0.04045) pow(f64, (x + 0.055) / 1.055, 2.4) else x / 12.92;
}

const RgbFloat = struct {
    r: f64,
    g: f64,
    b: f64,

    pub fn fromRgb(r: u8, g: u8, b: u8) RgbFloat {
        return .{
            .r = @as(f64, @floatFromInt(r)) / 255,
            .g = @as(f64, @floatFromInt(g)) / 255,
            .b = @as(f64, @floatFromInt(b)) / 255,
        };
    }

    pub fn toRgb(self: RgbFloat) Rgb {
        return .{
            .r = @intFromFloat(@round(255 * @max(0, @min(1, self.r)))),
            .g = @intFromFloat(@round(255 * @max(0, @min(1, self.g)))),
            .b = @intFromFloat(@round(255 * @max(0, @min(1, self.b)))),
        };
    }

    pub fn luma(self: RgbFloat) f64 {
        return 0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b;
    }
};

/// Converts the RGB color into an HSL color by calculating:
/// - Minimum and maximum color values
/// - Delta between max and min
/// - Hue based on which color channel is max
/// - Lightness as average of max and min
/// - Saturation based on delta and lightness
pub fn rgbToHsl(rgb: Rgb) Hsl {
    const rgb_float = RgbFloat.fromRgb(rgb.r, rgb.g, rgb.b);
    const min = @min(rgb_float.r, @min(rgb_float.g, rgb_float.b));
    const max = @max(rgb_float.r, @max(rgb_float.g, rgb_float.b));
    const delta = max - min;

    const hue = if (delta == 0) 0 else blk: {
        if (max == rgb_float.r) {
            break :blk (rgb_float.g - rgb_float.b) / delta;
        } else if (max == rgb_float.g) {
            break :blk 2 + (rgb_float.b - rgb_float.r) / delta;
        } else {
            break :blk 4 + (rgb_float.r - rgb_float.g) / delta;
        }
    };

    const l = (max + min) / 2.0;
    const s = if (delta == 0) 0 else if (l < 0.5) delta / (2 * l) else delta / (2 - 2 * l);

    return .{
        .h = @mod(hue * 60.0, 360.0),
        .s = @max(0, @min(1, s)) * 100.0,
        .l = @max(0, @min(1, l)) * 100.0,
    };
}

/// Converts HSL to RGB using the standard algorithm:
/// - Calculates hue sector and fractional part
/// - Applies saturation and lightness transformations
/// - Maps to RGB values based on hue sector
pub fn hslToRgb(hsl: Hsl) Rgb {
    const h = @max(0, @min(360, hsl.h));
    const s = @max(0, @min(1, hsl.s / 100));
    const l = @max(0, @min(1, hsl.l / 100));

    const hue_sector = h / 60.0;
    const sector: usize = @intFromFloat(hue_sector);
    const fractional = hue_sector - @as(f64, @floatFromInt(sector));

    const hue_factors = [_][3]f64{
        .{ 1, fractional, 0 },
        .{ 1 - fractional, 1, 0 },
        .{ 0, 1, fractional },
        .{ 0, 1 - fractional, 1 },
        .{ fractional, 0, 1 },
        .{ 1, 0, 1 - fractional },
    };

    const index = @mod(sector, 6);
    const r = lerp(1, 2 * hue_factors[index][0], s);
    const g = lerp(1, 2 * hue_factors[index][1], s);
    const b = lerp(1, 2 * hue_factors[index][2], s);

    const rgb_float = if (l < 0.5)
        RgbFloat{
            .r = r * l,
            .g = g * l,
            .b = b * l,
        }
    else
        RgbFloat{
            .r = lerp(r, 2, l) - 1,
            .g = lerp(g, 2, l) - 1,
            .b = lerp(b, 2, l) - 1,
        };

    return rgb_float.toRgb();
}

/// Converts RGB to CIELAB color space by:
/// - First converting RGB to XYZ using gamma correction
/// - Then converting XYZ to Lab using cube root transformations
/// - Normalizing by D65 illuminant reference white point
pub fn rgbToLab(rgb: Rgb) Lab {
    const rgb_float = RgbFloat.fromRgb(rgb.r, rgb.g, rgb.b);

    // Convert to XYZ first
    const r = gammaToLinear(rgb_float.r);
    const g = gammaToLinear(rgb_float.g);
    const b = gammaToLinear(rgb_float.b);

    const x = (r * 0.4124 + g * 0.3576 + b * 0.1805) * 100;
    const y = (r * 0.2126 + g * 0.7152 + b * 0.0722) * 100;
    const z = (r * 0.0193 + g * 0.1192 + b * 0.9505) * 100;

    // Convert XYZ to Lab
    var xn = x / 95.047;
    var yn = y / 100.000;
    var zn = z / 108.883;

    if (xn > 0.008856) {
        xn = pow(f64, xn, 1.0 / 3.0);
    } else {
        xn = (7.787 * xn) + (16.0 / 116.0);
    }

    if (yn > 0.008856) {
        yn = pow(f64, yn, 1.0 / 3.0);
    } else {
        yn = (7.787 * yn) + (16.0 / 116.0);
    }

    if (zn > 0.008856) {
        zn = pow(f64, zn, 1.0 / 3.0);
    } else {
        zn = (7.787 * zn) + (16.0 / 116.0);
    }

    return .{
        .l = @max(0, @min(100, (116.0 * yn) - 16.0)),
        .a = @max(-128, @min(127, 500.0 * (xn - yn))),
        .b = @max(-128, @min(127, 200.0 * (yn - zn))),
    };
}

/// Converts CIELAB to RGB by:
/// - Converting Lab to XYZ using inverse cube root transformations
/// - Converting XYZ to RGB using matrix multiplication
/// - Applying gamma correction for final RGB values
pub fn labToRgb(lab: Lab) Rgb {
    // Convert Lab to XYZ first
    var y: f64 = (@max(0, @min(100, lab.l)) + 16.0) / 116.0;
    var x: f64 = (@max(-128, @min(127, lab.a)) / 500.0) + y;
    var z: f64 = y - (@max(-128, @min(127, lab.b)) / 200.0);

    if (pow(f64, y, 3.0) > 0.008856) {
        y = pow(f64, y, 3.0);
    } else {
        y = (y - 16.0 / 116.0) / 7.787;
    }

    if (pow(f64, x, 3.0) > 0.008856) {
        x = pow(f64, x, 3.0);
    } else {
        x = (x - 16.0 / 116.0) / 7.787;
    }

    if (pow(f64, z, 3.0) > 0.008856) {
        z = pow(f64, z, 3.0);
    } else {
        z = (z - 16.0 / 116.0) / 7.787;
    }

    // Observer. = 2°, illuminant = D65.
    x *= 95.047;
    y *= 100.000;
    z *= 108.883;

    // Convert XYZ to RGB
    const r = (x * 3.2406 + y * -1.5372 + z * -0.4986) / 100;
    const g = (x * -0.9689 + y * 1.8758 + z * 0.0415) / 100;
    const b = (x * 0.0557 + y * -0.2040 + z * 1.0570) / 100;

    const rgb_float = RgbFloat{
        .r = @max(0, @min(1, linearToGamma(r))),
        .g = @max(0, @min(1, linearToGamma(g))),
        .b = @max(0, @min(1, linearToGamma(b))),
    };

    return rgb_float.toRgb();
}

pub fn hslToLab(hsl: Hsl) Lab {
    return rgbToLab(hslToRgb(hsl));
}

pub fn labToHsl(lab: Lab) Hsl {
    return rgbToHsl(labToRgb(lab));
}

// HSV conversions
/// Converts RGB to HSV color space using:
/// - Value as maximum of RGB components
/// - Saturation based on delta between max and min
/// - Hue calculated from which component is maximum
pub fn rgbToHsv(rgb: Rgb) Hsv {
    const rgb_float = RgbFloat.fromRgb(rgb.r, rgb.g, rgb.b);
    const min = @min(rgb_float.r, @min(rgb_float.g, rgb_float.b));
    const max = @max(rgb_float.r, @max(rgb_float.g, rgb_float.b));
    const delta = max - min;

    return .{
        .h = if (delta == 0) 0 else blk: {
            if (max == rgb_float.r) {
                break :blk @mod((rgb_float.g - rgb_float.b) / delta * 60, 360);
            } else if (max == rgb_float.g) {
                break :blk @mod(120 + (rgb_float.b - rgb_float.r) / delta * 60, 360);
            } else {
                break :blk @mod(240 + (rgb_float.r - rgb_float.g) / delta * 60, 360);
            }
        },
        .s = if (max == 0) 0 else (delta / max) * 100,
        .v = max * 100,
    };
}

/// Converts HSV to RGB using the standard algorithm:
/// - Calculates hue sector (0-5) and fractional part
/// - Computes intermediate values p, q, t
/// - Maps to RGB based on hue sector
pub fn hsvToRgb(hsv: Hsv) Rgb {
    const hue = @max(0, @min(1, hsv.h / 360));
    const sat = @max(0, @min(1, hsv.s / 100));
    const val = @max(0, @min(1, hsv.v / 100));

    if (sat == 0.0) {
        const gray: u8 = @intFromFloat(@round(255 * val));
        return .{ .r = gray, .g = gray, .b = gray };
    }

    const sector = hue * 6;
    const index: i32 = @intFromFloat(sector);
    const fractional = sector - @as(f64, @floatFromInt(index));
    const p = val * (1 - sat);
    const q = val * (1 - (sat * fractional));
    const t = val * (1 - sat * (1 - fractional));
    const colors = [_][3]f64{
        .{ val, t, p },
        .{ q, val, p },
        .{ p, val, t },
        .{ p, q, val },
        .{ t, p, val },
        .{ val, p, q },
    };
    const idx: usize = @intCast(@mod(index, 6));

    const rgb_float = RgbFloat{
        .r = colors[idx][0],
        .g = colors[idx][1],
        .b = colors[idx][2],
    };

    return rgb_float.toRgb();
}

pub fn hsvToHsl(hsv: Hsv) Hsl {
    return rgbToHsl(hsvToRgb(hsv));
}

pub fn hsvToLab(hsv: Hsv) Lab {
    return rgbToLab(hsvToRgb(hsv));
}

// XYZ conversions
/// Converts RGB to CIE 1931 XYZ color space using:
/// - Gamma correction to convert from sRGB to linear RGB
/// - Matrix multiplication with sRGB to XYZ transformation matrix
/// - Scaling by 100 for standard XYZ range
pub fn rgbToXyz(rgb: Rgb) Xyz {
    const rgb_float = RgbFloat.fromRgb(rgb.r, rgb.g, rgb.b);
    const r = gammaToLinear(rgb_float.r);
    const g = gammaToLinear(rgb_float.g);
    const b = gammaToLinear(rgb_float.b);

    return .{
        .x = (r * 0.4124 + g * 0.3576 + b * 0.1805) * 100,
        .y = (r * 0.2126 + g * 0.7152 + b * 0.0722) * 100,
        .z = (r * 0.0193 + g * 0.1192 + b * 0.9505) * 100,
    };
}

/// Converts CIE XYZ to RGB by:
/// - Matrix multiplication with XYZ to sRGB transformation matrix
/// - Applying gamma correction to convert linear RGB to sRGB
/// - Clamping values to valid RGB range [0,1]
pub fn xyzToRgb(xyz: Xyz) Rgb {
    const r = (xyz.x * 3.2406 + xyz.y * -1.5372 + xyz.z * -0.4986) / 100;
    const g = (xyz.x * -0.9689 + xyz.y * 1.8758 + xyz.z * 0.0415) / 100;
    const b = (xyz.x * 0.0557 + xyz.y * -0.2040 + xyz.z * 1.0570) / 100;

    const rgb_float = RgbFloat{
        .r = @max(0, @min(1, linearToGamma(r))),
        .g = @max(0, @min(1, linearToGamma(g))),
        .b = @max(0, @min(1, linearToGamma(b))),
    };

    return rgb_float.toRgb();
}

pub fn xyzToHsl(xyz: Xyz) Hsl {
    return rgbToHsl(xyzToRgb(xyz));
}

pub fn xyzToHsv(xyz: Xyz) Hsv {
    return rgbToHsv(xyzToRgb(xyz));
}

/// Converts XYZ to CIELAB using:
/// - Normalization by D65 illuminant white point
/// - Cube root transformation for perceptual uniformity
/// - L* (lightness), a* (green-red), b* (blue-yellow) calculations
pub fn xyzToLab(xyz: Xyz) Lab {
    // Observer. = 2°, illuminant = D65.
    var x = xyz.x / 95.047;
    var y = xyz.y / 100.000;
    var z = xyz.z / 108.883;

    if (x > 0.008856) {
        x = pow(f64, x, 1.0 / 3.0);
    } else {
        x = (7.787 * x) + (16.0 / 116.0);
    }

    if (y > 0.008856) {
        y = pow(f64, y, 1.0 / 3.0);
    } else {
        y = (7.787 * y) + (16.0 / 116.0);
    }

    if (z > 0.008856) {
        z = pow(f64, z, 1.0 / 3.0);
    } else {
        z = (7.787 * z) + (16.0 / 116.0);
    }

    return .{
        .l = @max(0, @min(100, (116.0 * y) - 16.0)),
        .a = @max(-128, @min(127, 500.0 * (x - y))),
        .b = @max(-128, @min(127, 200.0 * (y - z))),
    };
}

/// Converts XYZ to LMS (Long, Medium, Short) cone response space using:
/// - Linear transformation matrix based on human cone sensitivity
/// - Represents how the human eye's cone cells respond to light
pub fn xyzToLms(xyz: Xyz) Lms {
    return .{
        .l = (0.8951 * xyz.x + 0.2664 * xyz.y - 0.1614 * xyz.z) / 100,
        .m = (-0.7502 * xyz.x + 1.7135 * xyz.y + 0.0367 * xyz.z) / 100,
        .s = (0.0389 * xyz.x - 0.0685 * xyz.y + 1.0296 * xyz.z) / 100,
    };
}

pub fn xyzToOklab(xyz: Xyz) Oklab {
    return lmsToOklab(xyzToLms(xyz));
}

pub fn xyzToXyb(xyz: Xyz) Xyb {
    return lmsToXyb(xyzToLms(xyz));
}

// LMS conversions
pub fn lmsToRgb(lms: Lms) Rgb {
    return xyzToRgb(lmsToXyz(lms));
}

pub fn lmsToHsl(lms: Lms) Hsl {
    return rgbToHsl(lmsToRgb(lms));
}

pub fn lmsToHsv(lms: Lms) Hsv {
    return rgbToHsv(lmsToRgb(lms));
}

/// Converts LMS cone response to CIE XYZ using:
/// - Inverse transformation matrix of XYZ to LMS conversion
/// - Restores device-independent XYZ representation from cone response
pub fn lmsToXyz(lms: Lms) Xyz {
    return .{
        .x = 100 * (0.9869929 * lms.l - 0.1470543 * lms.m + 0.1599627 * lms.s),
        .y = 100 * (0.4323053 * lms.l + 0.5183603 * lms.m + 0.0492912 * lms.s),
        .z = 100 * (-0.0085287 * lms.l + 0.0400428 * lms.m + 0.9684867 * lms.s),
    };
}

pub fn lmsToLab(lms: Lms) Lab {
    return xyzToLab(lmsToXyz(lms));
}

/// Converts LMS to Oklab using:
/// - Cube root transformation for perceptual uniformity
/// - Linear transformation designed for better hue uniformity than CIELAB
/// - Oklab aims to be more perceptually uniform than other Lab spaces
pub fn lmsToOklab(lms: Lms) Oklab {
    const lp = std.math.cbrt(lms.l);
    const mp = std.math.cbrt(lms.m);
    const sp = std.math.cbrt(lms.s);
    return .{
        .l = 0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp,
        .a = 1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp,
        .b = 0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp,
    };
}

/// Converts LMS to XYB color space using:
/// - X = L - M (difference between long and medium cone response)
/// - Y = L + M (sum of long and medium cone response)
/// - B = S (short cone response unchanged)
pub fn lmsToXyb(lms: Lms) Xyb {
    return .{ .x = lms.l - lms.m, .y = lms.l + lms.m, .b = lms.s };
}

// Oklab conversions
pub fn oklabToRgb(oklab: Oklab) Rgb {
    return lmsToRgb(oklabToLms(oklab));
}

pub fn oklabToHsl(oklab: Oklab) Hsl {
    return rgbToHsl(oklabToRgb(oklab));
}

pub fn oklabToHsv(oklab: Oklab) Hsv {
    return rgbToHsv(oklabToRgb(oklab));
}

pub fn oklabToXyz(oklab: Oklab) Xyz {
    return lmsToXyz(oklabToLms(oklab));
}

pub fn oklabToLab(oklab: Oklab) Lab {
    return xyzToLab(oklabToXyz(oklab));
}

/// Converts Oklab to LMS using:
/// - Inverse linear transformation from Oklab space
/// - Cube (power of 3) transformation to restore LMS cone response
/// - Precise inverse of the LMS to Oklab conversion
pub fn oklabToLms(oklab: Oklab) Lms {
    return .{
        .l = std.math.pow(f64, 0.9999999985 * oklab.l + 0.3963377922 * oklab.a + 0.2158037581 * oklab.b, 3),
        .m = std.math.pow(f64, 1.000000009 * oklab.l - 0.1055613423 * oklab.a - 0.06385417477 * oklab.b, 3),
        .s = std.math.pow(f64, 1.000000055 * oklab.l - 0.08948418209 * oklab.a - 1.291485538 * oklab.b, 3),
    };
}

pub fn oklabToXyb(oklab: Oklab) Xyb {
    return lmsToXyb(oklabToLms(oklab));
}

// XYB conversions
pub fn xybToRgb(xyb: Xyb) Rgb {
    return lmsToRgb(xybToLms(xyb));
}

pub fn xybToHsl(xyb: Xyb) Hsl {
    return lmsToHsl(xybToLms(xyb));
}

pub fn xybToHsv(xyb: Xyb) Hsv {
    return lmsToHsv(xybToLms(xyb));
}

pub fn xybToXyz(xyb: Xyb) Xyz {
    return lmsToXyz(xybToLms(xyb));
}

pub fn xybToLab(xyb: Xyb) Lab {
    return xyzToLab(xybToXyz(xyb));
}

/// Converts XYB to LMS cone response using:
/// - L = 0.5 * (X + Y) (recovers long cone response)
/// - M = 0.5 * (Y - X) (recovers medium cone response)
/// - S = B (short cone response unchanged)
pub fn xybToLms(xyb: Xyb) Lms {
    return .{
        .l = 0.5 * (xyb.x + xyb.y),
        .m = 0.5 * (xyb.y - xyb.x),
        .s = xyb.b,
    };
}

pub fn xybToOklab(xyb: Xyb) Oklab {
    return lmsToOklab(xybToLms(xyb));
}
