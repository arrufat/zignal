const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectApproxEqRel = std.testing.expectApproxEqRel;
const pow = std.math.pow;

pub const Color = union(enum) {
    Gray: u8,
    Rgb: Rgb,
    Rgba: Rgba,
    Hsv: Hsv,
    Lab: Lab,

    /// Returns true if and only if T can be treated as a color.
    fn isColor(comptime T: type) bool {
        return switch (T) {
            u8, Rgb, Rgba, Hsv, Lab => true,
            else => false,
        };
    }

    /// Converts color into a the T colorspace.
    pub fn convert(comptime T: type, color: anytype) T {
        comptime assert(isColor(T));
        comptime assert(isColor(@TypeOf(color)));
        return switch (T) {
            u8 => switch (@TypeOf(color)) {
                u8 => color,
                inline Rgb, Rgba => @intFromFloat(color.toHsv().v / 100 * 255),
                else => @compileError("Unsupported color " ++ @typeName(@TypeOf(color))),
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
            Hsv => switch (@TypeOf(color)) {
                Hsv => color,
                u8 => .{ .h = 0, .s = 0, .v = @as(f32, @floatFromInt(color)) / 255 * 100 },
                inline else => color.toHsv(),
            },
            Lab => switch (@TypeOf(color)) {
                Lab => color,
                u8 => .{ .l = @as(f32, @floatFromInt(color)) / 255 * 100, .a = 0, .b = 0 },
                inline else => color.toLab(),
            },
            else => @compileError("Unsupported color " ++ @typeName(T)),
        };
    }
};

/// Checks whether a type T can be used as an Rgb color, i.e., it has r, g, b fields of type u8.
fn isRgbCompatible(comptime T: type) bool {
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

test "Rgb compatibility" {
    try comptime expectEqual(isRgbCompatible(Rgb), true);
    try comptime expectEqual(isRgbCompatible(Rgba), true);
    try comptime expectEqual(isRgbCompatible(Hsv), false);
    try comptime expectEqual(isRgbCompatible(Lab), false);
}

/// Alpha-blends c2 into c1.
fn alphaBlend(comptime T: type, c1: *T, c2: Rgba) void {
    if (comptime !isRgbCompatible(T)) {
        @compileError(@typeName(T) ++ " is not Rgb compatible");
    }
    if (c2.a == 0) {
        return;
    }
    const a = @as(f32, @floatFromInt(c2.a)) / 255;
    c1.r = @intFromFloat((1 - a) * @as(f32, @floatFromInt(c1.r)) + @max(0, @min(255, @round(a * @as(f32, @floatFromInt(c2.r))))));
    c1.g = @intFromFloat((1 - a) * @as(f32, @floatFromInt(c1.g)) + @max(0, @min(255, @round(a * @as(f32, @floatFromInt(c2.g))))));
    c1.b = @intFromFloat((1 - a) * @as(f32, @floatFromInt(c1.b)) + @max(0, @min(255, @round(a * @as(f32, @floatFromInt(c2.b))))));
}

test "alphaBlend" {
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    var output = Rgb{ .r = 0, .g = 0, .b = 0 };
    output.blend(white.toRgba(128));
    try expectEqualDeep(output, Rgb{ .r = 128, .g = 128, .b = 128 });
}

/// A Red-Green-Blue-Alpha pixel.
pub const Rgba = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    /// Constructs a RGBA pixel from a gray and alpha values.
    pub fn fromGray(gray: u8, alpha: u8) Rgba {
        return Rgb.fromGray(gray).toRgba(alpha);
    }

    /// Constructs a RGBA pixel from a hex value.
    pub fn fromHex(hex_code: u32) Rgb {
        return .{
            .r = @intCast((hex_code >> 24) & 0x0000ff),
            .g = @intCast((hex_code >> 16) & 0x0000ff),
            .b = @intCast((hex_code >> 8) & 0x0000ff),
            .a = @intCast(hex_code & 0x0000ff),
        };
    }

    /// Alpha-blends color into self.
    pub fn blend(self: *Rgba, color: Rgba) void {
        alphaBlend(Rgba, self, color);
    }

    /// Converts the RGBA color into a hex value.
    pub fn toHex(self: Rgba) u32 {
        return self.r << 24 + self.g << 16 + self.g << 8 + self.a;
    }

    /// Converts the RGBA color into an RGB color by removing the alpha channel.
    pub fn toRgb(self: Rgba) Rgb {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    /// Converts the RGBA color into an HSV color, ignoring the alpha channel.
    pub fn toHsv(self: Rgba) Hsv {
        return self.toRgb().toHsv();
    }

    /// Converts the RGBA color into an Lab color, ignoring the alpha channel.
    pub fn toLab(self: Rgba) Lab {
        return self.toRgb().toLab();
    }

    /// Checks if the pixel is a shade of gray.
    pub fn isGray(self: Rgba) bool {
        return self.r == self.g and self.g == self.b;
    }
};

/// A color in the RGB colorspace, with all components within the range 0-255.
pub const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    /// Constructs a RGB pixel from a gray value.
    pub fn fromGray(gray: u8) Rgb {
        return .{ .r = gray, .g = gray, .b = gray };
    }

    /// Constructs a RGB pixel from a hex value.
    pub fn fromHex(hex_code: u24) Rgb {
        return .{
            .r = @intCast((hex_code >> 16) & 0x0000ff),
            .g = @intCast((hex_code >> 8) & 0x0000ff),
            .b = @intCast(hex_code & 0x0000ff),
        };
    }

    /// Alpha-blends color into self.
    pub fn blend(self: *Rgb, color: Rgba) void {
        alphaBlend(Rgb, self, color);
    }

    /// Converts the RGB color into a hex value.
    pub fn toHex(self: Rgb) u24 {
        return self.r << 16 + self.g << 8 + self.g;
    }

    /// Converts the RGB color into an RGBA color with the specified alpha.
    pub fn toRgba(self: Rgb, alpha: u8) Rgba {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }

    /// Checks if the pixel is a shade of gray.
    pub fn isGray(self: Rgb) bool {
        return self.r == self.g and self.g == self.b;
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
        if (hsv.h < 0) {
            hsv.h += 360;
        }
        hsv.h = if (@round(hsv.h) == 360) 0 else @round(hsv.h);

        // saturation
        if (max == 0) {
            hsv.s = 0;
        } else {
            hsv.s = @round(delta / max * 100);
        }

        // value
        hsv.v = @round(max * 100);
        return hsv;
    }

    /// Converts the RGB color into a CIELAB color.
    pub fn toLab(self: Rgb) Lab {
        var r: f64 = @as(f64, @floatFromInt(self.r)) / 255;
        var g: f64 = @as(f64, @floatFromInt(self.g)) / 255;
        var b: f64 = @as(f64, @floatFromInt(self.b)) / 255;

        if (r > 0.04045) {
            r = pow(f64, (r + 0.055) / 1.055, 2.4);
        } else {
            r /= 12.92;
        }

        if (g > 0.04045) {
            g = pow(f64, (g + 0.055) / 1.055, 2.4);
        } else {
            g /= 12.92;
        }

        if (b > 0.04045) {
            b = pow(f64, (b + 0.055) / 1.055, 2.4);
        } else {
            b /= 12.92;
        }

        r *= 100;
        g *= 100;
        b *= 100;

        // Observer. = 2°, illuminant = D65.
        var x: f64 = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 95.047;
        var y: f64 = (r * 0.2126 + g * 0.7152 + b * 0.0722) / 100.000;
        var z: f64 = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 108.883;

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

/// A color in the HSV colorspace: h in degrees (0-359), s and v between 0-100.
pub const Hsv = struct {
    h: f32 = 0,
    s: f32 = 0,
    v: f32 = 0,

    /// Alpha-blends color into self.
    pub fn blend(self: *Hsv, color: Rgba) void {
        const rgb = self.toRgb().blend(color);
        self = rgb.toHsv();
    }

    /// Checks if the pixel is a shade of gray.
    pub fn isGray(self: Hsv) bool {
        return self.s == 0;
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
            .r = @intFromFloat(@max(0, @min(255, @round(r * 255)))),
            .g = @intFromFloat(@max(0, @min(255, @round(g * 255)))),
            .b = @intFromFloat(@max(0, @min(255, @round(b * 255)))),
        };
    }

    /// Converts the HSV color into a CIELAB color.
    pub fn toLab(self: Hsv) Lab {
        return self.toRgb().toLab();
    }

    /// Converts the HSV color into an RGBA color with the specified alpha.
    pub fn toRgba(self: Hsv, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }
};

/// A color in the CIELAB colorspace: L: 0 to 100, a: -128 to 127, b: -128 to 127.
pub const Lab = struct {
    l: f64 = 0,
    a: f64 = 0,
    b: f64 = 0,

    /// Converts the CIELAB color into a RGB color.
    pub fn toRgb(self: Lab) Rgb {
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

        x *= 95.047;
        y *= 100.000;
        z *= 108.883;

        x = x / 100.0;
        y = y / 100.0;
        z = z / 100.0;

        var r = x * 3.2406 + y * -1.5372 + z * -0.4986;
        var g = x * -0.9689 + y * 1.8758 + z * 0.0415;
        var b = x * 0.0557 + y * -0.2040 + z * 1.0570;

        if (r > 0.0031308) {
            r = 1.055 * pow(f64, r, (1.0 / 2.4)) - 0.055;
        } else {
            r = 12.92 * r;
        }

        if (g > 0.0031308) {
            g = 1.055 * pow(f64, g, (1.0 / 2.4)) - 0.055;
        } else {
            g = 12.92 * g;
        }

        if (b > 0.0031308) {
            b = 1.055 * pow(f64, b, (1.0 / 2.4)) - 0.055;
        } else {
            b = 12.92 * b;
        }

        return .{
            .r = @intFromFloat(@max(0, @min(255, @round(r * 255)))),
            .g = @intFromFloat(@max(0, @min(255, @round(g * 255)))),
            .b = @intFromFloat(@max(0, @min(255, @round(b * 255)))),
        };
    }
    /// Converts the CIELAB color into a RGBA color with the specified alpha.
    pub fn toRgba(self: Lab, alpha: u8) Rgba {
        return self.toRgb().toRgba(alpha);
    }

    /// Converts the CIELAB color into a HSV color.
    pub fn toHsv(self: Lab) Hsv {
        return self.toRgb().toHsv();
    }

    /// Alpha-blends color into self.
    pub fn blend(self: *Lab, color: Rgba) void {
        const rgb = self.toRgb().blend(color);
        self = rgb.toLab();
    }
};

test "hex to RGB/A" {
    try std.testing.expectEqualDeep(Rgb.fromHex(0x4e008e), Rgb{ .r = 78, .g = 0, .b = 142 });
    try std.testing.expectEqualDeep(Rgb.fromHex(0x000000), Rgb{ .r = 0, .g = 0, .b = 0 });
    try std.testing.expectEqualDeep(Rgb.fromHex(0xffffff), Rgb{ .r = 255, .g = 255, .b = 255 });
}

fn testHsvColorConversion(from: Rgb, to: Hsv) !void {
    const hsv = from.toHsv();
    try expectEqualDeep(hsv, to);
    const rgb = hsv.toRgb();
    try expectEqualDeep(rgb, from);
}

fn testLabColorConversion(from: Rgb, to: Lab) !void {
    const lab = from.toLab();
    const tol = @sqrt(std.math.floatEps(f64));
    try expectApproxEqRel(lab.l, to.l, tol);
    try expectApproxEqRel(lab.a, to.a, tol);
    try expectApproxEqRel(lab.b, to.b, tol);
    const rgb = lab.toRgb();
    try expectEqualDeep(rgb, from);
}

test "primary colors" {
    // red
    try testHsvColorConversion(.{ .r = 255, .g = 0, .b = 0 }, .{ .h = 0, .s = 100, .v = 100 });
    try testLabColorConversion(.{ .r = 255, .g = 0, .b = 0 }, .{ .l = 53.23288178584245, .a = 80.10930952982204, .b = 67.22006831026425 });
    // green
    try testHsvColorConversion(.{ .r = 0, .g = 255, .b = 0 }, .{ .h = 120, .s = 100, .v = 100 });
    try testLabColorConversion(.{ .r = 0, .g = 255, .b = 0 }, .{ .l = 87.73703347354422, .a = -86.18463649762525, .b = 83.18116474777854 });
    // blue
    try testHsvColorConversion(.{ .r = 0, .g = 0, .b = 255 }, .{ .h = 240, .s = 100, .v = 100 });
    try testLabColorConversion(.{ .r = 0, .g = 0, .b = 255 }, .{ .l = 32.302586667249486, .a = 79.19666178930935, .b = -107.86368104495168 });
}

test "secondary colors" {
    // cyan
    try testHsvColorConversion(.{ .r = 0, .g = 255, .b = 255 }, .{ .h = 180, .s = 100, .v = 100 });
    try testLabColorConversion(.{ .r = 0, .g = 255, .b = 255 }, .{ .l = 91.11652110946342, .a = -48.079618466228716, .b = -14.138127754846131 });
    // magenta
    try testHsvColorConversion(.{ .r = 255, .g = 0, .b = 255 }, .{ .h = 300, .s = 100, .v = 100 });
    try testLabColorConversion(.{ .r = 255, .g = 0, .b = 255 }, .{ .l = 60.319933664076004, .a = 98.25421868616114, .b = -60.84298422386232 });
    // yellow
    try testHsvColorConversion(.{ .r = 255, .g = 255, .b = 0 }, .{ .h = 60, .s = 100, .v = 100 });
    try testLabColorConversion(.{ .r = 255, .g = 255, .b = 0 }, .{ .l = 97.13824698129729, .a = -21.555908334832285, .b = 94.48248544644461 });
}

test "complimetary colors" {
    // orange
    try testHsvColorConversion(.{ .r = 255, .g = 136, .b = 0 }, .{ .h = 32, .s = 100, .v = 100 });
    try testLabColorConversion(.{ .r = 255, .g = 136, .b = 0 }, .{ .l = 68.65577208167872, .a = 38.85052375564024, .b = 74.99022544139405 });
    // purple
    try testHsvColorConversion(.{ .r = 128, .g = 0, .b = 128 }, .{ .h = 300, .s = 100, .v = 50 });
    try testLabColorConversion(.{ .r = 128, .g = 0, .b = 128 }, .{ .l = 29.782100092098077, .a = 58.93983731904206, .b = -36.49792996282386 });
}

test "neutral colors" {
    // white
    try testHsvColorConversion(.{ .r = 255, .g = 255, .b = 255 }, .{ .h = 0, .s = 0, .v = 100 });
    try testLabColorConversion(.{ .r = 255, .g = 255, .b = 255 }, .{ .l = 100, .a = 0.00526049995830391, .b = -0.010408184525267927 });
    // gray
    try testHsvColorConversion(.{ .r = 128, .g = 128, .b = 128 }, .{ .h = 0, .s = 0, .v = 50 });
    try testLabColorConversion(.{ .r = 128, .g = 128, .b = 128 }, .{ .l = 53.585013452169036, .a = 0.003155620347972121, .b = -0.006243566036245873 });
    // black
    try testHsvColorConversion(.{ .r = 0, .g = 0, .b = 0 }, .{ .h = 0, .s = 0, .v = 0 });
    try testLabColorConversion(.{ .r = 0, .g = 0, .b = 0 }, .{ .l = 0, .a = 0, .b = 0 });
}

test "pastel colors" {
    // pale_pink
    try testHsvColorConversion(.{ .r = 255, .g = 211, .b = 186 }, .{ .h = 22, .s = 27, .v = 100 });
    try testLabColorConversion(.{ .r = 255, .g = 211, .b = 186 }, .{ .l = 87.67593388241974, .a = 11.843797404960165, .b = 18.162369178544814 });
    // mint_green
    try testHsvColorConversion(.{ .r = 150, .g = 250, .b = 150 }, .{ .h = 120, .s = 40, .v = 98 });
    try testLabColorConversion(.{ .r = 150, .g = 250, .b = 150 }, .{ .l = 90.34795996024553, .a = -48.75545372512652, .b = 38.96689290268498 });
    // sky_blue
    try testHsvColorConversion(.{ .r = 138, .g = 209, .b = 237 }, .{ .h = 197, .s = 42, .v = 93 });
    try testLabColorConversion(.{ .r = 138, .g = 209, .b = 237 }, .{ .l = 80.24627015828005, .a = -15.11865203941365, .b = -20.767024460106587 });
}

test "vivid colors" {
    // hot_pink
    try testHsvColorConversion(.{ .r = 255, .g = 102, .b = 179 }, .{ .h = 330, .s = 60, .v = 100 });
    try testLabColorConversion(.{ .r = 255, .g = 102, .b = 179 }, .{ .l = 64.9763931162809, .a = 65.4066927837365, .b = -10.847761988977656 });
    // lime_green
    try testHsvColorConversion(.{ .r = 49, .g = 204, .b = 49 }, .{ .h = 120, .s = 76, .v = 80 });
    try testLabColorConversion(.{ .r = 49, .g = 204, .b = 49 }, .{ .l = 72.26888334336961, .a = -67.03378336285304, .b = 61.425460443480894 });
    // electric_blue
    try testHsvColorConversion(.{ .r = 128, .g = 223, .b = 255 }, .{ .h = 195, .s = 50, .v = 100 });
    try testLabColorConversion(.{ .r = 128, .g = 223, .b = 255 }, .{ .l = 84.26919487615706, .a = -19.77368831613657, .b = -24.252061008370763 });
}

test "100 random colors" {
    for (0..100) |_| {
        const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        var prng = std.Random.DefaultPrng.init(seed);
        var random = prng.random();
        const rgb: Rgb = .{
            .r = random.int(u8),
            .g = random.int(u8),
            .b = random.int(u8),
        };
        const rgb_from_hsv = rgb.toHsv().toRgb();
        const rgb_from_lab = rgb.toLab().toRgb();
        // Because of rounding errors and range differences, allow colors to differ a little bit.
        try expectApproxEqAbs(@as(f32, @floatFromInt(rgb.r)), @as(f32, @floatFromInt(rgb_from_hsv.r)), 3);
        try expectApproxEqAbs(@as(f32, @floatFromInt(rgb.g)), @as(f32, @floatFromInt(rgb_from_hsv.g)), 3);
        try expectApproxEqAbs(@as(f32, @floatFromInt(rgb.b)), @as(f32, @floatFromInt(rgb_from_hsv.b)), 3);
        try expectEqualDeep(rgb, rgb_from_lab);
    }
}

export fn computeBrightnessRgba(image: [*]const Rgba, rows: usize, cols: usize) f32 {
    const size = rows * cols;
    const img = image[0..size];
    var r_sum: u64 = 0;
    var g_sum: u64 = 0;
    var b_sum: u64 = 0;
    for (img) |p| {
        r_sum += p.r;
        g_sum += p.g;
        b_sum += p.b;
    }
    return (@as(f32, @floatFromInt(r_sum)) * 0.2 +
        @as(f32, @floatFromInt(g_sum)) * 0.7 +
        @as(f32, @floatFromInt(b_sum)) * 0.1) /
        @as(f32, @floatFromInt(size));
}

export fn computeBrightnessSimd(image: [*]const u8, size: usize) f32 {
    const vector_len: usize = 512;
    const pixel_len: usize = 4;
    const repeat: usize = vector_len / pixel_len;
    const img = image[0..size];
    const r_idx: @Vector(vector_len, usize) = [_]usize{ 1, 0, 0, 0 } ** repeat;
    const g_idx: @Vector(vector_len, usize) = [_]usize{ 0, 1, 0, 0 } ** repeat;
    const b_idx: @Vector(vector_len, usize) = [_]usize{ 0, 0, 1, 0 } ** repeat;
    var r_sum: u64 = 0;
    var g_sum: u64 = 0;
    var b_sum: u64 = 0;
    var pos: usize = 0;
    var rem = size;
    var tmp: @Vector(vector_len, usize) = undefined;
    while (rem > 0) {
        if (rem < vector_len) {
            while (pos < img.len) {
                r_sum += img[pos];
                g_sum += img[pos + 1];
                b_sum += img[pos + 2];
                pos += pixel_len;
                rem -= pixel_len;
            }
        } else {
            const v: @Vector(vector_len, u8) = img[pos..][0..vector_len].*;
            tmp = r_idx * v;
            r_sum += @reduce(.Add, tmp);
            tmp = g_idx * v;
            g_sum += @reduce(.Add, tmp);
            tmp = b_idx * v;
            b_sum += @reduce(.Add, tmp);
            pos += vector_len;
            rem -= vector_len;
        }
    }
    return (@as(f32, @floatFromInt(r_sum)) * 0.2 +
        @as(f32, @floatFromInt(g_sum)) * 0.7 +
        @as(f32, @floatFromInt(b_sum)) * 0.1) /
        @as(f32, @floatFromInt(size / pixel_len));
}

test "brightness" {
    const rows: usize = 4321;
    const cols: usize = 987;
    const pixel_len = 4;
    const size = rows * cols * pixel_len;
    var img = [_]u8{1} ** size;
    try std.testing.expectEqual(computeBrightnessRgba(@alignCast(@ptrCast(img[0..].ptr)), rows, cols), 1);
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
    var prng = std.Random.DefaultPrng.init(seed);
    var random = prng.random();
    for (&img) |*p| {
        p.* = random.int(u8);
    }
    try std.testing.expectEqual(
        computeBrightnessRgba(@alignCast(@ptrCast(img[0..].ptr)), rows, cols),
        computeBrightnessSimd(img[0..size].ptr, size),
    );
}
