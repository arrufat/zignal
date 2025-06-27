//! A color in the [CIE 1931 XYZ color space](https://en.wikipedia.org/wiki/CIE_1931_color_space).
//! This is a device-independent space that covers the full gamut of human-perceptible colors
//! visible to the CIE 2° standard observer.
//! - x, y, z: Tristimulus values, typically non-negative. Y represents luminance.
//!   The typical range for these values can vary depending on the reference white point (e.g. D65).
//!   Often, Y is normalized to 100 for white.

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");

x: f64,
y: f64,
z: f64,

pub const black: @This() = .{ .x = 0, .y = 0, .z = 0 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn isGray(self: Self) bool {
    return self.toRgb().isGray();
}

pub fn toGray(self: Self) u8 {
    return self.toLab().toGray();
}

pub fn toRgb(self: Self) @import("Rgb.zig") {
    return conversions.xyzToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) @import("Rgba.zig") {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) @import("Hsl.zig") {
    return conversions.xyzToHsl(self);
}

pub fn toHsv(self: Self) @import("Hsv.zig") {
    return conversions.xyzToHsv(self);
}

pub fn toLab(self: Self) @import("Lab.zig") {
    return conversions.xyzToLab(self);
}

pub fn toLms(self: Self) @import("Lms.zig") {
    return conversions.xyzToLms(self);
}

pub fn toOklab(self: Self) @import("Oklab.zig") {
    return conversions.xyzToOklab(self);
}

pub fn toXyb(self: Self) @import("Xyb.zig") {
    return conversions.xyzToXyb(self);
}
