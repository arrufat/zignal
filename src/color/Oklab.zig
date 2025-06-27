//! A color in the [Oklab color space](https://bottosson.github.io/posts/oklab/).
//! Oklab is designed to be a perceptually uniform color space.
//! - l: Perceived lightness (0 for black to approximately 1 for white).
//! - a: Green-red axis (negative values towards green, positive towards red, typically around -0.4 to 0.4).
//! - b: Blue-yellow axis (negative values towards blue, positive towards yellow, typically around -0.4 to 0.4).

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");

l: f64,
a: f64,
b: f64,

pub const black: @This() = .{ .l = 0, .a = 0, .b = 0 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn isGray(self: Self) bool {
    return self.a == 0 and self.b == 0;
}

pub fn toGray(self: Self) u8 {
    return @intFromFloat(@round(@max(0, @min(1, self.l)) * 255));
}

pub fn toRgb(self: Self) Rgb {
    return conversions.oklabToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) Hsl {
    return conversions.oklabToHsl(self);
}

pub fn toHsv(self: Self) Hsv {
    return conversions.oklabToHsv(self);
}

pub fn toXyz(self: Self) Xyz {
    return conversions.oklabToXyz(self);
}

pub fn toLab(self: Self) Lab {
    return conversions.oklabToLab(self);
}

pub fn toLms(self: Self) Lms {
    return conversions.oklabToLms(self);
}

pub fn toXyb(self: Self) Xyb {
    return conversions.oklabToXyb(self);
}

pub fn blend(self: *Self, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toOklab();
}
