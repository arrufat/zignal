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
const Lch = @import("Lch.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Oklch = @import("Oklch.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");
const Ycbcr = @import("Ycbcr.zig");

l: f64,
a: f64,
b: f64,

const Lab = @This();

pub const black: Lab = .{ .l = 0, .a = 0, .b = 0 };
pub const white: Lab = .{ .l = 100, .a = 0, .b = 0 };

/// Default formatting with ANSI color output
pub fn format(self: Lab, writer: *std.Io.Writer) !void {
    return formatting.formatColor(Lab, self, writer);
}

/// Returns true if both a* and b* components are 0 (neutral gray).
pub fn isGray(self: Lab) bool {
    return self.a == 0 and self.b == 0;
}

/// Converts to grayscale using the L* (lightness) component.
pub fn toGray(self: Lab) u8 {
    return @intFromFloat(@round(self.l / 100 * 255));
}

/// Converts CIELAB to RGB color space.
pub fn toRgb(self: Lab) Rgb {
    return conversions.labToRgb(self);
}

/// Converts CIELAB to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Lab, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts CIELAB to HSL color space using direct conversion.
pub fn toHsl(self: Lab) Hsl {
    return conversions.labToHsl(self);
}

/// Converts CIELAB to HSV color space via RGB intermediate conversion.
pub fn toHsv(self: Lab) Hsv {
    return self.toRgb().toHsv();
}

/// Converts CIELAB to CIE XYZ color space via RGB intermediate conversion.
pub fn toXyz(self: Lab) Xyz {
    return conversions.labToRgb(self).toXyz();
}

/// Converts CIELAB to LMS cone response via XYZ intermediate conversion.
pub fn toLms(self: Lab) Lms {
    return self.toXyz().toLms();
}

/// Converts CIELAB to Oklab via LMS intermediate conversion.
pub fn toOklab(self: Lab) Oklab {
    return self.toLms().toOklab();
}

/// Converts CIELAB to Oklch via Oklab intermediate conversion.
pub fn toOklch(self: Lab) Oklch {
    return self.toOklab().toOklch();
}

/// Converts CIELAB to XYB via LMS intermediate conversion.
pub fn toXyb(self: Lab) Xyb {
    return self.toLms().toXyb();
}

/// Converts CIELAB to YCbCr via RGB.
pub fn toYcbcr(self: Lab) Ycbcr {
    return self.toRgb().toYcbcr();
}

/// Converts CIELAB to LCh (cylindrical representation).
pub fn toLch(self: Lab) Lch {
    return conversions.labToLch(self);
}

/// Alpha blends the given RGBA color onto this CIELAB color in-place.
pub fn blend(self: *Lab, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toLab();
}
