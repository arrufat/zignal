const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const lerp = std.math.lerp;
const pow = std.math.pow;

/// Returns true if and only if T can be treated as a color.
pub fn isColor(comptime T: type) bool {
    return switch (T) {
        u8, Rgb, Rgba, Hsl, Hsv, Xyz, Lab => true,
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
            u8 => .{ .h = 0, .s = 0, .l = @as(f32, @floatFromInt(color)) / 255 * 100 },
            inline else => color.toHsl(),
        },
        Hsv => switch (@TypeOf(color)) {
            Hsv => color,
            u8 => .{ .h = 0, .s = 0, .v = @as(f32, @floatFromInt(color)) / 255 * 100 },
            inline else => color.toHsv(),
        },
        Xyz => switch (@TypeOf(color)) {
            Xyz => color,
            u8 => Rgb.fromGray(color).toXyz(),
            inline else => color.toXyz(),
        },
        Lab => switch (@TypeOf(color)) {
            Lab => color,
            u8 => .{ .l = @as(f32, @floatFromInt(color)) / 255 * 100, .a = 0, .b = 0 },
            inline else => color.toLab(),
        },
        else => @compileError("Unsupported color " ++ @typeName(T)),
    };
}

test "isRgbCompatible" {
    try comptime expectEqual(isRgbCompatible(u8), false);
    try comptime expectEqual(isRgbCompatible(Rgb), true);
    try comptime expectEqual(isRgbCompatible(Rgba), true);
    try comptime expectEqual(isRgbCompatible(Hsl), false);
    try comptime expectEqual(isRgbCompatible(Hsv), false);
    try comptime expectEqual(isRgbCompatible(Xyz), false);
    try comptime expectEqual(isRgbCompatible(Lab), false);
}

