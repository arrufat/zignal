//! A color in the [LMS color space](https://en.wikipedia.org/wiki/LMS_color_space).
//! Represents the response of the three types of cones (Long, Medium, Short wavelength) in the human eye.
//! Values are typically positive and represent the stimulus for each cone type.

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Oklab = @import("Oklab.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");

l: f64,
m: f64,
s: f64,

const Lms = @This();

pub const black: Lms = .{ .l = 0, .m = 0, .s = 0 };

/// Formats the LMS color for display. Use "color" format for ANSI color output.
pub fn format(self: Lms, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Lms, self, fmt, options, writer);
}

/// Returns true if the color represents a neutral gray (via Oklab a*=0, b*=0).
pub fn isGray(self: Lms) bool {
    const oklab = self.toOklab();
    return oklab.a == 0 and oklab.b == 0;
}

/// Converts to grayscale using Oklab lightness for perceptual accuracy.
pub fn toGray(self: Lms) u8 {
    return @intFromFloat(@round(@max(0, @min(1, self.toOklab().l)) * 255));
}

/// Converts LMS cone response to RGB color space.
pub fn toRgb(self: Lms) Rgb {
    return conversions.lmsToRgb(self);
}

/// Converts LMS to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Lms, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts LMS to HSL color space using direct conversion.
pub fn toHsl(self: Lms) Hsl {
    return conversions.lmsToHsl(self);
}

/// Converts LMS to HSV color space using direct conversion.
pub fn toHsv(self: Lms) Hsv {
    return conversions.lmsToHsv(self);
}

/// Converts LMS cone response to CIE XYZ color space using direct conversion.
pub fn toXyz(self: Lms) Xyz {
    return conversions.lmsToXyz(self);
}

/// Converts LMS to CIELAB color space using direct conversion.
pub fn toLab(self: Lms) Lab {
    return conversions.lmsToLab(self);
}

/// Converts LMS to Oklab color space using direct conversion.
pub fn toOklab(self: Lms) Oklab {
    return conversions.lmsToOklab(self);
}

/// Converts LMS to XYB color space using direct conversion.
pub fn toXyb(self: Lms) Xyb {
    return conversions.lmsToXyb(self);
}

/// Alpha blends the given RGBA color onto this LMS color in-place.
pub fn blend(self: *Lms, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toLms();
}
