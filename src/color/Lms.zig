//! A color in the [LMS color space](https://en.wikipedia.org/wiki/LMS_color_space).
//! Represents the response of the three types of cones (Long, Medium, Short wavelength) in the human eye.
//! Values are typically positive and represent the stimulus for each cone type.

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
m: f64,
s: f64,

pub const black: @This() = .{ .l = 0, .m = 0, .s = 0 };

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

/// Converts LMS cone response to RGB color space.
pub fn toRgb(self: Self) Rgb {
    return conversions.lmsToRgb(self);
}

/// Converts LMS to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts LMS to HSL color space using direct conversion.
pub fn toHsl(self: Self) Hsl {
    return conversions.lmsToHsl(self);
}

/// Converts LMS to HSV color space using direct conversion.
pub fn toHsv(self: Self) Hsv {
    return conversions.lmsToHsv(self);
}

/// Converts LMS cone response to CIE XYZ color space using direct conversion.
pub fn toXyz(self: Self) Xyz {
    return conversions.lmsToXyz(self);
}

/// Converts LMS to CIELAB color space using direct conversion.
pub fn toLab(self: Self) Lab {
    return conversions.lmsToLab(self);
}

/// Converts LMS to Oklab color space using direct conversion.
pub fn toOklab(self: Self) Oklab {
    return conversions.lmsToOklab(self);
}

/// Converts LMS to XYB color space using direct conversion.
pub fn toXyb(self: Self) Xyb {
    return conversions.lmsToXyb(self);
}

/// Alpha blends the given RGBA color onto this LMS color in-place.
pub fn blend(self: *Self, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toLms();
}