test "convert" {
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

/// A Red-Green-Blue-Alpha color.
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
    pub fn fromHex(hex_code: u32) Rgb {
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

    /// Converts the RGBA color into an RGB color by removing the alpha channel.
    pub fn toRgb(self: Rgba) Rgb {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    /// Converts the RGBA color into an HSL color, ignoring the alpha channel.
    pub fn toHsl(self: Rgba) Hsl {
        return self.toRgb().toHsl();
    }

    /// Converts the RGBA color into an HSV color, ignoring the alpha channel.
    pub fn toHsv(self: Rgba) Hsv {
        return self.toRgb().toHsv();
    }

    /// Converts the RGBA color into a CIE 1931 XYZ color.
    pub fn toXyz(self: Rgba) Xyz {
        self.toRgb().toXyz();
    }

    /// Converts the RGBA color into an Lab color, ignoring the alpha channel.
    pub fn toLab(self: Rgba) Lab {
        return self.toRgb().toLab();
    }
};

/// A color in the RGB colorspace, with all components within the range 0-255.
pub const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

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

    /// Converts the RGB color into an RGBA color with the specified alpha.
    pub fn toRgba(self: Rgb, alpha: u8) Rgba {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }

    /// Converts the RGB color into an HSL color.
    pub fn toHsl(self: Rgb) Hsl {
        const r: f32 = @as(f32, @floatFromInt(self.r)) / 255;
        const g: f32 = @as(f32, @floatFromInt(self.g)) / 255;
        const b: f32 = @as(f32, @floatFromInt(self.b)) / 255;
        const min = @min(r, @min(g, b));
        const max = @max(r, @max(g, b));
        const delta = max - min;
        var hsl = Hsl{ .h = 0, .s = 0, .l = 0 };
        hsl.l = (max + min) / 2;
        if (hsl.l > 0 and hsl.l < 1) {
            hsl.s = delta / if (hsl.l < 0.5) 2 * hsl.l else 2 - 2 * hsl.l;
        }
        if (delta > 0) {
            if (max == r and max != g) {
                hsl.h += (g - b) / delta;
            }
            if (max == g and max != b) {
                hsl.h += 2 + (b - r) / delta;
            }
            if (max == b and max != r) {
                hsl.h += 4 + (r - g) / delta;
            }
            hsl.h *= 60;
        }
        if (hsl.h < 0) hsl.h += 360;
        hsl.h = if (hsl.h == 360) 0 else hsl.h;
        hsl.s = @max(0, @min(1, hsl.s)) * 100;
        hsl.l = @max(0, @min(1, hsl.l)) * 100;
        return hsl;
    }

    /// Converts the RGB color into an HSV color.
    pub fn toHsv(self: Rgb) Hsv {
        const r: f32 = @as(f32, @floatFromInt(self.r)) / 255;
        const g: f32 = @as(f32, @floatFromInt(self.g)) / 255;
        const b: f32 = @as(f32, @floatFromInt(self.b)) / 255;
        var hsv = Hsv{};
        const min = @min(r, @min(g, b));
        const max = @max(r, @max(g, b));
        const delta = max - min;

        // hue
        if (delta == 0) {
            hsv.h = 0;
        } else if (max == r) {
            hsv.h = (g - b) / delta * 60;
        } else if (max == g) {
            hsv.h = 120 + (b - r) / delta * 60;
        } else {
            hsv.h = 240 + (r - g) / delta * 60;
        }
        if (hsv.h < 0) hsv.h += 360;
        hsv.h = if (hsv.h == 360) 0 else hsv.h;

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
    pub fn toXyz(self: Rgb) Xyz {
        var r: f64 = @as(f64, @floatFromInt(self.r)) / 255;
        var g: f64 = @as(f64, @floatFromInt(self.g)) / 255;
        var b: f64 = @as(f64, @floatFromInt(self.b)) / 255;

        r = if (r > 0.04045) pow(f64, (r + 0.055) / 1.055, 2.4) else r / 12.92;
        g = if (g > 0.04045) pow(f64, (g + 0.055) / 1.055, 2.4) else g / 12.92;
        b = if (b > 0.04045) pow(f64, (b + 0.055) / 1.055, 2.4) else b / 12.92;

        return .{
            .x = (r * 0.4124 + g * 0.3576 + b * 0.1805) * 100,
            .y = (r * 0.2126 + g * 0.7152 + b * 0.0722) * 100,
            .z = (r * 0.0193 + g * 0.1192 + b * 0.9505) * 100,
        };
    }

    /// Converts the RGB color into a CIELAB color.
    pub fn toLab(self: Rgb) Lab {
        return self.toXyz().toLab();
    }
};

/// A color in the HSL colorspace: h in degrees (0-359), s and l between 0-100.
pub const Hsl = struct {
    h: f32 = 0,
    s: f32 = 0,
    l: f32 = 0,

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
    /// Converts the HSL color into an RGB color.
    pub fn toRgb(self: Hsl) Rgb {
        var r: f32 = undefined;
        var g: f32 = undefined;
        var b: f32 = undefined;
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
            .r = @intFromFloat(@round(255 * @max(0, @min(1, r)))),
            .g = @intFromFloat(@round(255 * @max(0, @min(1, g)))),
            .b = @intFromFloat(@round(255 * @max(0, @min(1, b)))),
        };
    }

    /// Converts the HSL color into an RGBA color with the specified alpha.
    pub fn toRgba(self: Hsl, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the HSL color into a HSV color.
    pub fn toHsv(self: Hsl) Hsv {
        return self.toRgb().toHsv();
    }

    /// Converts the Hsl color into a CIE 1931 XYZ color.
    pub fn toXyz(self: Hsl) Xyz {
        self.toRgb().toXyz();
    }

    /// Converts the HSL color into a CIELAB color.
    pub fn toLab(self: Hsl) Lab {
        return self.toRgb().toLab();
    }
};

/// A color in the HSV colorspace: h in degrees (0-359), s and v between 0-100.
pub const Hsv = struct {
    h: f32 = 0,
    s: f32 = 0,
    v: f32 = 0,

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
    pub fn toRgb(self: Hsv) Rgb {
        var r: f32 = undefined;
        var g: f32 = undefined;
        var b: f32 = undefined;
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
            const fractional = sector - @as(f32, @floatFromInt(index));
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
            .r = @intFromFloat(@round(255 * @max(0, @min(1, r)))),
            .g = @intFromFloat(@round(255 * @max(0, @min(1, g)))),
            .b = @intFromFloat(@round(255 * @max(0, @min(1, b)))),
        };
    }

    /// Converts the HSV color into an RGBA color with the specified alpha.
    pub fn toRgba(self: Hsv, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the HSV color into an HSL color, ignoring the alpha channel.
    pub fn toHsl(self: Hsv) Hsl {
        return self.toRgb().toHsl();
    }

    /// Converts the HSV color into a CIE 1931 XYZ color.
    pub fn toXyz(self: Hsv) Xyz {
        self.toRgb().toXyz();
    }

    /// Converts the HSV color into a CIELAB color.
    pub fn toLab(self: Hsv) Lab {
        return self.toRgb().toLab();
    }
};

/// The CIE 1931 color space, a device independent space also known as XYZ which covers the
/// full gamut of human-perceptible colors visible to the CIE 2° standard observer.
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
    pub fn toRgb(self: Xyz) Rgb {
        var r = (self.x * 3.2406 + self.y * -1.5372 + self.z * -0.4986) / 100;
        var g = (self.x * -0.9689 + self.y * 1.8758 + self.z * 0.0415) / 100;
        var b = (self.x * 0.0557 + self.y * -0.2040 + self.z * 1.0570) / 100;

        r = if (r > 0.0031308) 1.055 * pow(f64, r, (1.0 / 2.4)) - 0.055 else r * 12.92;
        g = if (g > 0.0031308) 1.055 * pow(f64, g, (1.0 / 2.4)) - 0.055 else g * 12.92;
        b = if (b > 0.0031308) 1.055 * pow(f64, b, (1.0 / 2.4)) - 0.055 else b * 12.92;

        return .{
            .r = @intFromFloat(@round(255 * @max(0, @min(1, r)))),
            .g = @intFromFloat(@round(255 * @max(0, @min(1, g)))),
            .b = @intFromFloat(@round(255 * @max(0, @min(1, b)))),
        };
    }

    /// Converts the CIE 1931 XYZ color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Xyz, alpha: u8) Rgba {
        self.toRgb().toRgba(alpha);
    }

    /// Converts the CIE 1931 XYZ color into a HSL color.
    pub fn toHsl(self: Xyz) Hsl {
        self.toRgb().toHsl();
    }

    /// Converts the CIE 1931 XYZ color into a HSV color.
    pub fn toHsv(self: Xyz) Hsv {
        return self.toRgb().toHsv();
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
};

/// A color in the CIELAB colorspace: L: 0 to 100, a: -128 to 127, b: -128 to 127.
pub const Lab = struct {
    l: f64 = 0,
    a: f64 = 0,
    b: f64 = 0,

    /// Checks if the color is a shade of gray.
    pub fn isGray(self: Lab) bool {
        return self.a == 0 and self.b == 0;
    }

    /// Converts the Lab color into grayscale.
    pub fn toGray(self: Lab) u8 {
        return @intFromFloat(@round(self.l / 100 * 255));
    }

    /// Converts the CIELAB color into a RGB color.
    pub fn toRgb(self: Lab) Rgb {
        return self.toXyz().toRgb();
    }

    /// Converts the CIELAB color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Lab, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the CIELAB color into a HSL color.
    pub fn toHsl(self: Lab) Hsl {
        return self.toRgb().toHsl();
    }

    /// Converts the CIELAB color into a HSV color.
    pub fn toHsv(self: Lab) Hsv {
        return self.toRgb().toHsv();
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

    /// Alpha-blends color into self.
    pub fn blend(self: *Lab, color: Rgba) void {
        var rgb = self.toRgb();
        rgb.blend(color);
        self = rgb.toLab();
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
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Hsl{ .h = 300, .s = 100, .l = 25.098042 });
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Hsv{ .h = 300, .s = 100, .v = 50.196083 });
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Lab{ .l = 29.782100092098077, .a = 58.93983731904206, .b = -36.49792996282386 });
}

