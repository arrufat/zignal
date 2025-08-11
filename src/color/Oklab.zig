//! A color in the [Oklab color space](https://bottosson.github.io/posts/oklab/).
//! Oklab is designed to be a perceptually uniform color space.
//! - l: Perceived lightness (0 for black to approximately 1 for white).
//! - a: Green-red axis (negative values towards green, positive towards red, typically around -0.4 to 0.4).
//! - b: Blue-yellow axis (negative values towards blue, positive towards yellow, typically around -0.4 to 0.4).

const std = @import("std");

const BlendMode = @import("blending.zig").BlendMode;
const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lch = @import("Lch.zig");
const Lms = @import("Lms.zig");
const Oklch = @import("Oklch.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");
const Ycbcr = @import("Ycbcr.zig");

l: f64,
a: f64,
b: f64,

const Oklab = @This();

pub const black: Oklab = .{ .l = 0, .a = 0, .b = 0 };

/// Formats the Oklab color for display. Use "color" format for ANSI color output.
/// Default formatting with ANSI color output
pub fn format(self: Oklab, writer: *std.Io.Writer) !void {
    return formatting.formatColor(Oklab, self, writer);
}

/// Returns true if both a and b components are 0 (neutral gray).
pub fn isGray(self: Oklab) bool {
    return self.a == 0 and self.b == 0;
}

/// Converts to grayscale using the L (lightness) component.
pub fn toGray(self: Oklab) u8 {
    return @intFromFloat(@round(@max(0, @min(1, self.l)) * 255));
}

/// Converts Oklab to RGB color space.
pub fn toRgb(self: Oklab) Rgb {
    return conversions.oklabToRgb(self);
}

/// Converts Oklab to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Oklab, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts Oklab to HSL color space using direct conversion.
pub fn toHsl(self: Oklab) Hsl {
    return conversions.oklabToHsl(self);
}

/// Converts Oklab to HSV color space using direct conversion.
pub fn toHsv(self: Oklab) Hsv {
    return conversions.oklabToHsv(self);
}

/// Converts Oklab to CIE XYZ color space using direct conversion.
pub fn toXyz(self: Oklab) Xyz {
    return conversions.oklabToXyz(self);
}

/// Converts Oklab to CIELAB color space using direct conversion.
pub fn toLab(self: Oklab) Lab {
    return conversions.oklabToLab(self);
}

/// Converts Oklab to LCh color space via Lab intermediate conversion.
pub fn toLch(self: Oklab) Lch {
    return self.toLab().toLch();
}

/// Converts Oklab to LMS cone response using direct conversion.
pub fn toLms(self: Oklab) Lms {
    return conversions.oklabToLms(self);
}

/// Converts Oklab to Oklch (cylindrical representation).
pub fn toOklch(self: Oklab) Oklch {
    return conversions.oklabToOklch(self);
}

/// Converts Oklab to XYB color space using direct conversion.
pub fn toXyb(self: Oklab) Xyb {
    return conversions.oklabToXyb(self);
}

/// Converts Oklab to YCbCr via RGB.
pub fn toYcbcr(self: Oklab) Ycbcr {
    return self.toRgb().toYcbcr();
}

/// Alpha blends the given RGBA color onto this Oklab color and returns the result.
pub fn blend(self: Oklab, overlay: Rgba, mode: BlendMode) Oklab {
    return self.toRgb().blend(overlay, mode).toOklab();
}
