//! A color in the [CIELAB color space](https://en.wikipedia.org/wiki/CIELAB_color_space) (also known as L*a*b*).
//! It expresses color as three values:
//! - l: Lightness (0 for black to 100 for white).
//! - a: Green-red axis (-128 for green to +127 for red).
//! - b: Blue-yellow axis (-128 for blue to +127 for yellow).

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

/// Converts CIELAB to RGB color space.
pub fn toRgb(self: Self) Rgb {
    return conversions.labToRgb(self);
}

/// Converts CIELAB to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts CIELAB to HSL color space using direct conversion.
pub fn toHsl(self: Self) Hsl {
    return conversions.labToHsl(self);
}

/// Converts CIELAB to HSV color space via RGB intermediate conversion.
pub fn toHsv(self: Self) Hsv {
    return self.toRgb().toHsv();
}

/// Converts CIELAB to CIE XYZ color space via RGB intermediate conversion.
pub fn toXyz(self: Self) Xyz {
    return conversions.labToRgb(self).toXyz();
}

/// Converts CIELAB to LMS cone response via XYZ intermediate conversion.
pub fn toLms(self: Self) Lms {
    return self.toXyz().toLms();
}

/// Converts CIELAB to Oklab via LMS intermediate conversion.
pub fn toOklab(self: Self) Oklab {
    return self.toLms().toOklab();
}

/// Converts CIELAB to XYB via LMS intermediate conversion.
pub fn toXyb(self: Self) Xyb {
    return self.toLms().toXyb();
}

/// Alpha blends the given RGBA color onto this CIELAB color in-place.
pub fn blend(self: *Self, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toLab();
}