test "neutral colors" {
    // white: 0xffffff
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Hsl{ .h = 0, .s = 0, .l = 100 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Hsv{ .h = 0, .s = 0, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Lab{ .l = 100, .a = 0.00526049995830391, .b = -0.010408184525267927 });
    // gray: 0x808080
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Hsl{ .h = 0, .s = 0, .l = 50.196083 });
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Hsv{ .h = 0, .s = 0, .v = 50.196083 });
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Lab{ .l = 53.58501345216902, .a = 0.003155620347972121, .b = -0.006243566036268078 });
    // black: 0x000000
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Hsl{ .h = 0, .s = 0, .l = 0 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Hsv{ .h = 0, .s = 0, .v = 0 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Lab{ .l = 0, .a = 0, .b = 0 });
}

test "pastel colors" {
    // pale_pink: 0xffd3ba
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Hsl{ .h = 21.73913, .s = 100, .l = 86.47059 });
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Hsv{ .h = 21.73913, .s = 27.058823, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Lab{ .l = 87.67593388241974, .a = 11.843797404960165, .b = 18.16236917854479 });
    // mint_green: 0x96fa96
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Hsl{ .h = 120, .s = 90.909096, .l = 78.43137 });
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Hsv{ .h = 120, .s = 39.999996, .v = 98.039215 });
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Lab{ .l = 90.34795996024553, .a = -48.75545372512652, .b = 38.96689290268498 });
    // sky_blue: #8ad1ed
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Hsl{ .h = 196.9697, .s = 73.33332, .l = 73.52941 });
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Hsv{ .h = 196.9697, .s = 41.77215, .v = 92.94118 });
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Lab{ .l = 80.24627015828005, .a = -15.11865203941365, .b = -20.767024460106565 });
}

test "vivid colors" {
    // hot_pink: #ff66b3
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Hsl{ .h = 329.80392, .s = 100, .l = 70 });
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Hsv{ .h = 329.80392, .s = 60.000004, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Lab{ .l = 64.9763931162809, .a = 65.40669278373645, .b = -10.847761988977656 });
    // lime_green:#31cc31
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Hsl{ .h = 120, .s = 61.264824, .l = 49.60784 });
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Hsv{ .h = 120, .s = 75.98039, .v = 80 });
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Lab{ .l = 72.26888334336961, .a = -67.03378336285304, .b = 61.425460443480894 });
    // electric_blue: #80dfff
    try testColorConversion(.{ .r = 128, .g = 223, .b = 255 }, Hsl{ .h = 195.1181, .s = 99.999985, .l = 7.509804e1 });
    try testColorConversion(.{ .r = 128, .g = 223, .b = 255 }, Hsv{ .h = 195.1181, .s = 49.803917, .v = 100 });
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
