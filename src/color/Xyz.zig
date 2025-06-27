//! A color in the [CIE 1931 XYZ color space](https://en.wikipedia.org/wiki/CIE_1931_color_space).
//! This is a device-independent space that covers the full gamut of human-perceptible colors
//! visible to the CIE 2° standard observer.
//! - x, y, z: Tristimulus values, typically non-negative. Y represents luminance.
//!   The typical range for these values can vary depending on the reference white point (e.g. D65).
//!   Often, Y is normalized to 100 for white.

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");

// Import color types
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Xyz = @import("Xyz.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Xyb = @import("Xyb.zig");

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

pub fn toRgb(self: Self) Rgb {
    return conversions.xyzToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) Hsl {
    return conversions.xyzToHsl(self);
}

pub fn toHsv(self: Self) Hsv {
    return conversions.xyzToHsv(self);
}

pub fn toLab(self: Self) Lab {
    return conversions.xyzToLab(self);
}

pub fn toLms(self: Self) Lms {
    return conversions.xyzToLms(self);
}

pub fn toOklab(self: Self) Oklab {
    return conversions.xyzToOklab(self);
}

pub fn toXyb(self: Self) Xyb {
    return conversions.xyzToXyb(self);
}
