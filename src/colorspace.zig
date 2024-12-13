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

fn assertAllFieldTypesAreSame(comptime T: type) void {
    comptime assert(isColor(T));
    return for (std.meta.fields(T)) |field| {
        if (std.meta.fields(T)[0].type != field.type) break false;
    } else true;
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
pub fn convert(comptime T: type, color: anytype) T {
    comptime assert(isColor(T));
    comptime assert(isColor(@TypeOf(color)));
    return switch (T) {
        u8 => switch (@TypeOf(color)) {
            u8 => color,
            inline else => color.toGray(),
        },
        Rgb => switch (@TypeOf(color)) {
            Rgb => color,
            u8 => .{ .r = color, .g = color, .b = color },
            inline else => color.toRgb(),
        },
        Rgba => switch (@TypeOf(color)) {
            Rgba => color,
            u8 => .{ .r = color, .g = color, .b = color, .a = 255 },
            inline else => color.toRgba(255),
        },
        Hsl => switch (@TypeOf(color)) {
            Hsl => color,
            u8 => .{ .h = 0, .s = 0, .l = @as(f64, @floatFromInt(color)) / 255 * 100 },
            inline else => color.toHsl(),
        },
        Hsv => switch (@TypeOf(color)) {
            Hsv => color,
            u8 => .{ .h = 0, .s = 0, .v = @as(f64, @floatFromInt(color)) / 255 * 100 },
            inline else => color.toHsv(),
        },
        Xyz => switch (@TypeOf(color)) {
            Xyz => color,
            u8 => Rgb.fromGray(color).toXyz(),
            inline else => color.toXyz(),
        },
        Lab => switch (@TypeOf(color)) {
            Lab => color,
            u8 => .{ .l = @as(f64, @floatFromInt(color)) / 255 * 100, .a = 0, .b = 0 },
            inline else => color.toLab(),
        },
        Lms => switch (@TypeOf(color)) {
            Lms => color,
            u8 => .{},
            inline else => color.toLms(),
        },
        Oklab => switch (@TypeOf(color)) {
            Oklab => color,
            u8 => .{},
            inline else => color.toOklab(),
        },
        Xyb => switch (@TypeOf(color)) {
            Xyb => color,
            u8 => .{},
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

    fn fromRgb(r: u8, g: u8, b: u8) RgbFloat {
        return .{
            .r = @as(f64, @floatFromInt(r)) / 255,
            .g = @as(f64, @floatFromInt(g)) / 255,
            .b = @as(f64, @floatFromInt(b)) / 255,
        };
    }

    fn toRgb(self: RgbFloat) Rgb {
        return .{
            .r = @intFromFloat(@round(255 * @max(0, @min(1, self.r)))),
            .g = @intFromFloat(@round(255 * @max(0, @min(1, self.g)))),
            .b = @intFromFloat(@round(255 * @max(0, @min(1, self.b)))),
        };
    }

    /// Converts the RGB color into an HSL color.
    fn toHsl(self: RgbFloat) Hsl {
        const min = @min(self.r, @min(self.g, self.b));
        const max = @max(self.r, @max(self.g, self.b));
        const delta = max - min;
        var hsl = Hsl{ .h = 0, .s = 0, .l = 0 };
        hsl.l = (max + min) / 2;
        if (hsl.l > 0 and hsl.l < 1) {
            hsl.s = delta / if (hsl.l < 0.5) 2 * hsl.l else 2 - 2 * hsl.l;
        }
        if (delta > 0) {
            if (max == self.r and max != self.g) {
                hsl.h += (self.g - self.b) / delta;
            }
            if (max == self.g and max != self.b) {
                hsl.h += 2 + (self.b - self.r) / delta;
            }
            if (max == self.b and max != self.r) {
                hsl.h += 4 + (self.r - self.g) / delta;
            }
            hsl.h *= 60;
        }
        hsl.h = @mod(hsl.h, 360);
        hsl.s = @max(0, @min(1, hsl.s)) * 100;
        hsl.l = @max(0, @min(1, hsl.l)) * 100;
        return hsl;
    }

    /// Converts the RGB color into an HSV color.
    fn toHsv(self: RgbFloat) Hsv {
        var hsv = Hsv{};
        const min = @min(self.r, @min(self.g, self.b));
        const max = @max(self.r, @max(self.g, self.b));
        const delta = max - min;

        // hue
        if (delta == 0) {
            hsv.h = 0;
        } else if (max == self.r) {
            hsv.h = (self.g - self.b) / delta * 60;
        } else if (max == self.g) {
            hsv.h = 120 + (self.b - self.r) / delta * 60;
        } else {
            hsv.h = 240 + (self.r - self.g) / delta * 60;
        }
        hsv.h = @mod(hsv.h, 360);

        // saturation
        if (max == 0) {
            hsv.s = 0;
        } else {
            hsv.s = delta / max * 100;
        }

        // value
        hsv.v = max * 100;
        return hsv;
    }

    /// Converts the RGB color into a CIE 1931 XYZ color.
    fn toXyz(self: RgbFloat) Xyz {
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
    fn toLab(self: RgbFloat) Lab {
        return self.toXyz().toLab();
    }

    /// Converts the RGB color into an LMS color.
    fn toLms(self: RgbFloat) Lms {
        return self.toXyz().toLms();
    }

    /// Converts the RGB color into an Oklab color.
    fn toOklab(self: RgbFloat) Oklab {
        return self.toLms().toOklab();
    }

    /// Converts the RGB color into an XYB color.
    fn toXyb(self: RgbFloat) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [sRGB](https://en.wikipedia.org/wiki/SRGB) colorspace, with all components
/// within the range 0-255.
pub const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    /// Returns the normalized RGB color in floating point.
    fn toRgbFloat(self: Rgb) RgbFloat {
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

    /// Alpha-blends color into self.
    pub fn blend(self: *Rgb, color: Rgba) void {
        alphaBlend(Rgb, self, color);
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Rgb) bool {
        return self.r == self.g and self.g == self.b;
    }

    /// Converts the RGB color into grayscale.
    pub fn toGray(self: Rgb) u8 {
        return @intFromFloat(@round(self.toHsl().l / 100 * 255));
    }

    /// Converts the RGB color into a hex value.
    pub fn toHex(self: Rgb) u24 {
        return self.r << 16 + self.g << 8 + self.g;
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
    fn toLms(self: Rgb) Lms {
        return self.toRgbFloat().toLms();
    }

    /// Converts the RGB color into an Oklab color.
    fn toOklab(self: Rgb) Oklab {
        return self.toRgbFloat().toOklab();
    }

    /// Converts the RGB color into an XYB color.
    fn toXyb(self: Rgb) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [sRGB](https://en.wikipedia.org/wiki/SRGB) colorspace with alpha channel,
/// with all components within the range 0-255.
pub const Rgba = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

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

    /// Alpha-blends color into self.
    pub fn blend(self: *Rgba, color: Rgba) void {
        alphaBlend(Rgba, self, color);
    }

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Rgba) bool {
        return self.r == self.g and self.g == self.b;
    }

    /// Converts the RGBA color into grayscale.
    pub fn toGray(self: Rgba) u8 {
        return @intFromFloat(@round(self.toHsl().l / 100 * 255));
    }

    /// Converts the RGBA color into a hex value.
    pub fn toHex(self: Rgba) u32 {
        return self.r << (8 * 3) + self.g << (8 * 2) + self.g << (8 * 1) + self.a << (8 * 0);
    }

    /// Converts the RGBA color into a RGB color by removing the alpha channel.
    pub fn toRgb(self: Rgba) Rgb {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    /// Converts the RGBA color into a floating point RGB, ignoring the alpha channel.
    fn toRgbFloat(self: Rgba) RgbFloat {
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
        self.toRgbFloat().toXyz();
    }

    /// Converts the RGBA color into a Lab color, ignoring the alpha channel.
    pub fn toLab(self: Rgba) Lab {
        return self.toRgbFloat().toLab();
    }

    /// Converts the RGBA color into an LMS color.
    fn toLms(self: Rgba) Lms {
        return self.toXyz().toLms();
    }

    /// Converts the RGBA color into an Oklab color.
    fn toOklab(self: Rgba) Oklab {
        return self.toLms().toOklab();
    }

    /// Converts the RGBA color into an XYB color.
    fn toXyb(self: Rgba) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [HSL](https://en.wikipedia.org/wiki/HSL_and_HSV) colorspace: h in degrees
/// (0-359), s and l between 0-100.
pub const Hsl = struct {
    h: f64 = 0,
    s: f64 = 0,
    l: f64 = 0,

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
    fn toRgbFloat(self: Hsl) RgbFloat {
        var r: f64 = undefined;
        var g: f64 = undefined;
        var b: f64 = undefined;
        const s = self.s / 100;
        const l = self.l / 100;
        if (self.h < 120) {
            r = (120 - self.h) / 60;
            g = self.h / 60;
            b = 0;
        } else if (self.h < 240) {
            r = 0;
            g = (240 - self.h) / 60;
            b = (self.h - 120) / 60;
        } else {
            r = (self.h - 240) / 60;
            g = 0;
            b = (360 - self.h) / 60;
        }
        r = @min(r, 1);
        g = @min(g, 1);
        b = @min(b, 1);

        r = 2 * s * r + (1 - s);
        g = 2 * s * g + (1 - s);
        b = 2 * s * b + (1 - s);

        if (l < 0.5) {
            r *= l;
            g *= l;
            b *= l;
        } else {
            r = (1 - l) * r + 2 * l - 1;
            g = (1 - l) * g + 2 * l - 1;
            b = (1 - l) * b + 2 * l - 1;
        }
        return .{
            .r = @max(0, @min(1, r)),
            .g = @max(0, @min(1, g)),
            .b = @max(0, @min(1, b)),
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
    fn toLms(self: Hsl) Lms {
        return self.toRgb().toLms();
    }

    /// Converts the HSL color into an Oklab color.
    fn toOklab(self: Hsl) Oklab {
        return self.toRgb().toOklab();
    }

    /// Converts the HSL color into an XYB color.
    fn toXyb(self: Hsl) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [HSV](https://en.wikipedia.org/wiki/HSL_and_HSV) colorspace: h in degrees
/// (0-359), s and v between 0-100.
pub const Hsv = struct {
    h: f64 = 0,
    s: f64 = 0,
    v: f64 = 0,

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
        var r: f64 = undefined;
        var g: f64 = undefined;
        var b: f64 = undefined;
        const hue = @max(0, @min(1, self.h / 360));
        const sat = @max(0, @min(1, self.s / 100));
        const val = @max(0, @min(1, self.v / 100));

        if (sat == 0.0) {
            r = val;
            g = val;
            b = val;
        } else {
            const sector = hue * 6;
            const index: i32 = @intFromFloat(sector);
            const fractional = sector - @as(f64, @floatFromInt(index));
            const p = val * (1 - sat);
            const q = val * (1 - (sat * fractional));
            const t = val * (1 - sat * (1 - fractional));

            switch (index) {
                0 => {
                    r = val;
                    g = t;
                    b = p;
                },
                1 => {
                    r = q;
                    g = val;
                    b = p;
                },
                2 => {
                    r = p;
                    g = val;
                    b = t;
                },
                3 => {
                    r = p;
                    g = q;
                    b = val;
                },
                4 => {
                    r = t;
                    g = p;
                    b = val;
                },
                else => {
                    r = val;
                    g = p;
                    b = q;
                },
            }
        }
        return .{
            .r = @max(0, @min(1, r)),
            .g = @max(0, @min(1, g)),
            .b = @max(0, @min(1, b)),
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
    fn toLms(self: Hsv) Lms {
        return self.toRgbFloat().toLms();
    }

    /// Converts the HSV color into an Oklab color.
    fn toOklab(self: Hsv) Oklab {
        return self.toRgbFloat().toOklab();
    }

    /// Converts the HSV color into an XYB color.
    fn toXyb(self: Hsv) Xyb {
        return self.toLms().toXyb();
    }
};

/// The [CIE 1931 color space](https://en.wikipedia.org/wiki/CIE_1931_color_space), a device
/// independent space also known as XYZ which covers the full gamut of human-perceptible colors
/// visible to the CIE 2° standard observer.
pub const Xyz = struct {
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 0,

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
    fn toOklab(self: Xyz) Oklab {
        return self.toLms().toOklab();
    }

    /// Converts the CIE 1931 XYZ color into an XYB color.
    fn toXyb(self: Xyz) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [CIELAB colorspace](https://en.wikipedia.org/wiki/CIELAB_color_space).  L:
/// 0 to 100, a: -128 to 127, b: -128 to 127.
pub const Lab = struct {
    l: f64 = 0,
    a: f64 = 0,
    b: f64 = 0,

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
    fn toOklab(self: Lab) Oklab {
        return self.toLms().toOklab();
    }

    /// Converts the CIELAB color into an XYB color.
    fn toXyb(self: Lab) Xyb {
        return self.toLms().toXyb();
    }
};

/// A color in the [Oklab](https://en.wikipedia.org/wiki/Oklab_color_space) colorspace.  L:
/// 0 to 1 a: -0.5 to 0.5, b: -0.5to 0.5.
pub const Oklab = struct {
    l: f64 = 0,
    a: f64 = 0,
    b: f64 = 0,

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
    fn toRgbFloat(self: Oklab) RgbFloat {
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

/// A color in the [LMS colorspace](https://en.wikipedia.org/wiki/LMS_color_space), representing
/// the response of the three types of cones of the human eye.
pub const Lms = struct {
    l: f64 = 0,
    m: f64 = 0,
    s: f64 = 0,

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
    fn toRgbFloat(self: Lms) RgbFloat {
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

/// A color in the [XYB colorspace](https://en.wikipedia.org/wiki/LMS_color_space#Image_processing)
/// used in JPEG XL, which can be interpreted as a hybrid color theory where L and M are
/// opponents but S is handled in a tricromatic way. In practical terms, this allows for using
/// less data for storing blue signals without losing much perceived quality.
pub const Xyb = struct {
    x: f64 = 0,
    y: f64 = 0,
    b: f64 = 0,

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
    fn toRgbFloat(self: Xyb) RgbFloat {
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

    /// Converts the XYB color into an LMS color.
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

test "complimetary colors" {
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
    var prng = std.Random.DefaultPrng.init(seed);
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
