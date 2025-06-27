//! A color in the [XYB color space](https://jpeg.org/jpegxl/documentation/xl-color-management.html#xyb)
//! used in JPEG XL. It's derived from LMS and designed for efficient image compression.
//! - x: X component (L-M, red-green opponent channel).
//! - y: Y component (L+M, luminance-like channel).
//! - b: B component (S, blue-yellow like channel, but often scaled S cone response).
//! Ranges can vary based on transformations, but often centered around 0 for x and b, and positive for y.

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");

x: f64,
y: f64,
b: f64,

pub const black: @This() = .{ .x = 0, .y = 0, .b = 0 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn isGray(self: Self) bool {
    const oklab = self.toOklab();
    return oklab.a == 0 and oklab.b == 0;
}

pub fn toGray(self: Self) u8 {
    return @intFromFloat(@round(@max(0, @min(1, self.toOklab().l)) * 255));
}

pub fn toRgb(self: Self) @import("Rgb.zig") {
    return conversions.xybToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) @import("Rgba.zig") {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) @import("Hsl.zig") {
    return conversions.xybToHsl(self);
}

pub fn toHsv(self: Self) @import("Hsv.zig") {
    return conversions.xybToHsv(self);
}

pub fn toXyz(self: Self) @import("Xyz.zig") {
    return conversions.xybToXyz(self);
}

pub fn toLab(self: Self) @import("Lab.zig") {
    return conversions.xybToLab(self);
}

pub fn toLms(self: Self) @import("Lms.zig") {
    return conversions.xybToLms(self);
}

pub fn toOklab(self: Self) @import("Oklab.zig") {
    return conversions.xybToOklab(self);
}

pub fn blend(self: *Self, color: @import("Rgba.zig")) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toXyb();
}
