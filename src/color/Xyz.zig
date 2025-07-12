//! A color in the [CIE 1931 XYZ color space](https://en.wikipedia.org/wiki/CIE_1931_color_space).
//! This is a device-independent space that covers the full gamut of human-perceptible colors
//! visible to the CIE 2° standard observer.
//! - x, y, z: Tristimulus values, typically non-negative. Y represents luminance.
//!   The typical range for these values can vary depending on the reference white point (e.g. D65).
//!   Often, Y is normalized to 100 for white.

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
const Ycbcr = @import("Ycbcr.zig");

x: f64,
y: f64,
z: f64,

const Self = @This();

pub const black: Self = .{ .x = 0, .y = 0, .z = 0 };

/// Formats the CIE XYZ color for display. Use "color" format for ANSI color output.
pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

/// Returns true if the color represents a neutral gray (via RGB conversion).
pub fn isGray(self: Self) bool {
    return self.toRgb().isGray();
}

/// Converts to grayscale via Lab lightness component for accuracy.
pub fn toGray(self: Self) u8 {
    return self.toLab().toGray();
}

/// Converts CIE XYZ to RGB color space.
pub fn toRgb(self: Self) Rgb {
    return conversions.xyzToRgb(self);
}

/// Converts CIE XYZ to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts CIE XYZ to HSL color space using direct conversion.
pub fn toHsl(self: Self) Hsl {
    return conversions.xyzToHsl(self);
}

/// Converts CIE XYZ to HSV color space using direct conversion.
pub fn toHsv(self: Self) Hsv {
    return conversions.xyzToHsv(self);
}

/// Converts CIE XYZ to CIELAB color space using direct conversion.
pub fn toLab(self: Self) Lab {
    return conversions.xyzToLab(self);
}

/// Converts CIE XYZ to LMS cone response space using direct conversion.
pub fn toLms(self: Self) Lms {
    return conversions.xyzToLms(self);
}

/// Converts CIE XYZ to Oklab color space using direct conversion.
pub fn toOklab(self: Self) Oklab {
    return conversions.xyzToOklab(self);
}

/// Converts CIE XYZ to XYB color space using direct conversion.
pub fn toXyb(self: Self) Xyb {
    return conversions.xyzToXyb(self);
}

/// Converts CIE XYZ to YCbCr via RGB.
pub fn toYcbcr(self: Self) Ycbcr {
    return self.toRgb().toYcbcr();
}
