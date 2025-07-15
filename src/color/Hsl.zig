//! A color in the [HSL](https://en.wikipedia.org/wiki/HSL_and_HSV) colorspace.
//! - h: Hue, in degrees (0-360, though often normalized to 0-359).
//! - s: Saturation, as a percentage (0-100).
//! - l: Lightness, as a percentage (0-100).

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lch = @import("Lch.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Oklch = @import("Oklch.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");
const Ycbcr = @import("Ycbcr.zig");

h: f64,
s: f64,
l: f64,

const Hsl = @This();

pub const black: Hsl = .{ .h = 0, .s = 0, .l = 0 };
pub const white: Hsl = .{ .h = 0, .s = 0, .l = 100 };

/// Default formatting with ANSI color output
pub fn format(self: Hsl, writer: *std.Io.Writer) !void {
    return formatting.formatColor(Hsl, self, writer);
}

/// Returns true if saturation is 0 (grayscale).
pub fn isGray(self: Hsl) bool {
    return self.s == 0;
}

/// Converts to grayscale using the lightness component.
pub fn toGray(self: Hsl) u8 {
    return @intFromFloat(@round(self.l / 100 * 255));
}

/// Converts HSL to RGB color space.
pub fn toRgb(self: Hsl) Rgb {
    return conversions.hslToRgb(self);
}

/// Converts HSL to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Hsl, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts HSL to HSV color space via RGB intermediate conversion.
pub fn toHsv(self: Hsl) Hsv {
    return self.toRgb().toHsv();
}

/// Converts HSL to CIE XYZ color space via RGB intermediate conversion.
pub fn toXyz(self: Hsl) Xyz {
    return self.toRgb().toXyz();
}

/// Converts HSL to CIELAB color space using direct conversion.
pub fn toLab(self: Hsl) Lab {
    return conversions.hslToLab(self);
}

/// Converts HSL to LCh via Lab intermediate conversion.
pub fn toLch(self: Hsl) Lch {
    return self.toLab().toLch();
}

/// Converts HSL to LMS cone response via RGB intermediate conversion.
pub fn toLms(self: Hsl) Lms {
    return self.toRgb().toLms();
}

/// Converts HSL to Oklab via RGB intermediate conversion.
pub fn toOklab(self: Hsl) Oklab {
    return self.toRgb().toOklab();
}

/// Converts HSL to Oklch via RGB intermediate conversion.
pub fn toOklch(self: Hsl) Oklch {
    return self.toRgb().toOklch();
}

/// Converts HSL to XYB via RGB intermediate conversion.
pub fn toXyb(self: Hsl) Xyb {
    return self.toRgb().toXyb();
}

/// Converts HSL to YCbCr via RGB.
pub fn toYcbcr(self: Hsl) Ycbcr {
    return self.toRgb().toYcbcr();
}

/// Alpha blends the given RGBA color onto this HSL color in-place.
pub fn blend(self: *Hsl, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toHsl();
}
