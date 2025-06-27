//! A color in the [HSV](https://en.wikipedia.org/wiki/HSL_and_HSV) colorspace.
//! - h: Hue, in degrees (0-360, though often normalized to 0-359).
//! - s: Saturation, as a percentage (0-100).
//! - v: Value, as a percentage (0-100).

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

h: f64,
s: f64,
v: f64,

pub const black: @This() = .{ .h = 0, .s = 0, .v = 0 };
pub const white: @This() = .{ .h = 0, .s = 0, .v = 100 };

const Self = @This();

/// Formats the HSV color for display. Use "color" format for ANSI color output.
pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

/// Returns true if saturation is 0 (grayscale).
pub fn isGray(self: Self) bool {
    return self.s == 0;
}

/// Converts to grayscale using the value component.
pub fn toGray(self: Self) u8 {
    return @intFromFloat(@round(self.v / 100 * 255));
}

/// Converts HSV to RGB color space.
pub fn toRgb(self: Self) Rgb {
    return conversions.hsvToRgb(self);
}

/// Converts HSV to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts HSV to HSL color space using direct conversion.
pub fn toHsl(self: Self) Hsl {
    return conversions.hsvToHsl(self);
}

/// Converts HSV to CIE XYZ color space via RGB intermediate conversion.
pub fn toXyz(self: Self) Xyz {
    return self.toRgb().toXyz();
}

/// Converts HSV to CIELAB color space using direct conversion.
pub fn toLab(self: Self) Lab {
    return conversions.hsvToLab(self);
}

/// Converts HSV to LMS cone response via RGB intermediate conversion.
pub fn toLms(self: Self) Lms {
    return self.toRgb().toLms();
}

/// Converts HSV to Oklab via RGB intermediate conversion.
pub fn toOklab(self: Self) Oklab {
    return self.toRgb().toOklab();
}

/// Converts HSV to XYB via RGB intermediate conversion.
pub fn toXyb(self: Self) Xyb {
    return self.toRgb().toXyb();
}

/// Alpha blends the given RGBA color onto this HSV color in-place.
pub fn blend(self: *Self, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toHsv();
}
