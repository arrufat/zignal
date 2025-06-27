//! A color in the [CIELAB color space](https://en.wikipedia.org/wiki/CIELAB_color_space) (also known as L*a*b*).
//! It expresses color as three values:
//! - l: Lightness (0 for black to 100 for white).
//! - a: Green-red axis (-128 for green to +127 for red).
//! - b: Blue-yellow axis (-128 for blue to +127 for yellow).

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");

l: f64,
a: f64,
b: f64,

pub const black: @This() = .{ .l = 0, .a = 0, .b = 0 };
pub const white: @This() = .{ .l = 100, .a = 0, .b = 0 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn isGray(self: Self) bool {
    return self.a == 0 and self.b == 0;
}

pub fn toGray(self: Self) u8 {
    return @intFromFloat(@round(self.l / 100 * 255));
}

pub fn toRgb(self: Self) @import("Rgb.zig") {
    return conversions.labToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) @import("Rgba.zig") {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) @import("Hsl.zig") {
    return conversions.labToHsl(self);
}

pub fn toHsv(self: Self) @import("Hsv.zig") {
    return self.toRgb().toHsv();
}

pub fn toXyz(self: Self) @import("Xyz.zig") {
    return conversions.labToRgb(self).toXyz();
}

pub fn toLms(self: Self) @import("Lms.zig") {
    return self.toXyz().toLms();
}

pub fn toOklab(self: Self) @import("Oklab.zig") {
    return self.toLms().toOklab();
}

pub fn toXyb(self: Self) @import("Xyb.zig") {
    return self.toLms().toXyb();
}

pub fn blend(self: *Self, color: @import("Rgba.zig")) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toLab();
}
