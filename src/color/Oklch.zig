//! A color in the [Oklch color space](https://en.wikipedia.org/wiki/Oklab_color_space).
//! Oklch is the cylindrical representation of the Oklab color space.
//! - l: Perceived lightness (0 for black to approximately 1 for white).
//! - c: Chroma (chromatic intensity) (0 for achromatic to approximately 0.5 for pure colors).
//! - h: Hue angle in degrees (0-360).

const std = @import("std");

const BlendMode = @import("blending.zig").BlendMode;
const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lch = @import("Lch.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");
const Ycbcr = @import("Ycbcr.zig");

l: f64,
c: f64,
h: f64,

const Oklch = @This();

pub const black: Oklch = .{ .l = 0, .c = 0, .h = 0 };

/// Formats the Oklch color for display. Use "color" format for ANSI color output.
/// Default formatting with ANSI color output
pub fn format(self: Oklch, writer: *std.Io.Writer) !void {
    return formatting.formatColor(Oklch, self, writer);
}

/// Returns true if chroma is 0 (neutral gray).
pub fn isGray(self: Oklch) bool {
    return self.c == 0;
}

/// Converts to grayscale using proper RGB luminance calculation.
pub fn toGray(self: Oklch) u8 {
    return self.toRgb().toGray();
}

/// Converts Oklch to Oklab color space.
pub fn toOklab(self: Oklch) Oklab {
    return conversions.oklchToOklab(self);
}

/// Converts Oklch to RGB color space.
pub fn toRgb(self: Oklch) Rgb {
    return conversions.oklchToRgb(self);
}

/// Converts Oklch to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Oklch, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts Oklch to HSL color space via RGB intermediate conversion.
pub fn toHsl(self: Oklch) Hsl {
    return conversions.oklchToHsl(self);
}

/// Converts Oklch to HSV color space via RGB intermediate conversion.
pub fn toHsv(self: Oklch) Hsv {
    return conversions.oklchToHsv(self);
}

/// Converts Oklch to CIE XYZ color space via Oklab intermediate conversion.
pub fn toXyz(self: Oklch) Xyz {
    return conversions.oklchToXyz(self);
}

/// Converts Oklch to CIELAB color space via Oklab intermediate conversion.
pub fn toLab(self: Oklch) Lab {
    return conversions.oklchToLab(self);
}

/// Converts Oklch to LCh color space via Lab intermediate conversion.
pub fn toLch(self: Oklch) Lch {
    return self.toLab().toLch();
}

/// Converts Oklch to LMS cone response via Oklab intermediate conversion.
pub fn toLms(self: Oklch) Lms {
    return conversions.oklchToLms(self);
}

/// Converts Oklch to XYB color space via Oklab intermediate conversion.
pub fn toXyb(self: Oklch) Xyb {
    return conversions.oklchToXyb(self);
}

/// Converts Oklch to YCbCr via RGB.
pub fn toYcbcr(self: Oklch) Ycbcr {
    return self.toRgb().toYcbcr();
}

/// Alpha blends the given RGBA color onto this Oklch color and returns the result.
pub fn blend(self: Oklch, overlay: Rgba, mode: BlendMode) Oklch {
    return self.toRgb().blend(overlay, mode).toOklch();
}
