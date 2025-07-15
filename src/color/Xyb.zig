//! A color in the [XYB color space](https://jpeg.org/jpegxl/documentation/xl-color-management.html#xyb)
//! used in JPEG XL. It's derived from LMS and designed for efficient image compression.
//! - x: X component (L-M, red-green opponent channel).
//! - y: Y component (L+M, luminance-like channel).
//! - b: B component (S, blue-yellow like channel, but often scaled S cone response).
//! Ranges can vary based on transformations, but often centered around 0 for x and b, and positive for y.

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Oklch = @import("Oklch.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyz = @import("Xyz.zig");
const Ycbcr = @import("Ycbcr.zig");

x: f64,
y: f64,
b: f64,

const Xyb = @This();

pub const black: Xyb = .{ .x = 0, .y = 0, .b = 0 };

/// Formats the XYB color for display. Use "color" format for ANSI color output.
/// Default formatting with ANSI color output
pub fn format(self: Xyb, writer: *std.Io.Writer) !void {
    return formatting.formatColor(Xyb, self, writer);
}

/// Returns true if the color represents a neutral gray (via Oklab a=0, b=0).
pub fn isGray(self: Xyb) bool {
    const oklab = self.toOklab();
    return oklab.a == 0 and oklab.b == 0;
}

/// Converts to grayscale using Oklab lightness for perceptual accuracy.
pub fn toGray(self: Xyb) u8 {
    return @intFromFloat(@round(@max(0, @min(1, self.toOklab().l)) * 255));
}

/// Converts XYB to RGB color space.
pub fn toRgb(self: Xyb) Rgb {
    return conversions.xybToRgb(self);
}

/// Converts XYB to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Xyb, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts XYB to HSL color space using direct conversion.
pub fn toHsl(self: Xyb) Hsl {
    return conversions.xybToHsl(self);
}

/// Converts XYB to HSV color space using direct conversion.
pub fn toHsv(self: Xyb) Hsv {
    return conversions.xybToHsv(self);
}

/// Converts XYB to CIE XYZ color space using direct conversion.
pub fn toXyz(self: Xyb) Xyz {
    return conversions.xybToXyz(self);
}

/// Converts XYB to CIELAB color space using direct conversion.
pub fn toLab(self: Xyb) Lab {
    return conversions.xybToLab(self);
}

/// Converts XYB to LMS cone response using direct conversion.
pub fn toLms(self: Xyb) Lms {
    return conversions.xybToLms(self);
}

/// Converts XYB to Oklab color space using direct conversion.
pub fn toOklab(self: Xyb) Oklab {
    return conversions.xybToOklab(self);
}

/// Converts XYB to Oklch via Oklab intermediate conversion.
pub fn toOklch(self: Xyb) Oklch {
    return self.toOklab().toOklch();
}

/// Converts XYB to YCbCr via RGB.
pub fn toYcbcr(self: Xyb) Ycbcr {
    return self.toRgb().toYcbcr();
}

/// Alpha blends the given RGBA color onto this XYB color in-place.
pub fn blend(self: *Xyb, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toXyb();
}
