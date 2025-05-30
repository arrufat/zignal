//! This module defines various color space structures and provides functions for converting between them.
const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const lerp = std.math.lerp;
const pow = std.math.pow;

/// Returns true if and only if T can be treated as a color.
pub fn isColor(comptime T: type) bool {
    return switch (T) {
        u8, Rgb, Rgba, Hsl, Hsv, Xyz, Lab, Lms, Oklab, Xyb => true,
        else => false,
    };
}

/// Checks whether a type T can be used as an Rgb color, i.e., it has r, g, b fields of type u8.
fn isRgbCompatible(comptime T: type) bool {
    if (T == Rgb or T == Rgba) return true;
    if (@typeInfo(T) != .@"struct") return false;
    comptime var checks: usize = 0;
    for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, "r") and field.type == u8) {
            checks += 1;
        }
        if (std.mem.eql(u8, field.name, "g") and field.type == u8) {
            checks += 1;
        }
        if (std.mem.eql(u8, field.name, "b") and field.type == u8) {
            checks += 1;
        }
    }
    return checks == 3;
}

/// Converts color into the T colorspace.
/// When converting from a `u8` type, it's generally assumed to be a grayscale value which is then
/// converted to the target colorspace, often via an intermediate RGB representation.
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
        Xyz => switch (ColorType) {
            Xyz => color,
            u8 => Rgb.fromGray(color).toXyz(),
            inline else => color.toXyz(),
        },
        Lab => switch (ColorType) {
            Lab => color,
            u8 => .{ .l = @as(f64, @floatFromInt(color)) / 255 * 100, .a = 0, .b = 0 },
            inline else => color.toLab(),
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

test "isRgbCompatible" {
    try comptime expectEqual(isRgbCompatible(u8), false);
    try comptime expectEqual(isRgbCompatible(RgbFloat), false);
    try comptime expectEqual(isRgbCompatible(Rgb), true);
    try comptime expectEqual(isRgbCompatible(Rgba), true);
    try comptime expectEqual(isRgbCompatible(Hsl), false);
    try comptime expectEqual(isRgbCompatible(Hsv), false);
    try comptime expectEqual(isRgbCompatible(Xyz), false);
    try comptime expectEqual(isRgbCompatible(Lab), false);
    try comptime expectEqual(isRgbCompatible(Lms), false);
    try comptime expectEqual(isRgbCompatible(Oklab), false);
    try comptime expectEqual(isRgbCompatible(Xyb), false);
}

test "convert grayscale" {
    try expectEqual(convert(u8, Rgb{ .r = 128, .g = 128, .b = 128 }), 128);
    try expectEqual(convert(u8, Hsl{ .h = 0, .s = 100, .l = 50 }), 128);
    try expectEqual(convert(u8, Hsv{ .h = 0, .s = 100, .v = 50 }), 128);
    try expectEqual(convert(u8, Lab{ .l = 50, .a = 0, .b = 0 }), 128);
}

/// Alpha-blends c2 into c1.
inline fn alphaBlend(comptime T: type, c1: *T, c2: Rgba) void {
    if (comptime !isRgbCompatible(T)) {
        @compileError(@typeName(T) ++ " is not Rgb compatible");
    }
    if (c2.a == 0) {
        return;
    }
    const a = @as(f32, @floatFromInt(c2.a)) / 255;
    c1.r = @intFromFloat(lerp(@as(f32, @floatFromInt(c1.r)), @as(f32, @floatFromInt(c2.r)), a));
    c1.g = @intFromFloat(lerp(@as(f32, @floatFromInt(c1.g)), @as(f32, @floatFromInt(c2.g)), a));
    c1.b = @intFromFloat(lerp(@as(f32, @floatFromInt(c1.b)), @as(f32, @floatFromInt(c2.b)), a));
}
test "alphaBlend" {
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    var output = Rgb{ .r = 0, .g = 0, .b = 0 };
    output.blend(white.toRgba(128));
    try expectEqualDeep(output, Rgb{ .r = 128, .g = 128, .b = 128 });
}

inline fn linearToGamma(x: f64) f64 {
    return if (x > 0.0031308) 1.055 * pow(f64, x, (1.0 / 2.4)) - 0.055 else x * 12.92;
}

inline fn gammaToLinear(x: f64) f64 {
    return if (x > 0.04045) pow(f64, (x + 0.055) / 1.055, 2.4) else x / 12.92;
}

/// Helper sRGB color in floating point, with each channel ranging from 0 to 1.
/// Used to perform lossless conversions between colorspaces.
const RgbFloat = struct {
    r: f64,
    g: f64,
    b: f64,
    pub const black: RgbFloat = .{ .r = 0, .g = 0, .b = 0 };

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

    /// Luma is the weighted average of gamma-corrected R, G, and B, based on their contribution
    /// to perceived lightness.  This implementation uses the the Rec. 709 for sRGB.
    pub fn luma(self: RgbFloat) f64 {
        return 0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b;
    }

    /// Converts the RGB color into an HSL color.
    pub fn toHsl(self: RgbFloat) Hsl {
        const min = @min(self.r, @min(self.g, self.b));
        const max = @max(self.r, @max(self.g, self.b));
        const delta = max - min;
        const hue = if (delta == 0) 0 else blk: {
            if (max == self.r) {
                break :blk (self.g - self.b) / delta;
            } else if (max == self.g) {
                break :blk 2 + (self.b - self.r) / delta;
            } else {
                break :blk 4 + (self.r - self.g) / delta;
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

    /// Converts the RGB color into an HSV color.
    pub fn toHsv(self: RgbFloat) Hsv {
        const min = @min(self.r, @min(self.g, self.b));
        const max = @max(self.r, @max(self.g, self.b));
        const delta = max - min;
        return .{
            .h = if (delta == 0) 0 else blk: {
                if (max == self.r) {
                    break :blk @mod((self.g - self.b) / delta * 60, 360);
                } else if (max == self.g) {
                    break :blk @mod(120 + (self.b - self.r) / delta * 60, 360);
                } else {
                    break :blk @mod(240 + (self.r - self.g) / delta * 60, 360);
                }
            },
            .s = if (max == 0) 0 else (delta / max) * 100,
            .v = max * 100,
        };
    }

    /// Converts the RGB color into a CIE 1931 XYZ color.
    pub fn toXyz(self: RgbFloat) Xyz {
        const r = gammaToLinear(self.r);
        const g = gammaToLinear(self.g);
        const b = gammaToLinear(self.b);
        return .{
            .x = (r * 0.4124 + g * 0.3576 + b * 0.1805) * 100,
            .y = (r * 0.2126 + g * 0.7152 + b * 0.0722) * 100,
            .z = (r * 0.0193 + g * 0.1192 + b * 0.9505) * 100,
        };
    }

    /// Converts the RGB color into a Lab color.
    pub fn toLab(self: RgbFloat) Lab {
        return self.toXyz().toLab();
    }

    /// Converts the RGB color into an LMS color.
    pub fn toLms(self: RgbFloat) Lms {
        return self.toXyz().toLms();
    }

    /// Converts the RGB color into an Oklab color.
    pub fn toOklab(self: RgbFloat) Oklab {
        return self.toLms().toOklab();
    }

    /// Converts the RGB color into an XYB color.
    pub fn toXyb(self: RgbFloat) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [sRGB](https://en.wikipedia.org/wiki/SRGB) colorspace.
/// Each component (r, g, b) is an unsigned 8-bit integer (0-255).
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
    pub const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };

    /// Returns the normalized RGB color in floating point.
    pub fn toRgbFloat(self: Rgb) RgbFloat {
        return .{
            .r = @as(f64, @floatFromInt(self.r)) / 255,
            .g = @as(f64, @floatFromInt(self.g)) / 255,
            .b = @as(f64, @floatFromInt(self.b)) / 255,
        };
    }

    /// Constructs a RGB color from a gray value.
    pub fn fromGray(gray: u8) Rgb {
        return .{ .r = gray, .g = gray, .b = gray };
    }

    /// Constructs a RGB color from a hex value.
    pub fn fromHex(hex_code: u24) Rgb {
        return .{
            .r = @intCast((hex_code >> (8 * 2)) & 0x0000ff),
            .g = @intCast((hex_code >> (8 * 1)) & 0x0000ff),
            .b = @intCast((hex_code >> (8 * 0)) & 0x0000ff),
        };
    }

    /// Luma is the weighted average of gamma-corrected R, G, and B, based on their contribution
    /// to perceived lightness.  This implementation uses the the Rec. 709 for sRGB.
    pub fn luma(self: Rgb) f64 {
        return self.toRgbFloat().luma();
    }

    /// Alpha-blends color into self.
    pub fn blend(self: *Rgb, color: Rgba) void {
        alphaBlend(Rgb, self, color);
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Rgb) bool {
        return self.r == self.g and self.g == self.b;
    }

    /// Converts the RGB color into grayscale using luma.
    pub fn toGray(self: Rgb) u8 {
        return @intFromFloat(self.luma() * 255);
    }

    /// Converts the RGB color into a hex value.
    pub fn toHex(self: Rgb) u24 {
        return std.mem.bigToNative(u24, @bitCast(self));
    }

    /// Converts the RGB color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Rgb, alpha: u8) Rgba {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }

    /// Converts the RGB color into a HSL color.
    pub fn toHsl(self: Rgb) Hsl {
        return self.toRgbFloat().toHsl();
    }

    /// Converts the RGB color into a HSV color.
    pub fn toHsv(self: Rgb) Hsv {
        return self.toRgbFloat().toHsv();
    }

    /// Converts the RGB color into a CIE 1931 XYZ color.
    pub fn toXyz(self: Rgb) Xyz {
        return self.toRgbFloat().toXyz();
    }

    /// Converts the RGB color into a CIELAB color.
    pub fn toLab(self: Rgb) Lab {
        return self.toXyz().toLab();
    }

    /// Converts the RGB color into an LMS color.
    pub fn toLms(self: Rgb) Lms {
        return self.toRgbFloat().toLms();
    }

    /// Converts the RGB color into an Oklab color.
    pub fn toOklab(self: Rgb) Oklab {
        return self.toRgbFloat().toOklab();
    }

    /// Converts the RGB color into an XYB color.
    pub fn toXyb(self: Rgb) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [sRGB](https://en.wikipedia.org/wiki/SRGB) colorspace with an alpha channel.
/// Each component (r, g, b, a) is an unsigned 8-bit integer (0-255).
pub const Rgba = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    pub const black: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    /// Constructs a RGBA color from a gray and alpha values.
    pub fn fromGray(gray: u8, alpha: u8) Rgba {
        return Rgb.fromGray(gray).toRgba(alpha);
    }

    /// Constructs a RGBA color from a hex value.
    pub fn fromHex(hex_code: u32) Rgba {
        return .{
            .r = @intCast((hex_code >> (8 * 3)) & 0x0000ff),
            .g = @intCast((hex_code >> (8 * 2)) & 0x0000ff),
            .b = @intCast((hex_code >> (8 * 1)) & 0x0000ff),
            .a = @intCast((hex_code >> (8 * 0)) & 0x0000ff),
        };
    }

    /// Luma is the weighted average of gamma-corrected R, G, and B, based on their contribution
    /// to perceived lightness.  This implementation uses the the Rec. 709 for sRGB.
    pub fn luma(self: Rgba) f64 {
        return self.toRgbFloat().luma();
    }

    /// Alpha-blends color into self.
    pub fn blend(self: *Rgba, color: Rgba) void {
        alphaBlend(Rgba, self, color);
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Rgba) bool {
        return self.r == self.g and self.g == self.b;
    }

    /// Converts the RGB color into grayscale using luma.
    pub fn toGray(self: Rgba) u8 {
        return @intFromFloat(self.luma() * 255);
    }

    /// Converts the RGBA color into a hex value.
    pub fn toHex(self: Rgba) u32 {
        return std.mem.bigToNative(u32, @bitCast(self));
    }

    /// Converts the RGBA color into a RGB color by removing the alpha channel.
    pub fn toRgb(self: Rgba) Rgb {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    /// Converts the RGBA color into a floating point RGB, ignoring the alpha channel.
    pub fn toRgbFloat(self: Rgba) RgbFloat {
        return .{
            .r = @as(f64, @floatFromInt(self.r)) / 255,
            .g = @as(f64, @floatFromInt(self.g)) / 255,
            .b = @as(f64, @floatFromInt(self.b)) / 255,
        };
    }

    /// Converts the RGBA color into a HSL color, ignoring the alpha channel.
    pub fn toHsl(self: Rgba) Hsl {
        return self.toRgbFloat().toHsl();
    }

    /// Converts the RGBA color into a HSV color, ignoring the alpha channel.
    pub fn toHsv(self: Rgba) Hsv {
        return self.toRgbFloat().toHsv();
    }

    /// Converts the RGBA color into a CIE 1931 XYZ color, ignoring the alpha channel.
    pub fn toXyz(self: Rgba) Xyz {
        return self.toRgbFloat().toXyz();
    }

    /// Converts the RGBA color into a Lab color, ignoring the alpha channel.
    pub fn toLab(self: Rgba) Lab {
        return self.toRgbFloat().toLab();
    }

    /// Converts the RGBA color into an LMS color.
    pub fn toLms(self: Rgba) Lms {
        return self.toXyz().toLms();
    }

    /// Converts the RGBA color into an Oklab color.
    pub fn toOklab(self: Rgba) Oklab {
        return self.toLms().toOklab();
    }

    /// Converts the RGBA color into an XYB color.
    pub fn toXyb(self: Rgba) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [HSL](https://en.wikipedia.org/wiki/HSL_and_HSV) colorspace.
/// - h: Hue, in degrees (0-360, though often normalized to 0-359).
/// - s: Saturation, as a percentage (0-100).
/// - l: Lightness, as a percentage (0-100).
pub const Hsl = struct {
    h: f64,
    s: f64,
    l: f64,
    pub const black: Hsl = .{ .h = 0, .s = 0, .l = 0 };

    /// Alpha-blends color into self.
    pub fn blend(self: *Hsl, color: Rgba) void {
        var rgb = self.toRgb();
        rgb.blend(color);
        self = rgb.toHsl();
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Hsl) bool {
        return self.s == 0;
    }

    /// Converts the HSL color into grayscale.
    pub fn toGray(self: Hsl) u8 {
        return @intFromFloat(@round(self.l / 100 * 255));
    }
    /// Converts the HSL color into an RGB color, where each channel ranges from 0 to 1.
    pub fn toRgbFloat(self: Hsl) RgbFloat {
        const h = @max(0, @min(360, self.h));
        const s = @max(0, @min(1, self.s / 100));
        const l = @max(0, @min(1, self.l / 100));
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
        return if (l < 0.5)
            .{
                .r = r * l,
                .g = g * l,
                .b = b * l,
            }
        else
            .{
                .r = lerp(r, 2, l) - 1,
                .g = lerp(g, 2, l) - 1,
                .b = lerp(b, 2, l) - 1,
            };
    }

    /// Converts the HSL color into an RGB color.
    pub fn toRgb(self: Hsl) Rgb {
        const rgb = self.toRgbFloat();
        return .{
            .r = @intFromFloat(@round(255 * rgb.r)),
            .g = @intFromFloat(@round(255 * rgb.g)),
            .b = @intFromFloat(@round(255 * rgb.b)),
        };
    }

    /// Converts the HSL color into an RGBA color with the specified alpha.
    pub fn toRgba(self: Hsl, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the HSL color into a HSV color.
    pub fn toHsv(self: Hsl) Hsv {
        return self.toRgbFloat().toHsv();
    }

    /// Converts the Hsl color into a CIE 1931 XYZ color.
    pub fn toXyz(self: Hsl) Xyz {
        return self.toRgbFloat().toXyz();
    }

    /// Converts the HSL color into a CIELAB color.
    pub fn toLab(self: Hsl) Lab {
        return self.toRgbFloat().toLab();
    }

    /// Converts the HSL color into an LMS color.
    pub fn toLms(self: Hsl) Lms {
        return self.toRgb().toLms();
    }

    /// Converts the HSL color into an Oklab color.
    pub fn toOklab(self: Hsl) Oklab {
        return self.toRgb().toOklab();
    }

    /// Converts the HSL color into an XYB color.
    pub fn toXyb(self: Hsl) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [HSV](https://en.wikipedia.org/wiki/HSL_and_HSV) colorspace.
/// - h: Hue, in degrees (0-360, though often normalized to 0-359).
/// - s: Saturation, as a percentage (0-100).
/// - v: Value, as a percentage (0-100).
pub const Hsv = struct {
    h: f64,
    s: f64,
    v: f64,
    pub const black: Hsv = .{ .h = 0, .s = 0, .v = 0 };

    /// Alpha-blends color into self.
    pub fn blend(self: *Hsv, color: Rgba) void {
        var rgb = self.toRgb();
        rgb.blend(color);
        self = rgb.toHsv();
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Hsv) bool {
        return self.s == 0;
    }

    /// Converts the HSV color into grayscale.
    pub fn toGray(self: Hsv) u8 {
        return @intFromFloat(@round(self.v / 100 * 255));
    }

    /// Converts the HSV color into an RGB color.
    pub fn toRgbFloat(self: Hsv) RgbFloat {
        const hue = @max(0, @min(1, self.h / 360));
        const sat = @max(0, @min(1, self.s / 100));
        const val = @max(0, @min(1, self.v / 100));

        if (sat == 0.0) return .{ .r = val, .g = val, .b = val };
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
        return .{
            .r = colors[idx][0],
            .g = colors[idx][1],
            .b = colors[idx][2],
        };
    }

    /// Converts the HSV color into an RGB color.
    pub fn toRgb(self: Hsv) Rgb {
        return self.toRgbFloat().toRgb();
    }

    /// Converts the HSV color into an RGBA color with the specified alpha.
    pub fn toRgba(self: Hsv, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the HSV color into an HSL color, ignoring the alpha channel.
    pub fn toHsl(self: Hsv) Hsl {
        return self.toRgbFloat().toHsl();
    }

    /// Converts the HSV color into a CIE 1931 XYZ color.
    pub fn toXyz(self: Hsv) Xyz {
        return self.toRgbFloat().toXyz();
    }

    /// Converts the HSV color into a CIELAB color.
    pub fn toLab(self: Hsv) Lab {
        return self.toRgbFloat().toLab();
    }

    /// Converts the HSV color into an LMS color.
    pub fn toLms(self: Hsv) Lms {
        return self.toRgbFloat().toLms();
    }

    /// Converts the HSV color into an Oklab color.
    pub fn toOklab(self: Hsv) Oklab {
        return self.toRgbFloat().toOklab();
    }

    /// Converts the HSV color into an XYB color.
    pub fn toXyb(self: Hsv) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [CIE 1931 XYZ color space](https://en.wikipedia.org/wiki/CIE_1931_color_space).
/// This is a device-independent space that covers the full gamut of human-perceptible colors
/// visible to the CIE 2° standard observer.
/// - x, y, z: Tristimulus values, typically non-negative. Y represents luminance.
///   The typical range for these values can vary depending on the reference white point (e.g. D65).
///   Often, Y is normalized to 100 for white.
pub const Xyz = struct {
    x: f64,
    y: f64,
    z: f64,
    pub const black: Xyz = .{ .x = 0, .y = 0, .z = 0 };

    /// Checks if the CIE 1931 XYZ color is a shade of gray.
    pub fn isGray(self: Xyz) bool {
        return self.toRgb().isGray();
    }

    /// Converts the CIE 1931 XYZ color into grayscale using CIELAB.
    pub fn toGray(self: Xyz) u8 {
        return self.toLab().toGray();
    }

    /// Converts the CIE 1931 XYZ color into a RGB color.
    pub fn toRgbFloat(self: Xyz) RgbFloat {
        const r = (self.x * 3.2406 + self.y * -1.5372 + self.z * -0.4986) / 100;
        const g = (self.x * -0.9689 + self.y * 1.8758 + self.z * 0.0415) / 100;
        const b = (self.x * 0.0557 + self.y * -0.2040 + self.z * 1.0570) / 100;

        return .{
            .r = @max(0, @min(1, linearToGamma(r))),
            .g = @max(0, @min(1, linearToGamma(g))),
            .b = @max(0, @min(1, linearToGamma(b))),
        };
    }

    /// Converts the CIE 1931 XYZ color into a RGB color.
    pub fn toRgb(self: Xyz) Rgb {
        const rgb = self.toRgbFloat();
        return .{
            .r = @intFromFloat(@round(255 * rgb.r)),
            .g = @intFromFloat(@round(255 * rgb.g)),
            .b = @intFromFloat(@round(255 * rgb.b)),
        };
    }

    /// Converts the CIE 1931 XYZ color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Xyz, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the CIE 1931 XYZ color into a HSL color.
    pub fn toHsl(self: Xyz) Hsl {
        return self.toRgbFloat().toHsl();
    }

    /// Converts the CIE 1931 XYZ color into a HSV color.
    pub fn toHsv(self: Xyz) Hsv {
        return self.toRgbFloat().toHsv();
    }

    /// Converts the CIE 1931 XYZ color into a CIELAB color.
    pub fn toLab(self: Xyz) Lab {
        // Observer. = 2°, illuminant = D65.
        var x = self.x / 95.047;
        var y = self.y / 100.000;
        var z = self.z / 108.883;

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

    /// Converts the CIE 1931 XYZ color into an LMS color using the Bradford method.
    pub fn toLms(self: Xyz) Lms {
        return .{
            .l = (0.8951 * self.x + 0.2664 * self.y - 0.1614 * self.z) / 100,
            .m = (-0.7502 * self.x + 1.7135 * self.y + 0.0367 * self.z) / 100,
            .s = (0.0389 * self.x - 0.0685 * self.y + 1.0296 * self.z) / 100,
        };
    }

    /// Converts the CIE 1931 XYZ color into an Oklab color.
    pub fn toOklab(self: Xyz) Oklab {
        return self.toLms().toOklab();
    }

    /// Converts the CIE 1931 XYZ color into an XYB color.
    pub fn toXyb(self: Xyz) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [CIELAB color space](https://en.wikipedia.org/wiki/CIELAB_color_space) (also known as L*a*b*).
/// It expresses color as three values:
/// - l: Lightness (0 for black to 100 for white).
/// - a: Green-red axis (-128 for green to +127 for red).
/// - b: Blue-yellow axis (-128 for blue to +127 for yellow).
pub const Lab = struct {
    l: f64,
    a: f64,
    b: f64,
    pub const black: Lab = .{ .l = 0, .a = 0, .b = 0 };

    /// Alpha-blends color into self.
    pub fn blend(self: *Lab, color: Rgba) void {
        var rgb = self.toRgb();
        rgb.blend(color);
        self = rgb.toLab();
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Lab) bool {
        return self.a == 0 and self.b == 0;
    }

    /// Converts the Lab color into grayscale.
    pub fn toGray(self: Lab) u8 {
        return @intFromFloat(@round(self.l / 100 * 255));
    }

    /// Converts the CIELAB color into a RGB color.
    pub fn toRgbFloat(self: Lab) RgbFloat {
        return self.toXyz().toRgbFloat();
    }

    /// Converts the CIELAB color into a RGB color.
    pub fn toRgb(self: Lab) Rgb {
        return self.toRgbFloat().toRgb();
    }

    /// Converts the CIELAB color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Lab, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the CIELAB color into a HSL color.
    pub fn toHsl(self: Lab) Hsl {
        return self.toRgbFloat().toHsl();
    }

    /// Converts the CIELAB color into a HSV color.
    pub fn toHsv(self: Lab) Hsv {
        return self.toRgbFloat().toHsv();
    }

    /// Converts the CIELAB color into a CIE 1931 XYZ color.
    pub fn toXyz(self: Lab) Xyz {
        var y: f64 = (@max(0, @min(100, self.l)) + 16.0) / 116.0;
        var x: f64 = (@max(-128, @min(127, self.a)) / 500.0) + y;
        var z: f64 = y - (@max(-128, @min(127, self.b)) / 200.0);

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
        return .{
            .x = x * 95.047,
            .y = y * 100.000,
            .z = z * 108.883,
        };
    }

    /// Converts the CIELAB color into an LMS color.
    pub fn toLms(self: Lab) Lms {
        return self.toXyz().toLms();
    }

    /// Converts the CIELAB color into an Oklab color.
    pub fn toOklab(self: Lab) Oklab {
        return self.toLms().toOklab();
    }

    /// Converts the CIELAB color into an XYB color.
    pub fn toXyb(self: Lab) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [Oklab color space](https://bottosson.github.io/posts/oklab/).
/// Oklab is designed to be a perceptually uniform color space.
/// - l: Perceived lightness (0 for black to approximately 1 for white).
/// - a: Green-red axis (negative values towards green, positive towards red, typically around -0.4 to 0.4).
/// - b: Blue-yellow axis (negative values towards blue, positive towards yellow, typically around -0.4 to 0.4).
pub const Oklab = struct {
    l: f64,
    a: f64,
    b: f64,
    pub const black: Oklab = .{ .l = 0, .a = 0, .b = 0 };

    /// Alpha-blends color into self.
    pub fn blend(self: *Oklab, color: Rgba) void {
        var rgb = self.toRgb();
        rgb.blend(color);
        self = rgb.toLab();
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Oklab) bool {
        return self.a == 0 and self.b == 0;
    }

    /// Converts the Oklab color into grayscale.
    pub fn toGray(self: Oklab) u8 {
        return @intFromFloat(@round(@max(0, @min(1, self.l)) * 255));
    }

    /// Converts the Oklab color into a RGB color.
    pub fn toRgbFloat(self: Oklab) RgbFloat {
        return self.toXyz().toRgbFloat();
    }

    /// Converts the Oklab color into a RGB color.
    pub fn toRgb(self: Oklab) Rgb {
        return self.toRgbFloat().toRgb();
    }

    /// Converts the Oklab color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Oklab, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the Oklab color into a HSL color.
    pub fn toHsl(self: Oklab) Hsl {
        return self.toRgbFloat().toHsl();
    }

    /// Converts the Oklab color into a HSV color.
    pub fn toHsv(self: Oklab) Hsv {
        return self.toRgbFloat().toHsv();
    }

    /// Converts the Oklab color into an LMS color.
    pub fn toLms(self: Oklab) Lms {
        return .{
            .l = std.math.pow(f64, 0.9999999985 * self.l + 0.3963377922 * self.a + 0.2158037581 * self.b, 3),
            .m = std.math.pow(f64, 1.000000009 * self.l - 0.1055613423 * self.a - 0.06385417477 * self.b, 3),
            .s = std.math.pow(f64, 1.000000055 * self.l - 0.08948418209 * self.a - 1.291485538 * self.b, 3),
        };
    }

    /// Converts the Oklab color into a CIE 1931 XYZ color.
    pub fn toXyz(self: Oklab) Xyz {
        return self.toLms().toXyz();
    }

    /// Converts the Oklab color into a CIE Lab color.
    pub fn toLab(self: Oklab) Lab {
        return self.toXyz().toLab();
    }

    /// Converts the Oklab color into an XYB color.
    pub fn toXyb(self: Oklab) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [LMS color space](https://en.wikipedia.org/wiki/LMS_color_space).
/// Represents the response of the three types of cones (Long, Medium, Short wavelength) in the human eye.
/// Values are typically positive and represent the stimulus for each cone type.
pub const Lms = struct {
    l: f64, // Long cone response
    m: f64, // Medium cone response
    s: f64, // Short cone response
    pub const black: Lms = .{ .l = 0, .m = 0, .s = 0 };

    /// Alpha-blends color into self.
    pub fn blend(self: *Lms, color: Rgba) void {
        var rgb = self.toRgb();
        rgb.blend(color);
        self = rgb.toLms();
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Lms) bool {
        const lab = self.toOklab();
        return lab.a == 0 and lab.b == 0;
    }

    /// Converts the LMS color into grayscale.
    pub fn toGray(self: Lms) u8 {
        return @intFromFloat(@round(@max(0, @min(1, self.toOklab().l)) * 255));
    }

    /// Converts the LMS color into a RGB color.
    pub fn toRgbFloat(self: Lms) RgbFloat {
        return self.toXyz().toRgbFloat();
    }

    /// Converts the LMS color into a RGB color.
    pub fn toRgb(self: Lms) Rgb {
        return self.toRgbFloat().toRgb();
    }

    /// Converts the LMS color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Lms, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the LMS color into a HSL color.
    pub fn toHsl(self: Lms) Hsl {
        return self.toRgbFloat().toHsl();
    }

    /// Converts the LMS color into a HSV color.
    pub fn toHsv(self: Lms) Hsv {
        return self.toRgbFloat().toHsv();
    }

    /// Converts the LMS color into a CIE 1931 XYZ color using the Bradford method.
    pub fn toXyz(self: Lms) Xyz {
        return .{
            .x = 100 * (0.9869929 * self.l - 0.1470543 * self.m + 0.1599627 * self.s),
            .y = 100 * (0.4323053 * self.l + 0.5183603 * self.m + 0.0492912 * self.s),
            .z = 100 * (-0.0085287 * self.l + 0.0400428 * self.m + 0.9684867 * self.s),
        };
    }

    /// Converts the LMS color into an Oklab color.
    pub fn toOklab(self: Lms) Oklab {
        const lp = std.math.cbrt(self.l);
        const mp = std.math.cbrt(self.m);
        const sp = std.math.cbrt(self.s);
        return .{
            .l = 0.2104542553 * lp + 0.7936177850 * mp - 0.0040720468 * sp,
            .a = 1.9779984951 * lp - 2.4285922050 * mp + 0.4505937099 * sp,
            .b = 0.0259040371 * lp + 0.7827717662 * mp - 0.8086757660 * sp,
        };
    }

    /// Converts the LMS color into an XYB color.
    pub fn toXyb(self: Lms) Xyb {
        return .{ .x = self.l - self.m, .y = self.l + self.m, .b = self.s };
    }
};

/// A color in the [XYB color space](https://jpeg.org/jpegxl/documentation/xl-color-management.html#xyb)
/// used in JPEG XL. It's derived from LMS and designed for efficient image compression.
/// - x: X component (L-M, red-green opponent channel).
/// - y: Y component (L+M, luminance-like channel).
/// - b: B component (S, blue-yellow like channel, but often scaled S cone response).
/// Ranges can vary based on transformations, but often centered around 0 for x and b, and positive for y.
pub const Xyb = struct {
    x: f64,
    y: f64,
    b: f64,
    pub const black: Xyb = .{ .x = 0, .y = 0, .b = 0 };

    /// Alpha-blends color into self.
    pub fn blend(self: *Xyb, color: Rgba) void {
        var rgb = self.toRgb();
        rgb.blend(color);
        self = rgb.toXyb();
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Xyb) bool {
        const lab = self.toOklab();
        return lab.a == 0 and lab.b == 0;
    }

    /// Converts the XYB color into grayscale.
    pub fn toGray(self: Xyb) u8 {
        return @intFromFloat(@round(@max(0, @min(1, self.toOklab().l)) * 255));
    }

    /// Converts the XYB color into a RGB color.
    pub fn toRgbFloat(self: Xyb) RgbFloat {
        return self.toLms().toRgbFloat();
    }

    /// Converts the XYB color into a RGB color.
    pub fn toRgb(self: Xyb) Rgb {
        return self.toLms().toRgb();
    }

    /// Converts the XYB color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Xyb, alpha: u8) Rgba {
        return self.toLms().toRgba(alpha);
    }

    /// Converts the XYB color into a HSL color.
    pub fn toHsl(self: Xyb) Hsl {
        return self.toLms().toHsl();
    }

    /// Converts the XYB color into a HSV color.
    pub fn toHsv(self: Xyb) Hsv {
        return self.toLms().toHsv();
    }

    /// Converts the XYB color into an XYZ color.
    pub fn toXyz(self: Xyb) Xyz {
        return self.toLms().toXyz();
    }

    /// Converts the XYB color into a CIE LAB color.
    pub fn toLab(self: Xyb) Lab {
        return self.toXyz().toLab();
    }

    /// Converts the XYB into an LMS color.
    pub fn toLms(self: Xyb) Lms {
        return .{
            .l = 0.5 * (self.x + self.y),
            .m = 0.5 * (self.y - self.x),
            .s = self.b,
        };
    }

    /// Converts the XYB color into an Oklab color.
    pub fn toOklab(self: Xyb) Oklab {
        return self.toLms().toOklab();
    }
};

test "hex to RGB/A" {
    try std.testing.expectEqualDeep(Rgb.fromHex(0x4e008e), Rgb{ .r = 78, .g = 0, .b = 142 });
    try std.testing.expectEqualDeep(Rgb.fromHex(0x000000), Rgb{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expectEqualDeep(Rgb.fromHex(0xffffff), Rgb{ .r = 255, .g = 255, .b = 255 });
}

fn testColorConversion(from: Rgb, to: anytype) !void {
    const converted = convert(@TypeOf(to), from);
    try expectEqualDeep(converted, to);
    const recovered = convert(Rgb, converted);
    try expectEqualDeep(recovered, from);
}

test "primary colors" {
    // red: 0xff0000
    try testColorConversion(.{ .r = 255, .g = 0, .b = 0 }, Hsl{ .h = 0, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 255, .g = 0, .b = 0 }, Hsv{ .h = 0, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 0, .b = 0 }, Lab{ .l = 53.23288178584245, .a = 80.10930952982204, .b = 67.22006831026425 });
    // green: 0x00ff00
    try testColorConversion(.{ .r = 0, .g = 255, .b = 0 }, Hsl{ .h = 120, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 0, .g = 255, .b = 0 }, Hsv{ .h = 120, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 0, .g = 255, .b = 0 }, Lab{ .l = 87.73703347354422, .a = -86.1846364976253, .b = 83.18116474777855 });
    // blue: 0x0000ff
    try testColorConversion(.{ .r = 0, .g = 0, .b = 255 }, Hsl{ .h = 240, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 255 }, Hsv{ .h = 240, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 255 }, Lab{ .l = 32.302586667249486, .a = 79.19666178930935, .b = -107.86368104495168 });
}

test "secondary colors" {
    // cyan: 0x00ffff
    try testColorConversion(.{ .r = 0, .g = 255, .b = 255 }, Hsl{ .h = 180, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 0, .g = 255, .b = 255 }, Hsv{ .h = 180, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 0, .g = 255, .b = 255 }, Lab{ .l = 91.11652110946342, .a = -48.079618466228716, .b = -14.138127754846131 });
    // magenta: 0xff00ff
    try testColorConversion(.{ .r = 255, .g = 0, .b = 255 }, Hsl{ .h = 300, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 255, .g = 0, .b = 255 }, Hsv{ .h = 300, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 0, .b = 255 }, Lab{ .l = 60.319933664076004, .a = 98.25421868616108, .b = -60.84298422386232 });
    // yellow: 0xffff00
    try testColorConversion(.{ .r = 255, .g = 255, .b = 0 }, Hsl{ .h = 60, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 0 }, Hsv{ .h = 60, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 0 }, Lab{ .l = 97.13824698129729, .a = -21.555908334832285, .b = 94.48248544644461 });
}

test "complementary colors" {
    // orange: 0xff8800
    try testColorConversion(.{ .r = 255, .g = 136, .b = 0 }, Hsl{ .h = 32, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 255, .g = 136, .b = 0 }, Hsv{ .h = 32, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 136, .b = 0 }, Lab{ .l = 68.65577208167872, .a = 38.85052375564019, .b = 74.99022544139406 });
    // purple: 0x800080
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Hsl{ .h = 300, .s = 100, .l = 25.098039215686274 });
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Hsv{ .h = 300, .s = 100, .v = 50.19607843137255 });
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Lab{ .l = 29.782100092098077, .a = 58.93983731904206, .b = -36.49792996282386 });
}

test "neutral colors" {
    // white: 0xffffff
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Hsl{ .h = 0, .s = 0, .l = 100 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Hsv{ .h = 0, .s = 0, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Lab{ .l = 100, .a = 0.00526049995830391, .b = -0.010408184525267927 });
    // gray: 0x808080
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Hsl{ .h = 0, .s = 0, .l = 50.19607843137255 });
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Hsv{ .h = 0, .s = 0, .v = 50.19607843137255 });
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Lab{ .l = 53.58501345216902, .a = 0.003155620347972121, .b = -0.006243566036268078 });
    // black: 0x000000
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Hsl{ .h = 0, .s = 0, .l = 0 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Hsv{ .h = 0, .s = 0, .v = 0 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Lab{ .l = 0, .a = 0, .b = 0 });
}

test "pastel colors" {
    // pale_pink: 0xffd3ba
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Hsl{ .h = 21.739130434782602, .s = 100, .l = 86.47058823529412 });
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Hsv{ .h = 21.739130434782602, .s = 27.058823529411768, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Lab{ .l = 87.67593388241974, .a = 11.843797404960165, .b = 18.16236917854479 });
    // mint_green: 0x96fa96
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Hsl{ .h = 120, .s = 90.90909090909089, .l = 78.43137254901961 });
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Hsv{ .h = 120, .s = 40, .v = 98.0392156862745 });
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Lab{ .l = 90.34795996024553, .a = -48.75545372512652, .b = 38.96689290268498 });
    // sky_blue: #8ad1ed
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Hsl{ .h = 196.96969696969697, .s = 73.33333333333336, .l = 73.52941176470588 });
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Hsv{ .h = 196.96969696969697, .s = 41.77215189873419, .v = 92.94117647058823 });
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Lab{ .l = 80.24627015828005, .a = -15.11865203941365, .b = -20.767024460106565 });
}

test "vivid colors" {
    // hot_pink: #ff66b3
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Hsl{ .h = 329.80392156862746, .s = 99.99999999999997, .l = 70 });
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Hsv{ .h = 329.80392156862746, .s = 60, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Lab{ .l = 64.9763931162809, .a = 65.40669278373645, .b = -10.847761988977656 });
    // lime_green:#31cc31
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Hsl{ .h = 120, .s = 61.26482213438735, .l = 49.6078431372549 });
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Hsv{ .h = 120, .s = 75.98039215686275, .v = 80 });
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Lab{ .l = 72.26888334336961, .a = -67.03378336285304, .b = 61.425460443480894 });
    // electric_blue: #80dfff
    try testColorConversion(.{ .r = 128, .g = 223, .b = 255 }, Hsl{ .h = 195.11811023622047, .s = 100, .l = 75.09803921568627 });
    try testColorConversion(.{ .r = 128, .g = 223, .b = 255 }, Hsv{ .h = 195.11811023622047, .s = 49.80392156862745, .v = 100 });
    try testColorConversion(.{ .r = 128, .g = 223, .b = 255 }, Lab{ .l = 84.26919487615707, .a = -19.773688316136685, .b = -24.252061008370738 });
}

test "100 random colors" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var prng: std.Random.DefaultPrng = .init(seed);
    var random = prng.random();
    for (0..100) |_| {
        const rgb: Rgb = .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) };
        const rgb_from_hsl = rgb.toHsl().toRgb();
        try expectEqualDeep(rgb, rgb_from_hsl);
        const rgb_from_hsv = rgb.toHsv().toRgb();
        try expectEqualDeep(rgb, rgb_from_hsv);
        const rgb_from_xyz = rgb.toXyz().toRgb();
        try expectEqualDeep(rgb, rgb_from_xyz);
        const rgb_from_lab = rgb.toLab().toRgb();
        try expectEqualDeep(rgb, rgb_from_lab);
    }
}
